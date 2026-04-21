# Trino 네트워크 성능 최적화 분석

## 1. 전체 네트워크 흐름 구조

```
코디네이터
├─ HttpRemoteTask  ──────────────────── (Task 배분 / Split 전송)
│   └─ POST /task/{taskId}
├─ ContinuousTaskStatusFetcher  ──────── (상태 폴링)
│   └─ GET /task/{taskId}/status
└─ DynamicFiltersFetcher  ───────────── (동적 필터 수신)
    └─ GET /task/{taskId}/dynamicFilters

워커 → 워커 (Stage 간 데이터 셔플)
└─ HttpPageBufferClient  ────────────── (Page 데이터 pull)
    └─ GET /output/{outputBufferId}
```

---

## 2. Exchange — Stage 간 데이터 전송

`DirectExchangeClient`가 노드 간 Page 전송의 핵심입니다.

### 이중 전송 모드

| 모드 | 클래스 | 특징 |
|------|--------|------|
| Direct (인메모리) | `DirectExchangeDataSource` | 빠르지만 메모리 의존 |
| Spooling (외부 저장) | `SpoolingExchangeDataSource` | 대용량 셔플에 사용, 외부 스토리지 활용 |

### 동시 요청 제어 로직 (`scheduleRequestIfNecessary()`)

```java
long neededBytes = buffer.getRemainingCapacityInBytes();
long reservedBytes = runningClients.stream()
    .mapToLong(HttpPageBufferClient::getAverageRequestSizeInBytes).sum();
// 버퍼 잔여 용량 × multiplier 이상 예약되면 추가 요청 중단
if (projectedBytes >= neededBytes * concurrentRequestMultiplier - reservedBytes) {
    break;
}
```

버퍼 오버플로를 방지하면서 `concurrentRequestMultiplier`(기본 3)만큼 요청을 병렬화합니다.

### 핵심 설정값 (`exchange.*`)

```
exchange.max-buffer-size = 32MB            # 수신 Exchange 버퍼
exchange.concurrent-request-multiplier = 3  # 동시 요청 배수
exchange.client-threads = 25               # HTTP 클라이언트 스레드 수
exchange.deduplication-buffer-size = 32MB   # 재시도 중복 제거 버퍼
exchange.acknowledge-pages = true           # 페이지 수신 확인 전송 여부
```

---

## 3. 직렬화 / 압축 파이프라인

`CompressingEncryptingPageSerializer`의 처리 흐름:

```
Page (컬럼형 데이터)
    ↓
[압축 버퍼]  LZ4 / ZSTD (64KB 블록 단위)
    │         압축률 < 80% 이면 원본 그대로 저장 (MINIMUM_COMPRESSION_RATIO = 0.8)
    ↓
[암호화 버퍼] AES/CBC/PKCS5Padding (256-bit, 랜덤 IV)
    ↓
[직렬화 포맷]
  Byte 0-3:  positionCount
  Byte 4-7:  uncompressedSize
  Byte 8-11: compressedSize
  Byte 12+:  [blockSize(4)] [compressed_flag(1bit)] [blockData] ...
```

### 압축 코덱 선택 (`CompressionCodec`)

| 코덱 | 특성 | 적합한 상황 |
|------|------|------------|
| `NONE` | 압축 없음 | CPU 병목 상황 / 이미 압축된 데이터 |
| `LZ4` | 빠른 압축/해제 | 범용 (기본 권장) |
| `ZSTD` | 높은 압축률 | 네트워크 대역폭이 병목인 경우 |

압축 성능 지표는 `Metrics.exchangeSerializerInputBytes` / `Metrics.exchangeSerializerOutputBytes`로 모니터링 가능합니다.

---

## 4. HTTP 통신 최적화

### 코디네이터 → 워커: Task 업데이트

`HttpRemoteTask`의 적응형 배치 크기 조절:

```java
// 요청 크기가 maxRequestSize(8MB) 초과 시 자동으로 배치 재조정
newSplitBatchSize = clamp(
    (numSplits * (maxRequestSize - headroom)) / currentRequestSize,
    guaranteedSplitsPerRequest,   // 최소 3
    maxUnacknowledgedSplits       // 상한
);
```

네트워크 상황에 따라 Split 배치 크기를 동적으로 줄여 요청당 페이로드를 목표치(8MB) 안에 유지합니다.

### 워커 상태 폴링

`ContinuousTaskStatusFetcher`:
- HTTP Long Polling 방식: `TRINO_MAX_WAIT_HEADER`로 서버 측 최대 대기 시간 지정
- `RequestErrorTracker`가 실패 시 지수 백오프(최대 `maxErrorDuration` = 1분) 적용
- `statusRefreshMaxWait` (기본 1초, 범위 1ms~60초)

### 핵심 설정값 (`task.*`)

```
task.http-response-threads = 100           # HTTP 응답 처리 스레드
task.http-timeout-threads = 3              # 타임아웃 감지 스레드
task.client.timeout = 2 minutes            # HTTP 커넥션 타임아웃
task.max-local-exchange-buffer-size = 128MB # 로컬 Exchange 버퍼
sink.max-buffer-size = 32MB                # 출력 버퍼
sink.max-broadcast-buffer-size = 200MB     # 브로드캐스트 버퍼
```

### 핵심 설정값 (`query.*`)

```
query.max-remote-task-request-size = 8MB              # Task 업데이트 페이로드 한도
query.remote-task-request-size-headroom = 2MB          # 크기 조정 여유분
query.remote-task-guaranteed-splits-per-task = 3       # 요청당 최소 Split 수
query.remote-task-adaptive-update-request-size-enabled = true  # 적응형 배치 조절
```

---

## 5. 백프레셔 (흐름 제어)

### OutputBuffer 계층

```java
// OutputBuffer.java
ListenableFuture<Void> isFull()                              // 버퍼 가득 찼을 때 블로킹
void enqueue(List<Slice> pages)                              // 생산자 측
BufferResult get(OutputBufferId, long token, DataSize maxSize) // 소비자 측
```

### Split 큐 백프레셔 (HttpRemoteTask)

```java
// Split 큐가 maxUnacknowledgedSplits에 도달하면 스케줄러 차단
ListenableFuture<Void> whenSplitQueueHasSpace(long weightThreshold)
```

### 버퍼 상태 전이

```
OPEN → NO_MORE_PAGES → FLUSHING → FINISHED
     → NO_MORE_BUFFERS ↗
```

---

## 6. 동적 필터 네트워크 비용

`DynamicFiltersFetcher`:
- 버전 비교(`dynamicFiltersVersion` vs `localDynamicFiltersVersion`)로 **변경이 없으면 네트워크 요청 생략**
- 워커 → 코디네이터: `GET /dynamicFilters` 폴링
- 코디네이터 → 워커: `TaskUpdateRequest` JSON에 포함되어 함께 전송, 수신 확인 후 메모리 해제

---

## 7. 비동기 / 논블로킹 설계

모든 원격 호출은 `ListenableFuture<T>` (Guava) 기반입니다.

| 스레드 풀 | 용도 |
|-----------|------|
| `pageBufferClientCallbackExecutor` | Page 수신 콜백 |
| `remoteTaskMaxCallbackThreads` (기본 1000) | Task 업데이트 콜백 |
| `errorScheduledExecutor` | 백오프 재시도 (스레드 기아 방지를 위해 분리) |
| `taskManagementExecutor` | 상태 폴링 스케줄 |

---

## 8. 최적화 포인트 요약

| 처리 계층 | 최적화 기법 | 관련 설정 |
|-----------|-------------|-----------|
| 직렬화 계층 | LZ4/ZSTD 블록 압축 (64KB), 압축률 < 80%면 건너뜀 | `exchange.compression-codec` |
| 버퍼 계층 | 수신 32MB + 로컬 128MB + 브로드캐스트 200MB | `exchange.max-buffer-size` |
| 요청 계층 | 적응형 배치 크기, 동시 요청 × 3 배수 | `concurrent-request-multiplier` |
| 프로토콜 계층 | HTTP Long Polling + 버전 기반 캐시 | `task.status-refresh-max-wait` |
| 스레드 계층 | 풀 분리 (응답/타임아웃/콜백), 논블로킹 Future | `task.http-response-threads` |

---

## 9. 병목별 권장 조정

| 병목 상황 | 권장 조정 |
|-----------|-----------|
| 네트워크 대역폭 부족 | `exchange.compression-codec=ZSTD` 적용 |
| 작은 쿼리의 높은 지연 | `task.status-refresh-max-wait` 축소, `concurrent-request-multiplier` 증가 |
| 대규모 셔플 OOM | Spooling Exchange 활성화, `exchange.max-buffer-size` 조정 |
| Split 배분 지연 | `query.max-remote-task-request-size` 확대, `adaptive-update-request-size-enabled=true` 확인 |
| CPU 과부하 (압축) | `exchange.compression-codec=LZ4` 또는 `NONE`으로 전환 |

---

## 10. OS 커널 튜닝 권장 설정

### TCP 버퍼 크기

Trino의 Exchange 버퍼(32MB~200MB)와 맞추려면 TCP 소켓 버퍼도 충분히 키워야 합니다.

```bash
# /etc/sysctl.d/99-trino.conf

# TCP 수신/송신 버퍼 (min / default / max)
net.core.rmem_max       = 134217728   # 128MB — 소켓 최대 수신 버퍼
net.core.wmem_max       = 134217728   # 128MB — 소켓 최대 송신 버퍼
net.core.rmem_default   = 33554432    # 32MB  — exchange.max-buffer-size 와 일치
net.core.wmem_default   = 33554432    # 32MB

net.ipv4.tcp_rmem       = 4096 33554432 134217728
net.ipv4.tcp_wmem       = 4096 33554432 134217728

# 커널 소켓 수신 큐 (패킷 드롭 방지)
net.core.netdev_max_backlog = 65536
```

> **근거:** `exchange.max-buffer-size=32MB`, `sink.max-broadcast-buffer-size=200MB` — TCP 버퍼가 이보다 작으면 커널 레벨에서 병목이 생깁니다.

---

### TCP 연결 수 / 포트 범위

Trino는 워커당 `exchange.client-threads=25`, `task.http-response-threads=100` 수준의 동시 연결을 유지합니다.

```bash
# Ephemeral 포트 범위 확장 (기본 32768~60999 → 확장)
net.ipv4.ip_local_port_range = 1024 65535

# SYN 백로그 — 코디네이터가 많은 워커의 연결을 동시에 받을 때
net.core.somaxconn           = 65535
net.ipv4.tcp_max_syn_backlog = 65535

# TIME_WAIT 소켓 재사용 (단기 연결 반복 시 포트 고갈 방지)
net.ipv4.tcp_tw_reuse        = 1

# FIN_WAIT2 타임아웃 단축 (기본 60초 → 30초)
net.ipv4.tcp_fin_timeout     = 30
```

> **근거:** 노드 수 × `http-response-threads(100)` 규모의 동시 연결 + Long Polling 패턴으로 TIME_WAIT 소켓이 빠르게 누적됩니다.

---

### TCP 혼잡 제어

```bash
# BBR 혼잡 제어 알고리즘 (Linux 4.9+) — 데이터센터 내부 고대역폭에 최적
net.ipv4.tcp_congestion_control = bbr
net.core.default_qdisc          = fq    # BBR과 함께 사용
```

| 알고리즘 | 특성 | Trino 적합성 |
|----------|------|-------------|
| `cubic` (기본) | 패킷 손실 기반 | 보통 |
| `bbr` | 대역폭/RTT 기반 | **권장** — 대용량 Page 전송에 유리 |

---

### TCP Keep-Alive

Trino의 HTTP Long Polling(`statusRefreshMaxWait=1초~60초`)은 유휴 연결을 장시간 유지합니다.

```bash
# Keep-Alive 첫 프로브까지 대기 시간 (기본 7200초 → 단축)
net.ipv4.tcp_keepalive_time     = 60

# 프로브 간격
net.ipv4.tcp_keepalive_intvl    = 10

# 최대 프로브 횟수 (이후 연결 끊음)
net.ipv4.tcp_keepalive_probes   = 6
```

> **근거:** 죽은 연결을 빠르게 감지해야 `ContinuousTaskStatusFetcher`의 `RequestErrorTracker` 재시도 로직이 제때 동작합니다.

---

### 파일 디스크립터 / 연결 수 한도

```bash
# 시스템 전체 파일 디스크립터 한도
fs.file-max = 1048576

# TCP 연결 추적 테이블 (conntrack — 방화벽 사용 시)
net.netfilter.nf_conntrack_max                     = 1048576
net.netfilter.nf_conntrack_tcp_timeout_established = 86400
```

`/etc/security/limits.conf` (프로세스 단위):
```
trino soft nofile 1048576
trino hard nofile 1048576
trino soft nproc  65536
trino hard nproc  65536
```

---

### 스필 디스크 I/O 연계 설정

스필(`spill-compression-codec=LZ4`)이 활성화된 환경에서는 디스크 I/O도 영향을 줍니다.

```bash
# 더티 페이지 플러시 비율 조정 (스필 쓰기와 쿼리 I/O 경합 방지)
vm.dirty_ratio            = 10   # 전체 메모리의 10% 초과 시 동기 플러시
vm.dirty_background_ratio = 3    # 백그라운드 플러시 시작 비율

# NUMA 환경 — 원격 노드 메모리 사용보다 스왑 선호 방지
vm.swappiness = 1   # 거의 스왑 안 함 (0은 OOM 리스크)
```

> **근거:** `MemoryRevokingScheduler`가 회수 발동 시 스필 I/O가 집중되는데, dirty page 누적으로 쓰기 지연이 생기면 Revocable 메모리 반환이 느려집니다.

---

### NIC / 인터럽트 설정

```bash
# IRQ 밸런싱 — 멀티코어에 NIC 인터럽트 분산
systemctl enable irqbalance && systemctl start irqbalance

# NIC 수신 큐 크기 확장
ethtool -G <인터페이스명> rx 4096 tx 4096

# NIC RSS 큐 수 = CPU 코어 수
ethtool -L <인터페이스명> combined $(nproc)

# TCP Segmentation Offload — 대용량 Page 전송 CPU 절감
ethtool -K <인터페이스명> tso on gso on gro on
```

---

### 전체 적용 스크립트

```bash
cat > /etc/sysctl.d/99-trino.conf << 'EOF'
# TCP 버퍼
net.core.rmem_max = 134217728
net.core.wmem_max = 134217728
net.core.rmem_default = 33554432
net.core.wmem_default = 33554432
net.ipv4.tcp_rmem = 4096 33554432 134217728
net.ipv4.tcp_wmem = 4096 33554432 134217728
net.core.netdev_max_backlog = 65536

# 연결 수
net.ipv4.ip_local_port_range = 1024 65535
net.core.somaxconn = 65535
net.ipv4.tcp_max_syn_backlog = 65535
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 30

# 혼잡 제어
net.ipv4.tcp_congestion_control = bbr
net.core.default_qdisc = fq

# Keep-Alive
net.ipv4.tcp_keepalive_time = 60
net.ipv4.tcp_keepalive_intvl = 10
net.ipv4.tcp_keepalive_probes = 6

# 파일 디스크립터
fs.file-max = 1048576

# 스왑 / 디스크 I/O
vm.swappiness = 1
vm.dirty_ratio = 10
vm.dirty_background_ratio = 3
EOF

sysctl -p /etc/sysctl.d/99-trino.conf
```

---

### OS 커널 설정 우선순위 요약

| 우선순위 | 설정 | 효과 |
|----------|------|------|
| **높음** | TCP 버퍼 128MB | Exchange 대용량 전송 병목 제거 |
| **높음** | `tcp_tw_reuse=1` + 포트 범위 확장 | 동시 연결 고갈 방지 |
| **높음** | `vm.swappiness=1` | 메모리 풀 안정성 (스왑 개입 방지) |
| **중간** | BBR 혼잡 제어 | 노드 간 대역폭 활용률 향상 |
| **중간** | Keep-Alive 단축 (60초) | 죽은 연결 빠른 감지 |
| **중간** | IRQ 밸런싱 + NIC 큐 확장 | 고트래픽 시 CPU 분산 |
| **낮음** | `dirty_ratio` 조정 | 스필 I/O 경합 완화 |

---

## 11. K8s 환경 네트워크 권장 설정

### Pod sysctl — 커널 파라미터 적용

K8s에서는 `securityContext.sysctls`로 Pod 단위 커널 파라미터를 적용합니다. **safe sysctl**은 즉시 사용 가능하고, **unsafe sysctl**은 노드에서 허용(`--allowed-unsafe-sysctls`) 해야 합니다.

```yaml
# coordinator / worker Deployment 공통 적용
spec:
  template:
    spec:
      securityContext:
        sysctls:
          # ── safe sysctls (별도 노드 설정 불필요) ──────────────────
          - name: net.ipv4.tcp_keepalive_time
            value: "60"
          - name: net.ipv4.tcp_keepalive_intvl
            value: "10"
          - name: net.ipv4.tcp_keepalive_probes
            value: "6"
          - name: net.ipv4.tcp_fin_timeout
            value: "30"
          - name: net.ipv4.tcp_tw_reuse
            value: "1"
          # ── unsafe sysctls (노드 kubelet 허용 필요) ───────────────
          - name: net.core.rmem_max
            value: "134217728"
          - name: net.core.wmem_max
            value: "134217728"
          - name: net.ipv4.tcp_rmem
            value: "4096 33554432 134217728"
          - name: net.ipv4.tcp_wmem
            value: "4096 33554432 134217728"
```

Kubelet에서 unsafe sysctl 허용 (노드 설정):
```bash
# /etc/kubernetes/kubelet-config.yaml 또는 kubelet 실행 옵션
--allowed-unsafe-sysctls=net.core.rmem_max,net.core.wmem_max,net.ipv4.tcp_rmem,net.ipv4.tcp_wmem
```

---

### Pod 리소스 요청/한도 — 네트워크 연계

Exchange 버퍼(32MB~200MB)와 HTTP 스레드 수를 고려한 기준값입니다.

```yaml
# Coordinator
resources:
  requests:
    cpu: "4"
    memory: "16Gi"
  limits:
    cpu: "8"
    memory: "32Gi"

# Worker (Exchange 버퍼 + JVM 힙 고려)
resources:
  requests:
    cpu: "8"
    memory: "64Gi"
  limits:
    cpu: "16"
    memory: "128Gi"
```

> **포인트:** `limits.memory`를 JVM `-Xmx`보다 최소 20% 여유 있게 설정해야 OOMKilled를 방지합니다. `memory.heap-headroom-per-node`(기본 30%)가 추적 외 메모리를 사용하기 때문입니다.

---

### Service 구성 — 워커 간 직접 통신

워커 간 셔플(`HttpPageBufferClient`)은 Pod IP로 직접 통신해야 합니다.

```yaml
# Coordinator — ClusterIP (클라이언트 단일 진입점)
apiVersion: v1
kind: Service
metadata:
  name: trino-coordinator
spec:
  type: ClusterIP
  ports:
    - port: 8080
      targetPort: 8080
  selector:
    app: trino
    component: coordinator

---
# Worker — Headless (Pod IP 직접 해석, 셔플 경로 최적화)
apiVersion: v1
kind: Service
metadata:
  name: trino-worker
spec:
  clusterIP: None          # Headless
  ports:
    - port: 8080
      targetPort: 8080
  selector:
    app: trino
    component: worker
```

> **근거:** ClusterIP를 통하면 kube-proxy iptables NAT를 거치면서 셔플 트래픽에 불필요한 오버헤드가 생깁니다. Headless로 Pod IP를 직접 등록하면 NAT 없이 통신합니다.

---

### DNS 튜닝 — ndots 절감

Trino 내부 HTTP 호출은 짧은 호스트명을 자주 사용합니다. 기본 `ndots:5` 설정은 불필요한 DNS 조회를 유발합니다.

```yaml
spec:
  template:
    spec:
      dnsPolicy: ClusterFirst
      dnsConfig:
        options:
          - name: ndots
            value: "2"       # 기본 5 → 2로 절감 (불필요한 search domain 조회 제거)
          - name: single-request-reopen
          - name: timeout
            value: "2"
          - name: attempts
            value: "3"
```

NodeLocal DNSCache 활성화 (클러스터 수준):
```bash
# node-local-dns DaemonSet — DNS 조회 지연 수 ms → 수십 μs
# kube-system 네임스페이스에 배포 (공식 매니페스트 사용)
# kubectl apply -f https://k8s.io/examples/admin/dns/nodelocaldns.yaml
```

---

### Network Policy — 셔플 트래픽 허용

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: trino-network-policy
spec:
  podSelector:
    matchLabels:
      app: trino
  policyTypes:
    - Ingress
    - Egress
  ingress:
    # 워커 ↔ 워커 셔플 (8080)
    - from:
        - podSelector:
            matchLabels:
              app: trino
      ports:
        - port: 8080
    # 외부 클라이언트 → 코디네이터
    - from: []
      ports:
        - port: 8080
  egress:
    # Trino Pod 간 전체 통신 허용
    - to:
        - podSelector:
            matchLabels:
              app: trino
    # DNS
    - to: []
      ports:
        - port: 53
          protocol: UDP
        - port: 53
          protocol: TCP
    # 외부 데이터 소스 (S3, HDFS 등)
    - to: []
      ports:
        - port: 443
        - port: 9000   # MinIO / S3-compatible
```

---

### Pod 배치 — 네트워크 토폴로지 최적화

```yaml
spec:
  template:
    spec:
      # 같은 가용 영역(AZ)에 워커를 모아 셔플 트래픽의 AZ 간 비용 제거
      affinity:
        podAffinity:
          preferredDuringSchedulingIgnoredDuringExecution:
            - weight: 100
              podAffinityTerm:
                labelSelector:
                  matchLabels:
                    app: trino
                    component: worker
                topologyKey: topology.kubernetes.io/zone

        # 워커는 노드 분산 (단일 노드 장애 영향 최소화)
        podAntiAffinity:
          preferredDuringSchedulingIgnoredDuringExecution:
            - weight: 50
              podAffinityTerm:
                labelSelector:
                  matchLabels:
                    app: trino
                    component: worker
                topologyKey: kubernetes.io/hostname

      # 네트워크 집약적 워크로드 → 전용 노드 풀 권장
      nodeSelector:
        workload-type: trino-worker

      tolerations:
        - key: "workload-type"
          operator: "Equal"
          value: "trino-worker"
          effect: "NoSchedule"
```

---

### Trino 설정 — K8s 환경 특화

`config.properties` (coordinator / worker):
```properties
# HTTP 서버 — K8s 환경에서 Pod IP를 discovery 주소로 사용
node.internal-address-source=FQDN

# 셔플 스레드 수 — 워커 CPU 코어 수에 맞게 조정
exchange.client-threads=50
task.http-response-threads=200

# 대용량 셔플 환경
exchange.max-buffer-size=64MB
sink.max-buffer-size=64MB
sink.max-broadcast-buffer-size=256MB

# 적응형 배치 조절 활성화
query.remote-task-adaptive-update-request-size-enabled=true
```

---

### Helm Chart 주요 values

공식 Trino Helm Chart(`trino/trino`) 사용 시:

```yaml
# values.yaml
coordinator:
  jvm:
    maxHeapSize: "24G"
  config:
    query.max-memory: "20GB"
    query.max-memory-per-node: "8GB"
  resources:
    requests: { cpu: "4", memory: "28Gi" }
    limits:   { cpu: "8", memory: "32Gi" }

worker:
  jvm:
    maxHeapSize: "56G"
  config:
    query.max-memory-per-node: "48GB"
    memory.heap-headroom-per-node: "8GB"
    exchange.compression-codec: "LZ4"
    exchange.max-buffer-size: "64MB"
    exchange.client-threads: "50"
    task.http-response-threads: "200"
    sink.max-buffer-size: "64MB"
    sink.max-broadcast-buffer-size: "256MB"
  resources:
    requests: { cpu: "8", memory: "64Gi" }
    limits:   { cpu: "16", memory: "72Gi" }

securityContext:
  sysctls:
    - name: net.ipv4.tcp_keepalive_time
      value: "60"
    - name: net.ipv4.tcp_fin_timeout
      value: "30"
    - name: net.ipv4.tcp_tw_reuse
      value: "1"
```

---

### CNI 플러그인별 고려사항

| CNI | 특성 | Trino 권장 설정 |
|-----|------|----------------|
| **Calico** | NetworkPolicy 지원, BGP 라우팅 | `IPinIP` → `VXLAN` 비활성화 검토 (오버헤드 감소) |
| **Cilium** | eBPF 기반, kube-proxy 대체 가능 | `kubeProxyReplacement=true`로 NAT 오버헤드 제거 |
| **Flannel** | 단순, VXLAN | 고트래픽 셔플 시 MTU 조정 필요 (`vxlanMTU=1450`) |
| **AWS VPC CNI** | Pod = ENI IP, NAT 없음 | 기본값으로 Trino 셔플에 최적, `WARM_IP_TARGET` 조정 |

---

### K8s 환경 체크리스트 요약

| 항목 | 설정 | 우선순위 |
|------|------|----------|
| Pod sysctl TCP 버퍼 | `rmem_max=128MB`, `wmem_max=128MB` | **높음** |
| Worker Service | Headless (NAT 제거) | **높음** |
| `vm.swappiness=1` | OOMKilled 방지 | **높음** |
| DNS ndots | `5 → 2` 절감 | **중간** |
| NodeLocal DNSCache | DNS 지연 수십 μs | **중간** |
| Pod Affinity (AZ 집중) | AZ 간 셔플 비용 제거 | **중간** |
| Network Policy | 셔플 포트(8080) 명시 허용 | **중간** |
| Cilium eBPF | kube-proxy NAT 제거 | **낮음** (클러스터 교체 필요) |
