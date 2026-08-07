# Trino 쿼리 튜닝 Skill — 제작·고도화 단계별 설계

> 작성일: 2026년 7월 31일
> 선행 문서: [01-mcp-trino-poc-설계.md](01-mcp-trino-poc-설계.md) · [02-mcp-trino-아키텍처-및-보강점.md](02-mcp-trino-아키텍처-및-보강점.md)
> 목표: Claude Code와 Codex 양쪽에서 mcp-trino를 연결하고, Trino 쿼리 튜닝 skill을 만들고,
> 튜닝 세션의 결과를 규칙으로 적립해 skill을 반복 개선하는 전체 사이클을 정의한다.

---

## 목차

- [설계 원칙](#설계-원칙)
- [단계 개요](#단계-개요)
- [0단계 — 자산 인벤토리](#0단계--자산-인벤토리)
- [1단계 — Claude Code / Codex에 MCP 연결](#1단계--claude-code--codex에-mcp-연결)
- [2단계 — 튜닝 지식 베이스 구축](#2단계--튜닝-지식-베이스-구축)
- [3단계 — Skill v0.1 골격 제작](#3단계--skill-v01-골격-제작)
- [4단계 — 내부 튜닝 샘플 적용](#4단계--내부-튜닝-샘플-적용)
- [5단계 — Skill 고도화 루프](#5단계--skill-고도화-루프)
- [6단계 — 평가와 승격 기준](#6단계--평가와-승격-기준)
- [참고 자료](#참고-자료)

---

## 설계 원칙

1. **하나의 스킬 소스, 두 개의 플랫폼.** Claude Code와 Codex 모두 동일한 SKILL.md
   포맷(frontmatter `name`/`description` + 본문, agentskills.io 표준)을 따른다.
   스킬 본체를 저장소에 한 벌만 두고 양쪽에서 참조한다.
2. **SKILL.md는 얇게, 지식은 references/로.** 규칙 전체를 SKILL.md에 넣으면 매 세션
   컨텍스트를 낭비한다. SKILL.md에는 워크플로와 트리거 조건만 두고, 규칙·예제는
   필요할 때 읽는 참조 파일로 분리한다.
3. **검증되지 않은 예제는 스킬에 넣지 않는다.** 내부 샘플이든 인터넷 가이드든,
   trino-lab에서 `EXPLAIN ANALYZE` 실측으로 효과가 확인된 것만 채택한다.
4. **고도화는 GenRewrite식 규칙 적립.** 조사 문서([1부 §3-b](../LLM-Trino-쿼리튜닝-조사.md))의
   자연어 규칙(NLR2) + 반례 검증 루프 구조를 따른다 — 튜닝 세션마다 성공/실패 사유를
   규칙 파일로 적립하고, 고정 벤치 세트로 스킬 버전 간 A/B를 돌린다.

## 단계 개요

```
[0] 자산 인벤토리        인터넷 가이드 + 내부 문서/샘플 목록 확정
     │
[1] MCP 연결             Claude Code(.mcp.json) + Codex(config.toml) — 같은 바이너리·환경변수
     │
[2] 지식 베이스 구축      trino.io 가이드 정제 + 내부 문서 요약 → references/
     │
[3] Skill v0.1           SKILL.md 골격: 워크플로 6단계 고정 + 참조 로딩 규칙
     │
[4] 내부 샘플 적용        sql/sample*.sql 검증 → examples/, TPCH 분류 → 진단 매핑표
     │
[5] 고도화 루프           세션 결과 → rules/learned/ 적립 → 벤치 A/B → 규칙 승격/폐기
     │
[6] 평가·승격             버전별 성적표 + 플랫폼 간(Claude vs Codex) 비교
```

전제: [01 문서](01-mcp-trino-poc-설계.md)의 1단계(로컬 trino-lab + CLI 검증)가 끝난 상태.
스킬 개발·평가는 전부 로컬 trino-lab(TPC-H)에서 하고, 실 클러스터 적용은 01 문서의
3단계(인증 연결) 이후로 미룬다.

---

## 0단계 — 자산 인벤토리

### 외부(인터넷) 튜닝 가이드 — 지식 베이스의 뼈대

| 자료 | 내용 | 활용 |
|---|---|---|
| [Trino 공식: Query optimizer](https://trino.io/docs/current/optimizer.html) | 옵티마이저 개요 — table statistics, cost in EXPLAIN 하위 문서 포함 | 규칙의 1차 출처 |
| [Trino 공식: Cost-based optimizations](https://trino.io/docs/current/optimizer/cost-based-optimizations.html) | `join_reordering_strategy`, `join_distribution_type`, 통계 의존성 | 조인 전략 규칙 |
| [Trino 공식: Pushdown](https://trino.io/docs/current/optimizer/pushdown.html) | predicate/projection/aggregation pushdown — 플랜에서 `ScanFilterProject` 유무로 확인하는 방법 | 푸시다운 검증 규칙 |
| [Trino 공식: Adaptive plan optimizations](https://trino.io/docs/current/optimizer/adaptive-plan-optimizations.html) | 런타임 재최적화 — FTE 전제 조건 | 전제조건 규칙 |
| [Trino 블로그: Query tuning 트레이닝 (Martin Traverso)](https://trino.io/blog/2020/07/30/training-query-tuning.html) | 쿼리 처리 구조와 튜닝 방법론 영상 | 방법론 배경 |
| [Starburst: Understanding query plans](https://starburst.io/blog/understanding-query-plans/) | 플랜 읽는 법 — 프래그먼트/스테이지/익스체인지 해석 | EXPLAIN 해석 가이드 |
| [The New Stack: Speed Trino Queries](https://thenewstack.io/speed-trino-queries-with-these-performance-tuning-tips/) | 실무 팁 모음 | 보조 |
| [e6data: 14 Techniques for Faster Lakehouse SQL](https://www.e6data.com/query-and-cost-optimization-hub/how-to-optimize-trino-query-performance) | 파일 크기·포맷·파티셔닝 관점 | 스토리지 레이어 규칙 |
| Treasure Data [td-skills `trino-optimizer`](https://github.com/treasure-data/td-skills) | 실존하는 Trino 전용 스킬 — **구조 참고용** (td_ 함수 특화라 내용은 이식 불가) | SKILL.md 구조 템플릿 |

### 내부 자산 — 이 저장소에서 이미 만든 것

| 자산 | 내용 | 스킬에서의 역할 |
|---|---|---|
| [sql/sample.sql](../../sql/sample.sql) + [sql/sample_tuned.sql](../../sql/sample_tuned.sql) | CROSS JOIN UNNEST 행 폭증 튜닝 — v1(필터 푸시다운) → v2(zip 단일 UNNEST) → v3(ROW 명명 캐스팅) 적층 비교 | **1호 검증 예제** (4단계) |
| [docs/TPCH_쿼리_성능요소_분류.md](../TPCH_쿼리_성능요소_분류.md) | TPC-H 22개 쿼리를 성능 요소 6종(스캔/조인/집계/서브쿼리/정렬/표현식)으로 분류 | 쿼리 유형→진단 포인트 매핑표 + 벤치 세트 선정 |
| [docs/03-resource-tuning-plan.md](../03-resource-tuning-plan.md) 및 03-0x 시리즈 | 노드/JVM/스필/커넥터 튜닝 계획과 실측 | 세션 프로퍼티·시스템 한계 참조 |
| [Trino 메모리 성능 최적화 분석.md](../Trino%20메모리%20성능%20최적화%20분석.md) | 메모리 파라미터 분석 | 스필·메모리 규칙 출처 |
| [Trino 네트워크 성능 최적화 분석.md](../Trino%20네트워크%20성능%20최적화%20분석.md) | 익스체인지·네트워크 분석 | 셔플 비용 규칙 출처 |
| [scripts/trino_bench_compare-v2.py](../../scripts/trino_bench_compare-v2.py) | run 분포·워밍업·이상치 판정 + 버전 간 speedup 비교 | **스킬 평가 하네스** (5단계) |
| [docs/trino-479-480-481-release-notes.md](../trino-479-480-481-release-notes.md) | 버전별 변경점 | 버전 특이사항 참조 |

> ⚠ [sql/sample.sql](../../sql/sample.sql)은 의도적이든 아니든 **문법 오류가 있다**
> (괄호 불일치, `WHERE` 앞 세미콜론). 4단계에서 예제로 채택하기 전에 trino-lab에서
> 원본을 실행 가능한 형태로 정정하고, tuned 3개 버전과의 결과 동등성을 실측해야 한다.

---

## 1단계 — Claude Code / Codex에 MCP 연결

같은 `mcp-trino` 바이너리, 같은 환경변수를 두 플랫폼에 등록한다.

### 공통 환경변수 (로컬 trino-lab 기준)

```
TRINO_HOST=localhost  TRINO_PORT=18080
TRINO_SCHEME=http     TRINO_SSL=false
TRINO_USER=trino      TRINO_CATALOG=tpch  TRINO_SCHEMA=sf1
TRINO_QUERY_TIMEOUT=120  TRINO_MAX_ROWS=1000
MCP_TRANSPORT=stdio
```

### Claude Code

프로젝트 공유가 목적이므로 **project scope**(`.mcp.json`, git 커밋)로 등록한다:

```bash
claude mcp add trino-lab --scope project \
  -e TRINO_HOST=localhost -e TRINO_PORT=18080 \
  -e TRINO_SCHEME=http -e TRINO_SSL=false \
  -e TRINO_USER=trino -e TRINO_CATALOG=tpch -e TRINO_SCHEMA=sf1 \
  -e TRINO_QUERY_TIMEOUT=120 -e TRINO_MAX_ROWS=1000 \
  -e MCP_TRANSPORT=stdio \
  -- mcp-trino
```

### Codex

CLI 한 줄 또는 `config.toml` 직접 편집. 프로젝트 공유는 `.codex/config.toml`
(신뢰된 프로젝트 한정), 개인용은 `~/.codex/config.toml`:

```bash
codex mcp add trino-lab \
  --env TRINO_HOST=localhost --env TRINO_PORT=18080 \
  --env TRINO_SCHEME=http --env TRINO_SSL=false \
  --env TRINO_USER=trino --env TRINO_CATALOG=tpch --env TRINO_SCHEMA=sf1 \
  --env TRINO_QUERY_TIMEOUT=120 --env TRINO_MAX_ROWS=1000 \
  -- mcp-trino
```

```toml
# .codex/config.toml — 위 CLI와 동일한 선언형
[mcp_servers.trino-lab]
command = "mcp-trino"

[mcp_servers.trino-lab.env]
TRINO_HOST = "localhost"
TRINO_PORT = "18080"
TRINO_SCHEME = "http"
TRINO_SSL = "false"
TRINO_USER = "trino"
TRINO_CATALOG = "tpch"
TRINO_SCHEMA = "sf1"
TRINO_QUERY_TIMEOUT = "120"
TRINO_MAX_ROWS = "1000"
MCP_TRANSPORT = "stdio"
```

### 완료 기준

| 항목 | Claude Code | Codex |
|---|---|---|
| 서버 연결 확인 | `/mcp` → connected | `codex mcp list` |
| 툴 6개 노출 | 자연어로 `list_catalogs` 유도 | 동일 |
| 거부 케이스 동작 | `SET SESSION` 요청 → 거부 메시지 수신 | 동일 |

> 주의: mcp-trino는 stdio 모드에서 모든 쿼리가 `TRINO_USER` 단일 정체성으로 나간다
> ([02 문서 §3](02-mcp-trino-아키텍처-및-보강점.md)). 두 플랫폼을 구분하고 싶으면
> Codex 쪽에 `TRINO_SOURCE=mcp-trino-codex`를 추가로 주면 Web UI에서 소스가 갈린다.

---

## 2단계 — 튜닝 지식 베이스 구축

0단계 자산을 스킬이 읽을 수 있는 형태로 정제한다. **원문 복사가 아니라
"플랜 시그니처 → 진단 → 처방" 형태로 재구성**하는 것이 핵심이다.

### 산출물 디렉터리 (스킬 본체와 같이 배치)

```
skills/trino-query-tuning/
├── SKILL.md                      # 3단계에서 작성
├── references/
│   ├── plan-reading.md           # EXPLAIN/EXPLAIN ANALYZE 읽는 법 (Starburst 가이드 정제)
│   ├── rules-join.md             # 조인 전략: broadcast vs partitioned 판단 근거
│   ├── rules-pushdown.md         # 푸시다운·파티션 프루닝 확인법 (ScanFilterProject 유무)
│   ├── rules-stats.md            # SHOW STATS 해석, 추정-실측 괴리 진단
│   ├── rules-memory-spill.md     # 내부 메모리/스필 분석 문서 요약
│   ├── rules-antipatterns.md     # OR-LIKE→regexp_like, UNNEST 행 폭증 등
│   ├── session-properties.md     # 세션 프로퍼티 목록 + MCP로는 못 바꾼다는 명시
│   └── tpch-query-map.md         # TPCH 분류 문서 → 쿼리 유형별 진단 포인트 매핑
├── examples/                     # 4단계에서 작성
└── rules/learned/                # 5단계에서 적립
```

### 규칙 파일 공통 포맷 (NLR2 형식)

```markdown
## R-JOIN-001: 브로드캐스트 조인의 빌드 사이드 과대
- 증상(플랜 시그니처): DISTRIBUTED 플랜에서 `Fragment [BROADCAST]` + 빌드 사이드 추정 행수가 실측보다 10배 이상 작음
- 진단: SHOW STATS로 빌드 테이블 통계 유무 확인 → 통계 부재가 원인인지 판별
- 처방: 통계 갱신(ANALYZE — MCP 밖에서) 또는 세션 프로퍼티 join_distribution_type=PARTITIONED (MCP 밖에서)
- 검증: EXPLAIN ANALYZE 재실행, peak memory와 wall time 비교
- 출처: trino.io cost-based-optimizations + 내부 세션 2026-08-XX
```

### 완료 기준

- references/ 파일 8종 초안 완료, 각 규칙에 출처 링크
- 규칙 수보다 중요한 것: **모든 규칙이 "플랜에서 무엇을 보고 판단하는가"를 명시**할 것
  (조사 문서의 교훈 — 추정 행수 vs 실제 행수 괴리를 가장 먼저 보게 한다)

---

## 3단계 — Skill v0.1 골격 제작

### 배치 — 한 벌 작성, 양쪽 참조

스킬 본체는 저장소 `skills/trino-query-tuning/`에 두고 심볼릭 링크로 연결한다:

| 플랫폼 | 스킬 탐색 경로 | 연결 |
|---|---|---|
| Claude Code | `.claude/skills/<name>/` (프로젝트) | `ln -s ../../skills/trino-query-tuning .claude/skills/trino-query-tuning` |
| Codex | `.agents/skills/<name>/` (저장소) | `ln -s ../../skills/trino-query-tuning .agents/skills/trino-query-tuning` |

호출: Claude Code는 `/trino-query-tuning` 또는 설명 매칭으로 자동, Codex는
`$trino-query-tuning` 또는 자동 매칭.

### SKILL.md v0.1 초안

```markdown
---
name: trino-query-tuning
description: >
  Trino 쿼리의 성능을 진단하고 재작성한다. 느린 쿼리 분석, EXPLAIN/EXPLAIN ANALYZE
  해석, 조인 전략·푸시다운·통계 문제 진단, 쿼리 재작성과 등가성 검증에 사용.
  일반 SQL 작성이나 DDL, 인덱스 설계 요청에는 사용하지 않는다 (Trino는 인덱스가 없다).
---

# Trino 쿼리 튜닝

## 전제
- mcp-trino 툴(execute_query, explain_query, get_table_schema 등)이 연결되어 있어야 한다.
- 쿼리는 단일 statement만 가능. SET SESSION / ANALYZE는 MCP로 불가 — 필요하면
  사용자에게 trino CLI 실행을 요청할 것 (references/session-properties.md).

## 워크플로 — 반드시 이 순서로
1. **수집**: ① EXPLAIN (TYPE DISTRIBUTED) ② execute_query로 EXPLAIN ANALYZE
   ③ SHOW STATS FOR <관련 테이블> ④ get_table_schema
2. **괴리 확인**: 플랜의 추정 행수 vs EXPLAIN ANALYZE 실측 행수를 스테이지별로 비교.
   10배 이상 어긋나는 지점이 최우선 진단 대상이다. 통계 부재가 원인이면
   재작성보다 통계 갱신을 먼저 제안할 것 (references/rules-stats.md).
3. **진단**: 괴리 지점의 연산자에 따라 해당 규칙 파일을 읽는다 —
   조인이면 rules-join.md, 스캔이면 rules-pushdown.md, 메모리/스필이면
   rules-memory-spill.md, 패턴성 문제면 rules-antipatterns.md.
4. **재작성**: 결과 동등성이 보장되는 변환만. 각 변환에 적용한 규칙 ID를 주석으로 남길 것.
5. **등가성 게이트**: WITH a AS (원본), b AS (재작성) ... EXCEPT 양방향 차집합
   (references/plan-reading.md 하단 템플릿). 둘 다 0이 아니면 재작성 폐기.
6. **재측정·기록**: EXPLAIN ANALYZE 재실행 → wall time/peak memory/행수 비교표 제시.
   개선·실패 여부와 사유를 rules/learned/에 기록 제안.

## 금지사항
- 등가성 게이트를 통과하지 않은 재작성을 "완료"라고 보고하지 않는다.
- TRINO_ALLOW_WRITE_QUERIES 활성화를 제안하지 않는다.
- PostgreSQL식 조언(인덱스 추가, VACUUM 등)을 하지 않는다.
```

### 완료 기준

- 두 플랫폼 모두에서 스킬이 자동/명시 호출되는지 확인
- TPC-H 쿼리 1개(예: Q9)로 워크플로 6단계가 순서대로 실행되는지 관찰 —
  특히 2번(괴리 확인)을 건너뛰지 않는지

---

## 4단계 — 내부 튜닝 샘플 적용

내부에서 이미 작성한 튜닝 샘플을 스킬의 few-shot 예제와 규칙으로 편입한다.

### 4-1. UNNEST 샘플 (sql/sample*.sql) — 1호 예제

```
① 정정      sample.sql 문법 오류 수정 → trino-lab에서 실행 가능하게
② 실측      원본 vs tuned v1/v2/v3 각각 EXPLAIN ANALYZE 5회 (bench_compare-v2.py 입력 포맷으로 저장)
③ 등가성    4개 쿼리 결과 동등성 확인 (sample_tuned.sql 주석의 "동일 결과 반환" 주장을 실측으로)
④ 예제화    examples/unnest-row-explosion.md 작성:
            원본 쿼리 → 플랜 시그니처(폭증 지점) → 단계별 변환 → 실측 수치
⑤ 규칙화    rules-antipatterns.md에 R-UNNEST-001(필터 푸시다운), R-UNNEST-002(zip 단일화),
            R-UNNEST-003(ROW 명명 캐스팅) 등록 — 각 규칙에 ②의 실측 수치 첨부
```

### 4-2. TPCH 분류 문서 → 진단 매핑표

[TPCH_쿼리_성능요소_분류.md](../TPCH_쿼리_성능요소_분류.md)의 6개 성능 요소 분류를
`references/tpch-query-map.md`로 변환:

| 쿼리 유형 (내부 분류) | 먼저 볼 것 | 해당 규칙 파일 |
|---|---|---|
| 조인 성능 (Q2,Q5,Q7,Q8,Q9...) | 조인 순서·분배 방식·빌드 사이드 크기 | rules-join.md |
| 스캔/IO (Q1,Q6...) | 푸시다운 여부, ScanFilterProject | rules-pushdown.md |
| 집계 (Q1,Q13...) | partial/final aggregation 분리, 해시 스필 | rules-memory-spill.md |
| 서브쿼리 (Q4,Q17,Q20...) | 상관 서브쿼리 → 조인 변환 여부 | rules-antipatterns.md |
| 정렬/Top-N (Q2,Q3,Q10...) | TopN 연산자 vs 전체 정렬 | rules-antipatterns.md |

### 4-3. 시스템 튜닝 문서 → 경계 조건 참조

03-시리즈(노드/JVM/스필)와 메모리·네트워크 분석 문서에서 **쿼리 튜닝과 시스템 튜닝의
경계**를 `references/rules-memory-spill.md`에 명시한다 — 예: "스필이 발생하면 쿼리
재작성으로 중간 결과를 줄이는 것이 1차, `query.max-memory` 조정은 스킬 범위 밖이므로
[03-05 문서](../03-05-disk-spill-tuning-plan.md)를 사용자에게 안내".

### 완료 기준

- UNNEST 예제가 실측 수치와 함께 examples/에 등록
- 매핑표 기반으로 TPC-H 쿼리 유형별 진단 경로가 결정되는 것을 세션에서 확인

---

## 5단계 — Skill 고도화 루프

스킬은 만들고 끝이 아니라 **튜닝 세션의 결과가 다시 스킬로 흘러들어가는 루프**를 돌린다.

### 5-1. 세션 기록 적립

모든 튜닝 세션 종료 시 스킬이 다음 형식으로 기록을 남기게 한다(워크플로 6번):

```markdown
# rules/learned/2026-08-XX-q09-join-reorder.md
- 대상: TPC-H Q9 (sf1, trino-lab)
- 진단: partsupp-lineitem 조인 빌드 사이드 추정 500행 / 실측 80만행
- 적용 규칙: R-JOIN-001
- 결과: wall 42s → 18s (2.3x), 등가성 통과
- 교훈(신규 규칙 후보): supplier 필터가 조인 아래로 안 내려감 — LIKE 조건이 원인
- 실패한 시도: CTE 물질화 시도 → 오히려 12% 느려짐 (사유: 재사용 1회뿐)
```

**실패 기록이 성공 기록만큼 중요하다** — GenRewrite의 반례 축적과 같은 원리로,
"하지 말아야 할 변환"이 규칙화되어야 에이전트의 반복 실수가 줄어든다.

### 5-2. 규칙 승격 파이프라인

```
rules/learned/ (세션 기록, 자유 형식)
   │  주기적 리뷰(사람): 2회 이상 재현된 교훈만
   ▼
references/rules-*.md (NLR2 정식 규칙, 규칙 ID 부여)
   │  벤치 A/B에서 회귀 유발 시
   ▼
규칙 폐기 (폐기 사유를 규칙 파일에 주석으로 보존)
```

### 5-3. 스킬 버전 평가 하네스 — bench_compare 재사용

스킬을 고칠 때마다 고정 벤치 세트로 A/B를 돌린다:

```
벤치 세트: TPCH_쿼리_성능요소_분류.md 2부의 "옵티마이저 평가" 서브셋 (예: Q2,Q7,Q8,Q9,Q17,Q20)
절차:
  ① 스킬 vN으로 각 쿼리 튜닝 세션 실행 → 재작성 쿼리 + EXPLAIN ANALYZE JSON 저장
     (results/skill-vN/qXX_runY.json — bench_compare-v2.py 입력 구조 그대로)
  ② python3 scripts/trino_bench_compare-v2.py results/ --baseline original --warmup 1
  ③ 기록: 기하평균 speedup / 등가성 통과율 / 회귀 쿼리 수 / 규칙 적중률(적용 규칙 ID 집계)
```

측정 지표 4종을 스킬 저장소의 `CHANGELOG.md`에 버전별로 남긴다:

| 지표 | 정의 |
|---|---|
| 기하평균 speedup | 벤치 세트 전체, 원본 대비 |
| 등가성 통과율 | 게이트 통과 재작성 / 전체 재작성 시도 |
| 회귀율 | 5% 이상 느려진 쿼리 비율 |
| 워크플로 준수율 | 6단계를 순서대로 밟은 세션 비율 (관찰 기반) |

### 5-4. 플랫폼 간 비교 (Claude Code vs Codex)

같은 스킬·같은 벤치 세트를 두 플랫폼에서 돌려 비교한다. 목적은 우열이 아니라
**스킬 문구의 플랫폼 의존성 발견**이다 — 한쪽에서만 워크플로 이탈이 잦다면
SKILL.md 지시문이 그 플랫폼에서 모호하다는 신호이므로 문구를 조정한다.
`TRINO_SOURCE`를 플랫폼별로 다르게 주면(1단계 주의사항) Trino 쪽에서 세션을 구분해
집계할 수 있다.

### 5-5. 고도화 확장 (선택, 후순위)

- **02 문서 A2(세션 프로퍼티) 보강이 이뤄지면**: 워크플로에 "세션 프로퍼티 실험" 단계를
  추가하고 rules에 프로퍼티 처방을 승격 (현재는 "MCP 밖에서" 안내만 가능)
- **02 문서 A3(queryId/stats) 보강이 이뤄지면**: 벤치 하네스 ①의 JSON 수집을 세션 안에서
  자동화 (현재는 별도 수집 필요)
- 느린 쿼리 자동 수집(이벤트 리스너) → 상위 N개만 스킬 세션에 공급 — 조사 문서
  [권고안 3단계](../LLM-Trino-쿼리튜닝-조사.md)의 규모화 경로

---

## 6단계 — 평가와 승격 기준

| 조건 | 판정 |
|---|---|
| 벤치 세트 기하평균 speedup ≥ 1.5x **그리고** 등가성 위반 0건 (2개 버전 연속) | 실 클러스터 적용 검토 시작 — 01 문서 3단계(인증 연결)와 합류 |
| 등가성 위반 ≥ 1건 | 해당 버전 즉시 롤백, 위반을 만든 규칙 격리 후 반례를 rules/learned/에 기록 |
| 회귀율 > 5% | 최근 승격 규칙을 의심 — 규칙 단위로 bisect |
| 워크플로 준수율 < 80% | 성능 이전에 SKILL.md 지시문 문제 — 문구부터 수정 |
| 규칙 수가 늘어도 speedup 정체 | 규칙 풀이 canonical 패턴에 편향된 신호 (조사 문서 2부 Observation 2) — 벤치 세트에 비정형 쿼리 추가 |

실 클러스터 적용 시에는 스킬에 클러스터별 컨텍스트(카탈로그 구성, 리소스 그룹,
`root.default` 한도)를 references/에 추가하고, 등가성 게이트를 대표 파티션 샘플 기준으로
재정의한다 (조사 문서 [권고안 2단계](../LLM-Trino-쿼리튜닝-조사.md)).

---

## 참고 자료

### 인터넷 (2026-07-31 확인)

- Trino 공식 문서: [Query optimizer](https://trino.io/docs/current/optimizer.html) · [Cost-based optimizations](https://trino.io/docs/current/optimizer/cost-based-optimizations.html) · [Pushdown](https://trino.io/docs/current/optimizer/pushdown.html) · [Adaptive plan optimizations](https://trino.io/docs/current/optimizer/adaptive-plan-optimizations.html)
- [Trino 블로그: query tuning 트레이닝](https://trino.io/blog/2020/07/30/training-query-tuning.html)
- [Starburst: Understanding query plans](https://starburst.io/blog/understanding-query-plans/)
- [The New Stack: Speed Trino Queries with These Performance-Tuning Tips](https://thenewstack.io/speed-trino-queries-with-these-performance-tuning-tips/)
- [e6data: How to Optimize Trino Query Performance](https://www.e6data.com/query-and-cost-optimization-hub/how-to-optimize-trino-query-performance)
- [Treasure Data td-skills](https://github.com/treasure-data/td-skills) — `trino-optimizer` 스킬 구조 참고
- Codex 문서: [Build skills](https://developers.openai.com/codex/skills) · [MCP](https://developers.openai.com/codex/mcp) — 스킬 경로(`.agents/skills`, `~/.agents/skills`), `codex mcp add`, `[mcp_servers.*]` 포맷 확인
- [Composio: How to Set up MCPs with Codex CLI](https://composio.dev/content/how-to-mcp-with-codex)

### 내부

- [01-mcp-trino-poc-설계.md](01-mcp-trino-poc-설계.md) — MCP 연결 전제 단계
- [02-mcp-trino-아키텍처-및-보강점.md](02-mcp-trino-아키텍처-및-보강점.md) — 툴 제약과 보강 계획
- [LLM-Trino-쿼리튜닝-조사.md](../LLM-Trino-쿼리튜닝-조사.md) — NLR2·등가성 게이트·권고안의 근거
