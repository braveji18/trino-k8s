#!/usr/bin/env python3
"""
trino_bench_compare.py

Trino 서로 다른 버전의 TPC-H 벤치마크 결과(QueryInfo JSON)를 비교해서
버전별 성능 개선 여부를 계산한다.

핵심 출력
  - 쿼리별 speedup (baseline / candidate)  : 1.0 보다 크면 새 버전이 빠름
  - 22개 쿼리 실행시간의 기하평균 비교        : TPC-H Power 지표와 같은 방식
  - 회귀(regression) 자동 탐지              : 임계값보다 느려진 쿼리 표시
  - 보조 지표(CPU time, peak memory, spill, physical input) 비교

입력 디렉터리 구조 (기본 가정)
  results/
    435/                 <- 버전 라벨 (디렉터리 이름)
      q01_run1.json      <- QueryInfo JSON 1개 = 쿼리 1회 실행
      q01_run2.json
      q02_run1.json
      ...
    446/
      q01_run1.json
      ...

파일명에서 "쿼리 라벨"과 "실행 회차"를 정규식으로 뽑는다(--query-regex 로 변경 가능).
같은 (버전, 쿼리)에 여러 run이 있으면 중앙값(median)으로 집계한다.

사용 예
  python3 trino_bench_compare.py results/
  python3 trino_bench_compare.py results/ --baseline 435 --metric wall_minus_queued
  python3 trino_bench_compare.py results/ --csv out.csv
"""

import argparse
import csv
import json
import os
import re
import statistics
import sys
from collections import defaultdict

# ---------------------------------------------------------------------------
# 단위 파싱 : Trino 는 Duration/DataSize 를 "12.3s", "1.2GB" 같은 문자열로 직렬화한다.
#            (직렬화 설정에 따라 숫자(ms / bytes)로 올 수도 있어 둘 다 처리)
# ---------------------------------------------------------------------------

# Duration 단위 -> 밀리초(ms) 배수
_DURATION_UNITS = {
    "ns": 1e-6, "us": 1e-3, "µs": 1e-3, "ms": 1.0,
    "s": 1000.0, "m": 60_000.0, "h": 3_600_000.0, "d": 86_400_000.0,
}
# 더 긴 단위를 먼저 매칭하도록 정렬(ms 가 s 보다 먼저)
_DURATION_RE = re.compile(
    r"^\s*([0-9]*\.?[0-9]+)\s*(ns|µs|us|ms|d|h|m|s)\s*$"
)

# DataSize 단위 -> 바이트 배수 (Trino/airlift 는 1024 기반)
_SIZE_UNITS = {
    "B": 1, "kB": 1024, "MB": 1024**2, "GB": 1024**3,
    "TB": 1024**4, "PB": 1024**5,
}
_SIZE_RE = re.compile(
    r"^\s*([0-9]*\.?[0-9]+)\s*(B|kB|MB|GB|TB|PB)\s*$"
)


def parse_duration_ms(value):
    """Duration 값을 ms(float)로. None/파싱불가면 None."""
    if value is None:
        return None
    if isinstance(value, (int, float)):
        # 숫자로 온 경우 ms 로 가정
        return float(value)
    m = _DURATION_RE.match(str(value))
    if not m:
        return None
    return float(m.group(1)) * _DURATION_UNITS[m.group(2)]


def parse_size_bytes(value):
    """DataSize 값을 bytes(float)로. None/파싱불가면 None."""
    if value is None:
        return None
    if isinstance(value, (int, float)):
        return float(value)
    m = _SIZE_RE.match(str(value))
    if not m:
        return None
    return float(m.group(1)) * _SIZE_UNITS[m.group(2)]


def parse_int(value):
    if value is None:
        return None
    try:
        return int(value)
    except (ValueError, TypeError):
        return None


# ---------------------------------------------------------------------------
# QueryInfo JSON 에서 queryStats 찾기 + 지표 추출
# ---------------------------------------------------------------------------

# 두 스키마를 식별하는 표지 키
#  - QueryStats     : 서버 내부 (/v1/query/{queryId} 의 "queryStats")
#  - StatementStats : 클라이언트 프로토콜 (JDBC/CLI/python-client 가 주는 "stats")
_QUERYSTATS_MARKERS = ("totalCpuTime", "peakTotalMemoryReservation", "elapsedTime")
_STATEMENTSTATS_MARKERS = ("cpuTimeMillis", "wallTimeMillis", "elapsedTimeMillis")


def _looks_like_stats(d):
    """dict 가 두 스키마 중 하나의 stats 블록인지 판별 -> 'query'|'statement'|None."""
    if not isinstance(d, dict):
        return None
    if any(k in d for k in _STATEMENTSTATS_MARKERS):
        return "statement"
    if any(k in d for k in _QUERYSTATS_MARKERS):
        return "query"
    return None


def find_query_stats(obj):
    """
    JSON 어디에 stats 가 있든 찾아서 (stats_dict, schema) 를 반환.
    지원: 최상위 queryStats / stats / 객체 자체 / 흔한 래핑 키 아래.
    """
    if not isinstance(obj, dict):
        return None, None

    # 1) 명시적 키 우선
    for key in ("queryStats", "stats"):
        if isinstance(obj.get(key), dict):
            schema = _looks_like_stats(obj[key])
            if schema:
                return obj[key], schema

    # 2) 객체 자체가 stats 인 경우 (stats 만 따로 저장한 파일)
    schema = _looks_like_stats(obj)
    if schema:
        return obj, schema

    # 3) 흔한 래핑 키 아래 재귀 탐색
    for key in ("query", "queryInfo", "info", "result"):
        if isinstance(obj.get(key), dict):
            found, schema = find_query_stats(obj[key])
            if found:
                return found, schema

    return None, None


# 지표 정의: 출력이름 -> ( {스키마: JSON키}, 파서, kind )
#   query     = 서버 QueryStats 키 (단위 문자열, 예 "12.3s"/"1.2GB")
#   statement = 클라이언트 StatementStats 키 (숫자, 시간=ms / 크기=bytes)
#   파서는 숫자/문자열 양쪽을 처리하므로 동일 파서로 둘 다 커버됨.
METRIC_DEFS = {
    "elapsed":        ({"query": "elapsedTime",                "statement": "elapsedTimeMillis"},  parse_duration_ms, "time"),
    "queued":         ({"query": "queuedTime",                 "statement": "queuedTimeMillis"},   parse_duration_ms, "time"),
    "analysis":       ({"query": "analysisTime",               "statement": "analysisTimeMillis"}, parse_duration_ms, "time"),
    "planning":       ({"query": "planningTime",               "statement": "planningTimeMillis"}, parse_duration_ms, "time"),
    "cpu":            ({"query": "totalCpuTime",               "statement": "cpuTimeMillis"},      parse_duration_ms, "time"),
    # 클라이언트엔 wallTimeMillis(모든 태스크 합)이 별도로 있음 -> 참고 지표로 포함
    "wall_tasks":     ({"query": "totalScheduledTime",         "statement": "wallTimeMillis"},     parse_duration_ms, "time"),
    # 피크 메모리: 클라이언트는 단일 peakMemoryBytes. 서버는 total/user 구분.
    "peak_mem":       ({"query": "peakTotalMemoryReservation", "statement": "peakMemoryBytes"},    parse_size_bytes,  "size"),
    "peak_user_mem":  ({"query": "peakUserMemoryReservation",  "statement": None},                 parse_size_bytes,  "size"),
    "physical_input": ({"query": "physicalInputDataSize",      "statement": "physicalInputBytes"}, parse_size_bytes,  "size"),
    "processed_bytes":({"query": "processedInputDataSize",     "statement": "processedBytes"},     parse_size_bytes,  "size"),
    "processed_rows": ({"query": "processedInputPositions",    "statement": "processedRows"},      parse_int,         "count"),
    "spilled":        ({"query": "spilledDataSize",            "statement": "spilledBytes"},        parse_size_bytes,  "size"),
    "output_rows":    ({"query": "outputPositions",            "statement": None},                 parse_int,         "count"),
    "total_splits":   ({"query": "totalDrivers",               "statement": "totalSplits"},        parse_int,         "count"),
}


def extract_metrics(stats, schema):
    """stats dict + 스키마('query'|'statement') -> {지표이름: 값}."""
    out = {}
    for name, (keys, parser, _kind) in METRIC_DEFS.items():
        key = keys.get(schema)
        out[name] = parser(stats.get(key)) if key else None
    # 순수 실행 시간 = elapsed - queued (큐 대기 노이즈 제거)
    if out.get("elapsed") is not None and out.get("queued") is not None:
        out["wall_minus_queued"] = max(out["elapsed"] - out["queued"], 0.0)
    else:
        out["wall_minus_queued"] = out.get("elapsed")
    return out


# wall_minus_queued 도 시간 지표로 취급
METRIC_KIND = {name: kind for name, (_k, _p, kind) in METRIC_DEFS.items()}
METRIC_KIND["wall_minus_queued"] = "time"

ALL_METRICS = list(METRIC_DEFS.keys()) + ["wall_minus_queued"]


# ---------------------------------------------------------------------------
# 결과 파일 수집
# ---------------------------------------------------------------------------

def discover_runs(root, query_regex):
    """
    root/<version>/<file>.json 들을 읽어서
    data[version][query_label] = [{지표...}, ...]  (run 목록) 형태로 반환.
    """
    qre = re.compile(query_regex, re.IGNORECASE)
    data = defaultdict(lambda: defaultdict(list))
    skipped = []
    schemas_seen = set()

    for version in sorted(os.listdir(root)):
        vpath = os.path.join(root, version)
        if not os.path.isdir(vpath):
            continue
        for fname in sorted(os.listdir(vpath)):
            if not fname.lower().endswith(".json"):
                continue
            m = qre.search(fname)
            if not m:
                skipped.append(f"{version}/{fname} (쿼리 라벨 추출 실패)")
                continue
            qlabel = m.group("q").lower()
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
            data[version][qlabel].append(extract_metrics(stats, schema))

    return data, skipped, schemas_seen


def median_or_none(values):
    vals = [v for v in values if v is not None]
    if not vals:
        return None
    return statistics.median(vals)


def aggregate(data):
    """run 목록을 (버전,쿼리)별 중앙값으로 집계. 반복횟수/표준편차도 기록."""
    agg = defaultdict(dict)  # agg[version][query] = {지표: median, "_runs":n, "_cv":...}
    for version, queries in data.items():
        for q, runs in queries.items():
            entry = {}
            for metric in ALL_METRICS:
                entry[metric] = median_or_none([r.get(metric) for r in runs])
            entry["_runs"] = len(runs)
            # 헤드라인 지표의 변동계수(CV) = stdev/median, 측정 안정성 참고용
            head = [r.get("wall_minus_queued") for r in runs if r.get("wall_minus_queued") is not None]
            if len(head) >= 2 and statistics.median(head) > 0:
                entry["_cv"] = statistics.pstdev(head) / statistics.median(head)
            else:
                entry["_cv"] = None
            agg[version][q] = entry
    return agg


# ---------------------------------------------------------------------------
# 비교 + 리포트
# ---------------------------------------------------------------------------

def geomean(values):
    import math
    vals = [v for v in values if v is not None and v > 0]
    if not vals:
        return None
    # 로그 평균 후 지수화 -> 오버플로/언더플로 회피
    return math.exp(statistics.fmean([math.log(v) for v in vals]))


def fmt_ms(v):
    if v is None:
        return "-"
    if v >= 1000:
        return f"{v/1000:.2f}s"
    return f"{v:.0f}ms"


def fmt_bytes(v):
    if v is None:
        return "-"
    for unit in ("B", "kB", "MB", "GB", "TB"):
        if v < 1024 or unit == "TB":
            return f"{v:.1f}{unit}"
        v /= 1024


def compare(agg, baseline, metric, regress_threshold):
    """baseline 대비 각 candidate 버전을 metric 으로 비교."""
    import math

    versions = sorted(agg.keys())
    if baseline not in agg:
        raise SystemExit(f"baseline 버전 '{baseline}' 을(를) 결과에서 찾을 수 없습니다. "
                         f"있는 버전: {versions}")
    candidates = [v for v in versions if v != baseline]

    # baseline 에 존재하는 쿼리 집합 기준
    base_queries = sorted(agg[baseline].keys())

    report = {"baseline": baseline, "metric": metric, "versions": {}}

    for cand in candidates:
        per_query = []
        speedups = []
        base_times = []
        cand_times = []
        regressions = []
        missing = []

        for q in base_queries:
            b = agg[baseline][q].get(metric)
            c = agg[cand].get(q, {}).get(metric)
            if b is None or c is None or c <= 0 or b <= 0:
                missing.append(q)
                per_query.append((q, b, c, None))
                continue
            speedup = b / c  # 시간 지표 기준: >1 이면 cand 가 빠름
            per_query.append((q, b, c, speedup))
            speedups.append(speedup)
            base_times.append(b)
            cand_times.append(c)
            if speedup < (1.0 - regress_threshold):
                regressions.append((q, speedup))

        gm_speedup = geomean(speedups)
        gm_base = geomean(base_times)
        gm_cand = geomean(cand_times)

        report["versions"][cand] = {
            "per_query": per_query,
            "geomean_speedup": gm_speedup,
            "geomean_base": gm_base,
            "geomean_cand": gm_cand,
            "regressions": regressions,
            "missing": missing,
            "n": len(speedups),
        }

    return report


def secondary_summary(agg, baseline):
    """보조 지표(cpu, peak_mem, spilled, physical_input)의 버전별 기하평균 변화."""
    versions = sorted(agg.keys())
    base_queries = sorted(agg[baseline].keys())
    metrics = ["cpu", "peak_mem", "spilled", "physical_input"]
    summary = {}  # summary[version][metric] = (geomean_ratio, 설명)

    for v in versions:
        if v == baseline:
            continue
        summary[v] = {}
        for metric in metrics:
            ratios = []
            for q in base_queries:
                b = agg[baseline][q].get(metric)
                c = agg[v].get(q, {}).get(metric)
                if b is None or c is None or b <= 0 or c <= 0:
                    continue
                ratios.append(c / b)  # <1 이면 줄어듦(개선)
            summary[v][metric] = geomean(ratios)
    return summary


def spill_summary(agg):
    """버전별로 spill 이 발생한 쿼리 수와 총 spill 량을 집계."""
    out = {}
    for v, queries in agg.items():
        spilled_qs = [q for q, e in queries.items()
                      if e.get("spilled") not in (None, 0) and e.get("spilled", 0) > 0]
        total = sum(e.get("spilled", 0) or 0 for e in queries.values())
        out[v] = (len(spilled_qs), sorted(spilled_qs), total)
    return out


def print_report(agg, report, secondary, metric):
    baseline = report["baseline"]
    print("=" * 72)
    print(f" Trino 버전별 TPC-H 비교  (baseline = {baseline}, 지표 = {metric})")
    print(" 시간 지표는 (버전,쿼리)별 run 중앙값 사용. speedup = baseline / candidate")
    print("=" * 72)

    for cand, res in report["versions"].items():
        print(f"\n### {baseline}  ->  {cand}")
        print(f"  쿼리별 결과 (speedup > 1.00 = {cand} 가 더 빠름):\n")
        print(f"  {'query':<8}{'baseline':>12}{'candidate':>12}{'speedup':>10}  flag")
        print("  " + "-" * 52)
        for q, b, c, sp in res["per_query"]:
            flag = ""
            if sp is None:
                flag = "데이터없음"
            elif sp < 1.0:
                flag = "느려짐"
            sp_s = f"{sp:.3f}x" if sp is not None else "-"
            print(f"  {q:<8}{fmt_ms(b):>12}{fmt_ms(c):>12}{sp_s:>10}  {flag}")

        gm = res["geomean_speedup"]
        print("  " + "-" * 52)
        if gm is not None:
            verdict = "개선" if gm > 1.0 else ("회귀" if gm < 1.0 else "동일")
            pct = (gm - 1.0) * 100
            print(f"  기하평균 speedup : {gm:.3f}x  ({pct:+.1f}%)  -> 종합 {verdict}")
            print(f"  기하평균 실행시간: {baseline}={fmt_ms(res['geomean_base'])}, "
                  f"{cand}={fmt_ms(res['geomean_cand'])}  (쿼리 {res['n']}개)")
        else:
            print("  기하평균 계산 불가 (유효 데이터 부족)")

        if res["regressions"]:
            print(f"  ⚠ 회귀 쿼리({len(res['regressions'])}개): "
                  + ", ".join(f"{q}({sp:.2f}x)" for q, sp in res["regressions"]))
        if res["missing"]:
            print(f"  · 비교 누락 쿼리: {', '.join(res['missing'])}")

        # 보조 지표
        sec = secondary.get(cand, {})
        if sec:
            print("  보조 지표 기하평균 변화 (1.00 미만 = 감소=개선):")
            labels = {"cpu": "CPU time", "peak_mem": "peak memory",
                      "spilled": "spill", "physical_input": "physical input"}
            for m, label in labels.items():
                r = sec.get(m)
                if r is None:
                    print(f"    - {label:<16}: 데이터 없음")
                else:
                    print(f"    - {label:<16}: {r:.3f}x ({(r-1)*100:+.1f}%)")

    # spill 발생 현황 (버전 간 발생/해소는 wall time 차이의 큰 원인)
    sp = spill_summary(agg)
    print("\nSpill 발생 현황 (버전별):")
    for v in sorted(sp.keys()):
        n, qs, total = sp[v]
        if n == 0:
            print(f"  - {v}: spill 없음")
        else:
            print(f"  - {v}: {n}개 쿼리에서 spill, 총 {fmt_bytes(total)}  ({', '.join(qs)})")

    # 측정 안정성 경고
    noisy = []
    for v, queries in agg.items():
        for q, e in queries.items():
            cv = e.get("_cv")
            if cv is not None and cv > 0.10:
                noisy.append((v, q, cv, e.get("_runs")))
    if noisy:
        print("\n측정 안정성 경고 (헤드라인 지표 변동계수 CV > 10%):")
        for v, q, cv, n in sorted(noisy, key=lambda x: -x[2])[:15]:
            print(f"  - {v}/{q}: CV={cv*100:.1f}%  (run {n}회) "
                  f"-> 반복 실행을 늘려 노이즈를 줄이세요")


def write_csv(agg, report, path):
    """쿼리 x 버전 매트릭스를 CSV 로 저장(헤드라인 지표 + speedup)."""
    baseline = report["baseline"]
    versions = sorted(agg.keys())
    base_queries = sorted(agg[baseline].keys())
    metric = report["metric"]

    with open(path, "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        header = ["query"] + [f"{v}_{metric}_ms" for v in versions]
        for cand in report["versions"]:
            header.append(f"speedup_{baseline}_to_{cand}")
        w.writerow(header)

        for q in base_queries:
            row = [q]
            for v in versions:
                val = agg[v].get(q, {}).get(metric)
                row.append(f"{val:.1f}" if val is not None else "")
            for cand, res in report["versions"].items():
                sp = dict((pq[0], pq[3]) for pq in res["per_query"]).get(q)
                row.append(f"{sp:.4f}" if sp is not None else "")
            w.writerow(row)


# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------

def main():
    p = argparse.ArgumentParser(
        description="Trino 버전별 TPC-H 벤치마크(QueryInfo JSON) 비교")
    p.add_argument("root", help="버전별 하위 디렉터리를 담은 결과 루트 디렉터리")
    p.add_argument("--baseline", help="기준(구) 버전 라벨. 미지정 시 사전순 첫 버전")
    p.add_argument("--metric", default="wall_minus_queued",
                   choices=ALL_METRICS,
                   help="speedup 계산에 쓸 헤드라인 시간 지표 (기본: wall_minus_queued)")
    p.add_argument("--query-regex",
                   default=r"(?P<q>q\d+)",
                   help=r"파일명에서 쿼리 라벨을 뽑는 정규식. named group 'q' 필요 "
                        r"(기본: (?P<q>q\d+))")
    p.add_argument("--regress-threshold", type=float, default=0.05,
                   help="회귀로 판정할 speedup 하락 임계값 (기본 0.05 = 5%% 이상 느려짐)")
    p.add_argument("--csv", help="결과 매트릭스를 저장할 CSV 경로")
    args = p.parse_args()

    if not os.path.isdir(args.root):
        sys.exit(f"디렉터리가 아닙니다: {args.root}")

    data, skipped, schemas_seen = discover_runs(args.root, args.query_regex)
    if not data:
        sys.exit("결과를 찾지 못했습니다. 디렉터리 구조와 --query-regex 를 확인하세요.")

    schema_label = {"query": "서버 QueryStats (/v1/query)",
                    "statement": "클라이언트 StatementStats (stats)"}
    detected = ", ".join(schema_label.get(s, s) for s in sorted(schemas_seen))
    print(f"감지된 통계 스키마: {detected}")
    if len(schemas_seen) > 1:
        print("주의: 한 비교에 서로 다른 스키마가 섞였습니다. 같은 출처로 통일하는 것이 안전합니다.")

    agg = aggregate(data)

    baseline = args.baseline or sorted(agg.keys())[0]
    if args.metric not in ("wall_minus_queued",) and METRIC_KIND.get(args.metric) != "time":
        print(f"경고: --metric '{args.metric}' 는 시간 지표가 아닙니다. "
              f"speedup 해석에 주의하세요.\n", file=sys.stderr)

    report = compare(agg, baseline, args.metric, args.regress_threshold)
    secondary = secondary_summary(agg, baseline)
    print_report(agg, report, secondary, args.metric)

    if skipped:
        print(f"\n건너뛴 파일 {len(skipped)}개:")
        for s in skipped[:20]:
            print(f"  - {s}")

    if args.csv:
        write_csv(agg, report, args.csv)
        print(f"\nCSV 저장됨: {args.csv}")


if __name__ == "__main__":
    main()
