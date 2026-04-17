# Resource Quota Query Demo — 멀티테넌시 환경 Federated Query

3단계(멀티테넌시)에서 OAuth2 인증 + Resource Groups가 적용된 환경에서의
federated query 데모. [docs/02-federated-query-demo.md](02-federated-query-demo.md)의
1단계 버전을 **인증/리소스 격리 환경**에 맞게 업데이트한 문서.

## 1단계 vs 3단계 차이

| 항목 | 1단계 (docs/02) | 3단계 (본 문서) |
|---|---|---|
| 인증 | 없음 (`trino --execute` 직접 실행) | Keycloak OAuth2 토큰 필수 |
| 사용자 구분 | 없음 (단일 anonymous) | etl_/analyst_/bi_/admin_ 접두사 |
| 리소스 격리 | 없음 | Resource Group별 동시성/메모리 제한 |
| 쿼리 실행 방식 | `kubectl exec -- trino --execute` | REST API + Bearer 토큰 (G17: CLI는 HTTP에서 토큰 거부) |
| 외부 접근 | 없음 | `trino --server https://braveji.trino.quantumcns.ai --access-token` |

---

## 사전 조건

- Keycloak OAuth2 연동 완료 (§1)
- Resource Groups 배포 완료 (§2)
- `trino-oauth2` K8s Secret 존재 (Client Secret)
- 사용자 계정: `admin_trino`, `etl_user1`~`5`, `analyst_user1`~`5`, `bi_superset`, `bi_redash`

---

## 편의 함수 — OAuth2 인증 환경

### 방법 A — 클러스터 내부 REST API (개발/검증용)

Trino CLI는 HTTP 환경에서 `--access-token` 전송을 거부하므로 (G17),
coordinator 내부에서는 **curl REST API**로 쿼리를 실행해야 함.

```bash
setopt INTERACTIVE_COMMENTS 2>/dev/null  # zsh에서 인라인 주석 허용

NS=user-braveji
CLIENT_SECRET=$(kubectl -n $NS get secret trino-oauth2 \
  -o jsonpath='{.data.OAUTH2_CLIENT_SECRET}' | base64 -d)
```

Keycloak 토큰 발급 함수:

```bash
kc_token() {
  local USER="$1"
  kubectl -n $NS run "kc-tok-$(echo $USER | tr '_' '-')-$(date +%s)" \
    --rm -i --restart=Never \
    --overrides='{"metadata":{"annotations":{"sidecar.istio.io/inject":"false"}}}' \
    --image=curlimages/curl:8.5.0 -- \
    curl -s -X POST "http://keycloak:8080/realms/trino/protocol/openid-connect/token" \
    -d "grant_type=password" -d "client_id=trino" \
    -d "client_secret=$CLIENT_SECRET" \
    -d "username=$USER" -d "password=changeme-user" \
    2>/dev/null | grep -o '"access_token":"[^"]*"' | cut -d'"' -f4
}
```

Trino REST API 쿼리 실행 함수 (제출 + 결과 폴링).
zsh에서 인라인 주석이 파싱 에러를 일으키므로 (G19 유사) 함수 본문에 `#` 주석을
사용하지 않음:

```bash
tq() {
  local USER="$1"
  local QUERY="$2"
  local TOKEN=$(kc_token "$USER")

  if [ -z "$TOKEN" ]; then
    echo "ERROR: $USER 토큰 발급 실패"
    return 1
  fi

  local RESP=$(kubectl -n $NS exec deploy/my-trino-trino-coordinator -- \
    curl -s -X POST http://localhost:8080/v1/statement \
    -H "Authorization: Bearer $TOKEN" \
    -H "X-Trino-User: $USER" \
    -d "$QUERY")

  local NEXT=$(echo "$RESP" | python3 -c \
    'import sys,json; d=json.load(sys.stdin); print(d.get("nextUri",""))' 2>/dev/null)

  local i
  for i in $(seq 1 60); do
    [ -z "$NEXT" ] && break
    sleep 2
    RESP=$(kubectl -n $NS exec deploy/my-trino-trino-coordinator -- \
      curl -s "$NEXT" \
      -H "Authorization: Bearer $TOKEN" \
      -H "X-Trino-User: $USER")
    NEXT=$(echo "$RESP" | python3 -c \
      'import sys,json; d=json.load(sys.stdin); print(d.get("nextUri",""))' 2>/dev/null)

    echo "$RESP" | python3 -c '
import sys, json
d = json.load(sys.stdin)
if "columns" in d and "data" in d:
  cols = [c["name"] for c in d["columns"]]
  print(" | ".join(cols))
  print("-" * 80)
  for row in d["data"]:
    print(" | ".join(str(x) for x in row))
  sys.exit(0)
elif "error" in d:
  print("ERROR:", d["error"].get("message","unknown"))
  sys.exit(0)
sys.exit(1)
' 2>/dev/null && return 0
  done
  echo "TIMEOUT: 결과 대기 시간 초과"
}
```

> **주의**: `kc_token`은 매 호출마다 ephemeral pod를 생성하므로 반복 호출 시
> 다소 느림. 대량 테스트 시에는 토큰을 변수에 캐싱하여 재사용
> (Realm 설정 `accessTokenLifespan=1800`이므로 30분간 유효).

### 방법 B — 외부 HTTPS CLI (운영/BI 도구용)

외부에서 HTTPS Ingress를 통해 접근할 때는 Trino CLI가 정상 동작:

```bash
TRINO_URL="https://braveji.trino.quantumcns.ai"
KC_URL="https://braveji-keycloak.trino.quantumcns.ai"
```

외부에서 토큰 발급:

```bash
kc_token_ext() {
  local USER="$1"
  curl -sk -X POST \
    "$KC_URL/realms/trino/protocol/openid-connect/token" \
    -d "grant_type=password" -d "client_id=trino" \
    -d "client_secret=$CLIENT_SECRET" \
    -d "username=$USER" -d "password=changeme-user" \
    | python3 -c 'import sys,json; print(json.load(sys.stdin)["access_token"])'
}
```

Trino CLI (외부 HTTPS — 토큰 전송 가능):

```bash
tq_ext() {
  local USER="$1"
  local QUERY="$2"
  local TOKEN=$(kc_token_ext "$USER")
  trino --server "$TRINO_URL" --access-token "$TOKEN" --execute "$QUERY"
}
```

> 외부 접근 시 TLS 인증서가 `*.quantumcns.ai` 와일드카드라
> `*.trino.quantumcns.ai` 서브도메인과 매치되지 않을 수 있음 (G21).
> curl에 `-k` 플래그가 필요하거나, Trino CLI에 `--insecure` 플래그 사용.

---

## 1) 보조 테이블 준비 — ETL 사용자

테이블 생성은 **DDL 권한이 있는 etl_user1** 또는 **admin_trino**로 수행.
analyst/bi 사용자는 read-only이므로 CREATE 불가 (향후 Ranger 적용 시 거부됨).

```bash
# etl_user1 → root.etl 그룹 (DDL+DML 권한)

# Iceberg: customer → 국가 매핑 (MinIO s3://iceberg)
tq etl_user1 "CREATE SCHEMA IF NOT EXISTS iceberg.test WITH (location = 's3a://iceberg/test/')"
tq etl_user1 "DROP TABLE IF EXISTS iceberg.test.customer_dim"
tq etl_user1 "
CREATE TABLE iceberg.test.customer_dim AS
SELECT * FROM (VALUES
  ('alpha', 'KOREA'),
  ('beta',  'JAPAN'),
  ('gamma', 'CHINA')
) AS t(customer, nation_name)
"

# Hive: customer → 상품 매핑 (MinIO s3://warehouse)
tq etl_user1 "CREATE SCHEMA IF NOT EXISTS hive.test WITH (location = 's3a://warehouse/test/')"
tq etl_user1 "DROP TABLE IF EXISTS hive.test.product_map"
tq etl_user1 "
CREATE TABLE hive.test.product_map AS
SELECT * FROM (VALUES
  ('alpha', 'laptop'),
  ('beta',  'monitor'),
  ('gamma', 'keyboard')
) AS t(customer, product)
"
```

---

## 2) 사용자별 Federated Query — Resource Group 검증

### 2-1) admin_trino — root.admin 그룹

```bash
tq admin_trino "
SELECT
    o.order_id,
    o.customer,
    o.amount                         AS order_amount,
    c.nation_name                    AS lake_nation,
    p.product                        AS purchased_item,
    n.name                           AS tpch_nation_name,
    n.regionkey                      AS tpch_region_key
FROM postgresql.sales.orders        o
JOIN iceberg.test.customer_dim      c ON c.customer = o.customer
JOIN hive.test.product_map          p ON p.customer = o.customer
JOIN tpch.tiny.nation               n ON n.name    = c.nation_name
ORDER BY o.order_id
"
```

### 예상 결과

```
 order_id | customer | order_amount | lake_nation | purchased_item | tpch_nation_name | tpch_region_key
----------+----------+--------------+-------------+----------------+------------------+-----------------
        1 | alpha    |       100.00 | KOREA       | laptop         | KOREA            |               2
        2 | beta     |       250.50 | JAPAN       | monitor        | JAPAN            |               2
        3 | gamma    |        42.00 | CHINA       | keyboard       | CHINA            |               2
```

### 2-2) analyst_user1 — root.interactive.analyst 그룹

분석가는 동일한 4-catalog JOIN을 **read-only**로 실행:

```bash
tq analyst_user1 "
SELECT
    o.order_id,
    o.customer,
    o.amount                         AS order_amount,
    c.nation_name                    AS lake_nation,
    p.product                        AS purchased_item
FROM postgresql.sales.orders        o
JOIN iceberg.test.customer_dim      c ON c.customer = o.customer
JOIN hive.test.product_map          p ON p.customer = o.customer
ORDER BY o.order_id
"
```

### 2-3) bi_superset — root.interactive.bi 그룹

BI 도구는 통계성 쿼리 위주. 5초 SLA 대상:

```bash
tq bi_superset "
SELECT
    c.nation_name,
    COUNT(*)        AS order_count,
    SUM(o.amount)   AS total_amount
FROM postgresql.sales.orders   o
JOIN iceberg.test.customer_dim c ON c.customer = o.customer
GROUP BY c.nation_name
ORDER BY total_amount DESC
"
```

### 2-4) Resource Group 배정 확인

각 사용자로 쿼리를 실행한 후, admin으로 그룹 배정을 조회:

```bash
tq admin_trino "
SELECT
    query_id,
    \"user\",
    resource_group_id,
    state,
    query
FROM system.runtime.queries
ORDER BY created DESC
LIMIT 10
"
```

기대 결과:

| user | resource_group_id |
|---|---|
| `admin_trino` | `['root', 'admin']` |
| `etl_user1` | `['root', 'etl']` |
| `analyst_user1` | `['root', 'interactive', 'analyst']` |
| `bi_superset` | `['root', 'interactive', 'bi']` |

---

## 3) Resource Group 격리 검증

### 3-1) ETL 동시성 제한 (hardConcurrencyLimit: 5)

ETL 그룹은 동시 5개까지만 실행. 6번째 쿼리는 큐잉됨:

ETL 대형 쿼리 5개를 동시 실행 (백그라운드):

```bash
for i in $(seq 1 5); do
  tq "etl_user$i" "
    SELECT l.returnflag, sum(l.extendedprice * (1 - l.discount))
    FROM tpch.sf1.lineitem l
    JOIN tpch.sf1.orders o ON l.orderkey = o.orderkey
    WHERE o.orderdate < DATE '1995-01-01'
    GROUP BY l.returnflag
  " &
  sleep 1
done
```

잠시 대기 후 6번째 ETL 쿼리를 제출하면 큐잉됨:

```bash
sleep 5
tq etl_user1 "SELECT count(*) FROM tpch.sf1.lineitem" &
```

admin으로 큐 상태 확인 (기대: etl 쿼리 5개 RUNNING + 1개 QUEUED):

```bash
sleep 3
tq admin_trino "
SELECT \"user\", resource_group_id, state
FROM system.runtime.queries
WHERE state IN ('RUNNING', 'QUEUED')
ORDER BY created DESC
"
wait
```

### 3-2) ETL 부하 속 BI 쿼리 5초 SLA 테스트

ETL이 클러스터를 점유해도 interactive 그룹의 BI 쿼리는 별도 메모리 풀에서 실행:

ETL 대형 쿼리 5개를 백그라운드 실행:

```bash
for i in $(seq 1 5); do
  tq "etl_user$i" "
    SELECT l.returnflag, sum(l.extendedprice * (1 - l.discount))
    FROM tpch.sf1.lineitem l
    JOIN tpch.sf1.orders o ON l.orderkey = o.orderkey
    GROUP BY l.returnflag
  " &
  sleep 1
done
```

ETL 쿼리가 RUNNING 상태가 된 후 BI 쿼리 실행 + 시간 측정:

```bash
sleep 5

echo "--- BI query under ETL load ---"
start_ms=$(python3 -c 'import time; print(int(time.time()*1000))')

tq bi_superset "SELECT count(*) FROM tpch.sf1.customer"

end_ms=$(python3 -c 'import time; print(int(time.time()*1000))')
elapsed=$((end_ms - start_ms))
echo "BI query time: ${elapsed}ms (SLA: <5000ms)"

if [ $elapsed -gt 5000 ]; then
  echo 'FAIL: SLA 위반!'; 
else 
  echo 'PASS: SLA 충족'; 
fi

wait
```

> **참고**: REST API 폴링 오버헤드(kubectl exec + curl 왕복)가 포함되므로
> 순수 쿼리 실행 시간은 Web UI의 `wall_time`에서 확인하는 것이 정확.

### 3-3) 분석가 동시성 제한 (hardConcurrencyLimit: 15)

analyst 쿼리 15개를 동시 실행 (5명 × 3개):

```bash
for i in $(seq 1 5); do
  for j in $(seq 1 3); do
    tq "analyst_user$i" "SELECT count(*) FROM tpch.sf1.orders" &
    sleep 0.5
  done
done
```

16번째 쿼리 제출 → 큐잉 확인:

```bash
sleep 5
tq analyst_user1 "SELECT 1 AS overflow_query" &

sleep 3
tq admin_trino "
SELECT \"user\", resource_group_id, state, count(*)
FROM system.runtime.queries
WHERE state IN ('RUNNING', 'QUEUED')
  AND resource_group_id = ARRAY['root', 'interactive', 'analyst']
GROUP BY \"user\", resource_group_id, state
"

wait
```

---

## 4) 대용량 Federated Query — 사용자별 실행

[docs/02](02-federated-query-demo.md) 5절의 대용량 쿼리를 멀티테넌시 환경에서 재현.

### 4-1) 대용량 테이블 준비 (ETL 사용자)

```bash
tq etl_user1 "DROP TABLE IF EXISTS iceberg.test.customer_big"
tq etl_user1 "
CREATE TABLE iceberg.test.customer_big AS
SELECT
    c.custkey, c.name, c.mktsegment, c.acctbal,
    n.name AS nation_name, n.regionkey
FROM tpch.sf1.customer c
JOIN tpch.sf1.nation   n ON c.nationkey = n.nationkey
"

tq etl_user1 "DROP TABLE IF EXISTS hive.test.target_regions"
tq etl_user1 "
CREATE TABLE hive.test.target_regions AS
SELECT * FROM (VALUES
  (0, 'AFRICA',  1.00),
  (1, 'AMERICA', 1.10),
  (2, 'ASIA',    1.20),
  (3, 'EUROPE',  1.05)
) AS t(regionkey, region_name, adjust_factor)
"

# 행 수 확인
tq etl_user1 "SELECT count(*) FROM iceberg.test.customer_big"   -- ~150,000
tq etl_user1 "SELECT count(*) FROM hive.test.target_regions"    -- 4
```

### 4-2) ETL 사용자 — 대용량 4-catalog JOIN

ETL 그룹(60% 메모리, 동시 5개)에서 실행. 대형 쿼리에 적합한 리소스 할당:

```bash
tq etl_user1 "
WITH customer_orders AS (
    SELECT
        c.custkey, c.nation_name, c.regionkey,
        SUM(o.totalprice) AS gross_amount
    FROM iceberg.test.customer_big c
    JOIN tpch.sf1.orders           o ON o.custkey = c.custkey
    WHERE o.orderdate BETWEEN DATE '1995-01-01' AND DATE '1996-12-31'
    GROUP BY c.custkey, c.nation_name, c.regionkey
)
SELECT
    r.name                                         AS tpch_region,
    t.region_name                                  AS hive_region_label,
    co.nation_name,
    COUNT(*)                                       AS customer_count,
    SUM(co.gross_amount)                           AS total_gross,
    SUM(co.gross_amount * t.adjust_factor)         AS adjusted_total,
    RANK() OVER (
        PARTITION BY r.name
        ORDER BY SUM(co.gross_amount * t.adjust_factor) DESC
    )                                              AS nation_rank_in_region
FROM customer_orders              co
JOIN tpch.sf1.region              r ON r.regionkey = co.regionkey
JOIN hive.test.target_regions     t ON t.regionkey = co.regionkey
GROUP BY r.name, t.region_name, co.nation_name
ORDER BY r.name, adjusted_total DESC
"
```

### 4-3) 분석가 사용자 — 동일 쿼리 read-only 실행

analyst 그룹(35% × 50% = interactive의 절반, 동시 15개)에서 실행.
ETL과 동일 데이터를 읽지만 그룹이 다르므로 ETL 부하와 격리됨:

```bash
tq analyst_user1 "
SELECT
    r.name           AS region,
    co.nation_name,
    COUNT(*)         AS customer_count,
    SUM(co.gross)    AS total_gross
FROM (
    SELECT c.custkey, c.nation_name, c.regionkey, SUM(o.totalprice) AS gross
    FROM iceberg.test.customer_big c
    JOIN tpch.sf1.orders o ON o.custkey = c.custkey
    WHERE o.orderdate BETWEEN DATE '1995-01-01' AND DATE '1996-12-31'
    GROUP BY c.custkey, c.nation_name, c.regionkey
) co
JOIN tpch.sf1.region r ON r.regionkey = co.regionkey
GROUP BY r.name, co.nation_name
ORDER BY r.name, total_gross DESC
"
```

### 4-4) BI 사용자 — 경량 통계 쿼리

BI 그룹(schedulingWeight: 5, 최우선)에서 실행. 5초 SLA 대상:

```bash
tq bi_superset "
SELECT
    c.nation_name,
    c.mktsegment,
    COUNT(DISTINCT c.custkey) AS customer_count,
    SUM(c.acctbal)            AS total_balance
FROM iceberg.test.customer_big c
GROUP BY c.nation_name, c.mktsegment
ORDER BY total_balance DESC
LIMIT 20
"
```

---

## 5) 무엇이 증명되는가

| 증명 포인트 | 관찰 방법 |
|---|---|
| **OAuth2 인증 동작** | 토큰 없이 접근 시 401, 토큰 있으면 쿼리 실행 |
| **사용자 식별** | `system.runtime.queries`의 `"user"` 컬럼에 Keycloak username 표시 |
| **Resource Group 배정** | `resource_group_id`가 사용자 접두사 규칙에 따라 올바르게 매핑 |
| **ETL 동시성 제한** | 6번째 ETL 쿼리가 QUEUED 상태로 대기 |
| **interactive 격리** | ETL 5개 실행 중에도 BI/analyst 쿼리가 즉시 실행 |
| **BI 스케줄링 우선** | interactive 내에서 BI(weight:5) > analyst(weight:2) |
| **Federated JOIN** | 4개 catalog (postgresql, iceberg, hive, tpch) 조인 동작 |
| **DDL 권한 분리** | etl_user가 CREATE TABLE, analyst는 SELECT만 가능 (Ranger 적용 시) |

---

## 6) 실행 후 Resource Group 현황 조회

```bash
# 전체 쿼리 이력에서 그룹별 통계
tq admin_trino "
SELECT
    resource_group_id,
    state,
    COUNT(*)                    AS query_count,
    AVG(wall_time)              AS avg_wall_time,
    MAX(wall_time)              AS max_wall_time,
    SUM(peak_memory_bytes) / (1024*1024*1024) AS total_peak_memory_gb
FROM system.runtime.queries
WHERE created > current_timestamp - INTERVAL '1' HOUR
GROUP BY resource_group_id, state
ORDER BY resource_group_id, state
"
```

---

## 정리 (Clean-up)

ETL 사용자로 테이블 삭제 (DDL 권한 필요):

```bash
# 기본 3종 테이블
tq etl_user1 "DROP TABLE IF EXISTS iceberg.test.customer_dim"
tq etl_user1 "DROP TABLE IF EXISTS hive.test.product_map"

# 대용량 테이블 (4절)
tq etl_user1 "DROP TABLE IF EXISTS iceberg.test.customer_big"
tq etl_user1 "DROP TABLE IF EXISTS hive.test.target_regions"

# 스키마 정리
tq etl_user1 "DROP SCHEMA IF EXISTS iceberg.test"
tq etl_user1 "DROP SCHEMA IF EXISTS hive.test"
```

---

## docs/02와의 관계

| 문서 | 용도 | 인증 | 사용 시점 |
|---|---|---|---|
| [docs/02](02-federated-query-demo.md) | 1단계 federated query 기능 검증 | 없음 | 클러스터 초기 구축 직후 |
| **본 문서** | 3단계 멀티테넌시 환경 검증 | OAuth2 | Resource Groups 배포 후 |

docs/02의 6절(TPC-H 스케일 업)은 본 문서에 포함하지 않음 — 대규모 벤치마크는
멀티테넌시 격리 검증보다는 2단계 리소스 튜닝
([docs/03](03-resource-tuning-plan.md))에서 다루는 것이 적절.
멀티테넌시 SLA 전용 벤치마크는
[docs/04-resource-quota-multitenancy-plan.md](04-resource-quota-multitenancy-plan.md)
§7에서 별도 정의.
