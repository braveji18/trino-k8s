# Trino 메모리 성능 최적화 분석

## 1. 메모리 추적 계층 구조

```
클러스터 레벨
└─ ClusterMemoryManager          (전체 노드 메모리 집계 / 쿼리 킬러 조율)
    └─ LocalMemoryManager        (노드 1개의 풀 초기화)
        └─ MemoryPool            (실제 예약/해제 엔진, 노드당 1개)
            └─ QueryContext       (쿼리 단위 한도 관리)
                └─ TaskContext    (태스크 단위)
                    └─ PipelineContext
                        └─ OperatorContext  (오퍼레이터 단위 추적)
                            └─ LocalMemoryContext / AggregatedMemoryContext
```

모든 메모리 예약은 이 계층을 따라 `MemoryPool`까지 전파됩니다.

---

## 2. 메모리 컨텍스트 구조

`lib/trino-memory-context` 아래 5개 클래스가 추적을 담당합니다.

| 클래스 | 역할 |
|--------|------|
| `RootAggregatedMemoryContext` | `MemoryReservationHandler`에 실제 풀 예약 위임 |
| `ChildAggregatedMemoryContext` | 변경량을 부모로 전파 |
| `SimpleLocalMemoryContext` | 개별 할당 태그별 바이트 추적 (`setBytes`, `addBytes`) |
| `MemoryTrackingContext` | **User 메모리** / **Revocable 메모리** 분리 관리 |

### 메모리 종류 구분

| 종류 | 특성 | 용도 |
|------|------|------|
| User memory | 블로킹, 한도 초과 시 쿼리 킬 | 해시 테이블, 정렬 버퍼 |
| Revocable memory | 스필 가능, 회수 대상 1순위 | 조인 빌드 사이드, 집계 |
| System memory | 추적만, 한도 미적용 | 직렬화 버퍼, 출력 버퍼 |

---

## 3. MemoryPool — 핵심 예약 엔진

`core/trino-main/.../memory/MemoryPool.java`:

```java
// 블로킹 예약 — 여유 공간 없으면 Future 반환
public ListenableFuture<Void> reserve(TaskId taskId, String allocationTag, long bytes)

// 논블로킹 시도 — 공간 부족 시 false 반환, 할당 안 함
public boolean tryReserve(TaskId taskId, String allocationTag, long bytes)

// 여유 공간 = maxBytes - reservedBytes - reservedRevocableBytes
public synchronized long getFreeBytes()
```

**오버커밋 허용 설계:** `getFreeBytes()`가 음수가 되어도 즉시 에러를 내지 않고 `NonCancellableMemoryFuture`를 반환합니다. 메모리가 해제될 때까지 대기하며, 메모리 킬러가 개입합니다.

### 쿼리별 태그 추적

```java
Map<QueryId, Long>                  queryMemoryReservations
Map<QueryId, Map<String, Long>>     taggedMemoryAllocations  // 오퍼레이터 타입별
Map<TaskId, Long>                   taskMemoryReservations
```

어떤 오퍼레이터가 메모리를 많이 쓰는지 진단 가능합니다.

---

## 4. 노드 메모리 배분

`core/trino-main/.../memory/LocalMemoryManager.java`:

```
전체 JVM 힙 (예: 100GB)
├─ Heap Headroom (30%) = 30GB   ← 추적되지 않는 할당 예비 (GC 오버헤드 등)
└─ Memory Pool   (70%) = 70GB   ← 쿼리 실행에 사용
    ├─ User memory (query.max-memory-per-node, 기본 30% 힙)
    └─ Revocable memory
```

### NodeMemoryConfig 핵심 설정

```
query.max-memory-per-node       = heap의 30%   # 노드당 쿼리 메모리 한도
memory.heap-headroom-per-node   = heap의 30%   # 미추적 할당 예비
```

---

## 5. 메모리 회수 (Revocation)

`core/trino-main/.../execution/MemoryRevokingScheduler.java`가 회수를 조율합니다.

### 회수 발동 조건

```java
// 풀 사용률이 revokingThreshold(기본 80%) 초과 시
getFreeBytes() <= maxBytes * (1.0 - memoryRevokingThreshold)
    && getReservedRevocableBytes() > 0
```

### 회수 목표량 계산

```java
long remainingBytesToRevoke =
    -memoryPool.getFreeBytes()                     // 초과분
    + (maxBytes * (1.0 - memoryRevokingTarget));   // 목표 여유분 (기본 50%)
```

### 회수 순서

```
1. 가장 오래된 SqlTask 순으로 탐색
2. TaskContext → PipelineContext → OperatorContext 순으로 내려감
3. Revocable 메모리가 있는 오퍼레이터에 revocationRequestListener 호출
4. 오퍼레이터가 데이터를 디스크로 스필 → revocable 메모리 반환
```

### 폴링 + 이벤트 이중 감시

- 1초마다 정기 체크 (`scheduleWithFixedDelay`)
- 예약 시점에도 즉시 감지 (`memoryPool.addListener(...)`)

---

## 6. 스필 (Spill to Disk)

`core/trino-main/.../spiller/NodeSpillConfig.java`:

```
max-spill-per-node          = 100GB   # 노드당 스필 한도
query-max-spill-per-node    = 100GB   # 쿼리당 스필 한도
spill-compression-codec     = LZ4     # 스필 압축
spill-encryption-enabled    = false   # 스필 암호화
```

스필 추적은 `LocalSpillContext → 상위 SpillContext → QueryContext`로 전파됩니다.

---

## 7. OutputBuffer 메모리 제어

`core/trino-main/.../execution/buffer/OutputBufferMemoryManager.java`:

### 이중 블로킹 전략

```
생산자가 enqueue(page) 호출
    ↓
1. MemoryPool 고갈 → memoryContext.setBytes() 반환 Future로 블로킹
2. 버퍼 크기 초과 → bufferBlockedFuture 로 블로킹 (sink.max-buffer-size)
```

---

## 8. Block / Page 메모리 추적

`core/trino-spi/.../Page.java`:

```java
getSizeInBytes()         // 논리 데이터 크기 (lazy 계산, 캐싱)
getRetainedSizeInBytes() // 실제 힙 점유 크기 (구조체 오버헤드 포함)
```

`core/trino-spi/.../block/Block.java`:

```java
void retainedBytesForEachPart(ObjLongConsumer<Object> consumer)
// 내부 배열 각각의 실제 크기를 방문 → OperatorContext의 peak 추적에 사용
```

---

## 9. 메모리 킬러 전략

`core/trino-main/.../memory/MemoryManagerConfig.java`:

```
query.low-memory-killer.policy:
  NONE
  TOTAL_RESERVATION                       # 예약량 가장 큰 쿼리 킬
  TOTAL_RESERVATION_ON_BLOCKED_NODES      # 블록된 노드의 최대 예약 쿼리 킬 (기본)

task.low-memory-killer.policy:
  NONE
  TOTAL_RESERVATION_ON_BLOCKED_NODES      # (기본)
  LEAST_WASTE                             # 낭비 최소화 기준 태스크 킬
```

**킬 순서:** Task 킬러 먼저 → 그래도 부족하면 Query 킬러 (덜 파괴적인 것부터)

---

## 10. 전체 설정 요약

| 설정 | 기본값 | 목적 |
|------|--------|------|
| `query.max-memory` | 20GB | 쿼리당 User 메모리 상한 |
| `query.max-total-memory` | 40GB | 쿼리당 전체 메모리 상한 |
| `query.max-memory-per-node` | heap 30% | 노드당 쿼리 메모리 |
| `memory.heap-headroom-per-node` | heap 30% | 미추적 할당 예비 |
| `memory.revocation-threshold` | ~80% | 회수 발동 풀 사용률 |
| `memory.revocation-target` | ~50% | 회수 후 목표 풀 사용률 |
| `max-spill-per-node` | 100GB | 노드당 스필 한도 |
| `sink.max-buffer-size` | 32MB | 출력 버퍼 상한 |
| `sink.max-broadcast-buffer-size` | 200MB | 브로드캐스트 버퍼 상한 |

---

## 11. 병목별 권장 조정

| 병목 상황 | 원인 | 권장 조정 |
|-----------|------|-----------|
| 쿼리가 자주 메모리 초과로 킬됨 | `query.max-memory` 너무 작음 | 값 증가 또는 스필 활성화 |
| 노드 OOM 크래시 | Headroom 부족 | `heap-headroom-per-node` 증가 |
| 스필이 너무 느림 | 스필 압축 CPU 오버헤드 | `spill-compression-codec=NONE` |
| 회수가 너무 늦게 발동 | threshold 너무 높음 | `revocation-threshold` 낮춤 (예: 0.7) |
| 회수 후에도 메모리 부족 | target이 너무 높음 | `revocation-target` 낮춤 (예: 0.4) |
| 소규모 쿼리가 대형 쿼리에 밀림 | 킬러 정책 문제 | `LEAST_WASTE` 정책 검토 |

---

## 12. OS 커널 메모리 튜닝 권장 설정

### 스왑 억제

Trino의 `MemoryPool`은 JVM 힙 안에서 정밀하게 메모리를 추적합니다. OS가 JVM 힙 페이지를 스왑하면 `MemoryRevokingScheduler`의 1초 주기 감지가 무의미해집니다.

```bash
# 스왑 거의 사용 안 함 (0은 OOM 리스크 증가)
vm.swappiness = 1

# 스왑 파티션 자체를 비활성화 (권장, 메모리가 충분할 때)
swapoff -a
# /etc/fstab 에서 swap 라인 주석 처리
```

> **근거:** `QueryContext`가 `maxUserMemory(20GB)` 한도를 초과하면 쿼리를 킬하는데, OS 스왑이 개입하면 JVM이 느려지면서 킬 판단이 지연되고 전체 워커가 응답 불능 상태가 됩니다.

---

### Transparent Huge Pages (THP) 비활성화

THP는 JVM의 GC와 충돌하여 예측 불가능한 지연(수백ms)을 유발합니다. Trino의 Page/Block 할당 패턴(짧은 생존 객체 다량 생성)에서 특히 문제가 됩니다.

```bash
# 즉시 적용
echo never > /sys/kernel/mm/transparent_hugepage/enabled
echo never > /sys/kernel/mm/transparent_hugepage/defrag

# 재부팅 후 유지 — systemd 서비스로 등록
cat > /etc/systemd/system/disable-thp.service << 'EOF'
[Unit]
Description=Disable Transparent Huge Pages
After=sysinit.target local-fs.target

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'echo never > /sys/kernel/mm/transparent_hugepage/enabled'
ExecStart=/bin/sh -c 'echo never > /sys/kernel/mm/transparent_hugepage/defrag'
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
systemctl enable disable-thp && systemctl start disable-thp
```

> **근거:** THP defrag가 동작하면 GC Stop-the-World 시간이 수십 ms → 수백 ms로 늘어나고, 이 시간 동안 `MemoryPool.reserve()` Future가 해제되지 않아 다른 쿼리들이 연쇄 블로킹됩니다.

---

### OOM Killer 설정

Trino 워커가 OOM 킬 당하면 해당 워커의 모든 쿼리가 실패합니다. Trino 자체 메모리 킬러(`ClusterMemoryManager`)가 먼저 개입하도록 OS OOM 킬러 우선순위를 조정합니다.

```bash
# Trino 프로세스를 낮은 킬 우선순위로 설정 (되도록 보호)
echo -500 > /proc/$(pgrep -f 'TrinoServer')/oom_score_adj

# systemd 서비스로 Trino 실행 시
# /etc/systemd/system/trino.service
[Service]
OOMScoreAdjust=-500
```

메모리 오버커밋 정책:
```bash
# Trino는 명시적 한도 관리를 하므로 오버커밋 허용하지 않음
vm.overcommit_memory = 2    # 명시적 한도 초과 할당 거부
vm.overcommit_ratio  = 80   # 물리 메모리의 80%까지만 커밋 허용
```

---

### 더티 페이지 / 스필 I/O

`MemoryRevokingScheduler`가 Revocable 메모리를 회수할 때 스필 I/O가 집중됩니다. dirty page가 쌓여 있으면 동기 플러시로 인해 스필 쓰기가 지연됩니다.

```bash
vm.dirty_background_ratio    = 3     # 백그라운드 플러시 시작 비율 (일찍 시작해 누적 방지)
vm.dirty_ratio               = 10    # 동기 플러시 강제 비율
vm.dirty_expire_centisecs    = 1000  # 더티 페이지 최대 유지 시간 (10초, 기본 30초 → 단축)
vm.dirty_writeback_centisecs = 100   # 플러시 주기 (1초마다 백그라운드 플러시 체크)
```

> **근거:** 스필 파일(`max-spill-per-node=100GB`)을 빠르게 써야 Revocable 메모리가 빨리 반환되고, 블로킹된 쿼리들이 재개됩니다.

---

### NUMA 설정

다중 소켓 서버에서 NUMA 경계를 넘는 메모리 접근은 2~3배 지연이 발생합니다.

```bash
# NUMA 자동 밸런싱 활성화 (커널이 핫 페이지를 로컬 노드로 이동)
kernel.numa_balancing = 1

# 글로벌 회수 허용 (로컬 메모리 부족 시 원격 노드 메모리 사용, OOM 방지)
vm.zone_reclaim_mode = 0

# Trino 프로세스를 특정 NUMA 노드에 고정 (일관된 지연 보장)
numactl --cpunodebind=0 --membind=0 -- java -jar trino-server.jar
```

`jvm.config` NUMA 힌트:
```
-XX:+UseNUMA
-XX:+UseNUMAInterleaving   # 힙을 NUMA 노드 간 인터리브 (대형 서버)
```

---

### 명시적 Huge Pages (JVM 힙)

JVM 힙에 Huge Pages(2MB)를 사용하면 TLB 미스를 줄여 GC 성능을 개선합니다. THP(동적)와 달리 **명시적 Huge Pages**는 JVM에 안전합니다.

```bash
# 필요한 Huge Page 수 계산: JVM -Xmx / 2MB
# 예: -Xmx64g → 64 * 1024 / 2 = 32768 페이지
vm.nr_hugepages = 32768

# 확인
grep HugePages /proc/meminfo
```

`jvm.config`:
```
-XX:+UseLargePages
-XX:LargePageSizeInBytes=2m
```

`/etc/security/limits.conf`:
```
trino soft memlock unlimited   # Huge Pages 잠금 허용
trino hard memlock unlimited
```

---

### 메모리 단편화 / 캐시 설정

```bash
# 페이지 캐시 보유 압력 (기본 100 → 낮추면 스필 파일 재접근 시 캐시 히트 향상)
vm.vfs_cache_pressure    = 50

# 메모리 컴팩션 적극성 (너무 높으면 CPU 오버헤드)
vm.compaction_proactiveness = 20

# JVM NIO / 스필 mmap 부족 방지 (기본 65530)
vm.max_map_count         = 1048576
```

---

### GC 연계 JVM 설정 (`jvm.config`)

```
-XX:+UseG1GC
-XX:G1HeapRegionSize=32M           # 대용량 힙에서 Region 크기 증가
-XX:+G1UseAdaptiveIHOP             # 적응형 힙 점유율 기반 GC 트리거
-XX:InitiatingHeapOccupancyPercent=45
-XX:+ExplicitGCInvokesConcurrent   # System.gc()를 STW 없이 처리
-XX:+HeapDumpOnOutOfMemoryError
-XX:HeapDumpPath=/var/log/trino/
```

---

### 전체 적용 스크립트

```bash
cat > /etc/sysctl.d/99-trino-memory.conf << 'EOF'
# 스왑 억제
vm.swappiness = 1

# 오버커밋 제한
vm.overcommit_memory = 2
vm.overcommit_ratio  = 80

# 더티 페이지 / 스필 I/O
vm.dirty_background_ratio    = 3
vm.dirty_ratio               = 10
vm.dirty_expire_centisecs    = 1000
vm.dirty_writeback_centisecs = 100

# NUMA 밸런싱
kernel.numa_balancing = 1
vm.zone_reclaim_mode  = 0

# Huge Pages (JVM -Xmx 기준 계산)
vm.nr_hugepages = 32768

# 메모리 단편화 / 캐시
vm.vfs_cache_pressure       = 50
vm.compaction_proactiveness = 20
vm.max_map_count            = 1048576

# 파일 디스크립터
fs.file-max = 1048576
EOF

sysctl -p /etc/sysctl.d/99-trino-memory.conf

# THP 비활성화
echo never > /sys/kernel/mm/transparent_hugepage/enabled
echo never > /sys/kernel/mm/transparent_hugepage/defrag
```

---

### OS 커널 메모리 설정 우선순위 요약

| 우선순위 | 설정 | 효과 |
|----------|------|------|
| **높음** | `vm.swappiness=1` + `swapoff` | JVM 힙 스왑 방지, Revocation 지연 제거 |
| **높음** | THP 비활성화 | GC STW 예측 가능, MemoryPool 블로킹 방지 |
| **높음** | `vm.overcommit_memory=2` | OS 레벨 과할당 방지, OOM 예측 가능 |
| **중간** | `dirty_ratio=10` 단축 | 스필 I/O 집중 시 쓰기 지연 완화 |
| **중간** | 명시적 Huge Pages + `UseLargePages` | TLB 미스 감소, GC 처리량 향상 |
| **중간** | `vm.max_map_count=1048576` | JVM NIO / 스필 mmap 부족 방지 |
| **중간** | NUMA `+UseNUMA` | 다중 소켓 서버 메모리 지역성 향상 |
| **낮음** | `vfs_cache_pressure=50` | 스필 파일 재접근 캐시 히트 향상 |

---

## 13. K8s 환경 메모리 권장 설정

### Pod QoS — Guaranteed 클래스 확보

K8s의 메모리 QoS는 `requests == limits`일 때 **Guaranteed** 클래스가 부여됩니다. Trino는 반드시 Guaranteed를 확보해야 OOMKilled 위험이 줄어듭니다.

```yaml
# Guaranteed QoS: requests == limits 필수
resources:
  requests:
    memory: "72Gi"   # JVM -Xmx + headroom + 여유분
    cpu: "8"
  limits:
    memory: "72Gi"   # requests와 동일하게 설정
    cpu: "16"
```

**메모리 크기 계산 공식:**

```
limits.memory = JVM -Xmx
              + heap-headroom-per-node (Xmx의 ~30%)
              + OS/컨테이너 오버헤드 (1~2GB)

예시 (-Xmx56g):
  56GB (힙) + 17GB (headroom 30%) + 2GB (OS) = 75GB → 76Gi로 설정
```

> **근거:** `memory.heap-headroom-per-node`(기본 힙의 30%)는 `MemoryPool` 외부에서 사용되는 추적 불가 메모리입니다. limits가 이보다 작으면 cgroup에 의해 프로세스가 OOMKilled됩니다.

---

### JVM 힙 설정 — K8s 컨테이너 인식

```yaml
# ConfigMap — jvm.config
apiVersion: v1
kind: ConfigMap
metadata:
  name: trino-jvm-config
data:
  jvm.config: |
    -server
    -Xmx56G
    -Xms56G                          # 힙 초기/최대 동일 → GC 힙 크기 변동 방지
    -XX:+UseG1GC
    -XX:G1HeapRegionSize=32M
    -XX:+G1UseAdaptiveIHOP
    -XX:InitiatingHeapOccupancyPercent=45
    -XX:+ExplicitGCInvokesConcurrent
    -XX:+HeapDumpOnOutOfMemoryError
    -XX:HeapDumpPath=/var/log/trino/
    -XX:+ExitOnOutOfMemoryError      # OOM 시 즉시 종료 → K8s가 재시작
    -Djdk.attach.allowAttachSelf=true
```

> **`-XX:+ExitOnOutOfMemoryError` 포인트:** K8s 환경에서 OOM 발생 시 JVM이 좀비 상태로 남지 않고 즉시 종료해 Pod 재시작 루프를 유도하는 것이 안전합니다.

---

### THP 비활성화 — DaemonSet

K8s에서는 노드 DaemonSet 또는 Init Container로 THP를 비활성화합니다.

```yaml
# 방법 1: DaemonSet (노드 전체 적용, 권장)
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: disable-thp
  namespace: kube-system
spec:
  selector:
    matchLabels:
      name: disable-thp
  template:
    metadata:
      labels:
        name: disable-thp
    spec:
      hostPID: true
      containers:
        - name: disable-thp
          image: busybox
          command: ["sh", "-c"]
          args:
            - |
              echo never > /sys/kernel/mm/transparent_hugepage/enabled
              echo never > /sys/kernel/mm/transparent_hugepage/defrag
              while true; do sleep 3600; done
          securityContext:
            privileged: true
          volumeMounts:
            - name: sys
              mountPath: /sys
      volumes:
        - name: sys
          hostPath:
            path: /sys
      tolerations:
        - operator: Exists

---
# 방법 2: Init Container (Pod 단위 적용)
spec:
  initContainers:
    - name: disable-thp
      image: busybox
      command: ["sh", "-c"]
      args:
        - |
          echo never > /sys/kernel/mm/transparent_hugepage/enabled
          echo never > /sys/kernel/mm/transparent_hugepage/defrag
      securityContext:
        privileged: true
      volumeMounts:
        - name: sys
          mountPath: /sys
  volumes:
    - name: sys
      hostPath:
        path: /sys
```

---

### 스필 볼륨 설정

`MemoryRevokingScheduler`가 Revocable 메모리를 스필할 때 빠른 로컬 스토리지가 필요합니다.

```yaml
spec:
  template:
    spec:
      containers:
        - name: trino-worker
          volumeMounts:
            - name: spill-volume
              mountPath: /tmp/trino-spill

      volumes:
        # 방법 1: emptyDir (노드 로컬 디스크)
        - name: spill-volume
          emptyDir:
            sizeLimit: "200Gi"   # query-max-spill-per-node 이상으로 설정

        # 방법 2: hostPath (NVMe 전용 디스크 사용 시, 권장)
        - name: spill-volume
          hostPath:
            path: /nvme/trino-spill
            type: DirectoryOrCreate
```

`config.properties`:
```properties
spiller-spill-path=/tmp/trino-spill
max-spill-per-node=100GB
query-max-spill-per-node=50GB
spill-compression-codec=LZ4
```

> **NVMe 권장:** 스필 I/O는 순차 쓰기 집중적이므로 NVMe SSD를 `hostPath`로 마운트하면 Revocation 응답 시간이 크게 줄어듭니다.

---

### cgroup 메모리 / Pod sysctl

```yaml
spec:
  template:
    spec:
      securityContext:
        sysctls:
          # 스왑 억제 (safe sysctl)
          - name: vm.swappiness
            value: "1"
          # 더티 페이지 (스필 I/O 연계, safe sysctl)
          - name: vm.dirty_ratio
            value: "10"
          - name: vm.dirty_background_ratio
            value: "3"
          # unsafe sysctl — 노드 kubelet 허용 필요
          - name: vm.max_map_count
            value: "1048576"
          - name: vm.overcommit_memory
            value: "2"
          - name: vm.overcommit_ratio
            value: "80"
```

kubelet unsafe sysctl 허용:
```bash
--allowed-unsafe-sysctls=vm.max_map_count,vm.overcommit_memory,vm.overcommit_ratio
```

cgroup v2 스왑 차단 (K8s 1.28+, `kubelet-config.yaml`):
```yaml
memorySwap:
  swapBehavior: NoSwap
```

---

### Trino 설정 — K8s 환경 특화

`config.properties`:
```properties
# limits.memory=76Gi 기준 예시
query.max-memory-per-node=48GB            # limits의 ~65%
memory.heap-headroom-per-node=8GB         # 명시 지정 (기본 auto 대신)

# K8s OOMKilled 전에 Trino가 먼저 회수하도록 임계값 낮춤
memory.revocation-threshold=0.75          # 기본 0.8 → 조금 더 일찍 발동
memory.revocation-target=0.5

# 킬러 정책
query.low-memory-killer.policy=TOTAL_RESERVATION_ON_BLOCKED_NODES
task.low-memory-killer.policy=LEAST_WASTE
```

---

### LimitRange / ResourceQuota

```yaml
# LimitRange — 기본값 및 최대값 제한
apiVersion: v1
kind: LimitRange
metadata:
  name: trino-limit-range
  namespace: trino
spec:
  limits:
    - type: Container
      default:
        memory: "8Gi"
        cpu: "2"
      defaultRequest:
        memory: "4Gi"
        cpu: "1"
      max:
        memory: "128Gi"

---
# ResourceQuota — 네임스페이스 전체 상한
apiVersion: v1
kind: ResourceQuota
metadata:
  name: trino-quota
  namespace: trino
spec:
  hard:
    requests.memory: "1Ti"
    limits.memory:   "1Ti"
    pods: "100"
```

---

### Vertical Pod Autoscaler (VPA)

```yaml
apiVersion: autoscaling.k8s.io/v1
kind: VerticalPodAutoscaler
metadata:
  name: trino-worker-vpa
spec:
  targetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: trino-worker
  updatePolicy:
    updateMode: "Off"          # 추천값만 확인 — 자동 적용 X (재시작 시 쿼리 실패)
  resourcePolicy:
    containerPolicies:
      - containerName: trino-worker
        minAllowed:
          memory: "32Gi"
        maxAllowed:
          memory: "128Gi"
        controlledResources: ["memory"]
```

> **`updateMode: "Off"` 권장:** Trino 워커 재시작 시 실행 중인 모든 쿼리가 실패하므로 VPA 추천값을 참고해 수동으로 조정하는 것이 안전합니다.

---

### 노드 전용화 — Taint / Label

```bash
# 메모리 집약적 Trino 워커 전용 노드 설정
kubectl taint nodes <node-name> workload=trino-worker:NoSchedule
kubectl label nodes <node-name> workload-type=trino-worker memory-tier=high
```

```yaml
spec:
  template:
    spec:
      nodeSelector:
        workload-type: trino-worker
        memory-tier: high
      tolerations:
        - key: "workload"
          operator: "Equal"
          value: "trino-worker"
          effect: "NoSchedule"
```

---

### K8s 환경 메모리 체크리스트 요약

| 항목 | 설정 | 우선순위 |
|------|------|----------|
| QoS Guaranteed | `requests == limits` | **높음** |
| limits 여유 | `Xmx + headroom(30%) + 2GB` | **높음** |
| THP 비활성화 | DaemonSet 또는 Init Container | **높음** |
| `-XX:+ExitOnOutOfMemoryError` | OOM 시 즉시 종료 → 재시작 | **높음** |
| `vm.swappiness=1` sysctl | 스왑 억제 | **높음** |
| 스필 볼륨 (NVMe) | `emptyDir` 또는 `hostPath` | **중간** |
| `revocation-threshold=0.75` | K8s OOMKilled 전 선제 회수 | **중간** |
| `vm.max_map_count=1048576` | JVM mmap 부족 방지 | **중간** |
| cgroup v2 `NoSwap` | kubelet 레벨 스왑 차단 | **중간** |
| VPA `updateMode=Off` | 메모리 추천값 모니터링 | **낮음** |
| 전용 노드 Taint/Label | 다른 워크로드와 메모리 경합 제거 | **낮음** |
