#!/usr/bin/env python3
"""
trino_bench_compare-v2.py

같은 쿼리를 여러 번 실행한 TPC-H 벤치마크 결과(Trino QueryInfo/Statement stats JSON)를
분석한다. run-to-run 분포·안정성을 먼저 보고, 그 위에서 버전(478 vs 481 등)을 비교한다.

핵심 기능
  1) 반복 실행 분석   : (버전,쿼리)별 run 분포 — n, min, median, mean, max, stdev, CV, p95
  2) 워밍업 감지      : 첫 run 이 나머지보다 느린 콜드캐시 효과를 탐지 (--warmup 으로 제외)
  3) 이상치 탐지      : 수정 z-score(MAD 기반)로 튀는 run 표시
  4) 집계 방식 선택   : --agg median|mean|trimmed|min  (대표값 산출 방식)
  5) 버전 비교        : 쿼리별 speedup + 차이가 "노이즈 범위인지" 판정, 기하평균, 회귀 탐지
  6) 스키마 자동감지  : 서버 QueryStats / 클라이언트 StatementStats 모두 지원

입력 디렉터리 구조
  results/
    478/  q01_run1.json  q01_run2.json  ...  q22_run5.json
    481/  q01_run1.json  ...

파일명에서 쿼리 라벨(--query-regex)과 run 번호(--run-regex)를 뽑는다.
run 번호로 실행 순서를 정렬해 워밍업을 판단한다.

사용 예
  python3 trino_bench_compare.py results/ --baseline 478
  python3 trino_bench_compare.py results/ --warmup 1 --agg median --csv out.csv
  python3 trino_bench_compare.py results/478 --single   # 한 버전 반복 분석만
"""

import argparse
import csv
import json
import math
import os
import re
import statistics
import sys
from collections import defaultdict

# ===========================================================================
# 단위 파싱 (서버 QueryStats 는 "12.3s"/"1.2GB" 문자열, 클라이언트 StatementStats 는 숫자)
# ===========================================================================

_DURATION_UNITS = {
    "ns": 1e-6, "us": 1e-3, "µs": 1e-3, "ms": 1.0,
    "s": 1000.0, "m": 60_000.0, "h": 3_600_000.0, "d": 86_400_000.0,
}
_DURATION_RE = re.compile(r"^\s*([0-9]*\.?[0-9]+)\s*(ns|µs|us|ms|d|h|m|s)\s*$")

_SIZE_UNITS = {"B": 1, "kB": 1024, "MB": 1024**2, "GB": 1024**3,
               "TB": 1024**4, "PB": 1024**5}
_SIZE_RE = re.compile(r"^\s*([0-9]*\.?[0-9]+)\s*(B|kB|MB|GB|TB|PB)\s*$")


def parse_duration_ms(value):
    if value is None:
        return None
    if isinstance(value, (int, float)):
        return float(value)          # 클라이언트 stats 는 ms 숫자
    m = _DURATION_RE.match(str(value))
    return float(m.group(1)) * _DURATION_UNITS[m.group(2)] if m else None


def parse_size_bytes(value):
    if value is None:
        return None
    if isinstance(value, (int, float)):
        return float(value)          # 클라이언트 stats 는 bytes 숫자
    m = _SIZE_RE.match(str(value))
    return float(m.group(1)) * _SIZE_UNITS[m.group(2)] if m else None


def parse_int(value):
    if value is None:
        return None
    try:
        return int(value)
    except (ValueError, TypeError):
        return None


# ===========================================================================
# 스키마 감지 + stats 블록 추출
# ===========================================================================

_QUERYSTATS_MARKERS = ("totalCpuTime", "peakTotalMemoryReservation", "elapsedTime")
_STATEMENTSTATS_MARKERS = ("cpuTimeMillis", "wallTimeMillis", "elapsedTimeMillis")


def _looks_like_stats(d):
    if not isinstance(d, dict):
        return None
    if any(k in d for k in _STATEMENTSTATS_MARKERS):
        return "statement"
    if any(k in d for k in _QUERYSTATS_MARKERS):
        return "query"
    return None


def find_query_stats(obj):
    """JSON 어디에 있든 stats 를 찾아 (stats_dict, schema) 반환."""
    if not isinstance(obj, dict):
        return None, None
    for key in ("queryStats", "stats"):
        if isinstance(obj.get(key), dict):
            schema = _looks_like_stats(obj[key])
            if schema:
                return obj[key], schema
    schema = _looks_like_stats(obj)
    if schema:
        return obj, schema
    for key in ("query", "queryInfo", "info", "result"):
        if isinstance(obj.get(key), dict):
            found, schema = find_query_stats(obj[key])
            if found:
                return found, schema
    return None, None


# 지표: 출력이름 -> ( {스키마: 키}, 파서, kind )
METRIC_DEFS = {
    "elapsed":        ({"query": "elapsedTime",                "statement": "elapsedTimeMillis"},  parse_duration_ms, "time"),
    "queued":         ({"query": "queuedTime",                 "statement": "queuedTimeMillis"},   parse_duration_ms, "time"),
    "analysis":       ({"query": "analysisTime",               "statement": "analysisTimeMillis"}, parse_duration_ms, "time"),
    "planning":       ({"query": "planningTime",               "statement": "planningTimeMillis"}, parse_duration_ms, "time"),
    "cpu":            ({"query": "totalCpuTime",               "statement": "cpuTimeMillis"},      parse_duration_ms, "time"),
    "wall_tasks":     ({"query": "totalScheduledTime",         "statement": "wallTimeMillis"},     parse_duration_ms, "time"),
    "peak_mem":       ({"query": "peakTotalMemoryReservation", "statement": "peakMemoryBytes"},    parse_size_bytes,  "size"),
    "peak_user_mem":  ({"query": "peakUserMemoryReservation",  "statement": None},                 parse_size_bytes,  "size"),
    "physical_input": ({"query": "physicalInputDataSize",      "statement": "physicalInputBytes"}, parse_size_bytes,  "size"),
    "processed_bytes":({"query": "processedInputDataSize",     "statement": "processedBytes"},     parse_size_bytes,  "size"),
    "processed_rows": ({"query": "processedInputPositions",    "statement": "processedRows"},      parse_int,         "count"),
    "spilled":        ({"query": "spilledDataSize",            "statement": "spilledBytes"},        parse_size_bytes,  "size"),
    "output_rows":    ({"query": "outputPositions",            "statement": None},                 parse_int,         "count"),
    "total_splits":   ({"query": "totalDrivers",               "statement": "totalSplits"},        parse_int,         "count"),
}
METRIC_KIND = {name: kind for name, (_k, _p, kind) in METRIC_DEFS.items()}
METRIC_KIND["wall_minus_queued"] = "time"
ALL_METRICS = list(METRIC_DEFS.keys()) + ["wall_minus_queued"]


def extract_metrics(stats, schema):
    out = {}
    for name, (keys, parser, _kind) in METRIC_DEFS.items():
        key = keys.get(schema)
        out[name] = parser(stats.get(key)) if key else None
    if out.get("elapsed") is not None and out.get("queued") is not None:
        out["wall_minus_queued"] = max(out["elapsed"] - out["queued"], 0.0)
    else:
        out["wall_minus_queued"] = out.get("elapsed")
    return out


# ===========================================================================
# 결과 파일 수집 (run 번호로 실행 순서 보존)
# ===========================================================================

def discover_runs(root, query_regex, run_regex):
    """
    data[version][query] = [ (run_no, {지표..}), ... ]  (run_no 오름차순 정렬)
    """
    qre = re.compile(query_regex, re.IGNORECASE)
    rre = re.compile(run_regex, re.IGNORECASE) if run_regex else None
    data = defaultdict(lambda: defaultdict(list))
    skipped = []
    schemas_seen = set()

    for version in sorted(os.listdir(root)):
        vpath = os.path.join(root, version)
        if not os.path.isdir(vpath):
            continue
        seq = 0
        for fname in sorted(os.listdir(vpath)):
            if not fname.lower().endswith(".json"):
                continue
            qm = qre.search(fname)
            if not qm:
                skipped.append(f"{version}/{fname} (쿼리 라벨 추출 실패)")
                continue
            qlabel = qm.group("q").lower()
            # run 번호: 정규식 우선, 없으면 등장 순서
            run_no = None
            if rre:
                rm = rre.search(fname)
                if rm:
                    try:
                        run_no = int(rm.group("run"))
                    except (IndexError, ValueError):
                        run_no = None
            if run_no is None:
                seq += 1
                run_no = seq
            fpath = os.path.join(vpath, fname)
            try:
                with open(fpath, "r", encoding="utf-8") as f:
                    obj = json.load(f)
            except (json.JSONDecodeError, OSError) as e:
                skipped.append(f"{version}/{fname} ({e})")
                continue
            stats, schema = find_query_stats(obj)
            if stats is None:
                skipped.append(f"{version}/{fname} (stats 블록 없음)")
                continue
            schemas_seen.add(schema)
            data[version][qlabel].append((run_no, extract_metrics(stats, schema)))

    # run 번호로 정렬
    for version in data:
        for q in data[version]:
            data[version][q].sort(key=lambda t: t[0])
    return data, skipped, schemas_seen


# ===========================================================================
# 반복 실행 통계
# ===========================================================================

def percentile(sorted_vals, p):
    if not sorted_vals:
        return None
    if len(sorted_vals) == 1:
        return sorted_vals[0]
    k = (len(sorted_vals) - 1) * p
    lo = math.floor(k)
    hi = math.ceil(k)
    if lo == hi:
        return sorted_vals[int(k)]
    return sorted_vals[lo] * (hi - k) + sorted_vals[hi] * (k - lo)


def detect_outliers(values):
    """수정 z-score(MAD 기반)로 이상치 인덱스 반환. n<4 면 빈 목록."""
    if len(values) < 4:
        return []
    med = statistics.median(values)
    devs = [abs(v - med) for v in values]
    mad = statistics.median(devs)
    if mad == 0:
        return []
    out = []
    for i, v in enumerate(values):
        mz = 0.6745 * (v - med) / mad
        if abs(mz) > 3.5:
            out.append(i)
    return out


def aggregate_value(values, how):
    """대표값 산출: median|mean|trimmed|min."""
    vals = [v for v in values if v is not None]
    if not vals:
        return None
    if how == "min":
        return min(vals)
    if how == "mean":
        return statistics.fmean(vals)
    if how == "trimmed" and len(vals) >= 4:
        s = sorted(vals)
        return statistics.fmean(s[1:-1])   # 최소/최대 1개씩 절삭
    return statistics.median(vals)          # 기본


def analyze_repeats(runs, metric, warmup, agg_how):
    """
    runs: [(run_no, metrics_dict), ...] (정렬됨)
    metric 한 지표에 대한 반복 분석 결과를 dict 로 반환.
    """
    ordered = [m.get(metric) for _rn, m in runs]      # 실행 순서대로의 값
    ordered = [v for v in ordered if v is not None]
    res = {"n_total": len(ordered)}
    if not ordered:
        return None

    # 워밍업 효과: 첫 run vs 나머지 중앙값
    if len(ordered) >= 2:
        rest_med = statistics.median(ordered[1:])
        res["warmup_ratio"] = (ordered[0] / rest_med) if rest_med > 0 else None
    else:
        res["warmup_ratio"] = None

    # 워밍업 제외
    used = ordered[warmup:] if warmup < len(ordered) else ordered
    res["n_used"] = len(used)
    s = sorted(used)
    res["min"] = s[0]
    res["max"] = s[-1]
    res["median"] = statistics.median(used)
    res["mean"] = statistics.fmean(used)
    res["p95"] = percentile(s, 0.95)
    if len(used) >= 2 and res["mean"] > 0:
        res["stdev"] = statistics.stdev(used)
        res["cv"] = res["stdev"] / res["mean"]
    else:
        res["stdev"] = 0.0
        res["cv"] = 0.0
    res["outliers"] = len(detect_outliers(used))
    res["representative"] = aggregate_value(used, agg_how)
    return res


def build_analysis(data, metric, warmup, agg_how):
    """
    analysis[version][query] = {지표별 분석..., '_secondary': {보조지표 대표값}}
    """
    analysis = defaultdict(dict)
    for version, queries in data.items():
        for q, runs in queries.items():
            entry = analyze_repeats(runs, metric, warmup, agg_how)
            if entry is None:
                continue
            # 보조 지표 대표값 (워밍업 동일 적용)
            sec = {}
            for m in ("cpu", "peak_mem", "spilled", "physical_input"):
                vals = [d.get(m) for _rn, d in runs]
                vals = [v for v in vals if v is not None]
                used = vals[warmup:] if warmup < len(vals) else vals
                sec[m] = aggregate_value(used, agg_how) if used else None
            entry["_secondary"] = sec
            analysis[version][q] = entry
    return analysis


# ===========================================================================
# 포맷터
# ===========================================================================

def fmt_ms(v):
    if v is None:
        return "-"
    return f"{v/1000:.2f}s" if v >= 1000 else f"{v:.0f}ms"


def fmt_bytes(v):
    if v is None:
        return "-"
    for unit in ("B", "kB", "MB", "GB", "TB"):
        if v < 1024 or unit == "TB":
            return f"{v:.1f}{unit}"
        v /= 1024


def fmt_val(v, metric):
    kind = METRIC_KIND.get(metric, "time")
    if kind == "time":
        return fmt_ms(v)
    if kind == "size":
        return fmt_bytes(v)
    return "-" if v is None else f"{v:,.0f}"


def geomean(values):
    vals = [v for v in values if v is not None and v > 0]
    if not vals:
        return None
    return math.exp(statistics.fmean([math.log(v) for v in vals]))


# ===========================================================================
# 1) 반복 실행 안정성 리포트
# ===========================================================================

def print_stability(analysis, metric, cv_warn, warmup):
    print("=" * 84)
    print(f" [1] 반복 실행 분석  (지표 = {metric}"
          + (f", 워밍업 {warmup} run 제외)" if warmup else ")"))
    print(f"     run 분포로 측정 안정성을 본다. CV(변동계수)가 작을수록 신뢰도 높음.")
    print("=" * 84)
    for version in sorted(analysis.keys()):
        print(f"\n### 버전 {version}")
        print(f"  {'query':<7}{'runs':>6}{'median':>11}{'min':>10}{'max':>10}"
              f"{'CV':>8}{'p95':>11}  flags")
        print("  " + "-" * 78)
        for q in sorted(analysis[version].keys()):
            e = analysis[version][q]
            flags = []
            if e["cv"] > cv_warn:
                flags.append(f"CV높음")
            if e.get("warmup_ratio") and e["warmup_ratio"] > 1.15 and warmup == 0:
                flags.append(f"워밍업{(e['warmup_ratio']-1)*100:.0f}%")
            if e["outliers"]:
                flags.append(f"이상치{e['outliers']}")
            runs_s = f"{e['n_used']}/{e['n_total']}" if e['n_used'] != e['n_total'] else str(e['n_total'])
            print(f"  {q:<7}{runs_s:>6}{fmt_val(e['median'],metric):>11}"
                  f"{fmt_val(e['min'],metric):>10}{fmt_val(e['max'],metric):>10}"
                  f"{e['cv']*100:>7.1f}%{fmt_val(e['p95'],metric):>11}  {' '.join(flags)}")


# ===========================================================================
# 2) 버전 비교 (노이즈 인지)
# ===========================================================================

def compare_versions(analysis, baseline, metric, regress_threshold):
    versions = sorted(analysis.keys())
    if baseline not in analysis:
        raise SystemExit(f"baseline '{baseline}' 없음. 있는 버전: {versions}")
    candidates = [v for v in versions if v != baseline]
    base_queries = sorted(analysis[baseline].keys())
    report = {"baseline": baseline, "metric": metric, "versions": {}}

    for cand in candidates:
        rows = []
        speedups = []
        base_repr, cand_repr = [], []
        regressions = []
        missing = []
        for q in base_queries:
            be = analysis[baseline].get(q)
            ce = analysis[cand].get(q)
            if not be or not ce or not be.get("representative") or not ce.get("representative"):
                missing.append(q)
                rows.append((q, None, None, None, False))
                continue
            b = be["representative"]
            c = ce["representative"]
            speedup = b / c if c > 0 else None
            # 노이즈 범위 판정: 차이가 두 분포의 합산 상대잡음보다 작으면 유의하지 않음
            noise = (be["cv"] + ce["cv"])
            significant = speedup is not None and abs(speedup - 1.0) > noise
            rows.append((q, b, c, speedup, significant))
            if speedup:
                speedups.append(speedup)
                base_repr.append(b)
                cand_repr.append(c)
                if speedup < (1.0 - regress_threshold) and significant:
                    regressions.append((q, speedup))
        report["versions"][cand] = {
            "rows": rows,
            "geomean_speedup": geomean(speedups),
            "geomean_base": geomean(base_repr),
            "geomean_cand": geomean(cand_repr),
            "regressions": regressions,
            "missing": missing,
            "n": len(speedups),
        }
    return report


def secondary_summary(analysis, baseline):
    versions = sorted(analysis.keys())
    base_queries = sorted(analysis[baseline].keys())
    metrics = ["cpu", "peak_mem", "spilled", "physical_input"]
    summary = {}
    for v in versions:
        if v == baseline:
            continue
        summary[v] = {}
        for metric in metrics:
            ratios = []
            for q in base_queries:
                b = analysis[baseline][q]["_secondary"].get(metric)
                c = analysis[v].get(q, {}).get("_secondary", {}).get(metric)
                if b and c and b > 0 and c > 0:
                    ratios.append(c / b)
            summary[v][metric] = geomean(ratios)
    return summary


def spill_summary(analysis):
    out = {}
    for v, queries in analysis.items():
        spilled = [(q, e["_secondary"].get("spilled"))
                   for q, e in queries.items()
                   if e["_secondary"].get("spilled")]
        total = sum(s for _q, s in spilled)
        out[v] = (len(spilled), sorted(q for q, _s in spilled), total)
    return out


def print_comparison(analysis, report, secondary, metric):
    baseline = report["baseline"]
    print("\n" + "=" * 84)
    print(f" [2] 버전 비교  (baseline = {baseline}, 지표 = {metric})")
    print(f"     speedup = baseline / candidate (>1 이면 candidate 가 빠름)")
    print(f"     '~' = 차이가 측정 노이즈 범위 안이라 유의하지 않음")
    print("=" * 84)
    for cand, res in report["versions"].items():
        print(f"\n### {baseline}  ->  {cand}")
        print(f"  {'query':<7}{'baseline':>11}{'candidate':>11}{'speedup':>10}  판정")
        print("  " + "-" * 54)
        for q, b, c, sp, sig in res["rows"]:
            if sp is None:
                verdict = "데이터없음"
                sp_s = "-"
            elif not sig:
                verdict = "~ 노이즈"
                sp_s = f"{sp:.3f}x"
            elif sp < 1.0:
                verdict = "느려짐"
                sp_s = f"{sp:.3f}x"
            else:
                verdict = "개선"
                sp_s = f"{sp:.3f}x"
            print(f"  {q:<7}{fmt_val(b,metric):>11}{fmt_val(c,metric):>11}{sp_s:>10}  {verdict}")
        print("  " + "-" * 54)
        gm = res["geomean_speedup"]
        if gm:
            verdict = "개선" if gm > 1.0 else ("회귀" if gm < 1.0 else "동일")
            print(f"  기하평균 speedup : {gm:.3f}x  ({(gm-1)*100:+.1f}%)  -> 종합 {verdict}")
            print(f"  기하평균 {metric}: {baseline}={fmt_val(res['geomean_base'],metric)}, "
                  f"{cand}={fmt_val(res['geomean_cand'],metric)}  (쿼리 {res['n']}개)")
        else:
            print("  기하평균 계산 불가")
        if res["regressions"]:
            print(f"  ⚠ 유의한 회귀({len(res['regressions'])}개): "
                  + ", ".join(f"{q}({sp:.2f}x)" for q, sp in res["regressions"]))
        if res["missing"]:
            print(f"  · 비교 누락: {', '.join(res['missing'])}")
        sec = secondary.get(cand, {})
        if sec:
            print("  보조 지표 기하평균 변화 (1.00 미만 = 감소=개선):")
            labels = {"cpu": "CPU time", "peak_mem": "peak memory",
                      "spilled": "spill", "physical_input": "physical input"}
            for m, label in labels.items():
                r = sec.get(m)
                print(f"    - {label:<16}: "
                      + ("데이터 없음" if r is None else f"{r:.3f}x ({(r-1)*100:+.1f}%)"))

    sp = spill_summary(analysis)
    print("\nSpill 발생 현황 (버전별):")
    for v in sorted(sp.keys()):
        n, qs, total = sp[v]
        print(f"  - {v}: " + ("spill 없음" if n == 0
              else f"{n}개 쿼리, 총 {fmt_bytes(total)}  ({', '.join(qs)})"))


# ===========================================================================
# CSV
# ===========================================================================

def write_csv(analysis, report, metric, path):
    baseline = report["baseline"]
    versions = sorted(analysis.keys())
    base_queries = sorted(analysis[baseline].keys())
    with open(path, "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        header = ["query"]
        for v in versions:
            header += [f"{v}_median", f"{v}_min", f"{v}_cv", f"{v}_runs"]
        for cand in report["versions"]:
            header.append(f"speedup_{baseline}_to_{cand}")
        w.writerow(header)
        for q in base_queries:
            row = [q]
            for v in versions:
                e = analysis[v].get(q)
                if e:
                    row += [f"{e['median']:.3f}", f"{e['min']:.3f}",
                            f"{e['cv']:.4f}", e["n_used"]]
                else:
                    row += ["", "", "", ""]
            for cand, res in report["versions"].items():
                sp = dict((r[0], r[3]) for r in res["rows"]).get(q)
                row.append(f"{sp:.4f}" if sp else "")
            w.writerow(row)


# ===========================================================================
# main
# ===========================================================================

def main():
    p = argparse.ArgumentParser(
        description="같은 쿼리를 여러 번 실행한 Trino TPC-H 결과 분석 + 버전 비교")
    p.add_argument("root", help="버전별 하위 디렉터리(또는 --single 시 단일 버전 디렉터리)")
    p.add_argument("--baseline", help="기준 버전 라벨. 미지정 시 사전순 첫 버전")
    p.add_argument("--metric", default="wall_minus_queued", choices=ALL_METRICS,
                   help="분석/비교 헤드라인 지표 (기본 wall_minus_queued)")
    p.add_argument("--query-regex", default=r"(?P<q>q\d+)",
                   help=r"파일명에서 쿼리 라벨 추출 (named group 'q', 기본 (?P<q>q\d+))")
    p.add_argument("--run-regex", default=r"run(?P<run>\d+)",
                   help=r"파일명에서 run 번호 추출 (named group 'run', 기본 run(?P<run>\d+)). "
                        r"없으면 파일 정렬 순서를 run 순서로 사용")
    p.add_argument("--warmup", type=int, default=0,
                   help="각 쿼리에서 제외할 앞쪽 워밍업 run 수 (기본 0)")
    p.add_argument("--agg", default="median", choices=["median", "mean", "trimmed", "min"],
                   help="대표값 산출 방식 (기본 median). min=완전 웜 베스트케이스")
    p.add_argument("--regress-threshold", type=float, default=0.05,
                   help="회귀 판정 speedup 하락 임계값 (기본 0.05)")
    p.add_argument("--cv-warn", type=float, default=0.10,
                   help="CV 경고 임계값 (기본 0.10 = 10%%)")
    p.add_argument("--single", action="store_true",
                   help="root 를 단일 버전 디렉터리로 보고 반복 분석만 수행")
    p.add_argument("--csv", help="결과 매트릭스 CSV 경로")
    args = p.parse_args()

    if not os.path.isdir(args.root):
        sys.exit(f"디렉터리가 아닙니다: {args.root}")

    # --single 이면 부모를 root 로, 해당 디렉터리만 버전으로 처리
    if args.single:
        parent = os.path.dirname(os.path.abspath(args.root)) or "."
        only = os.path.basename(os.path.abspath(args.root))
        data, skipped, schemas = discover_runs(parent, args.query_regex, args.run_regex)
        data = {only: data.get(only, {})}
    else:
        data, skipped, schemas = discover_runs(args.root, args.query_regex, args.run_regex)

    if not any(data.values()):
        sys.exit("결과를 찾지 못했습니다. 디렉터리 구조와 --query-regex/--run-regex 를 확인하세요.")

    schema_label = {"query": "서버 QueryStats (/v1/query)",
                    "statement": "클라이언트 StatementStats (stats)"}
    print(f"감지된 통계 스키마: {', '.join(schema_label.get(s, s) for s in sorted(schemas))}")
    if len(schemas) > 1:
        print("주의: 서로 다른 스키마가 섞였습니다. 같은 출처로 통일하세요.")

    analysis = build_analysis(data, args.metric, args.warmup, args.agg)
    if not any(analysis.values()):
        sys.exit(f"지표 '{args.metric}' 에 유효한 값이 없습니다. 다른 --metric 을 시도하세요.")

    print_stability(analysis, args.metric, args.cv_warn, args.warmup)

    versions = [v for v in analysis if analysis[v]]
    if not args.single and len(versions) >= 2:
        baseline = args.baseline or sorted(versions)[0]
        report = compare_versions(analysis, baseline, args.metric, args.regress_threshold)
        secondary = secondary_summary(analysis, baseline)
        print_comparison(analysis, report, secondary, args.metric)
        if args.csv:
            write_csv(analysis, report, args.metric, args.csv)
            print(f"\nCSV 저장됨: {args.csv}")
    else:
        print("\n(버전이 1개이거나 --single 이라 버전 비교는 생략)")

    if skipped:
        print(f"\n건너뛴 파일 {len(skipped)}개:")
        for s in skipped[:20]:
            print(f"  - {s}")


if __name__ == "__main__":
    main()
