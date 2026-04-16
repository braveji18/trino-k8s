# 7단계 튜닝 — 커넥터 레벨 최적화

[docs/03-resource-tuning-plan.md](03-resource-tuning-plan.md)의 **7. 커넥터 레벨 튜닝** 단계에
해당하는 실제 적용 가이드. 5단계(디스크/spill)까지 인프라 레벨 튜닝이 완료된 상태에서,
**카탈로그별 설정**을 조정하여 쿼리 성능과 안정성을 개선한다.

---

## 1. 현재 카탈로그 설정 현황

[helm/values.yaml](../helm/values.yaml)의 `catalogs:` 섹션. 4개 데이터 카탈로그 + 2개 유틸리티.

| 카탈로그 | 커넥터 | 주요 설정 | 튜닝 포인트 |
|---|---|---|---|
| **hive** | hive | HMS thrift 30/60s timeout, 3 retries, S3(MinIO) | 통계 수집, partition batch, 캐시 |
| **iceberg** | iceberg | hive_metastore, HMS thrift 30/60s, PARQUET | 파일 크기, split weight, 메타데이터 캐시 |
| **postgresql** | postgresql | JDBC, analytics-postgres, case-insensitive | push-down, 커넥션 풀 |
| **tpch** | tpch | splits-per-node=4 | splits 수 조정 |
| jmx | jmx | (기본) | 변경 없음 |
| memory | memory | (기본) | 변경 없음 |

---

## 2. HMS (Hive Metastore) 연결 튜닝

Hive와 Iceberg 카탈로그가 공유하는 HMS 연결이 병목이 되면 모든 lake 쿼리가 느려진다.

### 2-1. 현재 상태

```properties
# hive / iceberg 공통
hive.metastore.uri=thrift://hive-metastore:9083
hive.metastore.thrift.client.connect-timeout=30s
hive.metastore.thrift.client.read-timeout=60s
hive.metastore.thrift.client.max-retries=3
```

HMS는 단일 replica Deployment. 동시 쿼리가 늘면 HMS가 SPOF.

### 2-2. 변경 사항

**Step 1 — 카탈로그 설정 추가** (이번 단계):

```properties
# hive 카탈로그에 추가
hive.metastore-cache-ttl=2m
hive.metastore-refresh-interval=1m
hive.metastore.partition-batch-size.min=10
hive.metastore.partition-batch-size.max=100

# iceberg 카탈로그에 추가

```

| 파라미터 | 값 | 효과 |
|---|---|---|
| `metastore-cache-ttl` | 2m | 테이블/파티션 메타데이터 캐시 2분 유지 |
| `metastore-refresh-interval` | 1m | 캐시 백그라운드 갱신 주기 |
| `partition-batch-size.min/max` | 10/100 | 파티션 목록 조회 시 배치 크기 |

**Step 2 — HMS replica 증설** (선택, 부하 확인 후):

```yaml
# manifests/hive-metastore/hive-metastore.yaml
spec:
  replicas: 2
```

HMS를 2 replica로 올리면 Trino의 `hive.metastore.uri`에 두 엔드포인트를 나열하거나,
Service가 round-robin으로 분산. 현재 단일 Service이므로 replica만 올리면 자동 분산.

---

## 3. Hive 커넥터 튜닝

### 3-1. 쓰기 통계 (collect-column-statistics-on-write)

현재 `false`로 꺼져 있음. [docs/01-trino-cluster-setup.md](01-trino-cluster-setup.md)의 G13에
기록된 대로, Hive 3.1.3의 `TAB_COL_STATS.ENGINE` NOT NULL 제약으로 CTAS 직후 통계
INSERT가 실패하는 문제를 회피하기 위한 것.

**복구 조건**: HMS 백엔드 PostgreSQL에서 `TAB_COL_STATS.ENGINE` 컬럼에 기본값을 추가하는
스키마 패치를 적용한 뒤에만 `true`로 돌릴 수 있음.

```sql
-- HMS PostgreSQL (hms-postgres-rw)에서 실행
ALTER TABLE "TAB_COL_STATS" ALTER COLUMN "ENGINE" SET DEFAULT 'hive';
ALTER TABLE "PART_COL_STATS" ALTER COLUMN "ENGINE" SET DEFAULT 'hive';
```

패치 적용 후:

```properties
# hive 카탈로그
hive.collect-column-statistics-on-write=true
```

통계가 수집되면 Trino optimizer가 join reorder, filter push-down, broadcast vs partitioned
join 결정을 더 정확하게 함 → 특히 federated query에서 효과 큼.

### 3-2. S3 성능 관련

```properties
# hive 카탈로그에 추가
hive.s3.max-connections=100
hive.s3.multipart.min-file-size=16MB
hive.s3.multipart.min-part-size=8MB
```

MinIO가 in-cluster라 네트워크 latency는 낮지만, 동시 split read가 많아지면 커넥션이
부족할 수 있음.

---

## 4. Iceberg 커넥터 튜닝

### 4-1. 파일 크기 & split weight

```properties
# iceberg 카탈로그에 추가
iceberg.target-max-file-size=512MB
iceberg.minimum-assigned-split-weight=0.05
```

| 파라미터 | 기본값 | 변경값 | 효과 |
|---|---|---|---|
| `target-max-file-size` | 1GB | 512MB | 작은 파일로 쪼개 병렬성 향상, MinIO 부하 분산 |
| `minimum-assigned-split-weight` | 0.05 | 0.05 | 작은 split도 워커에 배분 (기본값 유지) |

### 4-2. 메타데이터 캐시 (Trino 480+)

```properties
# iceberg 카탈로그에 추가
iceberg.metadata-cache-enabled=true
iceberg.metadata-cache-ttl=5m
```

Iceberg 테이블의 metadata.json / manifest list 조회를 캐싱. 같은 테이블을 반복 조회하는
벤치마크에서 효과적.

---

## 5. PostgreSQL 커넥터 튜닝

### 5-1. Push-down 강화

```properties
# postgresql 카탈로그에 추가
postgresql.experimental.enable-string-pushdown-with-collate=true
```

문자열 비교 (`WHERE customer = 'alpha'`)가 PostgreSQL까지 내려가 Trino로 올라오는 데이터가
줄어듦. [docs/02-federated-query-demo.md](02-federated-query-demo.md) 3절에서 EXPLAIN으로
push-down 여부를 검증하는 방법이 기록되어 있음.

### 5-2. 커넥션 풀

```properties
# postgresql 카탈로그에 추가
postgresql.connection-pool.max-size=20
postgresql.connection-pool.min-size=5
```

기본 커넥션 풀은 작음. 동시 쿼리가 많아지면 커넥션 획득 대기가 발생할 수 있음.

---

## 6. TPCH 커넥터 튜닝

```properties
# tpch 카탈로그
tpch.splits-per-node=4   # 현재값
```

SF10+ 스케일 테스트에서 CPU 코어 활용률이 낮으면 splits를 늘림:

```properties
tpch.splits-per-node=8    # 또는 16
```

`splits-per-node`는 워커 하나가 받는 split 수. CPU 코어(24 available)보다 적으면
파이프라인 병렬성이 떨어짐. 단, 너무 올리면 스케줄링 오버헤드가 커짐.

벤치마크에서 `EXPLAIN (TYPE DISTRIBUTED)` 결과의 splits 수와 CPU 사용률을 보고 조정.

---

## 7. [helm/values.yaml](../helm/values.yaml) 변경 diff

### Step 1 — 전체 카탈로그 튜닝 (한 커밋)

```yaml
catalogs:
  tpch: |
    connector.name=tpch
    tpch.splits-per-node=8
  jmx: |
    connector.name=jmx
  memory: |
    connector.name=memory
  hive: |
    connector.name=hive
    hive.metastore.uri=thrift://hive-metastore:9083
    hive.metastore.thrift.client.connect-timeout=30s
    hive.metastore.thrift.client.read-timeout=60s
    hive.metastore.thrift.client.max-retries=3
    hive.metastore-cache-ttl=2m
    hive.metastore-refresh-interval=1m
    hive.metastore.partition-batch-size.min=10
    hive.metastore.partition-batch-size.max=100
    fs.native-s3.enabled=true
    s3.endpoint=http://minio:9000
    s3.path-style-access=true
    s3.region=us-east-1
    s3.aws-access-key=minioadmin
    s3.aws-secret-key=changeme-minio-admin
    hive.non-managed-table-writes-enabled=true
    hive.recursive-directories=true
    hive.collect-column-statistics-on-write=false
  iceberg: |
    connector.name=iceberg
    iceberg.catalog.type=hive_metastore
    hive.metastore.uri=thrift://hive-metastore:9083
    hive.metastore.thrift.client.connect-timeout=30s
    hive.metastore.thrift.client.read-timeout=60s
    hive.metastore.thrift.client.max-retries=3
    fs.native-s3.enabled=true
    s3.endpoint=http://minio:9000
    s3.path-style-access=true
    s3.region=us-east-1
    s3.aws-access-key=minioadmin
    s3.aws-secret-key=changeme-minio-admin
    iceberg.file-format=PARQUET
    iceberg.target-max-file-size=512MB
    iceberg.minimum-assigned-split-weight=0.05
  postgresql: |
    connector.name=postgresql
    connection-url=jdbc:postgresql://analytics-postgres-rw:5432/analytics?sslmode=disable
    connection-user=trino_ro
    connection-password=changeme-analytics-pg
    case-insensitive-name-matching=true
    postgresql.experimental.enable-string-pushdown-with-collate=true
```

### Step 2 — Hive 통계 복구 (스키마 패치 후 별도 커밋)

HMS PostgreSQL에서 스키마 패치 실행 후:

```yaml
  hive: |
    ...
    hive.collect-column-statistics-on-write=true   # false → true
```

---

## 8. 적용 & 검증 순서

```bash
NS=user-braveji

# 1) helm upgrade
helm upgrade --install my-trino my-trino/trino -n $NS -f helm/values.yaml --wait --timeout 10m

# 2) 카탈로그 설정 반영 확인
POD=$(kubectl -n $NS get pod -l app.kubernetes.io/component=worker -o name | head -1)
kubectl -n $NS exec "$POD" -c trino-worker -- cat /etc/trino/catalog/hive.properties
kubectl -n $NS exec "$POD" -c trino-worker -- cat /etc/trino/catalog/iceberg.properties
kubectl -n $NS exec "$POD" -c trino-worker -- cat /etc/trino/catalog/postgresql.properties

# 3) 기본 연결 검증
tq() { kubectl -n "$NS" exec deploy/my-trino-trino-coordinator -- trino --execute "$1"; }
tq "SHOW CATALOGS"
tq "SELECT count(*) FROM tpch.sf1.nation"
tq "SELECT count(*) FROM postgresql.sales.orders"
```

### 커넥터별 검증

```bash
# HMS 캐시 동작 확인 — 같은 테이블 2회 조회, 두 번째가 빨라야 함
time tq "SELECT count(*) FROM hive.test.product_map"
time tq "SELECT count(*) FROM hive.test.product_map"

# PostgreSQL push-down 확인
tq "
EXPLAIN
SELECT o.order_id, o.amount
FROM postgresql.sales.orders o
WHERE o.amount > 50 AND o.customer = 'alpha'
"
# → plan에 filter가 postgresql 쪽으로 내려갔는지 확인
# TableScan[..., filter = ((amount > ...) AND (customer = 'alpha'))]

# TPCH splits 확인
tq "
EXPLAIN (TYPE DISTRIBUTED)
SELECT l.returnflag, sum(l.extendedprice*(1-l.discount))
FROM tpch.sf1.lineitem l
GROUP BY l.returnflag
"
# → splits 수가 workers × splits-per-node(8) = 24 근처인지 확인
```

---

## 9. 벤치마크 — tune-7

```bash
tq "SELECT count(*) FROM tpch.sf1.lineitem" >/dev/null  # 워밍업

START_TS=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

# Q3 sf1 (3회)
for i in 1 2 3; do
  echo "=== Q3 sf1 run $i ==="
  start=$(date +%s)
  tq "
    SELECT l.returnflag, sum(l.extendedprice*(1-l.discount))
    FROM tpch.sf1.lineitem l
    JOIN tpch.sf1.orders   o ON l.orderkey = o.orderkey
    WHERE o.orderdate < DATE '1995-01-01'
    GROUP BY l.returnflag
  "
  end=$(date +%s)
  echo "running(초): $((end - start))"
  sleep 5
done

# Q4 federated (3회) — 커넥터 튜닝 효과가 가장 잘 드러나는 쿼리
for i in 1 2 3; do
  echo "=== Q4 federated run $i ==="
  start=$(date +%s)
  tq "
    SELECT
        o.order_id, o.customer, o.amount,
        c.nation_name, p.product, n.name AS tpch_nation
    FROM postgresql.sales.orders        o
    JOIN iceberg.test.customer_dim      c ON c.customer = o.customer
    JOIN hive.test.product_map          p ON p.customer = o.customer
    JOIN tpch.tiny.nation               n ON n.name    = c.nation_name
    ORDER BY o.order_id
  "
  end=$(date +%s)
  echo "running(초): $((end - start))"
  sleep 5
done

END_TS=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
echo "tune-7: start=$START_TS end=$END_TS"
```

### 기대 변화

| 쿼리 | 기대 효과 | 관찰 포인트 |
|---|---|---|
| Q3 sf1 (tpch only) | splits 증가로 CPU 활용 개선 | wall-clock 소폭 개선, `EXPLAIN` splits 수 |
| Q4 federated | HMS 캐시 + PG push-down 효과 | 2회차부터 HMS 호출 감소, PG scan rows 감소 |
| SF10 Q3 | splits 증가로 병렬성 개선 | CPU 사용률 향상, wall-clock 개선 |

수치 기록은 [docs/04-tuning-results.md](04-tuning-results.md)의 `tune-7 (connector)` 컬럼에 누적.

---

## 10. 롤백 규칙

- 카탈로그 설정 오류 시 Trino가 시작되지 않을 수 있음. `kubectl logs`에서
  `Catalog 'hive' failed to initialize` 같은 에러 확인.
- 특정 카탈로그만 문제면 해당 카탈로그의 추가 설정만 제거하고 재배포.
- `hive.collect-column-statistics-on-write=true` 후 CTAS 실패가 다시 발생하면 → 스키마
  패치가 제대로 안 된 것. 즉시 `false`로 롤백하고 HMS PostgreSQL 확인.

---

## 11. 다음 단계

| 결과 | 다음 행동 |
|---|---|
| Q4 federated latency 개선 | 커넥터 튜닝 완료 → **8. 재측정 & 비교** |
| HMS 호출이 여전히 병목 | Step 2 — HMS replica 2로 증설 |
| PG push-down이 안 내려감 | EXPLAIN 분석 후 `enable-string-pushdown-with-collate` 외 추가 설정 검토 |
| 전체 튜닝 완료 | **9. 문서화** — 04-tuning-results.md 마무리 + 01 Gotchas 보완 |
