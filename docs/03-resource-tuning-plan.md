# 2단계: Trino Resource 튜닝 — 진행 순서

1단계에서 동작을 확보했다면, 2단계는 **"이 클러스터의 워크로드에 맞는 설정으로
조율"**. 무작정 메모리부터 키우지 않고, 측정 → 판단 → 조정 → 검증의 순서로 진행.

**측정은 Grafana + Prometheus를 primary 도구로 사용.** JMX→SQL 직접 조회는
신규 메트릭 발굴용 보조수단으로만.

---

## 전체 흐름

```
[0. 준비]          Grafana/Prometheus 확인 + 벤치마크 쿼리 고정
     │
[1. 베이스라인]    Grafana time-window 고정 → 3회 실행 → 대시보드 snapshot
     │             → 04-tuning-results.md 표 기록
     │
[2. 노드 용량]     k8s 노드 가용 리소스 + 스케줄링 여유
     │
[3. 메모리 모델]   Container → JVM heap → query.max-memory-per-node 3계층
     │
[4. JVM 튜닝]      G1GC 파라미터, GC 로깅, 컨테이너 인식
     │
[5. 디스크/셔플]   spill, exchange 경로를 emptyDir → local PV로
     │
[6. 워커 수]       고정 vs HPA, anti-affinity, PDB
     │
[7. 커넥터 레벨]   HMS 연결, hive/iceberg 쓰기 패턴, 통계
     │
[8. 재측정]        동일 벤치마크로 Grafana 비교 뷰 + 04 표 누적
     │
[9. 문서화]        04-tuning-results.md 마무리 + 01 Gotchas 보완
```

각 단계는 **독립 커밋 단위**로 진행. 한 번에 여러 변수를 건드리면 효과 측정 불가.

---

## 0. 준비 — 측정 도구와 벤치마크 쿼리 고정

### 측정 수단 (Primary: Grafana + Prometheus)

Trino 메트릭은 **JMX Exporter javaagent → Prometheus → Grafana** 경로로 수집/시각화.
측정의 90%는 Grafana 대시보드에서 이뤄지고, 상세 분석이 필요할 때만 PromQL 직접
호출 또는 Trino Web UI 보조 사용.

| 용도 | 도구 | 접근 |
|---|---|---|
| **실시간 상태 + 트렌드 시각화 (기본)** | Grafana | [https://braveji-grafana.trino.quantumcns.ai/](https://braveji-grafana.trino.quantumcns.ai/) |
| **PromQL ad-hoc query** | Prometheus | [https://braveji-prom.trino.quantumcns.ai/](https://braveji-prom.trino.quantumcns.ai/) |
| **개별 쿼리 실행 계획 / Stage별 통계** | Trino Web UI | [https://braveji.trino.quantumcns.ai/ui/](https://braveji.trino.quantumcns.ai/ui/) |
| **컨테이너 리소스 (OS 레벨)** | `kubectl top pod` | CLI |
| **이상 동작 디버깅** | pod/coordinator 로그 | `kubectl logs` |

설치/구성은 [scripts/install-monitor.sh](../scripts/install-monitor.sh) 참고.

### Grafana 대시보드

[manifests/monitoring/grafana-dashboard-trino.yaml](../manifests/monitoring/grafana-dashboard-trino.yaml)
의 "Trino Cluster Overview"를 기본으로 사용. 9개 패널 구성:

| 구역 | 패널 | PromQL 근거 |
|---|---|---|
| 상단 | Running / Queued / Completed rate / Failed rate | `trino_execution_*` |
| 2행 | JVM Heap (per pod) / GC Collection Time rate | `jvm_memory_*`, `jvm_gc_*` |
| 3행 | Cluster Memory Pool / Worker Memory Pool | `trino_memory_*` |
| 4행 | Spill Bytes / HMS Call Rate | `trino_spiller_*`, `trino_hive_metastore_*` |

튜닝 각 단계에서 기록해야 할 값은 모두 이 대시보드의 패널 위에서 확인 가능.

### 벤치마크 실행 중 관찰할 핵심 PromQL

Grafana "Explore" 탭에서 직접 찍어 볼 쿼리. 각 쿼리의 기대값/임계는 베이스라인 측정 후
04 문서에 기록.

```promql
# (1) 쿼리 매니저 상태
sum(trino_execution_running_queries)
sum(trino_execution_queued_queries)
sum(rate(trino_execution_completedqueries_total[5m]))
sum(rate(trino_execution_failedqueries_total[5m]))

# (2) JVM Heap 사용률 (80% 이상이면 위험)
jvm_memory_heap_memory_usage_used_bytes
  / jvm_memory_heap_memory_usage_max_bytes

# (3) GC pause — 쿼리 실행 중 스파이크 확인
sum by (pod) (rate(jvm_gc_collectiontime[1m]))

# (4) 클러스터 user memory reservation (query.max-memory 튜닝 근거)
trino_memory_cluster_clusterusermemoryreservation
trino_memory_cluster_pool_reservedbytes{pool="general"}
trino_memory_cluster_pool_maxbytes{pool="general"}

# (5) Worker 메모리 풀 포화도 (단일 워커의 max-memory-per-node 튜닝 근거)
max by (pod) (
  trino_memory_pool_reservedbytes{pool="general"}
    / trino_memory_pool_maxbytes{pool="general"}
)

# (6) Spill 발생 — 큰 쿼리가 메모리 부족으로 디스크로 빠지는지
rate(trino_spiller_totalspilledbytes[5m])

# (7) HMS 호출 rate (커넥터 병목 관찰)
sum by (method) (rate(trino_hive_metastore_*_alltime_count[5m]))
```

> 메트릭 이름은
> [manifests/monitoring/trino-jmx-exporter-config.yaml](../manifests/monitoring/trino-jmx-exporter-config.yaml)
> 의 rule에 따라 결정됨. 실제 이름은 Prometheus의 label 탐색으로 항상 재확인:
> ```
> curl -sG https://braveji-prom.trino.quantumcns.ai/api/v1/label/__name__/values \
>   | jq -r '.data[]' | grep '^trino_'
> ```

### Grafana에서 측정하는 표준 절차

벤치마크 쿼리 한 번 돌릴 때마다 아래 4단계로 수치를 남긴다.

1. **Time window 고정**: Grafana 우상단 time picker를 "Last 5 minutes" 같은 상대값 대신
   **절대 시각**으로 맞춤(쿼리 시작 직전 ~ 종료 직후). 이유: 재측정 시 동일 window를
   비교 가능하게 하기 위함.
2. **대시보드 캡처**: 스크린샷 또는 "Share → Snapshot"으로 JSON 저장.
3. **핵심 수치 추출**: 각 패널의 최댓값/평균값을 `docs/04-tuning-results.md` 표에 기록.
4. **Query detail**: 해당 쿼리의 `query_id`를 Trino Web UI에서 찾아 stage별 peak memory,
   CPU time, input rows도 기록 (PromQL만으로는 안 보이는 per-stage 상세).

### (보조) JMX 카탈로그 — Grafana에 없는 메트릭이 필요할 때만

Grafana + Prometheus로 충분하지만, JMX exporter rule에 정의되지 않은 MBean을 즉석에서
보고 싶을 때 SQL로 직접 접근할 수 있음. 일상 튜닝에는 쓰지 않고 **신규 메트릭 발굴용**
으로만 사용.

```sql
-- trino 네임스페이스 MBean 목록
SELECT table_name
FROM jmx.information_schema.tables
WHERE table_schema = 'current' AND table_name LIKE 'trino.%'
ORDER BY table_name;

-- 특정 MBean 전체 필드 덤프 (한 row)
SELECT * FROM jmx.current."trino.execution:name=querymanager" LIMIT 1;
```

유용한 MBean이 발견되면 → `trino-jmx-exporter-config.yaml`에 rule 추가 → helm upgrade
→ Grafana 대시보드에 패널 신설. **"일회성 JMX 쿼리 → 항상 보이는 Grafana 패널"로
승격하는 워크플로**를 유지.

### (보조) Memory 카탈로그 — I/O 변수 배제

외부 PG/S3 I/O를 배제하고 **순수 연산 성능만** 재고 싶을 때 사용. 메모리/CPU 설정
변경의 효과를 선명하게 관찰할 수 있음.

```sql
-- 작은 세트를 memory로 적재
CREATE TABLE memory.default.lineitem_small AS
SELECT * FROM tpch.sf1.lineitem WHERE orderkey < 1000000;

-- 벤치마크
SELECT returnflag, sum(extendedprice * (1 - discount))
FROM memory.default.lineitem_small
GROUP BY returnflag;

DROP TABLE memory.default.lineitem_small;
```

주의:
- 데이터는 coordinator/worker 재시작 시 **소실**
- 테이블 크기는 worker heap 범위 내
- worker 간 round-robin distribution → 실제 Iceberg/Hive join skew와 다름

### 벤치마크 쿼리 (고정)
리소스 튜닝 전/후를 비교하려면 **같은 쿼리 세트를 반복 실행**해야 의미 있음.

- **Q1. Point lookup**: `SELECT * FROM tpch.sf1.customer WHERE custkey = 12345`
  — 목표: <100ms, scan 최소화 확인
- **Q2. Aggregation**: `SELECT nationkey, sum(acctbal) FROM tpch.sf1.customer GROUP BY nationkey`
  — 목표: 중간 크기 aggregation, worker 간 exchange 발생
- **Q3. Join**:
  ```sql
  SELECT l.returnflag, sum(l.extendedprice * (1 - l.discount))
  FROM tpch.sf1.lineitem l JOIN tpch.sf1.orders o ON l.orderkey = o.orderkey
  WHERE o.orderdate < DATE '1995-01-01'
  GROUP BY l.returnflag
  ```
  — 목표: 대용량 조인 + exchange + spill 유도
- **Q4. Federated** ([docs/02-federated-query-demo.md](02-federated-query-demo.md)의 4-catalog JOIN)
  — 목표: 커넥터 연결/메타데이터 지연 포함 end-to-end

각 쿼리를 **3회 실행하고 중앙값**을 기록. 캐시 효과를 배제하려면 첫 실행은 warm-up으로 버림.

---

## 1. 베이스라인 측정

튜닝 전 숫자를 고정. 못 재면 개선 여부를 주장할 수 없음.
기본 흐름: **Grafana time window 고정 → 벤치마크 실행 → 대시보드 캡처 → 수치 추출**.

### 1-1. 준비

```bash
NS=user-braveji
tq() { kubectl -n "$NS" exec deploy/my-trino-trino-coordinator -- trino --execute "$1"; }

# 워밍업 (캐시 워밍 + JIT, 결과값은 버림)
tq "SELECT count(*) FROM tpch.sf1.lineitem" >/dev/null
```

1. Grafana 접속: [https://braveji-grafana.trino.quantumcns.ai/](https://braveji-grafana.trino.quantumcns.ai/)
2. "Trino Cluster Overview" 대시보드 열기
3. 시작 시간 기록 (`date` 명령)

### 1-2. 벤치마크 실행 (3회)

```bash
START_TS=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
echo "baseline start: $START_TS"

for i in 1 2 3; do
  echo "=== Q3 run $i ==="
  start=$(date +%s)
  time tq "
    SELECT l.returnflag, sum(l.extendedprice*(1-l.discount))
    FROM tpch.sf1.lineitem l
    JOIN tpch.sf1.orders   o ON l.orderkey = o.orderkey
    WHERE o.orderdate < DATE '1995-01-01'
    GROUP BY l.returnflag
  "
  end=$(date +%s)  
  diff=$((end - start))
  echo "running(초): $diff"  
  sleep 5  # 메트릭 scrape 간격(30s) 여유
done

END_TS=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
echo "baseline end: $END_TS"
```

### 1-3. Grafana에서 수치 추출

1. Time picker → **"Absolute time range"** → `$START_TS` ~ `$END_TS`
   (30초 정도 앞뒤로 여유) → Apply
2. 대시보드 전체 스크린샷 또는 `Share → Snapshot` 저장
3. 아래 표에 값 기입

### 1-4. 기록 템플릿 (docs/04-tuning-results.md에 복사)

```markdown
## Baseline (YYYY-MM-DD HH:MM)

### 환경
- Trino image: harbor.quantumcns.ai/akashiq/trino:480-jmx
- Coordinator: N cores / X Gi heap
- Worker count: N
- Worker: N cores / X Gi heap, query.max-memory-per-node=XGi

### Q3 (TPCH sf1 join)

| run | wall-clock | coordinator CPU | worker peak heap | GC pause total | spill bytes |
|-----|-----------:|-----------------|------------------|---------------:|------------:|
|  1  |      X.Xs  |                 |                  |           Xms  |           0 |
|  2  |      X.Xs  |                 |                  |           Xms  |           0 |
|  3  |      X.Xs  |                 |                  |           Xms  |           0 |
| median |   **X.Xs** |              |                  |                |             |

- Grafana snapshot: <URL>
- Trino query_id: <id1>, <id2>, <id3>
- Notes: ...
```

### 1-5. Grafana 패널별 추출 가이드

| 기록 항목 | Grafana 패널 / PromQL |
|---|---|
| **wall-clock latency** | `time tq ...` 출력 (Grafana 아님) |
| **running queries peak** | "Running Queries" 패널 or `max(trino_execution_running_queries)` |
| **Worker peak heap** | "JVM Heap Usage" 패널의 "used" max |
| **GC pause 합계** | `increase(jvm_gc_collectiontime[$range])` — 쿼리 window 전체 |
| **Cluster user memory peak** | "Cluster Memory Pool" 패널의 reserved max |
| **Spill bytes** | "Spill Bytes" 패널 delta |
| **HMS 호출 건수** | "HMS Call Rate" 패널의 누적 |

### 1-6. CPU/메모리 사용률 (OS 레벨)

Grafana에는 JVM 내부만 보이므로 컨테이너 관점은 `kubectl top`으로 보완:

```bash
kubectl -n $NS top pod -l app.kubernetes.io/component=worker
# request/limit 대비 실사용 퍼센트 계산
```

### 1-7. Trino Web UI — 개별 쿼리 상세

Grafana는 클러스터 집계만 보여주므로, **per-query stage 통계**는 Trino Web UI에서 확인:

1. `https://braveji.trino.quantumcns.ai/ui/` → Query ID 목록
2. 해당 쿼리 클릭 → Stage 탭
3. 기록: Peak memory, CPU time, Input/Output rows per stage

이것을 1-4 표의 "notes"에 붙임.

---

→ 결과를 `docs/04-tuning-results.md`의 "Baseline" 섹션에 표로 남김.

---

## 2. 노드 용량 파악

워커를 키우기 전에 **k8s 노드가 실제로 감당 가능한지** 먼저 확인.

```bash
# 노드 스펙과 현재 allocation
kubectl get nodes -o custom-columns=\
NAME:.metadata.name,\
CPU:.status.capacity.cpu,\
MEM:.status.capacity.memory,\
POD-CAP:.status.capacity.pods

kubectl describe node | grep -E 'Allocated resources|cpu |memory '

# 현재 ResourceQuota
kubectl -n $NS describe resourcequota
```

**판단 기준**:
- 노드 하나에 워커 하나만 뜰 건지(배타) vs 여러 워커 허용할 건지
- Coordinator는 분리된 안정 노드에 둘 건지 (nodeSelector/taint)
- `data-platform`류 별도 node pool이 있는지

**결과물**: 워커 한 대에 할당할 "목표 사양" 확정. 예:
| 항목 | 현재 | 목표 |
|---|---|---|
| CPU request/limit | 4 / 8 | 8 / 12 |
| Memory request/limit | 20Gi / 24Gi | 28Gi / 32Gi |
| Worker 수 | 3 | 3~6 (HPA) |

---

## 3. 메모리 모델 — Trino의 3계층 이해부터

Trino 메모리 설정은 **컨테이너 → JVM → Query**의 3계층으로 엮여 있음. 한쪽만 키우면
OOM이나 리소스 낭비로 직결.

```
[Container memory limit]
   │  ≥ 필요
[JVM -Xmx]
   │  ≥ heap-headroom + query working set
[query.max-memory-per-node] (user 메모리)
   │
[query.max-memory] (cluster 전체, coordinator가 트래킹)
```

### 권장 비율 (worker 기준)

| 항목 | 비율 / 공식 | 예 (32Gi limit) |
|---|---|---|
| Container memory limit | L | 32Gi |
| JVM `-Xmx` (`maxHeapSize`) | 0.8 × L | 26Gi |
| `memory.heap-headroom-per-node` | 0.3 × Xmx | 8Gi |
| `query.max-memory-per-node` | Xmx − headroom − safety(~2Gi) | 16Gi |
| `query.max-memory` (cluster) | N × max-memory-per-node × 0.7 | 3 × 16Gi × 0.7 ≈ 33Gi |

### 조정 포인트 — [helm/values.yaml](../helm/values.yaml)

```yaml
worker:
  jvm:
    maxHeapSize: "26G"
    gcMethod:
      type: "UseG1GC"
      g1:
        heapRegionSize: "32M"
  config:
    memory:
      heapHeadroomPerNode: "8GB"
    query:
      maxMemoryPerNode: "16GB"
  resources:
    requests: { cpu: "8", memory: "28Gi" }
    limits:   { cpu: "12", memory: "32Gi" }

coordinator:
  config:
    query:
      maxMemory: "33GB"          # cluster-wide
```

### 주의
- `maxMemoryPerNode`를 JVM heap의 80% 이상으로 설정하지 말 것 → GC 스파이크로 OOM
- coordinator의 `query.max-memory`는 **workers의 합보다 작아야** 현실적
- spill을 켜면 `query.max-total-memory`를 `max-memory`의 2~3배로 잡는 것이 일반적

---

## 4. JVM 튜닝

### 기본 G1 파라미터 (Trino 공식 권장 기반)

[helm/values.yaml](../helm/values.yaml) `additionalJVMConfig` 또는 `jvm.additionalArguments`:

```
-XX:+UseContainerSupport
-XX:InitialRAMPercentage=80
-XX:MaxRAMPercentage=80
-XX:+ExplicitGCInvokesConcurrent
-XX:+HeapDumpOnOutOfMemoryError
-XX:HeapDumpPath=/tmp/heapdump
-XX:+UseG1GC
-XX:G1HeapRegionSize=32M
-XX:+ExitOnOutOfMemoryError
-XX:ErrorFile=/tmp/hs_err_%p.log
-XX:ReservedCodeCacheSize=512M
-Djdk.attach.allowAttachSelf=true
-Dfile.encoding=UTF-8
```

### GC 로깅 (튜닝 중에만 활성화)

```
-Xlog:gc*:file=/tmp/gc.log:time,uptime,level,tags:filecount=5,filesize=100M
```

nearly full GC나 long pause(>1s)가 보이면 heapRegionSize, heap 증설, 쿼리 분산 조정.

---

## 5. 디스크 — spill & exchange

현재 [helm/values.yaml](../helm/values.yaml)는 `emptyDir` + `sizeLimit: 100Gi`로 되어 있음.
대용량 쿼리에서 spill이 발생하면 노드 디스크 속도에 그대로 종속. 두 가지 개선:

### 5-1. Spill 전용 local PV 또는 hostPath

- 노드에 **NVMe SSD**가 있다면 `local PV` + `local-storage` StorageClass
- 임시 해결책으로 `hostPath` 사용 가능 (PVC 관리는 수동)

예 (hostPath):
```yaml
additionalVolumes:
  - name: trino-spill
    hostPath:
      path: /var/lib/trino-spill
      type: DirectoryOrCreate
additionalVolumeMounts:
  - name: trino-spill
    mountPath: /data/trino
```

해당 디렉토리는 **노드별로 존재**해야 하므로 DaemonSet 또는 init 스크립트로 선생성 필요.

### 5-2. Spill 켜기 + 용량 정책

[helm/values.yaml](../helm/values.yaml):
```yaml
server:
  config:
    experimental:
      spill:
        enabled: true
        spillPath: /data/trino/spill
        maxSpillPerNode: 200GB
        queryMaxSpillPerNode: 100GB
```

### 5-3. Exchange manager (Trino 403+)

큰 셔플을 위해 fault-tolerant execution과 함께 쓰이는 경우가 많음. POC 단계에서는 보류.

---

## 6. 워커 수 & 스케줄링

### 고정 vs HPA 결정
- **고정 N개**: 쿼리 패턴이 예측 가능, 레이턴시 민감, 간단한 운영
- **HPA**: 낮·밤 부하 편차가 크고 비용 최적화 필요할 때

HPA 지표로는 CPU보다 **동시 쿼리 수**나 **queue length**가 더 잘 반영됨. Trino JMX를
Prometheus adapter로 노출하거나, custom metric API 필요.

### PDB, Anti-affinity

```yaml
worker:
  podAntiAffinity:
    enabled: true
    topologyKey: kubernetes.io/hostname
    type: preferred
  podDisruptionBudget:
    enabled: true
    minAvailable: 2   # N-1
```

### Coordinator는 분리

- 별도 node pool(가능하면 taint 사용)
- Replicas: 1 (Trino는 active-active coordinator 비공식 지원. 운영엔 1 + HA via restart)

---

## 7. 커넥터 레벨 튜닝

### 7-1. HMS 연결
[helm/values.yaml](../helm/values.yaml)에서 이미 connect/read timeout을 30/60s로 확장.
2단계에서 HMS replica 2로 증설 + 다음 속성 추가 고려:
```properties
hive.metastore.partition-batch-size.min=10
hive.metastore.partition-batch-size.max=100
```

### 7-2. Hive 쓰기 통계 복구
G13 해결책 B(스키마 패치) 적용 후 `hive.collect-column-statistics-on-write` 를 제거.

### 7-3. Iceberg
```properties
iceberg.target-max-file-size=512MB
iceberg.minimum-assigned-split-weight=0.05
```
partition pruning/metadata cache 관련 속성은 실제 쿼리 패턴 측정 후 조정.

### 7-4. PG catalog push-down 확인
```properties
postgresql.experimental.enable-string-pushdown-with-collate=true  # 문자열 비교 push-down
```
push-down이 제대로 내려가는지 EXPLAIN으로 매번 확인.

---

## 8. 재측정 & 비교

0/1단계와 **동일한 벤치마크 쿼리 세트 + 동일 절차**로 재실행. 바뀐 설정 이외의
변수(데이터, worker 수, 클러스터 부하)가 통제되는지 확인.

### 8-1. 재측정 실행

1단계 1-1~1-7 절차를 그대로 반복. 단, **`tune-<단계번호>`**로 label 붙여 기록:

```bash
START_TS=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
# ... 동일 벤치마크 3회 ...
END_TS=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
echo "tune-3 (memory model) start=$START_TS end=$END_TS"
```

### 8-2. Grafana 비교 뷰 세팅

Grafana time range에 **두 구간(Baseline / Tuned)을 나란히**:

- 한 번에 보고 싶으면: time range를 양쪽을 다 덮는 범위로 설정
- 구간별 단독 비교: 각각의 절대 시각 범위로 대시보드 snapshot 저장 후 나란히 보기

PromQL로 직접 비교할 수도 있음:

```promql
# 특정 query_id가 발생시킨 running_queries 피크를
# 베이스라인 시각대와 튜닝 후 시각대에서 각각 조회
max_over_time(trino_execution_running_queries[1m] @ 1744545600)  # baseline
max_over_time(trino_execution_running_queries[1m] @ 1744599600)  # tuned
```

`@<unix-timestamp>` 오퍼레이터로 과거 시점 조회 가능.

### 8-3. 비교표

`docs/04-tuning-results.md`에 튜닝 단계별로 누적. 예시:

| 쿼리 | Baseline | tune-3 (memory) | tune-4 (JVM) | tune-5 (spill) | 최종 개선률 |
|---|---:|---:|---:|---:|---:|
| Q1 point-lookup | 80ms | 75ms | 70ms | 68ms | -15% |
| Q2 aggregation  | 1.2s | 0.9s | 0.8s | 0.75s | -38% |
| Q3 join+spill   | 12s  | 9s   | 8.2s | 6.5s  | -46% |
| Q4 federated    | 3.1s | 2.8s | 2.6s | 2.4s  | -23% |

각 cell 옆에 Grafana snapshot URL 링크를 붙이면 나중에 검증 가능.

### 8-4. 롤백 규칙

개선이 없거나 역행하면 **직전 변경만** 롤백하고 원인 분석. 한 번에 여러 변수를
바꿨다면 어떤 변경이 효과인지 분리 불가 → 단계당 커밋 1개 원칙 유지.

### 8-5. Grafana 패널에서 회귀 감지

베이스라인 때의 정상 범위를 대시보드 alert 또는 threshold 라인으로 표시해 두면
튜닝 후 지표가 선을 넘는지 즉시 판단 가능. 예:

- `jvm_memory_heap_memory_usage_used_bytes / _max_bytes`가 0.85 이상이면 경고
- `rate(jvm_gc_collectiontime[1m])`가 1000 이상(초당 1초 이상 pause)이면 경고
- `rate(trino_spiller_totalspilledbytes[5m]) > 0`이 장시간 유지되면 경고

---

## 9. 문서화

- 결과는 `docs/04-tuning-results.md`로 별도 파일에 기록 (본 문서는 "어떻게 진행할지"의
  가이드, 결과 기록은 별도)
- 각 단계에서 의미 있는 변경은 커밋 메시지에 `tune: ...` prefix로 남김
- helm values 변경은 diff와 함께 commit

---

## 진행 체크리스트

- [ ] 0. 벤치마크 쿼리 확정, 측정 명령 스크립트화
- [ ] 1. Baseline 수치 기록 (`docs/04-tuning-results.md` 초안)
- [ ] 2. 노드 capacity + 워커 목표 사양 확정
- [ ] 3. 메모리 3계층 재계산 및 values.yaml 반영
- [ ] 4. JVM 파라미터 갱신 + GC 로깅 임시 활성
- [ ] 5. Spill 경로 hostPath/local PV로 전환
- [ ] 6. 워커 수/PDB/anti-affinity 조정
- [ ] 7. 커넥터 레벨 튜닝 (HMS, Hive stats, Iceberg)
- [ ] 8. 재측정 & 비교표 작성
- [ ] 9. 결과 문서 마무리, G14+ 발견 사항 01 문서에 추가
