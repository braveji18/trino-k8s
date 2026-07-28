# LLM을 활용한 Trino 쿼리 튜닝 — 종합 조사 보고서

> 작성일: 2026년 7월 28일
> 구성: 1부 개괄 조사 / 2부 심화 리서치(벤치마크 비교 · 프로덕션 사례)

---

## 목차

- [1부. 개괄 조사](#1부-개괄-조사)
  - [1. 연구 흐름 — LLM 기반 쿼리 최적화의 세 갈래](#1-연구-흐름--llm-기반-쿼리-최적화의-세-갈래)
  - [2. 바로 쓸 수 있는 도구](#2-바로-쓸-수-있는-도구)
  - [3. Trino 전용 튜닝 Skill을 직접 만든다면](#3-trino-전용-튜닝-skill을-직접-만든다면)
  - [4. 현실적인 한계](#4-현실적인-한계)
- [2부. 심화 리서치 보고서](#2부-심화-리서치-보고서)
  - [TL;DR](#tldr)
  - [1. LLM 기반 쿼리 재작성 시스템 벤치마크 비교](#1-llm-기반-쿼리-재작성-시스템-벤치마크-비교)
  - [2. 등가성 검증 방법론 비교](#2-등가성semantic-equivalence-검증-방법론-비교)
  - [3. LLM 기반 knob/configuration 튜닝 계열](#3-llm-기반-knobconfiguration-튜닝-계열)
  - [4. LLM 기반 DB 진단 계열](#4-llm-기반-db-진단-계열)
  - [5. 국내외 기업 Trino/Presto + LLM/AI 도입 사례](#5-국내외-기업-trinopresto--llmai-도입-사례)
  - [6. Trino MCP 서버 구현체 비교](#6-trino-mcp-서버-구현체-비교)
  - [7. Claude Skills / Cursor / Copilot의 Trino 전용 스킬](#7-claude-skills--cursor--copilot의-trino-전용-스킬)
  - [8. Trino 자체의 AI 관련 기능·로드맵](#8-trino-자체의-ai-관련-기능로드맵)
  - [상세 분석](#상세-분석)
  - [권고안](#권고안)
  - [주의사항](#주의사항)
- [참고 링크 모음](#참고-링크-모음)

---

# 1부. 개괄 조사

LLM으로 Trino 쿼리를 튜닝하는 방법을 (1) 연구 흐름, (2) 바로 쓸 수 있는 도구, (3) 직접 Skill을 만들 때의 설계 순으로 정리한다.

미리 말해두면, **Trino 전용으로 완성된 LLM 튜닝 솔루션은 아직 없다.** 대부분 PostgreSQL/MySQL 기준 연구·스킬이고, Trino는 MCP로 엔진에 연결한 뒤 도메인 지식을 직접 주입하는 형태가 현실적이다.

## 1. 연구 흐름 — LLM 기반 쿼리 최적화의 세 갈래

### 쿼리 재작성(Query Rewrite)

가장 성숙한 영역이다.

**LLM-R2** (VLDB 2025)
LLM이 직접 SQL을 고치는 게 아니라 *어떤 재작성 규칙을 어떤 순서로 적용할지*를 LLM에게 추천시키고, 실제 변환은 Calcite 같은 규칙 엔진이 수행한다. 기존 방식이 규칙 조합 탐색에 자원을 많이 쓰고 부정확한 DBMS 비용 추정기에 과도하게 의존한다는 문제의식에서 출발했고, 좋은 예시(demonstration)를 고르기 위해 대조 학습 모델을 커리큘럼 방식으로 훈련시킨다. 결과 동등성이 규칙으로 보장된다는 게 장점이다.

**GenRewrite** (SIGMOD 2026)
규칙 집합 밖으로 나간다. 자연어 재작성 규칙(NLR2)이라는 개념을 도입해 LLM에 힌트로 주는 동시에 한 쿼리에서 얻은 지식을 다른 쿼리로 이전하는 수단으로 쓰고, 반례 기반(counterexample-guided) 기법으로 재작성된 쿼리의 문법·의미 오류를 반복 교정한다. TPC-DS 기준 2배 이상 속도 향상을 얻은 쿼리가 25개로, LLM-R2(10개)나 R-Bot(9개)보다 많았다.

> **Trino 튜닝 스킬을 설계한다면 이 논문의 "자연어 규칙 축적 + 반례 검증 루프" 구조가 가장 참고할 만하다.**

그 외 **R-Bot**(VLDB 2025), **QUITE**(규칙을 넘어선 LLM 에이전트 재작성 시스템) 등이 있다.

### 시스템/노브 튜닝

**GPTuner**가 대표적이다. DBMS 매뉴얼과 포럼 등 문서화된 도메인 지식을 LLM 파이프라인으로 수집·정제해 탐색 공간을 줄인 뒤 베이지안 최적화를 돌린다. 이후 **AgentTune**(SIGMOD 2026), **MCTuner** 등 에이전트 기반으로 확장되고 있다.

### 성능 진단

**Panda**(CIDR 2024, LLM 에이전트 기반 성능 디버깅)와 **D-Bot**(VLDB 2024, LLM 기반 DB 진단)이 출발점이다. 논문 목록은 HKUSTDial의 `awesome-data-agents` 저장소가 가장 잘 정리돼 있다.

## 2. 바로 쓸 수 있는 도구

### Trino MCP 서버

LLM을 실제 클러스터에 붙이는 핵심 부품이다.

| 구현체 | 특징 |
|---|---|
| `tuannvm/mcp-trino` | Go 구현, 표준 MCP 툴로 분산 SQL 질의. 성능·안정성 면에서 무난한 선택 |
| `stinkgen/trino_mcp` | SQL 실행, 쿼리 ID로 실행 중 쿼리 취소, 컬럼·통계 포함 테이블 메타데이터 조회 지원. Docker(9097) / 독립 Python API(8008) 두 경로 제공, STDIO 트랜스포트 권장(SSE는 불안정) |
| `dreadew/trino-mcp` | 스키마 분석 특화 — 구조 탐색, 안전한 쿼리 실행, DDL 검증, 의존성 분석, 스키마 문서 자동 생성 |

튜닝 목적이라면 **쿼리 취소 기능이 있는 서버**를 고를 것. 에이전트가 실험 쿼리를 돌리다 클러스터를 잡아먹는 사고를 막을 수 있다.

### Claude Skills

마켓플레이스에 SQL 최적화 스킬이 여럿 있다. `sql-optimization-patterns`는 EXPLAIN 분석·인덱싱 전략을 다루지만 예제가 PostgreSQL 중심이고, 각 DB별 문법 차이는 사용자가 직접 맞춰야 한다고 명시돼 있다. `sql-query-optimizer` 계열도 풀 테이블 스캔·누락된 인덱스·비효율적 조인 탐지에 초점이다.

> **인덱스 개념이 없고 파티션 프루닝·푸시다운·익스체인지가 핵심인 Trino에는 오히려 잘못된 조언을 유도할 수 있다.** 그대로 쓰기보다 참고 구조로만 볼 것.

### Starburst

LLM·MCP 연동과 자체 AI 에이전트를 데이터 프로덕트 위에 얹는 방향으로 가고 있고, SQL 내장 LLM 함수, 벡터 검색, 모델별 토큰·비용 가드레일 거버넌스를 제공한다. 다만 이건 "쿼리로 LLM을 호출"하는 쪽이지 "LLM으로 쿼리를 튜닝"하는 기능은 아니다.

## 3. Trino 전용 튜닝 Skill을 직접 만든다면

Trino는 인덱스가 없고 CBO가 통계에 크게 의존하므로, 범용 SQL 스킬로는 부족하다. `SKILL.md`에 다음을 명시적으로 넣는 게 효과적이다.

### (a) 에이전트가 수집할 컨텍스트를 순서로 고정

1. `EXPLAIN` — 논리/분산 플랜 + 비용 추정
2. `EXPLAIN ANALYZE` — 실측: 스테이지별 시간, 행 수, 추정 대비 실제 오차
3. `SHOW STATS FOR <table>` — 통계 부재/노후 여부. 추정치가 없거나 오래됐으면 먼저 테이블 통계를 갱신해 CBO 판단을 개선하는 것이 순서다
4. 파티션 컬럼, 파일 포맷, 파일 크기 분포
5. `system.runtime.queries` / 쿼리 JSON — 스테이지 스큐, 스필 발생, 피크 메모리

> 추정 행 수와 실제 행 수의 괴리를 LLM에게 **가장 먼저 보게 하는 것**이 핵심이다. Trino의 잘못된 플랜은 거의 항상 여기서 시작한다.

### (b) Trino 고유 규칙을 자연어 규칙(NLR2)으로 축적

- **조인 전략**: 기본은 파티션드 조인(양쪽 테이블을 조인 키 해시로 분할)이고, 브로드캐스트는 각 노드가 데이터를 복제받아 해시 테이블을 구성한다. 빌드 사이드 크기 판단 근거를 반드시 플랜에서 가져오게 할 것
- **정규식 치환**: `OR`로 이어진 다수의 `LIKE` 절은 옵티마이저가 개선하지 못하므로 단일 `regexp_like`로 치환
- **푸시다운 확인**: 파티션 프루닝 / 프레디킷 푸시다운 / 컬럼 프루닝이 실제로 걸렸는지 플랜에서 확인
- **스필**: 메모리 초과 시 스필-투-디스크로 중간 결과를 디스크에 임시 저장해 OOM 실패를 막는 옵션
- **적응형 최적화**: 런타임 통계 기반 동적 조정(예: 파티션드 조인 입력 순서 재정렬)은 내결함성 실행(fault-tolerant execution)이 켜져 있을 때만 동작한다는 전제 조건
- **힌트**: 세션 프로퍼티와 매직 코멘트 — 옵티마이저보다 데이터 구조를 잘 알고 있을 때 실행 계획을 강제로 덮어쓰는 수단

### (c) 검증 루프를 스킬에 강제

GenRewrite식으로:

1. 소량 샘플에서 결과 동등성 확인 (집합 차집합 양방향)
2. `EXPLAIN ANALYZE` 재측정
3. 개선 실패 시 실패 사유를 규칙으로 적립

> 이 루프가 없으면 LLM 재작성은 "빨라졌지만 결과가 다른 쿼리"를 만들어낸다.

## 4. 현실적인 한계

Starburst가 정확하게 지적한 부분이 있다.

> "이 Trino 쿼리 플랜을 분석해서 성능 개선 인사이트를 달라"고 물어보는 건 물론 가능하지만, 돌아오는 답변은 프래그먼트·파티션·해싱·브로드캐스트·통계·스플릿·스테이지·익스체인지 같은 전문 용어로 표현되고, 분산 엔진에서 멀티 스테이지 작업이 어떻게 실행되는지를 이해해야 그 답변을 검증하고 무엇을 실제로 적용할지 판단할 수 있다.

즉 **LLM은 진단 가속기이지 검증자가 아니다.** 그리고 Trino 병목의 상당수는 시스템 문제가 아니라 사용자의 비효율적 쿼리 패턴, 리소스 관리 부실, 잘못된 스케일링 전략에서 온다. 개별 쿼리 튜닝 에이전트보다, 느린 쿼리를 자동 수집해 패턴별로 분류하고 상위 N개에 대해서만 LLM 리뷰를 붙이는 워크플로가 투자 대비 효과가 크다.

**시작점을 하나 고르라면:**

```
MCP 서버 연결
  → EXPLAIN ANALYZE 수집 자동화
    → Trino 규칙을 담은 자체 Skill
      → 결과 동등성 검증 스크립트
```

---

# 2부. 심화 리서치 보고서

## TL;DR

- **학술 벤치마크는 성숙했으나 Trino 대상 실증은 사실상 전무하다.** LLM 기반 쿼리 재작성 시스템(LLM-R2, GenRewrite, R-Bot, QUITE, LITHE)은 거의 전부 PostgreSQL(및 Apache Calcite) 위에서 TPC-H/DSB/JOB/Calcite로 평가되었으며, Trino/Presto 같은 분산 MPP 엔진에서 재작성 효과가 직접 검증된 사례는 조사 범위 내에서 발견되지 않았다.
- **국내외 프로덕션에서 "LLM으로 Trino 쿼리를 자동 튜닝/재작성"한 명시적 사례는 없다.** Uber QueryGPT, LinkedIn·배달의민족 물어보새 등은 모두 **Text-to-SQL(자연어→쿼리 생성)**이며, 느린 쿼리를 LLM이 재작성해 성능을 개선하는 프로덕션 파이프라인은 확인되지 않았다. Meta/Uber의 Presto 자동 최적화(HBO)는 LLM이 아니라 실행 이력 기반 통계 기법이다.
- **실용 경로는 두 갈래다.** (1) Trino MCP 서버(tuannvm/mcp-trino 등) + Claude/Cursor 스킬로 사람이 개입하는 "리뷰형" 튜닝, (2) Starburst Galaxy AI Agent 같은 벤더 기능. 다만 이들은 read-only 안전장치는 있으나 등가성 정형 검증은 제공하지 않으므로, 프로덕션 적용 시 사람 리뷰가 필수다.

## 1. LLM 기반 쿼리 재작성 시스템 벤치마크 비교

조사한 모든 주요 시스템은 **PostgreSQL(일부 MySQL)** 위에서, **Apache Calcite**의 재작성 규칙 세트를 재작성 플랫폼으로 삼아 평가되었다. 어느 논문도 Trino/Presto/Spark SQL 같은 분산 MPP 엔진에서 재작성 효과를 직접 측정하지 않았다.

| 시스템 (발표) | arXiv/DOI | 접근방식 | 평가 엔진 | 벤치마크 | 핵심 정량 결과 | 등가성 검증 |
|---|---|---|---|---|---|---|
| **LearnedRewrite (LR)** (VLDB 2022) | DOI 10.14778/3611540.3611633 | MCTS + 학습 비용모델로 규칙 순서 탐색 | PostgreSQL / Calcite | TPC-H, IMDB, DSB | LLM 계열의 표준 baseline. 후속 재현 시 등가율 TPC-H 68%·Calcite 75% | 규칙 기반(규칙 자체가 등가 보장) |
| **LLM-R2** (VLDB 2025) | arXiv 2404.12872, PVLDB v18 p53 | LLM이 ICL로 Calcite 규칙 선택 + 학습된 demonstration 선택기 | PostgreSQL / Calcite | TPC-H, IMDB, DSB | 원 쿼리 대비 평균 실행시간을 TPC-H·IMDB·DSB에서 각각 **52.5%·56.0%·39.8%** 수준으로 단축; LR 대비 94.5%·63.1%·40.7%, LLM only 대비 52.7%·56.0%·33.1% | 규칙 기반 + 실행 검증. 재현 시 등가율 GPT-4o TPC-H 90%·Calcite 72% |
| **R-Bot** (VLDB 2025) | arXiv 2412.01661, DOI 10.14778/3750601.3750625 | RAG(규칙 명세 67개 + Q&A 2091개) + step-by-step 규칙 선택 | PostgreSQL / Calcite | TPC-H 10x, DSB, Calcite | 원 쿼리 평균 지연 대비 대폭 감소(예: DSB p90 300s→55.02s, ↓81.7%). Huawei 실배포 보고 | RAG로 환각 억제 + 규칙 기반. 정형 등가 보장은 아님 |
| **GenRewrite** (SIGMOD/PACMMOD 2026) | arXiv 2403.09060, DOI 10.1145/3786684 | 순수 LLM 재작성 + 자연어 규칙(NLR2) + 반례기반 교정 | PostgreSQL | TPC-DS, JOB + SQLStorm 변형 | TPC-DS에서 **약 25%의 쿼리를 2배 이상 speedup**(JOB·SQLStorm 변형은 7~12%). 전통기법 대비 커버리지 2.5–3.2배, out-of-the-box LLM 대비 2.1배. TPC-DS서 **85.9%** 쿼리에 등가 재작성 1개 이상 생성, 재작성 정확도 **70%**(baseline LLM 51.8%) | **반례 기반** 반복 교정으로 구문·의미 오류 수정 |
| **LITHE** ("Query Rewriting via LLMs") | arXiv 2502.12918 (EDBT 2026) | 기본 프롬프트 앙상블 + DB-민감 프롬프트 + 토큰확률(MCTS) 경로 | PostgreSQL v16(GPT-4o), 상용 DBMS | TPC-DS 등 | TPC-DS/PostgreSQL 느린 쿼리에서 네이티브 옵티마이저 대비 런타임 speedup 기하평균 **13.2배**(SOTA 4.9배); 비용감소 GM 11.5배(SOTA 6.1배) | 논리 기반 + 통계(샘플링) 도구로 의미 위반 검사, 회귀 식별 |
| **QUITE** (arXiv 2025) | arXiv 2506.07675 | FSM 기반 멀티에이전트 + 하이브리드 SQL corrector + hint injection | PostgreSQL v14.13(DeepSeek-R1) | TPC-H, DSB, Calcite, StackOverflow | SOTA 대비 실행시간 최대 **35.8% 단축**, 추가 재작성 **24.1%**. R-Bot 대비 TPC-H·DSB·Calcite·SO에서 21.6%·70.6%·55.1%·72.8% 단축 | 하이브리드 SQL corrector(구문+의미) + 실행 피드백 |

### 핵심 해석

- 절대 수치는 벤치마크·데이터스케일·기준선·LLM에 따라 크게 다르므로 시스템 간 직접 비교는 위험하다. QUITE 논문의 통일된 재실험(모두 PostgreSQL, DeepSeek-R1)이 가장 공정한 비교이며, 여기서 순위는 대체로 **QUITE > R-Bot > LLM-R2 ≈ LLM Agent > LR** 순이다.
- **SQLStorm(복잡·비정형 쿼리) 조건에서는 "LLM 강화" 규칙 기반 시스템(LLM-R2, R-Bot)이 LLM 없는 LR보다도 나빠질 수 있다** — GenRewrite 논문의 Observation 2. 규칙/데모 풀이 canonical 패턴에 편향되어 있기 때문으로, 실무의 다양한 쿼리에 대한 이전 가능성에 중요한 경고다.

## 2. 등가성(semantic equivalence) 검증 방법론 비교

| 방법론 | 대표 시스템 | 특징 | 한계 |
|---|---|---|---|
| 규칙 기반(변환 규칙이 등가 보장) | LLM-R2, R-Bot, LR | Calcite 규칙 자체가 검증된 등가 변환 | 규칙 밖 재작성 불가, 커버리지 제한 |
| 반례 기반(counterexample-guided) | GenRewrite | 반례로 반복 교정, LLM 호출·수작업 검증 비용 절감 | 완전한 정형 증명 아님 |
| 정형 검증기 결합 | (참조) QED, SPES, 정수선형연산 기반 | 정형 등가 판정 | 지원 연산자 제한, 복잡 쿼리 미지원 |
| 논리+통계(샘플) 혼합 | LITHE | 논리 도구 + 샘플 데이터 기반 위반 탐지 | 샘플 미포착 시 위반 통과 가능 |
| 하이브리드 corrector + 실행 피드백 | QUITE | 구문+의미 corrector, DB 피드백 | 실행 기반이라 데이터 의존 |

Trino 같은 MPP 엔진에 이식할 경우, **표준 SQL 방언 차이·분산 실행 시맨틱(NULL 정렬, 부동소수점 집계 순서)**이 등가성 검증을 어렵게 만들 수 있어, PostgreSQL에서 검증된 등가성 도구(QED/SPES)를 그대로 신뢰하기 어렵다.

## 3. LLM 기반 knob/configuration 튜닝 계열

이 계열은 쿼리 재작성이 아니라 **DBMS 설정 파라미터** 최적화이며, 전부 PostgreSQL/MySQL 대상이다. Trino의 경우 세션 프로퍼티/리소스 그룹 튜닝에 개념적으로 대응하나 직접 검증된 도구는 없다.

| 시스템 | arXiv/DOI | 접근 | 평가 대상 | 핵심 결과 |
|---|---|---|---|---|
| **DB-BERT** (SIGMOD 2022) | — | BERT로 매뉴얼 읽고 RL 유도 | PostgreSQL/MySQL | GPTuner의 주요 baseline; TPC-H 20회 반복서 37.5% 지연 감소 후 정체 |
| **GPTuner** (VLDB 2024) | arXiv 2311.03157, DOI 10.14778/3659437.3659449 | LLM로 매뉴얼·포럼 지식 정제 + Coarse-to-Fine 베이지안 최적화 | PostgreSQL/MySQL, TPC-H/TPC-C | SOTA 대비 **평균 16배 빠르게** 더 나은 설정 발견, **최대 30% 성능 향상**; TPC-H 20회에 44.4% 지연 감소 |
| **λ-Tune** (SIGMOD 2025) | arXiv 2411.03500, DOI 10.1145/3709652 | LLM이 전체 설정 스크립트 생성, 프롬프트를 비용기반 최적화 | PostgreSQL/MySQL | 학습·GPU 불필요(zero-shot), 프롬프트 토큰예산으로 LLM 호출비 제어, 기존 LLM/ML baseline 능가·더 견고 |
| **E2ETune** (VLDB 2025) | arXiv 2404.11581, PVLDB v18 p5540 | 파인튜닝된 생성 LM으로 워크로드→설정 직접 추천 | 10개 벤치마크 + 3 실워크로드 | TPC-H에서 HEBO 1381.7분 → **19.8분(98.6% 시간 단축)**, 학습 상한(HEBO) 자체를 초과 |
| **MCTuner** (arXiv 2025) | arXiv 2509.06298 | 공간분해 + LLM 유도 탐색 | PostgreSQL 등 | GPTuner/E2ETune 대비 개선 주장(세부 수치는 논문 참조) |

## 4. LLM 기반 DB 진단 계열

| 시스템 | arXiv/DOI | 접근 | 결과 |
|---|---|---|---|
| **D-Bot** (VLDB 2024) | arXiv 2312.01454, DOI 10.14778/3675034.3675043 | 문서 지식 추출 + 트리탐색 근본원인 분석 + 협업 | **6개 앱 539개 이상징후**로 검증, GPT-4 대비 유의미하게 우수, 진단 **10분 이내**(DBA는 수 시간) |
| **Panda** (2024) | — | LLM 에이전트 기반 성능 디버깅 | λ-Tune 관련 문헌에서 인용, 성능 디버깅 컨텍스트 제공 |
| **Andromeda** (SIGMOD 2025) | — | LLM으로 설정 디버깅, 자연어 Q&A | DBA 대리로 설정 이슈 진단·수정 제안 |

이 계열은 진단 리포트 생성이 목적이며, Trino 클러스터 진단에 개념적으로 응용 가능하나 Trino 특화 구현·검증 사례는 없다.

## 5. 국내외 기업 Trino/Presto + LLM/AI 도입 사례

> **중요: "LLM으로 Trino/Presto를 튜닝/재작성"하는 프로덕션 사례는 국내외 모두 확인되지 않았다.** 대부분은 Text-to-SQL(자연어→쿼리 생성)이며, 자동 최적화는 비-LLM 기법(HBO)이다.

### 해외

**Uber QueryGPT**
Presto 위에서 자연어→SQL 생성. LLM+벡터DB+RAG. Uber 데이터플랫폼은 **월 약 120만 대화형 쿼리** 처리(그중 Operations 조직이 약 36% 기여), QueryGPT로 쿼리 작성시간을 **약 10분 → 약 3분(≈70% 단축)** 주장. **쿼리 튜닝이 아니라 생성.**
출처: `uber.com/us/en/blog/query-gpt`

- "월 14만 시간 절감"은 Uber 원문이 아니라 서드파티 **Wren AI**의 환산치("1.2M queries/month … 140,000 hours saved monthly", getwren.ai). Uber 원문은 시간 절감 총액을 명시하지 않는다.

**Uber Presto 규모**
"around 20 Presto clusters across over 10,000 nodes in 2 regions, supporting approximately 12,000 weekly active users. These users run about 500,000 queries daily, reading around 100 PB from HDFS."
출처: `uber.com/blog/presto-express` (2024-11-07)

**Meta/Uber Presto HBO(History-Based Optimizer)**
실행 이력 기반 통계로 카디널리티/비용 추정 및 조인·집계·writer 최적화. **LLM 아님.** Redis 통계 저장소. Meta·Uber 프로덕션 적용.
출처: `prestodb.io/blog/2024/09/26`, VLDB DOI 10.14778/3685800.3685828, `vldb.org/pvldb/vol17/p4077-shankhdhar.pdf`

**LinkedIn**
Trino 기반 사내 분석 Text-to-SQL 솔루션(Trino Summit 2023 발표). 정확도·성능·사용자 확산 과제 논의. 생성 중심.

**Netflix**
15개 이상 Trino 클러스터, 월 1000만+ 쿼리(Trino Summit 2023). LLM 튜닝 언급 없음.

**Starburst Galaxy AI Agent / AI Data Assistant**
자연어→SQL 생성·실행, MCP 서버 내장. AWS Bedrock의 Starburst 관리 LLM 사용, 고객 데이터는 외부 모델로 안 나감. **public preview**. 쿼리 최적화 자동화라기보다 대화형 분석.
출처: `docs.starburst.io/starburst-galaxy/starburst-ai`

**AutoSteer** (참조)
Bao 기반 hint-set 자동탐색, PostgreSQL·PrestoDB·Spark-SQL·MySQL·DuckDB에 적용, Meta PrestoDB 프로덕션 워크로드로 평가. **LLM 아님**(학습 기반). Presto 계열 자동 최적화의 드문 실증.

### 국내

**배달의민족/우아한형제들 "물어보새(MuleoboSae)"**
국내에서 가장 근접한 "LLM+Trino" 프로덕션 사례. GPT-4o+RAG+LangChain 기반 AI 데이터 분석가, Slack 제공. **Text-to-SQL로 생성한 쿼리가 Trino에서 실행**되며, 블로그에서 "Trino 쿼리 함수와 응답시간 개선 필요"를 명시(생성이지 튜닝/재작성 아님). 답변 30초~1분, 500+ 내부 A/B 테스트.
출처: `techblog.woowahan.com/18144/`, `/18362/`, `/23273/`

**SK플래닛**
2019 Presto 도입, 2021 Trino 전환, 전사 데이터 분석 플랫폼 "DIC". Trino Gateway(lyft OSS) HA, Apache Ranger 접근제어, 사내 약 20~25% 임직원 사용. **LLM/AI 튜닝 언급 없음.**
출처: `techtopic.skplanet.com/trino`

**쿠팡**
Presto/Zeppelin을 대화형·애드혹 쿼리에 사용, 페타바이트 규모. **LLM-on-Presto 증거 없음.**
출처: `medium.com/coupang-engineering`

**당근페이 "브로쿼리(BroQuery)"**
Text-to-SQL이나 **Trino가 아니라 Amazon Redshift**에서 실행. Amazon Bedrock+OpenSearch RAG. 샘플쿼리 유무가 정확도 90%+ 차이.
출처: `aws.amazon.com/ko/blogs/tech/daangnpay-text-to-sql-2/`

**네이버**
검색 AI Data Platform 스택에 Trino(Presto) 포함, NAVER Cloud "Data Forest"가 Trino 437 매니지드 제공. **LLM 튜닝 사례 없음.**

**카카오·라인·토스·삼성**
조사 범위 내에서 Trino+LLM 튜닝 프로덕션 사례 확인 불가(부재 ≠ 미사용).

## 6. Trino MCP 서버 구현체 비교

| 구현체 | 언어 | 성숙도 | 안전장치 | 비고 |
|---|---|---|---|---|
| **tuannvm/mcp-trino** | Go | 가장 성숙(약 109 stars, 활발 유지보수, Helm 차트, 2026-06 업데이트) | **기본 read-only(SELECT/SHOW/DESCRIBE/EXPLAIN만)**, 쓰기는 `TRINO_ALLOW_WRITE_QUERIES=true`로 명시적 해제. OAuth 2.1(Okta/Google/Azure AD), PKCE, JWT, 사용자 임퍼소네이션·쿼리 어트리뷰션(X-Trino-User/Client-Tags) | 프로덕션 지향. STDIO/HTTP 전송, Cursor·Claude Desktop·Windsurf 호환 |
| **stinkgen/trino_mcp** | Python | 베타(v0.1.2, 약 10 stars) | 별도 read-only 강제 문서화 안 됨; FastAPI REST 노출 | SSE 전송이 MCP 1.3.0에서 크래시 → STDIO 권장. 학습/PoC용 |
| **dreadew/trino-mcp** | (미상) | 조사 범위 내 상세 확인 불가 | 확인 불가 | 커뮤니티 초기 단계 |

**핵심:** tuannvm/mcp-trino는 read-only 기본값·OAuth·쿼리 어트리뷰션 등 안전장치가 잘 갖춰져 프로덕션 후보다. 다만 **쿼리 타임아웃·리소스 그룹 제한은 MCP 서버 자체 기능이 아니라 Trino 서버 측 설정(resource groups, `query.max-execution-time`)**에 위임되며, MCP 서버가 직접 강제하지는 않는다.

## 7. Claude Skills / Cursor / Copilot의 Trino 전용 스킬

- **Treasure Data 공식 `td-skills`** (`github.com/treasure-data/td-skills`) — Claude Code용. `sql-skills/trino`(작성·최적화), **`sql-skills/trino-optimizer`(느린 Trino 쿼리 최적화, 타임아웃·메모리 오류 수정, 비용 절감)**, `trino-to-hive-migration`, `time-filtering`(td_interval 파티션 프루닝) 등 Trino 전용 스킬이 **실재**한다. 단 Treasure Data 환경(td_ 함수) 특화.
- **Altimate AI `data-engineering-skills`** — Claude Code 마켓플레이스 플러그인. dbt/Snowflake 중심이나, SQL 최적화 스킬이 "TPC-H 1TB에서 22% 빠른 실행, 100% 논리 등가 쿼리 생성"을 주장. Trino 전용은 아님(벤더 자체 주장, 독립 검증 없음).
- **범용 SQL 최적화 스킬** — LobeHub·claudemarketplaces 등에 `sql-query-optimizer`, `sql-optimization`(MySQL/PostgreSQL 등) 존재하나 Trino 특화 아님.
- **결론:** Trino 전용 최적화 스킬은 주로 **Treasure Data 생태계**에 존재하며, 벤더 중립적 범용 Trino 튜닝 스킬은 아직 드물다.

## 8. Trino 자체의 AI 관련 기능·로드맵

- **Trino Summit 2024**(가상, 무료 2일)에서 "Lessons and news from the AI world for Trino" 패널 진행. 공동창업자 Martin Traverso 키노트에서 2024년 성과(릴리스 436–467, 30+ 릴리스, 프로젝트 시작 이래 총 4만+ 커밋에 5000+ 추가)와 2025 계획 발표. Trino Gateway, trino-python-client, 신규 trino-js-client·trino-csharp-client 개선.
- **핵심:** Trino 코어에 LLM 기반 쿼리 최적화 기능이 내장된 정황은 없다. AI 관련 움직임은 주로 **MCP 서버 생태계**와 **Starburst(상용) Galaxy AI**에 집중. Trino 자체 최적화는 **CBO + 통계 기반**이며, Presto 계열의 HBO(비-LLM)가 이력 기반 자동 최적화의 대표다.

## 상세 분석

### 이전 가능성(transferability) 평가

LLM 재작성 연구의 speedup은 대부분 PostgreSQL 단일 노드에서 측정되었다. Trino/Presto는 다음의 다른 비용 구조를 가진다:

1. 분산 셔플·조인 분배
2. 동적 필터링·파티션 프루닝
3. 스테이지 기반 파이프라인 실행

따라서 "CTE로 중복 계산 제거", "고선택도 조인 먼저", "불필요 조인 제거" 같은 **논리적 재작성(QUITE의 예시 1–3)은 Trino에도 유효**할 가능성이 높지만, 규칙 선택이 PostgreSQL 비용모델·통계에 의존하는 부분(LLM-R2, R-Bot)은 그대로 이전되지 않는다. 특히 Presto/Trino는 이미 HBO·CBO로 조인 순서·분배를 자동 처리하므로, LLM 재작성의 한계이득이 PostgreSQL보다 작을 수 있다.

### 비용/토큰 관점

GenRewrite의 반례기반 교정과 λ-Tune의 토큰예산 비용최적화는 LLM 호출비를 명시적으로 관리한다. 프로덕션에서 매 느린 쿼리마다 LLM을 호출하면 비용이 누적되므로 다음 파이프라인이 현실적이다:

```
느린 쿼리 자동 탐지
  → 배치 후보 선별
    → LLM 재작성
      → 사람 리뷰
        → 카나리 실행
```

다만 이런 end-to-end 파이프라인을 Trino에서 프로덕션 적용해 비용절감률을 보고한 공개 사례는 없다.

## 권고안

### 1단계 (지금, 저위험) — 사람-개입 워크플로

- tuannvm/mcp-trino를 **read-only 기본 모드**로 배포하고, Trino 서버 측에서 **리소스 그룹·`query.max-execution-time`·`query.max-memory`**를 별도로 강제할 것 (MCP 서버는 이를 강제하지 않음)
- Claude/Cursor에 사내 Trino 튜닝 가이드(파티션 프루닝, 브로드캐스트 vs 파티션 조인, `approx_distinct`, 동적 필터링)를 스킬/룰로 주입. Treasure Data `trino-optimizer` 스킬이 참고 템플릿
- LLM은 **제안만** 하게 하고, EXPLAIN/EXPLAIN ANALYZE 비교와 결과 샘플 대조를 사람이 검토

### 2단계 (검증 후) — 등가성 게이트 자체 구현

GenRewrite/QUITE의 **반례 기반·corrector 아이디어**를 Trino용 등가성 게이트로 자체 구현. 원 쿼리와 재작성 쿼리를 대표 파티션 샘플에서 실행해 결과 해시를 비교하고, 불일치 시 자동 폐기한다. 정형 등가 도구(QED/SPES)는 Trino 방언 미지원이므로 샘플 기반이 현실적이다.

### 3단계 (규모화) — 자동 파이프라인

느린 쿼리를 QueryHistory/이벤트리스너로 자동 수집 → 임계값(예: 실행 60초↑ 또는 스캔 1TB↑) 이상만 후보화 → 배치 LLM 재작성 → 카나리 클러스터에서 A/B → 성능·비용 회귀 없을 때만 사용자에게 제안. 벤더 종속을 허용한다면 **Starburst Galaxy AI Agent(preview)**를 PoC로 평가.

### 판단을 바꿀 벤치마크/임계값

| 조건 | 조치 |
|---|---|
| Trino에서 LLM 재작성이 실측 speedup 기하평균 **1.5배 이상 + 등가성 위반 0건** 달성 | 2단계 → 3단계 승격 |
| SQLStorm류 비정형 쿼리에서 **회귀(느려짐)가 5% 초과** | 규칙 선택 방식 폐기, 순수 생성형(GenRewrite류) + 강한 등가 게이트로 전환 |
| LLM 호출비가 절감된 컴퓨트 비용의 **20% 초과** | 후보 선별 임계값 상향 |

## 주의사항

- **추측과 실측의 구분:** 표의 수치는 각 논문이 보고한 값이며, 서로 다른 하드웨어·데이터스케일·LLM·기준선에서 측정되어 **시스템 간 직접 비교는 부정확**하다. Uber "약 10분→약 3분(≈70%) 단축"은 Uber 자체 보고이나, "월 14만 시간 절감"은 서드파티(Wren AI)의 환산치로 Uber 원문에 없다.
- **Trino 실증 부재:** 조사 범위 내에서 LLM 재작성·knob 튜닝·진단 시스템 중 **Trino/Presto에서 직접 평가된 것은 없다.** AutoSteer가 PrestoDB에 적용된 유일한 자동 최적화지만 LLM이 아니다. "LLM으로 Trino를 튜닝한다"는 프로덕션 사례는 국내외 모두 **없다**고 판단한다.
- **국내 사례 한계:** 카카오·라인·토스·삼성의 Trino 사용 여부는 공개 1차 출처로 확정하지 못했다(부재 ≠ 미사용). 배달의민족 물어보새와 당근페이 브로쿼리는 튜닝이 아니라 생성이며, 후자는 Trino가 아닌 Redshift 기반이다.
- **MCP 안전장치:** read-only는 SQL 문형 필터링 수준이라 우회 가능성이 있고, 실제 리소스 보호는 Trino 서버 설정에 의존한다. dreadew/trino-mcp는 상세 검증을 하지 못했다.
- **시점:** 2026년 7월 기준이며, GenRewrite v3(2025-12)·QUITE 등 일부는 프리프린트 단계로 값이 개정될 수 있다. Altimate AI의 "22% 빠른 실행" 등 벤더 주장 수치는 독립 검증되지 않았다.

---

# 참고 링크 모음

## 논문

| 시스템 | 링크 |
|---|---|
| LLM-R2 | `arxiv.org/abs/2404.12872` / `dl.acm.org/doi/10.14778/3696435.3696440` |
| GenRewrite | `arxiv.org/abs/2403.09060` / `dl.acm.org/doi/10.1145/3786684` |
| R-Bot | `arxiv.org/abs/2412.01661` / DOI 10.14778/3750601.3750625 |
| QUITE | `arxiv.org/abs/2506.07675` |
| LITHE | `arxiv.org/abs/2502.12918` |
| GPTuner | `arxiv.org/abs/2311.03157` / `dl.acm.org/doi/abs/10.14778/3659437.3659449` |
| λ-Tune | `arxiv.org/abs/2411.03500` |
| E2ETune | `arxiv.org/abs/2404.11581` |
| MCTuner | `arxiv.org/abs/2509.06298` |
| D-Bot | `arxiv.org/abs/2312.01454` |
| Presto HBO | `vldb.org/pvldb/vol17/p4077-shankhdhar.pdf` |
| 논문 목록 | `github.com/HKUSTDial/awesome-data-agents` |

## 도구 / 저장소

| 항목 | 링크 |
|---|---|
| mcp-trino (Go) | `github.com/tuannvm/mcp-trino` |
| trino_mcp (Python) | `github.com/stinkgen/trino_mcp` |
| Treasure Data td-skills | `github.com/treasure-data/td-skills` |

## 기업 블로그 / 문서

| 항목 | 링크 |
|---|---|
| Uber QueryGPT | `uber.com/us/en/blog/query-gpt` |
| Uber Presto Express | `uber.com/blog/presto-express` |
| Uber Preon | `uber.com/blog/preon/` |
| Presto HBO 블로그 | `prestodb.io/blog/2024/09/26` |
| Starburst Galaxy AI | `docs.starburst.io/starburst-galaxy/starburst-ai` |
| Starburst 쿼리 플랜 이해 | `starburst.io/blog/understanding-query-plans/` |
| 우아한형제들 물어보새 | `techblog.woowahan.com/18144/` |
| SK플래닛 Trino | `techtopic.skplanet.com/trino/` |
| 당근페이 Text-to-SQL | `aws.amazon.com/ko/blogs/tech/daangnpay-text-to-sql-2/` |
| Trino 적응형 플랜 최적화 | `trino.io/docs/current/optimizer/adaptive-plan-optimizations.html` |
