# tuannvm/mcp-trino — 아키텍처 분석 및 기능 보강점

> 작성일: 2026년 7월 31일
> 분석 대상: `github.com/tuannvm/mcp-trino` main 브랜치 (v4.2.0, 2026-07-31 clone)
> 선행 문서: [01-mcp-trino-poc-설계.md](01-mcp-trino-poc-설계.md)
> 분석 방법: 전체 소스 정독(테스트 제외 3,627 LOC) + 하부 드라이버(trinodb/trino-go-client) 대조 + open 이슈 검토

---

## 목차

- [1부. 아키텍처](#1부-아키텍처)
  - [1. 전체 구조](#1-전체-구조--한-바이너리-두-프론트엔드-하나의-정책-지점)
  - [2. 설계의 중심축 세 가지](#2-설계의-중심축-세-가지)
  - [3. 인증 — 두 방향의 분리](#3-인증--두-방향이-완전히-분리되어-있다)
  - [4. 주의해서 볼 지점](#4-주의해서-볼-지점)
  - [5. 배포 형태](#5-배포-형태-4가지)
- [2부. 기능 보강점](#2부-기능-보강점)
  - [A. 드라이버는 지원하는데 mcp-trino가 안 쓰는 것](#a-드라이버는-지원하는데-mcp-trino가-안-쓰는-것--저비용고가치)
  - [B. 신규 툴이 필요한 것](#b-신규-툴이-필요한-것)
  - [C. 버그·견고성](#c-버그견고성)
  - [D. 운영 편의](#d-운영-편의-후순위)
  - [종합 판단](#종합-판단)

---

# 1부. 아키텍처

## 1. 전체 구조 — 한 바이너리, 두 프론트엔드, 하나의 정책 지점

```
                       cmd/main.go  ── 모드 디스패처 (258 LOC)
                    ┌───────┴───────┐
          MCP 모드  │               │  CLI 모드
                    ▼               ▼
        internal/mcp/           cmd/cli.go (686 LOC)
        ├ server.go   전송/OAuth  ├ 플래그·서브커맨드 파싱
        └ handlers.go 툴 6개      └ internal/cli/
             │                       ├ commands.go  출력 포맷(table/json/csv)
             │                       ├ repl.go      대화형 셸
             │                       └ config.go    프로필 → 환경변수
             └───────────┬───────────┘
                         ▼
        internal/config/config.go   환경변수 → TrinoConfig (단일 수렴점)
                         ▼
        internal/trino/client.go    ★ 정책 게이트 + database/sql (701 LOC)
                         ▼
        trinodb/trino-go-client → Trino Coordinator
```

외부 의존은 4개뿐:

| 모듈 | 역할 |
|---|---|
| `mark3labs/mcp-go` | MCP 프로토콜 (stdio + StreamableHTTP) |
| `trinodb/trino-go-client` | Trino 공식 Go 드라이버 (`database/sql`) |
| `tuannvm/oauth-mcp-proxy` | MCP 클라이언트 → MCP 서버 방향 OAuth 2.1 |
| `yaml.v3` | CLI 프로필 파일 |

## 2. 설계의 중심축 세 가지

### (a) 모든 툴이 SQL 한 줄로 환원된다

툴 6개가 전부 `ExecuteQueryWithContext()` 하나를 거친다:

| 툴 | 실제 실행 SQL |
|---|---|
| `list_catalogs` | `SHOW CATALOGS` |
| `list_schemas` | `SHOW SCHEMAS FROM <catalog>` |
| `list_tables` | `SHOW TABLES FROM <catalog>.<schema>` |
| `get_table_schema` | `DESCRIBE <catalog>.<schema>.<table>` |
| `explain_query` | `EXPLAIN [(TYPE LOGICAL\|DISTRIBUTED\|VALIDATE\|IO)] <query>` |
| `execute_query` | 입력 그대로 |

**결과:** read-only 필터·타임아웃·`MaxRows` 절단·어트리뷰션 헤더가 모든 툴에 일괄 적용된다.
게이트를 빠뜨릴 경로가 구조적으로 없다.

부수 효과 — `explain_query` 툴에는 **ANALYZE 옵션이 없다**(TYPE 4종뿐). 실측 플랜은
`execute_query`로 `EXPLAIN ANALYZE ...`를 보내야 한다. 튜닝 워크플로가 `execute_query`에
의존하게 되는 이유다.

### (b) 환경변수가 단일 진실 공급원

CLI 플래그도 프로필 파일도 최종적으로 `os.Setenv()`를 거쳐
`config.NewTrinoConfigWithVersion()`이 환경변수를 읽는다.
우선순위: **플래그 > 프로필 > 기존 환경변수 > 기본값**.

- 장점: MCP 모드와 CLI 모드가 설정 경로를 100% 공유
- 대가: 플래그가 없는 항목은 환경변수로만 제어 — `TRINO_SCHEME`이 정확히 이 경우
  (01 문서 §1-4 함정)

### (c) 정책 게이트는 `client.go` 한 곳뿐

```go
ExecuteQueryWithContext(ctx, query):
    query = TrimSuffix(TrimSpace(query), ";")        // ① 끝 세미콜론 1개 자동 제거
    if !AllowWriteQueries && !isReadOnlyQuery(query) // ② 정규식 기반 필터
        return error
    ctx, cancel = WithTimeout(ctx, c.timeout)        // ③ 타임아웃 (기본 300초)
    rows = db.QueryContext(ctx, query,
        Named("X-Trino-Client-Tags", user),          // ④ 어트리뷰션
        Named("X-Trino-Client-Info", user),
        Named("X-Trino-User", impersonated))         //   impersonation 켤 때만
    for rows.Next():
        if len(results) >= MaxRows: truncated=true; break   // ⑤ 행 절단
```

②는 **파서가 아니라 정규식 문자열 검사**다. 리터럴/주석을 먼저 치환해 오탐을 줄이지만,
`TRINO_ALLOWED_*`가 이 경로에 없다는 점(01 문서 §1-6)과 합쳐 보면
**이 계층은 "실수 방지"이지 "권한 통제"가 아니다.**

## 3. 인증 — 두 방향이 완전히 분리되어 있다

```
Claude/Cursor ──[방향 A: OAuth 2.1 / JWT]──> mcp-trino ──[방향 B: HTTP Basic]──> Trino
                  oauth-mcp-proxy 위임                     url.UserPassword()
                  HTTP 전송에서만 동작                       유일한 수단
```

- **방향 A** (`OAUTH_ENABLED`, `OIDC_*`, `JWT_SECRET`): `oauth-mcp-proxy`에 위임, MCP 툴
  미들웨어로 삽입. `native`(토큰 검증만) / `proxy`(서버가 IdP 클라이언트) 두 모드.
  **stdio 전송에서는 헤더가 없어 무의미.**
- **방향 B**: DSN에 `user:password`뿐. **bearer 토큰을 Trino로 보내는 경로가 코드에 없다.**
  → 우리 클러스터(OAUTH2 전용)에 그대로 못 붙는 원인 (01 문서 §0 문제 1)

두 방향을 잇는 유일한 다리가 **impersonation**: `TRINO_ENABLE_IMPERSONATION=true`이면
방향 A의 OAuth 사용자를 `X-Trino-User` 헤더로 방향 B에 전달.
반대로 **stdio + OAuth 미사용 조합(PoC 1·2단계)에서는 모든 쿼리가 `TRINO_USER` 단일
정체성**으로 나가고, 어트리뷰션 사용자명은 `mcp-trino-user`로 고정된다.

## 4. 주의해서 볼 지점

- **SQL 문자열 보간.** `fmt.Sprintf("SHOW SCHEMAS FROM %s", catalog)` — MCP 인자를 검증 없이
  보간한다. `execute_query`가 이미 임의 SQL을 허용하므로 권한 상승은 아니지만,
  파라미터 바인딩이 아니라는 점은 알고 있을 것.
- **타임아웃은 서버 측 취소까지 전파된다.** context 취소 → 드라이버 `rows.Close()` →
  `DELETE /v1/query/{queryID}` 전송 (trino-go-client `trino.go:1616`). 즉 타임아웃이 걸리면
  Trino 쪽 쿼리도 취소된다. 다만 **임의 쿼리를 골라 취소하는 툴은 없다** (→ 2부 B1).
- **MaxRows 절단 처리가 꼼꼼하다.** 절단 시 `rows.Close()`를 먼저 호출해 서버 스트리밍을
  끊고 `rows.Err()` 검사를 건너뛴다(허위 취소 에러 방지). MCP 응답은
  `structuredContent`(truncated 메타) + text(순수 JSON 배열, 구버전 호환) 이중 구조.
- **툴 어노테이션.** `execute_query`만 `DestructiveHint(true)`, 나머지 5개는
  `ReadOnlyHint(true)`. `TRINO_ALLOW_WRITE_QUERIES=true` 가능성 때문이며, 호스트 승인 UI의
  근거가 된다.

## 5. 배포 형태 (4가지)

| 형태 | 산출물 | 비고 |
|---|---|---|
| 바이너리 | goreleaser / `install.sh` / Homebrew | `~/.local/bin`, stdio용 |
| Docker | 멀티스테이지 → alpine, `ghcr.io/tuannvm/mcp-trino` | 컨테이너 내 바이너리명은 `trino-mcp` |
| Helm 차트 | `charts/mcp-trino` (deployment/hpa/ingress/networkpolicy/pdb/rbac) | HTTP 전송 전제. HPA 다중 파드 + proxy 모드는 `JWT_SECRET` 공유 필요 |
| Claude Code 플러그인 | `.claude-plugin/` + `install-binary.mjs` | node 런처가 바이너리 다운로드 후 실행 |

PoC 1·2단계는 **바이너리 + stdio**, 3단계도 port-forward 기준이면 동일.
Helm 차트는 팀 공용화 시점에 검토.

---

# 2부. 기능 보강점

기준: (1) PoC 튜닝 워크플로의 결핍, (2) 하부 드라이버가 이미 지원하는지, (3) upstream 이슈 현황.

**핵심 발견: 필요 기능 상당수를 trino-go-client 드라이버가 이미 지원하는데 mcp-trino가
노출하지 않고 있다.** fork/patch 작업량이 예상보다 작다.

## A. 드라이버는 지원하는데 mcp-trino가 안 쓰는 것 — 저비용·고가치

| # | 보강 | 드라이버 근거 | PoC 가치 |
|---|---|---|---|
| **A1** | **JWT/Bearer 인증** (`TRINO_ACCESS_TOKEN` 신설) | `Config.AccessToken` 필드 — JWT 인증 공식 지원. mcp-trino는 `url.UserPassword()`만 사용 | **최대.** Keycloak 토큰을 그대로 쓰면 3단계의 `OAUTH2,PASSWORD` 전환 + 3중 등록이 통째로 불필요해질 수 있음. 단 토큰 만료 시 재발급→재기동 필요 (장기 실행은 refresh 로직 추가) |
| **A2** | **세션 프로퍼티** 노출 | DSN `session_properties` 파라미터 + `Config.SessionProperties` 지원 (`query_max_run_time:10m;query_priority:2` 형식) | **최대.** `SET SESSION` 차단을 SQL 없이 우회. `execute_query`에 `session_properties` 인자를 추가하면 `join_distribution_type` 등 튜닝 실험이 MCP 안에서 가능 — read-only 필터를 건드리지 않아 안전성 유지 |
| **A3** | **queryId + 실행 통계 노출** | `ProgressUpdater` 인터페이스가 `QueryProgressInfo{QueryId, QueryStats}` 콜백 제공. mcp-trino 미사용 → 결과에 queryId 없음 | **큼.** queryId가 있어야 `system.runtime.queries`/쿼리 JSON에서 스테이지 스큐·스필·피크 메모리를 수집해 [trino_bench_compare-v2.py](../../scripts/trino_bench_compare-v2.py)에 연결 가능. 현재는 쿼리 텍스트로 역검색해야 함 |
| A4 | X-Trino-Role 전달 | `sql.Named("X-Trino-Role", ...)` 지원 | 낮음 (우리는 OPA 사용) |

## B. 신규 툴이 필요한 것

| # | 보강 | 내용 |
|---|---|---|
| B1 | `cancel_query` 툴 | 임의 queryId 취소. `CALL system.runtime.kill_query(...)`는 read-only 필터(`call`)에 막히므로 **사용자 SQL 경로가 아닌 전용 핸들러**로 구현 — 드라이버의 `DELETE /v1/query/{id}` 재사용이 가장 깔끔. 조사 문서의 "쿼리 취소 기능" 요건 충족 |
| B2 | `explain_query`에 ANALYZE 포맷 | 현재 TYPE 4종뿐. `EXPLAIN ANALYZE [VERBOSE]` 추가 시 실측 플랜이 read-only 힌트 달린 정식 툴로 제공됨 (현재는 `execute_query` 우회) |
| B3 | `get_query_stats(query_id)` 툴 | `system.runtime.queries` + `/v1/query/{id}` JSON 요약. A3와 세트로 측정 단계 자동화 |
| B4 | 통계 갱신 (`ANALYZE <table>`) | 시작 패턴에 없어 차단. CBO 개선의 선행 작업이므로 `TRINO_ALLOW_ANALYZE=true` 같은 **별도 게이트**로 허용 (쓰기 전체 해제보다 안전) |

## C. 버그·견고성

| # | 항목 | 내용 |
|---|---|---|
| C1 | **이슈 #161 (open): 주석 시작 쿼리 오탐** | `-- comment\nSELECT ...`에서 개행 치환·주석 제거 순서 문제로 쿼리 전체가 지워져 거부된다는 보고. 현재 main은 sanitize가 개행 치환보다 먼저라 수정된 것으로 보이나 이슈는 열려 있음. **LLM은 SQL 앞에 주석을 흔히 붙이므로** 1단계 체크리스트에 `"-- test\nSELECT 1"` 케이스 추가 |
| C2 | 허용목록이 `execute_query`에 미적용 | 01 문서 §1-6 참고. 제대로 하려면 SQL 파서 필요 — 우리는 Trino 측 OPA로 방어, upstream에는 문서화 수준 기여가 현실적 |
| C3 | read-only 필터의 과차단 | `set`/`call`/`execute`/`refresh`가 단어 경계로 전역 검사됨. 파서 기반 판정이 근본 해결이나, 단기로는 거부 메시지에 "걸린 키워드"를 명시하는 것만으로 에이전트의 불필요한 재시도를 줄임 |

## D. 운영 편의 (후순위)

- Prometheus 메트릭 없음 (`/status` JSON뿐) — 쿼리 수/지연/거부 카운터
- `execute_query`에 per-call `max_rows` 인자 (현재 전역 `TRINO_MAX_ROWS`뿐, 페이지네이션 없음)
- 쿼리 감사 로그 — stdio 모드에선 전 쿼리가 `TRINO_USER` 단일 정체성이라 특히 필요

## 종합 판단

- **A1+A2+A3가 우선순위 1.** 셋 다 드라이버가 이미 지원하므로 각각 수십 줄 규모 패치이고,
  합치면 튜닝 루프의 3대 결핍(인증 방식·세션 실험·측정 자동화)이 전부 풀린다.
- 저장소는 활발하다 (Expedia 채택 이슈 #152, v4.2.0). **fork보다 upstream PR을 먼저 검토** —
  특히 A1은 open 이슈 #52(Trino OAuth2 인증 지원 요청)·#159(basic auth)와 정확히 겹치는
  주제라 수용 가능성이 있다.
- PoC 일정 기준: **1·2단계는 현재 기능으로 충분.** 보강이 실제 필요해지는 시점은
  3단계(A1)와 4단계(A2·A3)다. [01 문서의 5단계 판정표](01-mcp-trino-poc-설계.md#8-5단계--판정)에
  "fork 또는 보조 툴 추가" 분기가 이미 있으므로 그 시점에 결정한다.

---

## 확인한 소스 (2026-07-31 main 기준)

- mcp-trino: `cmd/main.go`, `cmd/cli.go`, `internal/mcp/{server,handlers}.go`,
  `internal/trino/client.go`, `internal/config/config.go`, `internal/cli/{commands,repl,config}.go`,
  `docs/allowlists.md`, `.claude-plugin/`, `charts/mcp-trino/`, `Dockerfile`
- trino-go-client: `trino/trino.go` (AccessToken, session_properties, ProgressUpdater,
  DELETE /v1/query 취소 경로), README
- upstream 이슈: #52, #152, #159, #161, #173
