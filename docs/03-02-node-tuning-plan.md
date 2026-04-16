# 2단계 튜닝 — 노드 용량 기반 Worker Sizing

[docs/03-resource-tuning-plan.md](03-resource-tuning-plan.md)의 **2. 노드 용량 파악** 단계에
해당하는 실제 적용 가이드. 베이스라인(`tune-0`) 측정이 끝난 상태에서 `tune-2` 커밋으로
워커의 리소스/배치만 조정하고, 그 외 변수(JVM 파라미터, spill, 커넥터)는 건드리지 않는다.

---

## 1. 클러스터 현황 스냅샷 (2026-04-16 기준)

```bash
kubectl get nodes -o custom-columns=\
NAME:.metadata.name,CPU:.status.capacity.cpu,MEM:.status.capacity.memory,POD-CAP:.status.capacity.pods

kubectl describe node | grep -E 'Allocated resources|cpu |memory '
kubectl -n user-braveji describe resourcequota
```

결과:

| 노드 | CPU | Mem | CPU req / lim | Mem req / lim | 판단 |
|---|---:|---:|---|---|---|
| **qcs01** | 64 | 258Gi | 1% / 1% | 0% / 0% | **거의 비어 있음 — Trino worker 배치 최적** |
| **qcs02** | 64 | 258Gi | 1% / 0% | 0% / 0% | **동일 — 최적** |
| **qcs03** | 64 | 258Gi | 1% / 0% | 0% / 0% | **동일 — 최적** |
| qcs04 | 32 | 128Gi | 42% / **101%** | 29% / 50% | CPU limit 이미 오버커밋 → 배치 금지 |
| qcs05 | 128 | 258Gi | 31% / 64% | 47% / 78% | 여유 있지만 타 워크로드와 경합 |
| qcs06 | 128 | 258Gi | 31% / 60% | 41% / 67% | 동일 |
| qcs07 | 64 | 515Gi | 76% / **110%** | 21% / 45% | CPU 오버커밋 → 배치 금지 |

`user-braveji` 네임스페이스에 **ResourceQuota 없음** → 클러스터 allocatable이 곧 한계.

---

## 2. 결론 — qcs01/02/03 세 노드에 워커 1:1 pin

세 노드가 완전히 대칭(64C / 258Gi)이고 거의 비어 있어서, 워커 3대를 노드 하나씩 pin 하는
게 가장 깔끔하다. 이렇게 가면 튜닝 변수 중 "노드 간 skew", "다른 워크로드와의 경합"이
둘 다 제거되어 측정 재현성이 올라간다.

- qcs04 / qcs07은 이미 CPU limit이 100% 를 넘겨 오버커밋 상태 → 배치 금지
- qcs05 / qcs06은 여유는 있지만 타 워크로드가 올라와 있어 측정이 오염될 수 있음 → 예비
- 워커 수는 현재 `server.workers: 3` 유지. 더 늘리려면 affinity를 풀어 qcs05/06 허용 필요.

---

## 3. 목표 사양 — 4단계 점진적 확장 계획

한 번에 크게 올리지 않고, heap을 **16G → 32G → 64G → 128G** 로 2배씩 올리며 각 단계에서
벤치마크를 돌려 "이 크기에서 뭐가 병목인가"를 식별한다. 단계가 끝날 때마다
[docs/04-tuning-results.md](04-tuning-results.md)에 결과를 누적하고, 개선이 포화되면
그 시점에서 멈춘다.

산식은 [docs/03-resource-tuning-plan.md](03-resource-tuning-plan.md) 3절 권장 비율을 그대로 적용:
`Xmx = 0.8 × limit` → `headroom = 0.3 × Xmx` → `maxMemoryPerNode = Xmx − headroom − 2Gi 안전분`
→ `cluster max-memory = workers × maxMemoryPerNode × 0.7`.

### 전체 로드맵

| 항목 | Baseline (현재) | **Step 1 (32G)** | **Step 2 (64G)** | **Step 3 (128G)** |
|---|---:|---:|---:|---:|
| Worker request CPU / Mem | 4 / 20Gi | 8 / 36Gi | 16 / 72Gi | 24 / 120Gi |
| Worker limit CPU / Mem | 8 / 24Gi | 12 / 40Gi | 24 / 80Gi | 32 / 160Gi |
| JVM `-Xmx` | 16G | **32G** | **64G** | **128G** |
| `heapHeadroomPerNode` | 4GB | 10GB | 20GB | 38GB |
| `query.maxMemoryPerNode` | 8GB | 20GB | 42GB | 88GB |
| Cluster `query.maxMemory` (×3 workers ×0.7) | 17GB | 42GB | 88GB | 185GB |
| 노드(64C/258Gi) 대비 limit 점유 | 13% / 9% | 19% / 16% | 38% / 31% | 50% / 62% |
| 현재 대비 heap 배율 | 1× | **2×** | **4×** | **8×** |
| 주 대상 벤치마크 | — | Q3 sf1 | Q3 sf10, Q1 sf10 | Q3 sf100, SF 스케일 업 |

### Step 1 (32G) — 최소한의 확장, 메모리 모델 검증

- 목표: 현재 대비 2배. "메모리 3계층 산식이 실제로 맞는지" 확인하는 단계.
- heap 16G → 32G로 올릴 때 GC pause가 어떻게 변하는지 관찰. G1GC의 heapRegionSize가
  32M 그대로여도 괜찮은지(32G ÷ 32M = 1024 regions, G1 권장 2048~4096 내이므로 OK).
- Q3 sf1이 spill 없이 돌아가는 건 베이스라인부터 당연 → 여기서는 **GC pause 변화와
  heap 포화율** 측정이 핵심. `jvm_memory_heap_memory_usage_used_bytes / _max_bytes` 가
  0.5 이하로 떨어지면 "아직 여유 있다"는 근거.
- 노드 점유 16% — 나머지 워크로드에 전혀 영향 없는 안전한 시작점.
- 예상 소요: helm upgrade + 벤치마크 3회 ≈ **30분**.

### Step 2 (64G) — 중간 규모, SF10 한계 탐색

- 목표: SF10(lineitem 60M rows, ~10GB)에서 spill 없이 돌아가는 것.
- heap 64G면 `maxMemoryPerNode=42GB` → 워커 하나가 42GB까지 쿼리에 쓸 수 있으므로
  SF10 Q3 join의 hash table이 충분히 in-memory에 들어감.
- CPU도 request 8→16으로 올림 — SF10은 scan+hash build에 CPU 병렬성이 중요해지기
  시작하는 크기.
- 노드 점유 31% — 아직 절반 이상 남아 있어 다른 실험과 공존 가능.
- 측정 포인트: Q3 sf10 wall-clock, spill bytes, exchange bytes, GC pause.
- 예상 소요: helm upgrade + SF1/SF10 벤치마크 각 3회 ≈ **1시간**.

### Step 3 (128G) — 대규모, SF100 도전

- 목표: SF100(lineitem 600M rows, ~100GB)에서 돌아가는지 확인. spill이 발생해도 OK —
  "어디서 spill이 시작되는가"를 기록하는 것이 이 단계의 목적.
- heap 128G, `maxMemoryPerNode=88GB` → SF100 쿼리의 peak memory가 이 안에 들어오면
  spill 없이 통과, 넘으면 spill 발생. 두 경우 모두 유의미한 데이터.
- 노드 점유 62% — kubelet/데몬셋 여유는 남아 있지만 다른 대형 워크로드와의 공존은
  어려워짐. 측정 중에는 다른 워크로드를 pause 하거나 확인 필요.
- 이 결과에 따라 다음 방향이 갈림:
  - spill 0 + 여유 → 메모리는 충분, 다음은 JVM/커넥터 튜닝으로 넘어감
  - spill 발생 but 완주 → spill 경로 최적화(5. 디스크)로 넘어감
  - OOM → L 티어(160G heap, 200Gi limit)로 한 단계 더 올림 or `query.max-memory` 낮춰서
    쿼리가 먼저 죽게 설정
- 예상 소요: helm upgrade + SF1/SF10/SF100 벤치마크 ≈ **2~3시간**.

### 단계별 진행 원칙

1. **한 번에 한 단계만.** Step 1 → 측정 → 기록 → Step 2 → 측정 → 기록 → ... 순서.
   건너뛰기 금지. 2배씩 올리는 게 아니라 "한 변수만 바꾸는" 원칙이 핵심.
2. **개선이 포화되면 멈춤.** Step 1→2에서 Q3 sf1 wall-clock이 거의 안 변하면 "이
   워크로드에선 메모리가 병목이 아니다"는 결론. 더 올릴 이유 없이 다음 튜닝 축(JVM,
   spill, 커넥터)으로 넘어감.
3. **각 단계 결과는 커밋 1개.** values.yaml 변경 + 04 문서의 해당 컬럼 기록을 하나의
   커밋으로: `tune: step-1 worker heap 16G→32G`.
4. **coordinator는 Step 3까지 건드리지 않음.** 현재 8G heap이면 SF100 이하에서 coordinator
   자체가 병목이 되진 않음. `query.maxMemory`(cluster-wide cap)만 각 단계에서 같이 올림.

### values.yaml 변경 요약 — 단계별 diff

각 Step에서 [helm/values.yaml](../helm/values.yaml)의 worker 섹션만 수정.
coordinator는 `query.maxMemory` 만 해당 단계 값으로 교체.

**Step 1 (32G)**:
```yaml
worker:
  jvm:
    maxHeapSize: "32G"
  config:
    memory:
      heapHeadroomPerNode: "10GB"
    query:
      maxMemoryPerNode: "20GB"
  resources:
    requests: { cpu: "8",  memory: "36Gi" }
    limits:   { cpu: "12", memory: "40Gi" }
coordinator:
  config:
    query:
      maxMemory: "42GB"
```

**Step 2 (64G)**:
```yaml
worker:
  jvm:
    maxHeapSize: "64G"
  config:
    memory:
      heapHeadroomPerNode: "20GB"
    query:
      maxMemoryPerNode: "42GB"
  resources:
    requests: { cpu: "16", memory: "72Gi" }
    limits:   { cpu: "24", memory: "80Gi" }
coordinator:
  config:
    query:
      maxMemory: "88GB"
```

**Step 3 (128G)**:
```yaml
worker:
  jvm:
    maxHeapSize: "128G"
  config:
    memory:
      heapHeadroomPerNode: "38GB"
    query:
      maxMemoryPerNode: "88GB"
  resources:
    requests: { cpu: "24", memory: "120Gi" }
    limits:   { cpu: "32", memory: "160Gi" }
coordinator:
  config:
    query:
      maxMemory: "185GB"
```

Coordinator는 Step 3까지 resources/heap을 건드리지 않는다 (현재 8G heap으로 SF100 이하 충분).
[docs/03-resource-tuning-plan.md](03-resource-tuning-plan.md) 6절의 "coordinator 분리"
논의는 3단계 이후. 단, cluster-wide `query.maxMemory` 만큼은 워커 업그레이드에 맞춰
올려야 워커가 가진 메모리를 실제로 쓸 수 있다.

---

## 4. [helm/values.yaml](../helm/values.yaml) 변경 — Step 1 (첫 번째 적용)

Step 1에서 바꾸는 것: **리소스 + heap + 메모리 모델 + affinity**. affinity는 한 번
넣으면 이후 Step에서 건드리지 않으므로 Step 1에서 같이 적용.

```yaml
worker:
  # [신규] qcs01/02/03에만 배치 + 노드당 1개
  affinity:
    nodeAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
        nodeSelectorTerms:
          - matchExpressions:
              - key: kubernetes.io/hostname
                operator: In
                values: [qcs05, qcs06, qcs07]
    podAntiAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
        - labelSelector:
            matchExpressions:
              - key: app.kubernetes.io/component
                operator: In
                values: [worker]
          topologyKey: kubernetes.io/hostname

  jvm:
    maxHeapSize: "32G"             # 16G → 32G
    gcMethod:
      type: "UseG1GC"
      g1:
        heapRegionSize: "32M"
  config:
    memory:
      heapHeadroomPerNode: "10GB"  # 4GB → 10GB
    query:
      maxMemoryPerNode: "20GB"     # 8GB → 20GB
  resources:
    requests:
      cpu: "8"                     # 4 → 8
      memory: "36Gi"               # 20Gi → 36Gi
    limits:
      cpu: "12"                    # 8 → 12
      memory: "40Gi"               # 24Gi → 40Gi

coordinator:
  config:
    query:
      maxMemory: "42GB"            # 20GB → 42GB (= 3 × 20 × 0.7)
      maxMemoryPerNode: "4GB"      # 그대로
  # resources / heap은 건드리지 않음
```

Step 2/Step 3의 values.yaml 값은 3절의 단계별 diff 블록 참고. 각 Step에서는
위 yaml의 숫자만 해당 단계 값으로 교체하면 됨.

참고:

- `server.workers: 3` 그대로 유지. qcs01/02/03에 1:1 pin 되므로 더 올리려면 affinity를
  풀어 qcs05/06 등 다른 노드를 허용해야 함.
- nodeSelector/affinity 적용 후 대상 노드에 taint가 있으면 `tolerations`를 추가해야 함.
  `kubectl describe node qcs01 | grep Taints` 로 선 확인.
- [docs/01-trino-cluster-setup.md](01-trino-cluster-setup.md) 에 적힌 "values.yaml 의
  `server.config` 키를 chart가 조용히 드롭하는 이슈"가 있으므로, apply 전에 렌더링이
  실제로 반영됐는지 반드시 확인:
  ```bash
  helm template my-trino my-trino/trino -f helm/values.yaml \
    | grep -E 'max-memory|Xmx|memory:' | head -40
  ```

---

## 5. 적용 & 검증 순서

```bash
NS=user-braveji

# 1) diff로 의도한 변경만 들어가는지 확인 (helm-diff plugin)
helm diff upgrade my-trino my-trino/trino -n $NS -f helm/values.yaml

# 2) 업그레이드 (rolling; PDB 없음이므로 한 번에 한 pod씩 재스케줄)
helm upgrade --install my-trino my-trino/trino -n $NS -f helm/values.yaml --wait

# 3) qcs01/02/03에만 떠 있는지 + limit/heap 반영 확인
kubectl -n $NS get pod -l app.kubernetes.io/component=worker -o wide
kubectl -n $NS get pod -l app.kubernetes.io/component=worker \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.nodeName}{"\t"}{.spec.containers[0].resources.limits}{"\n"}{end}'

# 4) JVM이 실제로 100G를 잡았는지 (container inspect만으로는 확인 불가)
POD=$(kubectl -n $NS get pod -l app.kubernetes.io/component=worker -o name | head -1)
kubectl -n $NS exec "$POD" -c trino-worker -- \
  sh -c 'jcmd 1 VM.flags | tr " " "\n" | grep -E "MaxHeapSize|InitialHeapSize"'

# 5) Trino 관점의 메모리 풀 반영 확인
kubectl -n $NS exec deploy/my-trino-trino-coordinator -- \
  trino --execute "SELECT node, heap_available, non_heap_used FROM system.runtime.nodes"
```

### 기대 변화 (재측정 시 확인할 지표)

베이스라인(`tune-0`) 대비 tune-2 에서 보고 싶은 값:

- Q3 wall-clock 개선 — heap 여유로 hash table이 fully in-memory 유지 → spill 0 유지 +
  partial aggregation 확장
- `trino_memory_cluster_clusterusermemoryreservation` peak은 베이스라인 대비 커졌지만,
  `trino_memory_cluster_pool_maxbytes{pool="general"}` 대비 점유율은 **낮아짐**
- `max by (pod) (rate(jvm_gc_collectiontime[1m]))` peak 감소 (heap 여유)
- `rate(trino_spiller_totalspilledbytes[5m])` 0 유지
- `kubectl top pod -l app.kubernetes.io/component=worker` 의 mem 실사용 ≫ 20Gi 였던 값이
  수십 Gi 대로 올라야 함 (안 올라오면 JVM이 새 Xmx를 못 잡았다는 신호)

수치 기록은 [docs/04-tuning-results.md](04-tuning-results.md)의 `tune-2 (node sizing)`
컬럼에 누적.

---

## 6. 롤백 규칙

- 업그레이드 중 워커 pod가 `OOMKilled` (exit 137)로 죽으면 **즉시 롤백**:
  ```bash
  helm rollback my-trino -n user-braveji
  ```
  원인은 99% "JVM Xmx 대비 container limit이 부족" → limit을 먼저 올리지 않고 Xmx만
  올린 경우. 이 문서의 diff는 둘을 항상 함께 올리도록 되어 있지만, 수동 수정 시 실수
  가능.
- 워커가 `Pending`으로 남으면 qcs01/02/03 중 하나에 taint가 걸렸거나 다른 워크로드가
  새로 올라와 리소스를 먹은 경우. `kubectl describe pod` 의 Events 를 확인.
- 벤치마크 결과가 **베이스라인보다 나쁘면** 직전 변경만 롤백하고 원인 분석. 한 번에
  여러 변수를 바꾸지 않았는지 커밋을 되돌아볼 것.

---

## 7. 다음 단계 — Step 완료 후 분기

각 Step의 재측정 결과를 [docs/04-tuning-results.md](04-tuning-results.md)에 기록한 뒤,
아래 분기표에 따라 결정:

| Step 결과 | 판단 | 다음 행동 |
|---|---|---|
| Q3 latency가 직전 Step 대비 **10% 이상 개선** | 메모리가 아직 병목 | → 다음 Step으로 진행 |
| Q3 latency가 직전 Step 대비 **변화 미미** (<5%) | 메모리는 포화, 다른 축이 병목 | → 메모리 확장 중단, **4. JVM 파라미터** 로 이동 |
| Spill 0 유지 + 여유 | 현재 워크로드엔 메모리 충분 | → SF 스케일 업(SF10→SF100)으로 한계 탐색 |
| Spill 발생 but 쿼리 완주 | 메모리 부족이 시작됨 | → 다음 Step 적용, 또는 **5. 디스크(spill 경로)** 최적화 |
| OOM (exit 137 또는 쿼리 실패) | 메모리 부족 + 안전장치 미달 | → `query.max-memory` 낮춰 쿼리 실패를 선행시킨 뒤 다음 Step |

최종적으로 Step 3(128G)까지 적용 완료되면:
- SF100 기준 벤치마크 결과가 안정적 → [docs/03-resource-tuning-plan.md](03-resource-tuning-plan.md)의 **4. JVM 튜닝** 단계로 진행
- SF100에서도 spill 없음 → **5. 디스크** 건너뛰고 **6. 워커 수** 또는 **7. 커넥터** 로 진행
- SF300/SF1000까지 도전하고 싶으면 → 노드 점유율 62%에서 여유를 확인 후 **L+ 티어**(160G heap, 200Gi limit) 검토
