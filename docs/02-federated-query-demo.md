# Federated Query Demo — 4-Catalog JOIN

Trino의 핵심 가치는 **federated query**. 한 쿼리로 서로 다른 시스템(OLTP DB,
데이터 레이크, 레거시 warehouse, 내장 샘플)의 데이터를 조인할 수 있다는 점.
이 문서는 1단계에서 구축한 4종 카탈로그를 한 쿼리에서 조인해 실제로 동작함을
검증하는 스크립트.

## 시나리오

| 카탈로그 | 테이블 | 역할 |
|---|---|---|
| `postgresql` | `sales.orders` | OLTP 시스템의 주문 (bootstrap 시 주입된 3 rows) |
| `iceberg` | `test.customer_dim` | 데이터 레이크의 고객 차원 테이블 (고객 ↔ 국가) |
| `hive` | `test.product_map` | 레거시 Hive warehouse의 고객 ↔ 상품 매핑 |
| `tpch` | `tiny.nation` | 내장 샘플 (국가 참조) |

주문 한 건에 대해 **국가(Iceberg) + 구매 상품(Hive) + 표준 국가 메타(TPCH)**를
모두 붙여서 enriched view를 만드는 전형적인 federated 쿼리.

## 편의 함수

> ⚠️ zsh는 변수에 담긴 명령어를 단어 분리 없이 한 토큰으로 처리하므로
> `T="kubectl ..."`로 두면 `zsh: no such file or directory` 에러가 발생합니다.
> bash/zsh 모두에서 동작하도록 **함수**로 정의합니다.

```bash
NS=user-braveji
tq() {
  kubectl -n "$NS" exec deploy/my-trino-trino-coordinator -- trino --execute "$1"
}
```

이후 예제는 모두 `tq "..."` 형태로 호출합니다.

## 1) 보조 테이블 준비

각 명령은 독립 쿼리. 줄 단위로 실행.

```bash
# Iceberg: customer → 국가 매핑 (MinIO s3://iceberg)
tq "CREATE SCHEMA IF NOT EXISTS iceberg.test WITH (location = 's3a://iceberg/test/')"
tq "DROP TABLE IF EXISTS iceberg.test.customer_dim"
tq "
CREATE TABLE iceberg.test.customer_dim AS
SELECT * FROM (VALUES
  ('alpha', 'KOREA'),
  ('beta',  'JAPAN'),
  ('gamma', 'CHINA')
) AS t(customer, nation_name)
"

# Hive: customer → 상품 매핑 (MinIO s3://warehouse)
tq "CREATE SCHEMA IF NOT EXISTS hive.test WITH (location = 's3a://warehouse/test/')"
tq "DROP TABLE IF EXISTS hive.test.product_map"
tq "
CREATE TABLE hive.test.product_map AS
SELECT * FROM (VALUES
  ('alpha', 'laptop'),
  ('beta',  'monitor'),
  ('gamma', 'keyboard')
) AS t(customer, product)
"
```

> Hive 커넥터의 CTAS는 managed table로 생성. schema location 밑에 자동 배치되므로
> 별도 경로 지정 없이 동작함.

## 2) 4-Catalog Federated JOIN

```bash
tq "
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

## 무엇이 증명되는가

| 증명 포인트 | 관찰 방법 |
|---|---|
| **Federated JOIN** 자체 동작 | 4개 catalog가 하나의 쿼리에서 조인됨 |
| **postgresql → JDBC push-down** | `EXPLAIN`에서 postgres side filter/projection이 내려가는 것 확인 |
| **Iceberg on S3(MinIO)** 읽기 | `iceberg.test.customer_dim` 조회 시 worker가 MinIO에서 parquet 읽음 |
| **Hive on S3(MinIO)** 읽기 | `hive.test.product_map`도 동일하게 MinIO에서 읽음 |
| **HMS 공유** | iceberg/hive가 같은 HMS를 쓰므로 `SHOW SCHEMAS`에서 둘 다 `test` 스키마 보임 |

## 3) EXPLAIN으로 push-down 관찰

JDBC catalog는 필터/프로젝션을 원본 DB까지 내려보내 worker로 올라오는 row 수를
줄임.

```bash
tq "
EXPLAIN
SELECT o.order_id, o.amount
FROM postgresql.sales.orders o
WHERE o.amount > 50 AND o.customer = 'alpha'
"
```

plan에 다음 형태의 TableScan이 보이면 push-down 성공:

```
TableScan[postgresql:sales.orders ..., filter = ((amount > DECIMAL '50') AND (customer = 'alpha'))]
```

amount/customer 비교가 postgres에서 수행되어 Trino로 전송되는 데이터가 최소화됨.

## 4) 혼합 집계 예시

OLTP와 lake 데이터를 섞어 국가별 주문 합계 산출:

```bash
tq "
SELECT
    c.nation_name,
    n.regionkey,
    COUNT(*)            AS order_count,
    SUM(o.amount)       AS total_amount
FROM postgresql.sales.orders   o
JOIN iceberg.test.customer_dim c ON c.customer = o.customer
JOIN tpch.tiny.nation          n ON n.name    = c.nation_name
GROUP BY c.nation_name, n.regionkey
ORDER BY total_amount DESC
"
```

## 5) 대용량 Federated JOIN — `iceberg.test.customer_big`

앞의 예제(3 rows)는 기능 검증용이라 튜닝 효과 측정엔 부적합함. tpch `sf1`
(고객 150k, 주문 1.5M, lineitem 6M 수준)을 활용해 **실제로 shuffle/스캔/
조인 비용이 발생하는** federated 쿼리를 만들어 둠. 2단계 튜닝 벤치마크에 그대로
재사용 가능.

### 5-1) 대용량 테이블 준비

```bash
# Iceberg: customer 차원 테이블 (sf1 customer + nation 조인 결과)
tq "DROP TABLE IF EXISTS iceberg.test.customer_big"
tq "
CREATE TABLE iceberg.test.customer_big AS
SELECT
    c.custkey,
    c.name,
    c.mktsegment,
    c.acctbal,
    n.name       AS nation_name,
    n.regionkey
FROM tpch.sf1.customer c
JOIN tpch.sf1.nation   n ON c.nationkey = n.nationkey
"

# Hive: 분석 대상 region 필터 (작은 참조 테이블)
tq "DROP TABLE IF EXISTS hive.test.target_regions"
tq "
CREATE TABLE hive.test.target_regions AS
SELECT * FROM (VALUES
  (0, 'AFRICA',  1.00),
  (1, 'AMERICA', 1.10),
  (2, 'ASIA',    1.20),
  (3, 'EUROPE',  1.05)
) AS t(regionkey, region_name, adjust_factor)
"

# 행 수 확인
tq "SELECT count(*) FROM iceberg.test.customer_big"   -- ~150,000
tq "SELECT count(*) FROM hive.test.target_regions"    -- 4
tq "SELECT count(*) FROM tpch.sf1.orders"             -- ~1,500,000
```

### 5-2) 4-catalog 대용량 federated JOIN

**시나리오**: 특정 region 고객들의 총 구매액과 국가별 순위를 산출. lake 차원테이블
(`iceberg.customer_big`)과 OLTP 대용량 fact 테이블(`tpch.sf1.orders`)을 조인하고,
legacy warehouse의 region 조정 팩터(`hive.target_regions`)와 내장 region
참조(`tpch.sf1.region`)를 함께 사용.

```bash
tq "
WITH customer_orders AS (
    SELECT
        c.custkey,
        c.nation_name,
        c.regionkey,
        SUM(o.totalprice) AS gross_amount
    FROM iceberg.test.customer_big c
    JOIN tpch.sf1.orders           o ON o.custkey = c.custkey
    WHERE o.orderdate BETWEEN DATE '1995-01-01' AND DATE '1996-12-31'
    GROUP BY c.custkey, c.nation_name, c.regionkey
)
SELECT
    r.name                                              AS tpch_region,
    t.region_name                                       AS hive_region_label,
    co.nation_name,
    COUNT(*)                                            AS customer_count,
    SUM(co.gross_amount)                                AS total_gross,
    SUM(co.gross_amount * t.adjust_factor)              AS adjusted_total,
    RANK() OVER (
        PARTITION BY r.name
        ORDER BY SUM(co.gross_amount * t.adjust_factor) DESC
    )                                                   AS nation_rank_in_region
FROM customer_orders              co
JOIN tpch.sf1.region              r ON r.regionkey = co.regionkey
JOIN hive.test.target_regions     t ON t.regionkey = co.regionkey
GROUP BY r.name, t.region_name, co.nation_name
ORDER BY r.name, adjusted_total DESC
"
```

**이 쿼리가 증명하는 것**:

| 요소 | 증명 |
|---|---|
| **Iceberg 대용량 스캔** | `customer_big` 150k rows 전체 read |
| **tpch 대용량 CTE 조인** | `orders` 1.5M rows와 조인 후 group-by |
| **커넥터 간 shuffle** | Iceberg/tpch/hive 간 hash exchange 발생 |
| **Hive 작은 broadcast join** | `target_regions` 4 rows → broadcast 최적화 |
| **Window function** | `RANK() OVER (PARTITION BY ...)` 분산 실행 |

### 5-3) 쿼리 프로파일링

```bash
# 실행 시간 측정
time tq "<위 5-2 쿼리>"

# EXPLAIN으로 실제 실행 계획 확인
tq "
EXPLAIN (TYPE DISTRIBUTED)
WITH customer_orders AS (
    SELECT c.custkey, c.nation_name, c.regionkey, SUM(o.totalprice) AS gross_amount
    FROM iceberg.test.customer_big c
    JOIN tpch.sf1.orders o ON o.custkey = c.custkey
    WHERE o.orderdate BETWEEN DATE '1995-01-01' AND DATE '1996-12-31'
    GROUP BY c.custkey, c.nation_name, c.regionkey
)
SELECT r.name, co.nation_name, SUM(co.gross_amount * t.adjust_factor)
FROM customer_orders co
JOIN tpch.sf1.region          r ON r.regionkey = co.regionkey
JOIN hive.test.target_regions t ON t.regionkey = co.regionkey
GROUP BY r.name, co.nation_name
"
```

Web UI (`https://braveji.trino.quantumcns.ai/ui/`)에서 Query details → Stages 탭을
열어 각 stage의 input/output rows, peak memory, CPU time을 기록. 2단계 튜닝 전/후
값을 비교할 벤치마크 수치.

### 5-4) 추가 쿼리 아이디어 (대용량 + 다양한 연산 패턴)

```bash
# (a) 고객별 RFM 분석 — 대량 집계 + window
tq "
SELECT
    c.nation_name,
    APPROX_PERCENTILE(recency, 0.5)  AS median_recency_days,
    APPROX_PERCENTILE(frequency, 0.5) AS median_frequency,
    APPROX_PERCENTILE(monetary, 0.5)  AS median_monetary
FROM (
    SELECT
        o.custkey,
        DATE_DIFF('day', MAX(o.orderdate), DATE '1996-12-31') AS recency,
        COUNT(*)                                               AS frequency,
        SUM(o.totalprice)                                      AS monetary
    FROM tpch.sf1.orders o
    GROUP BY o.custkey
) r
JOIN iceberg.test.customer_big c ON c.custkey = r.custkey
GROUP BY c.nation_name
ORDER BY median_monetary DESC
"

# (b) Anti-join — Iceberg에 있지만 주문 없는 고객
tq "
SELECT c.nation_name, COUNT(*) AS inactive_customers
FROM iceberg.test.customer_big c
WHERE NOT EXISTS (
  SELECT 1 FROM tpch.sf1.orders o WHERE o.custkey = c.custkey
)
GROUP BY c.nation_name
"
```

## 정리 (Clean-up)

```bash
# 기본 3종 테이블
tq "DROP TABLE  IF EXISTS iceberg.test.customer_dim"
tq "DROP TABLE  IF EXISTS hive.test.product_map"
tq "DROP TABLE  IF EXISTS iceberg.test.t1"

# 대용량 테이블 (5절)
tq "DROP TABLE  IF EXISTS iceberg.test.customer_big"
tq "DROP TABLE  IF EXISTS hive.test.target_regions"

# 스키마 정리
tq "DROP SCHEMA IF EXISTS iceberg.test"
tq "DROP SCHEMA IF EXISTS hive.test"
```

## 2단계 튜닝과의 연결

5절의 대용량 쿼리(특히 5-2)를 **튜닝 전/후로 돌려 latency 비교**하면 리소스 튜닝
효과를 정량적으로 보여줄 수 있음:

```bash
# 튜닝 전
time tq "<5-2 쿼리>"

# helm upgrade로 worker 메모리/JVM 변경 후 재실행
time tq "<5-2 쿼리>"
```

측정 포인트 ([docs/03-resource-tuning-plan.md](03-resource-tuning-plan.md) 0단계 참고):
- Wall-clock latency (3회 중앙값)
- Peak memory per worker (Web UI Stages 탭)
- GC pause 합계 (JMX 차분)
- Input/Output bytes per stage
