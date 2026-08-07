# tuannvm/mcp-trino PoC — 진행 순서 설계

> 작성일: 2026년 7월 31일
> 배경: [LLM-Trino-쿼리튜닝-조사.md](../LLM-Trino-쿼리튜닝-조사.md) §6 · 권고안 1단계 실행 계획
> 대상: `github.com/tuannvm/mcp-trino` (Go, MCP 서버 + CLI 겸용 바이너리)

---

## 목차

- [0. 요약 — 붙이기 전에 알아야 할 것](#0-요약--붙이기-전에-알아야-할-것)
- [1. 사전 조사 결과 (소스 확인)](#1-사전-조사-결과-소스-확인)
- [2. 단계 개요](#2-단계-개요)
- [3. 0단계 — 접근 경로 확보](#3-0단계--접근-경로-확보)
- [4. 1단계 — 로컬 Trino + CLI 모드 검증](#4-1단계--로컬-trino--cli-모드-검증)
- [5. 2단계 — Claude Code MCP 등록](#5-2단계--claude-code-mcp-등록)
- [6. 3단계 — 실 클러스터 연결](#6-3단계--실-클러스터-연결)
- [7. 4단계 — 튜닝 워크플로 검증](#7-4단계--튜닝-워크플로-검증)
- [8. 5단계 — 판정](#8-5단계--판정)
- [9. 리스크 정리](#9-리스크-정리)

---

## 0. 요약 — 붙이기 전에 알아야 할 것

조사 문서는 tuannvm/mcp-trino를 "read-only 기본값·OAuth·쿼리 어트리뷰션이 갖춰진 프로덕션 후보"로 평가했다.
실제 소스와 이 저장소의 설정을 대조한 결과, **그대로는 연결되지 않는다.** 세 가지 이유:

| # | 문제 | 근거 |
|---|---|---|
| 1 | **인증 방식 불일치.** 이 클러스터 Trino는 `authenticationType: "OAUTH2"`(Keycloak)인데, mcp-trino는 Trino에 붙을 때 HTTP Basic만 보낸다. bearer 토큰 경로가 없어 401만 받는다 | [helm/values.yaml:39](../../helm/values.yaml#L39) vs `internal/trino/client.go:121` (`url.UserPassword(...)`) |
| 2 | **작업 호스트에서 클러스터가 안 보인다.** 현재 kubectl 컨텍스트는 `QKS`이고 `user-braveji` namespace가 없음. `braveji.trino.quantumcns.ai` → 115.71.7.200 이지만 `/v1/info`가 nginx `default backend - 404` 반환 | 2026-07-31 실측 |
| 3 | **read-only 필터가 튜닝 작업 일부를 막는다.** `SET SESSION`·`ANALYZE` 불가, 세미콜론 포함 시 거부 | `internal/trino/client.go:196` `isReadOnlyQuery` |

> **중요한 오해 정정:** mcp-trino의 `OAUTH_ENABLED` / `OIDC_*` 설정은 **"MCP 클라이언트 → MCP 서버"** 인증용이다.
> **"MCP 서버 → Trino"** 인증이 아니다. 이걸 켜도 Keycloak OAuth2로 보호된 Trino에 붙지 못한다.

---

## 1. 사전 조사 결과 (소스 확인)

### 1-1. 노출 툴 (MCP) — 6개

`execute_query`, `list_catalogs`, `list_schemas`, `list_tables`, `get_table_schema`, `explain_query`

**쿼리 취소 툴이 없다.** 조사 문서에서 "튜닝 목적이라면 쿼리 취소 기능이 있는 서버를 고를 것"이라고 했으나,
tuannvm 구현에는 없다. 폭주 방지는 `TRINO_QUERY_TIMEOUT`(기본 300초)과 Trino 측 resource group에 의존한다.

### 1-2. CLI 모드 — MCP 클라이언트 없이 단독 실행 가능

한 바이너리가 두 모드를 겸한다. 판별 우선순위 (`cmd/main.go:24-100`):

1. `MCP_PROTOCOL_VERSION` 환경변수 존재 → MCP 서버
2. `--mcp` → MCP 서버 / `--cli` → CLI
3. CLI 서브커맨드·플래그 존재 → CLI
4. 인자 없음 + `MCP_TRANSPORT` 설정됨 → MCP 서버
5. 인자 없음 + TTY → CLI 도움말
6. 그 외(파이프/리다이렉트) → MCP 서버

```
mcp-trino query "<SQL>"                     # execute_query 와 동일 코드 경로
mcp-trino catalogs
mcp-trino schemas  [--catalog X]
mcp-trino tables   [--catalog X] [--schema Y]
mcp-trino describe <table>
mcp-trino explain  "<SQL>"
mcp-trino interactive                       # REPL
mcp-trino config profile list|use <name>|show <name>
```

공통 플래그: `--host --port --user --password --catalog --schema --profile --config --format table|json|csv --version`

> **CLI와 MCP 툴이 같은 `trino.Client`를 탄다.** read-only 필터·타임아웃·행 제한이 CLI에서 그대로 재현되므로,
> **MCP 등록 전에 CLI만으로 검증을 끝낼 수 있다.** 1단계를 CLI로 잡은 이유다.

### 1-3. read-only 필터 상세 (`isReadOnlyQuery`)

| 항목 | 동작 |
|---|---|
| 허용 시작 패턴 | `select` / `show` / `describe` / `explain` / `with` |
| 금지 키워드 (쿼리 어디든, 단어 경계) | `insert update delete drop create alter truncate merge copy grant revoke commit rollback call execute refresh set reset` |
| 세미콜론 | 끝의 `;` **1개는 자동 제거**되므로 통과 (`client.go:327` `TrimSuffix`). 중간 세미콜론이나 `;;`는 거부 = 멀티 statement 차단 |
| `EXPLAIN ANALYZE SELECT ...` | **허용** (`analyze`는 금지 목록에 없음) ← 튜닝 핵심 기능은 살아있음 |
| `SET SESSION ...` | **거부** (`set`) → 세션 프로퍼티 실험은 MCP 밖에서 |
| `ANALYZE <table>` | **거부** (시작 패턴 아님) → 통계 갱신은 MCP 밖에서 |
| `SHOW STATS FOR ...` | 허용 |
| 해제 플래그 | `TRINO_ALLOW_WRITE_QUERIES=true` (README 요약본의 `ALLOW_WRITE_QUERIES`는 오기) |

### 1-4. 환경변수 (`internal/config/config.go`)

| 변수 | 기본값 | 비고 |
|---|---|---|
| `TRINO_HOST` | `localhost` | |
| `TRINO_PORT` | `8080` | |
| `TRINO_USER` | `trino` | DSN의 basic auth user |
| `TRINO_PASSWORD` | (없음) | |
| `TRINO_SCHEME` | **`https`** | **CLI 플래그·프로필로 못 바꾼다. 환경변수 전용** |
| `TRINO_SSL` | **`true`** | |
| `TRINO_SSL_INSECURE` | `true` | |
| `TRINO_CATALOG` / `TRINO_SCHEMA` | `memory` / `default` | |
| `TRINO_QUERY_TIMEOUT` | `300` (초) | |
| `TRINO_MAX_ROWS` | `10000` | |
| `TRINO_ALLOW_WRITE_QUERIES` | `false` | |
| `TRINO_ALLOWED_CATALOGS` / `_SCHEMAS` / `_TABLES` | (없음) | 허용 목록 |
| `TRINO_SOURCE` | `mcp-trino/<version>` | `X-Trino-Source` → resource group selector 키로 활용 가능 |
| `TRINO_ENABLE_IMPERSONATION` / `_FIELD` | `false` / `username` | OAuth 사용자로 `X-Trino-User` 설정 |
| `MCP_TRANSPORT` | — | `stdio` / `http` |

### 1-6. 허용목록(`TRINO_ALLOWED_*`)의 실제 적용 범위 — 중요

**허용목록은 "목록 조회 필터"이지 "실행 차단"이 아니다.** 소스 확인 결과:

| 경로 | 허용목록 적용 |
|---|---|
| `list_catalogs` / `list_schemas` / `list_tables` | ✅ 결과에서 걸러냄 (`filterCatalogs/Schemas/Tables`) |
| `get_table_schema` | ✅ `isTableAllowed`로 거부 |
| **`execute_query`** | ❌ **검사 없음** (`ExecuteQueryWithContext`에 허용목록 코드가 없음) |

즉 `TRINO_ALLOWED_CATALOGS=tpch`를 걸어도 `SELECT * FROM system.runtime.queries`는 그대로 실행된다.
공식 문서도 "Not primary security / Bypass possible"이라고 명시한다(`docs/allowlists.md`).

> **결론: 실질 방어선은 Trino 측(OPA + resource group + 계정 권한)이다.** 허용목록은 에이전트에게
> 불필요한 카탈로그를 안 보여주는 "노이즈 감소" 용도로만 취급할 것.

### 1-5. 프로필 파일

`~/.config/trino/config.json` 또는 `config.yaml`. 구조는 `{current, profiles{}, output{}}`.

**함정 두 개:**
- `config profile` 서브커맨드에 **`add`가 없다** (`list` / `use` / `show`만). 파일을 직접 작성해야 한다.
- 프로필에 **`scheme` 필드가 없다.** `ApplyToEnv`가 `TRINO_SSL`은 세팅하지만 `TRINO_SCHEME`은 건드리지 않는다
  → HTTP 접속은 반드시 `export TRINO_SCHEME=http` 필요.

---

## 2. 단계 개요

```
[0] 접근 경로 확보        kubeconfig / DNS / Trino 응답 확인
     │
[1] 로컬 Trino + CLI      docker trino:480 → mcp-trino CLI 로 단독 검증  ← 위험 0, 여기서 시작
     │
[2] Claude Code MCP 등록  1단계 통과 후 stdio 로 등록, 툴 6개 확인
     │
[3] 실 클러스터 연결      PASSWORD authenticator 추가 + OPA/group/resource-group 3중 등록
     │
[4] 튜닝 워크플로 검증    EXPLAIN ANALYZE 수집 → 재작성 → 등가성 게이트 → 재측정
     │
[5] 판정                  다음 투자 여부 결정
```

각 단계는 독립 커밋 단위. 1→2 순서를 지키는 이유는, MCP 등록 상태에서 문제가 나면
"MCP 프로토콜 문제인지 Trino 연결 문제인지" 분리가 안 되기 때문이다.

---

## 3. 0단계 — 접근 경로 확보

| 확인 | 방법 | 통과 기준 |
|---|---|---|
| 클러스터 접근 | 대상 kubeconfig로 `kubectl -n user-braveji get pods` | coordinator/worker Running |
| Trino 응답 | `kubectl -n user-braveji port-forward svc/my-trino 18080:8080` 후 `curl -s localhost:18080/v1/info` | **401** (= 인증이 살아있다는 뜻, 정상) |
| Keycloak | `curl .../realms/trino/.well-known/openid-configuration` | JSON 응답 |

0단계가 막혀도 1·2단계는 로컬만으로 진행 가능하다.

---

## 4. 1단계 — 로컬 Trino + CLI 모드 검증

**목적:** MCP를 걸기 전에 바이너리·연결·필터 동작을 전부 확인한다. 실 클러스터를 건드리지 않으므로 위험 0.

```bash
# 1-1. 로컬 Trino (tpch/tpcds/memory/jmx 카탈로그 기본 탑재)
docker run -d --name trino-lab -p 18080:8080 trinodb/trino:480

# 1-2. 설치 (~/.local/bin 에 설치 → PATH 확인)
curl -fsSL https://raw.githubusercontent.com/tuannvm/mcp-trino/main/install.sh | bash
mcp-trino --version

# 1-3. HTTP 접속을 위한 환경변수 (플래그로는 불가 — §1-4 참고)
export TRINO_SCHEME=http TRINO_SSL=false

# 1-4. 연결 확인
mcp-trino --host localhost --port 18080 --user trino catalogs
mcp-trino --host localhost --port 18080 --user trino --catalog tpch --schema sf1 tables
```

### 검증 체크리스트

`ARGS="--host localhost --port 18080 --user trino --catalog tpch --schema sf1"` 로 두고:

| # | 명령 | 기대 결과 |
|---|---|---|
| 1 | `mcp-trino $ARGS query "SELECT count(*) FROM customer"` | 정상 |
| 2 | `mcp-trino $ARGS query "SELECT count(*) FROM customer;"` | **통과** (끝 세미콜론 자동 제거). `"SELECT 1; SELECT 2"`는 거부 |
| 3 | `mcp-trino $ARGS query "SET SESSION join_distribution_type='BROADCAST'"` | **거부** (`set`) |
| 4 | `mcp-trino $ARGS query "ANALYZE customer"` | **거부** (시작 패턴 아님) |
| 5 | `mcp-trino $ARGS query "EXPLAIN ANALYZE SELECT count(*) FROM orders"` | **통과** |
| 6 | `mcp-trino $ARGS query "SHOW STATS FOR orders"` | 통과 |
| 7 | `mcp-trino $ARGS --format json explain "SELECT * FROM orders o JOIN customer c ON o.custkey=c.custkey"` | JSON 플랜 |
| 8 | `TRINO_MAX_ROWS=10 mcp-trino $ARGS query "SELECT * FROM orders"` | 10행에서 절단 |
| 9 | `TRINO_ALLOWED_CATALOGS=tpch mcp-trino $ARGS query "SELECT * FROM system.runtime.queries"` | **실행됨** — 허용목록은 `execute_query`에 적용되지 않는다 (§1-6). 이 사실 확인이 목적 |
| 9-b | `TRINO_ALLOWED_CATALOGS=tpch mcp-trino $ARGS catalogs` | `tpch`만 표시 |
| 10 | `mcp-trino $ARGS interactive` | REPL 진입 |
| 11 | `mcp-trino $ARGS query "$(printf -- '-- test\nSELECT 1')"` | **통과해야 함** — 주석 시작 쿼리 오탐 이슈(#161) 재현 확인. LLM이 SQL 앞에 주석을 붙이는 일이 흔하므로 중요 ([02 문서 C1](02-mcp-trino-아키텍처-및-보강점.md#c-버그견고성)) |

**완료 기준:** 위 10개 결과를 기록. 특히 3·4번은 4단계 워크플로 설계를 바꾸는 제약이므로 반드시 실측할 것.

---

## 5. 2단계 — Claude Code MCP 등록

1단계 체크리스트를 통과한 뒤에만 진행한다.

```bash
claude mcp add trino-lab \
  -e TRINO_HOST=localhost -e TRINO_PORT=18080 \
  -e TRINO_SCHEME=http -e TRINO_SSL=false \
  -e TRINO_USER=trino -e TRINO_CATALOG=tpch -e TRINO_SCHEMA=sf1 \
  -e MCP_TRANSPORT=stdio \
  -- mcp-trino
```

### 검증 항목

- `/mcp`로 서버 상태 connected 확인
- 툴 6개가 모두 노출되는지
- 1단계에서 CLI로 확인한 거부 케이스(2·3·4번)가 **MCP 툴 호출에서도 동일하게** 거부되는지
- 에이전트가 거부 메시지를 받았을 때 우회를 시도하지 않는지 (예: 세미콜론 제거 후 재시도는 정상, `TRINO_ALLOW_WRITE_QUERIES` 언급은 무시할 것)
- 긴 쿼리에서 타임아웃(`TRINO_QUERY_TIMEOUT`) 동작 — **쿼리 취소 툴이 없으므로** 타임아웃 후 Trino 쪽 쿼리가 실제로 종료되는지 Web UI에서 확인

**완료 기준:** Claude Code 세션에서 자연어 요청만으로 `tpch.sf1`에 대해 EXPLAIN ANALYZE 수집이 되는 것.

---

## 6. 3단계 — 실 클러스터 연결

mcp-trino가 붙으려면 Trino에 Basic 인증 경로가 필요하다(§0 문제 1).

| 안 | 방법 | 평가 |
|---|---|---|
| **A (권장)** | `authenticationType: "OAUTH2,PASSWORD"` + file password authenticator(htpasswd), 전용 계정 `mcp_agent` | 변경 최소. 사람의 브라우저 로그인은 OAUTH2 그대로 유지 |
| B | `OAUTH2,JWT` + 앞단에 `Authorization: Bearer` 주입 프록시 | 비밀번호 경로를 안 열지만 부품이 하나 더 늘어남 |
| C | 인증 없는 테스트 전용 coordinator 별도 기동 | 격리는 최고, 실환경 재현성 낮음 |

### A안 — 세 곳을 동시에 갱신해야 한다

이 저장소에서 사용자 추가는 항상 3중 등록이다. 하나라도 빠지면 조용히 거부된다.

1. **[helm/values.yaml](../../helm/values.yaml)**
   - `server.config.authenticationType: "OAUTH2,PASSWORD"`
   - password authenticator 설정 + htpasswd 시크릿 (bcrypt: `htpasswd -B -C 10 -n mcp_agent`)
   - PASSWORD 인증을 HTTP로 쓰려면 `http-server.authentication.allow-insecure-over-http=true`가 필요한데 [이미 설정되어 있다](../../helm/values.yaml#L69)
   - ⚠️ chart가 구조화된 키를 조용히 무시한 이력이 있다(CLAUDE.md 함정 #2). 적용 후 coordinator 파드에서 `config.properties` 실물을 확인할 것

2. **[manifests/opa/opa-policy-configmap.yaml](../../manifests/opa/opa-policy-configmap.yaml)**
   - `default allow := false`이므로 미등록 사용자는 전부 거부된다
   - `user_to_groups`에 `"mcp_agent": {"trino-analyst"}` 추가 (읽기 전용 그룹)
   - [trino-group-provider-configmap.yaml](../../manifests/opa/trino-group-provider-configmap.yaml)의 `groups.txt`에도 동일하게 추가

3. **[helm/values.yaml resource-groups selectors](../../helm/values.yaml#L163)**
   - `{"group": "root.default", "source": "mcp-trino.*"}` 를 selector 목록 **앞쪽**에 추가
   - `root.default`는 `hardConcurrencyLimit: 2`, `softMemoryLimit: 5%` → 에이전트 폭주 시 클러스터 보호

### mcp-trino 측 안전장치 (이중 방어)

조사 문서 §6이 지적한 "리소스 보호가 Trino 서버 설정에 위임됨"에 대한 대응:

```bash
TRINO_ALLOW_WRITE_QUERIES=false      # 기본값이지만 명시적으로 유지
TRINO_ALLOWED_CATALOGS=tpch,hive,iceberg   # ⚠ 목록 조회 필터일 뿐, execute_query는 못 막는다 (§1-6)
TRINO_QUERY_TIMEOUT=120              # 300 → 하향
TRINO_MAX_ROWS=1000
TRINO_SOURCE=mcp-trino               # resource group selector 매칭 키
```

> `TRINO_ALLOWED_*`는 실행 차단이 아니므로, **카탈로그 접근 제한은 반드시 OPA 정책에서** 걸어야 한다.
> `mcp_agent`를 `trino-analyst` 그룹에 넣는 것만으로 부족하면 OPA에 전용 규칙을 추가할 것.

접속은 **port-forward**(`localhost:18080`, `TRINO_SCHEME=http`)로 시작한다.
ingress 경유는 wildcard 인증서 SAN 불일치 문제(문서 §1의 G21과 동일 원인)가 얽혀 변수가 늘어난다.

**완료 기준:** `list_catalogs`가 카탈로그 4개 반환, `INSERT` 시도 거부,
MCP 쿼리가 Trino Web UI에서 `source=mcp-trino` / `user=mcp_agent`로 식별됨.

---

## 7. 4단계 — 튜닝 워크플로 검증

조사 문서 [권고안 1단계](../LLM-Trino-쿼리튜닝-조사.md)의 "사람-개입 리뷰형"을 한 바퀴 돌린다.
대상은 [TPCH_쿼리_성능요소_분류.md](../TPCH_쿼리_성능요소_분류.md)에서 고른 무거운 TPC-H 쿼리 3~5개.

```
① 컨텍스트 수집 (MCP)   SHOW STATS → EXPLAIN → EXPLAIN ANALYZE
                        ※ 추정 행수 vs 실제 행수 괴리를 LLM에게 가장 먼저 보게 할 것
② LLM 재작성 제안       Trino 고유 규칙 적용
                        (파티션 프루닝 / 브로드캐스트 vs 파티션드 조인 / OR-LIKE → regexp_like)
③ 등가성 게이트         아래 단일 statement로 양방향 차집합
④ 재측정                EXPLAIN ANALYZE 재수집
⑤ 비교 판정             scripts/trino_bench_compare-v2.py 로 run 분포·노이즈 판정
```

### ③ 등가성 검증 쿼리

세미콜론 금지·단일 statement 제약을 만족해야 하므로 `WITH`로 시작하는 한 문장으로 짠다:

```sql
WITH a AS (원본쿼리), b AS (재작성쿼리)
SELECT (SELECT count(*) FROM (SELECT * FROM a EXCEPT SELECT * FROM b)) AS a_minus_b,
       (SELECT count(*) FROM (SELECT * FROM b EXCEPT SELECT * FROM a)) AS b_minus_a
```

둘 다 0이어야 통과. 부동소수점 집계는 순서에 따라 미세 차이가 날 수 있으므로,
집계 컬럼은 `round(x, 6)` 등으로 정규화한 뒤 비교한다.

### 이 단계에서 확인할 한계

- `SET SESSION` 불가 → **세션 프로퍼티 실험은 `trino` CLI로 별도 수행**
- `ANALYZE` 불가 → 통계 갱신도 MCP 밖에서
- 쿼리 취소 툴 없음 → 폭주 시 `system.runtime.kill_query`를 사람이 실행

→ **"MCP 단독으로 튜닝 루프가 닫히는가"의 답은 '아니오'가 될 가능성이 높다.**
그 경계를 명확히 기록하는 것이 4단계의 실제 산출물이다.

### 재사용할 저장소 자산

| 자산 | 용도 |
|---|---|
| [scripts/trino_bench_compare-v2.py](../../scripts/trino_bench_compare-v2.py) | run 분포·워밍업·이상치 판정 후 speedup 비교 |
| [docs/TPCH_쿼리_성능요소_분류.md](../TPCH_쿼리_성능요소_분류.md) | 대상 쿼리 선정 |
| [sql/sample.sql](../../sql/sample.sql), [sql/sample_tuned.sql](../../sql/sample_tuned.sql) | 원본/재작성 쌍 보관 패턴 |
| `TPC-H V3.0.1/` | 데이터 생성 |

---

## 8. 5단계 — 판정

| 조건 | 결론 |
|---|---|
| 등가성 위반 0건 + 기하평균 speedup **1.5배 이상** | 조사 문서 권고안 2단계(등가성 게이트 자체 구현)로 승격 |
| speedup은 나오나 `SET SESSION` 부재가 병목 | mcp-trino fork 또는 세션 프로퍼티 전용 보조 툴 추가 |
| 재작성 회귀(느려짐)가 **5% 초과** | MCP는 진단(EXPLAIN 수집) 전용으로 한정, 재작성은 사람이 수행 |
| 등가성 위반 1건 이상 | 게이트 강화 전까지 재작성 제안 자체를 중단 |

---

## 9. 리스크 정리

| 리스크 | 완화 |
|---|---|
| 에이전트가 무거운 쿼리로 클러스터 점유 | resource group `root.default`(동시 2, 메모리 5%) + `TRINO_QUERY_TIMEOUT=120` |
| 쿼리 취소 수단 부재 | 타임아웃 + `system.runtime.kill_query` 수동 절차를 운영 문서에 기재 |
| PASSWORD authenticator 추가로 인한 공격면 확대 | 전용 계정 1개, bcrypt, OPA에서 읽기 전용 그룹, 카탈로그 허용 목록 |
| read-only 필터 우회 (조사 문서 §주의사항) | 필터는 문자열 검사 수준 — 실질 방어는 OPA + resource group에 둘 것 |
| 재작성 결과가 미묘하게 다름 | §7-③ 등가성 게이트를 **모든** 재작성에 강제 |
| chart 키 드리프트 | 적용 후 `config.properties` 실물 확인 (CLAUDE.md 함정 #2) |

---

## 참고

- 조사 보고서: [LLM-Trino-쿼리튜닝-조사.md](../LLM-Trino-쿼리튜닝-조사.md)
- 아키텍처 분석·보강점: [02-mcp-trino-아키텍처-및-보강점.md](02-mcp-trino-아키텍처-및-보강점.md)
- 튜닝 Skill 설계: [03-trino-튜닝-skill-설계.md](03-trino-튜닝-skill-설계.md)
- 튜닝 웹서비스 설계: [04-trino-튜닝-웹서비스-설계.md](04-trino-튜닝-웹서비스-설계.md)
- 저장소: `github.com/tuannvm/mcp-trino`
- 확인한 소스 (2026-07-31 기준 main): `cmd/main.go`, `cmd/cli.go`, `internal/config/config.go`, `internal/trino/client.go`, `internal/cli/config.go`
