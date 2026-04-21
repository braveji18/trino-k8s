# Trino 코디네이터 튜닝

## 1. 코디네이터의 역할

### 네트워크 측면

코디네이터는 워커로 Task를 밀어넣고 상태를 폴링합니다.

```
코디네이터
├─ HttpRemoteTask              → POST /task/{taskId}            (Task 배분 / Split 전송)
├─ ContinuousTaskStatusFetcher → GET /task/{taskId}/status      (상태 폴링)
└─ DynamicFiltersFetcher        → GET /task/{taskId}/dynamicFilters
```

### 메모리 측면

코디네이터는 클러스터 전체 메모리를 집계하고 쿼리 킬러를 조율합니다.

```
ClusterMemoryManager (코디네이터)  ← 전체 노드 메모리 집계 / 쿼리 킬러 조율
    └─ LocalMemoryManager (워커)
```

---

## 2. Task 배분 최적화 (코디네이터 → 워커)

### 적응형 배치 크기 조절 (HttpRemoteTask)

```java
// 요청 페이로드가 maxRequestSize(8MB) 초과 시 자동으로 Split 배치 크기 재조정
newSplitBatchSize = clamp(
    (numSplits * (maxRequestSize - headroom)) / currentRequestSize,
    guaranteedSplitsPerRequest,   // 최소 3
    maxUnacknowledgedSplits
);
```

### 핵심 설정 (`query.*` — 코디네이터가 소비)

| 설정 | 기본값 | 용도 |
|------|--------|------|
| `query.max-remote-task-request-size` | 8MB | Task 업데이트 페이로드 한도 |
| `query.remote-task-request-size-headroom` | 2MB | 크기 조정 여유분 |
| `query.remote-task-guaranteed-splits-per-task` | 3 | 요청당 최소 Split 수 |
| `query.remote-task-adaptive-update-request-size-enabled` | true | 적응형 배치 조절 |

---

## 3. 워커 상태 폴링 (코디네이터가 주도)

- **Long Polling**: `TRINO_MAX_WAIT_HEADER`로 서버 측 최대 대기 지정
- **지수 백오프**: `RequestErrorTracker` 실패 시 최대 `maxErrorDuration=1분`
- **`statusRefreshMaxWait`**: 기본 1초 (1ms~60초)

**튜닝 포인트:**
- 작은 쿼리 지연이 크면 `task.status-refresh-max-wait` 축소
- 연결이 자주 끊기면 커널 keepalive 단축

---

## 4. 동적 필터 네트워크 비용 (코디네이터 중심)

- 워커 → **코디네이터**: `GET /dynamicFilters` 폴링
- 코디네이터 → 워커: `TaskUpdateRequest` JSON에 포함
- 버전 비교로 변경 없으면 네트워크 요청 생략

---

## 5. 메모리 킬러 — 코디네이터가 담당

```
query.low-memory-killer.policy:
  NONE
  TOTAL_RESERVATION                      # 예약량 가장 큰 쿼리 킬
  TOTAL_RESERVATION_ON_BLOCKED_NODES     # (기본)

task.low-memory-killer.policy:
  NONE
  TOTAL_RESERVATION_ON_BLOCKED_NODES     # (기본)
  LEAST_WASTE                            # 낭비 최소화 기준 태스크 킬
```

**킬 순서:** Task 킬러 먼저 → 부족하면 Query 킬러 (덜 파괴적인 것부터)

---

## 6. 쿼리 전체 메모리 상한 (코디네이터가 집계)

| 설정 | 기본값 | 범위 |
|------|--------|------|
| `query.max-memory` | 20GB | 쿼리당 User 메모리 상한 (클러스터 전체) |
| `query.max-total-memory` | 40GB | 쿼리당 전체 메모리 상한 |

---

## 7. 코디네이터 메모리당 동시 쿼리 용량 가이드

### 공식 기준은 없음

Trino 공식 문서/소스 어디에도 **"코디네이터 1GB당 동시 쿼리 N개"** 같은 정량 기준이 없습니다. 쿼리 복잡도, 클러스터 규모(워커 수), 스테이지 수에 따라 **쿼리당 메모리가 수십 배 차이**나기 때문입니다.

### 코디네이터 힙을 먹는 주요 항목

| 항목 | 쿼리당 대략 크기 | 증가 요인 |
|------|-----------------|----------|
| **플랜 트리(PlanNode) + Analysis** | 1~50MB | 테이블/조인/서브쿼리 수 |
| **RemoteTask 상태 × (스테이지 × 워커)** | Task당 1~5MB | **워커 수에 비례 — 가장 큰 변수** |
| Split 큐 (`pendingSplits`) | 1~20MB | 파티션/파일 수 |
| OutputBuffer 메타데이터 | < 1MB | 스테이지 수 |
| 완료 쿼리 히스토리 (`query.max-history=100`) | 전체 50~200MB | 한 번만 잡힘 |
| Metadata 캐시 (테이블/스키마) | 100MB~수 GB | 카탈로그 수 |

### 쿼리 1개의 코디네이터 메모리 계산 모델

```
쿼리당 메모리 ≈ 플랜 + (스테이지 × 워커 × Task오버헤드)

간단 쿼리 (단일 테이블 scan, 10 워커):
  2MB (플랜) + (3 stages × 10 workers × 2MB) = ~60MB

중간 쿼리 (조인 3개, 50 워커):
  10MB (플랜) + (8 stages × 50 workers × 3MB) = ~1.2GB

복잡 쿼리 (조인 10+, 서브쿼리, 100 워커):
  50MB (플랜) + (20 stages × 100 workers × 5MB) = ~10GB
```

### 실무 근사 — Headroom 30% 적용

| 코디네이터 힙 | 사용 가능 (~70%) | 간단 쿼리 (60MB/건) | 중간 쿼리 (500MB/건) | 복잡 쿼리 (2GB/건) |
|--------------|-----------------|--------------------|---------------------|-------------------|
| **1GB** | ~700MB | ~10건 | 1건 (빠듯) | 불가 |
| **4GB** | ~2.8GB | ~40건 | ~5건 | 1건 |
| **16GB** | ~11GB | ~100건 | ~20건 | ~5건 |
| **32GB** | ~22GB | ~200건 | ~40건 | ~10건 |

> **"1GB당 대략"**: 간단 쿼리 ~10건, 중간 쿼리 ~2건, 복잡 쿼리는 1건도 빠듯

### 메모리보다 먼저 터지는 실제 병목

코디네이터가 불안정해지는 원인은 대부분 메모리가 **아니라** 다음 항목입니다:

1. **스레드 풀 고갈**
   - `query.executor-pool-size` (기본 1000) — 쿼리 실행 스케줄 스레드
   - `task.http-response-threads` (기본 100) — HTTP 응답 처리
2. **네트워크 대역폭** — 수백 워커 × 1초 폴링 = 수천 req/s
3. **GC Pause** — 힙이 크면 Full GC 1회에 수 초 정지, 그 사이 워커 타임아웃
4. **Resource Group 큐 관리** — `hardConcurrencyLimit`가 실제 방어선

### 클러스터 규모별 권장 용량

| 클러스터 규모 | 코디네이터 힙 | 동시 쿼리 목표 |
|--------------|--------------|--------------|
| 소규모 (< 10 워커) | 8~16GB | 20~50건 |
| 중규모 (10~50 워커) | 32~64GB | 50~100건 |
| 대규모 (50~200 워커) | 64~128GB | 100~300건 |
| 초대규모 (200+ 워커) | 128GB+ + **Trino Gateway로 클러스터 분리** | 클러스터당 100~300건 |

### 실측 모니터링

메모리 공식보다 **실측**이 정답입니다.

```sql
-- 현재 활성 쿼리
SELECT count(*) FROM system.runtime.queries WHERE state = 'RUNNING';

-- JMX 힙 사용률
SELECT * FROM jmx.current."java.lang:type=memory";
```

**원칙:** `hardConcurrencyLimit`로 명시적 상한을 걸고, **GC 시간 + 힙 사용률**을 모니터링하며 점진적으로 늘립니다. 메모리를 2배 키워도 스레드 풀이나 GC가 먼저 터지면 의미가 없습니다.

---

## 8. K8s 코디네이터 리소스 설정

```yaml
# Coordinator — 워커보다 작은 리소스 (쿼리 직접 실행 X, 플랜/스케줄만 담당)
resources:
  requests:
    cpu: "4"
    memory: "16Gi"
  limits:
    cpu: "8"
    memory: "32Gi"
```

> `limits.memory`를 JVM `-Xmx`보다 최소 20% 여유로. `memory.heap-headroom-per-node`(기본 30%)가 추적 외 메모리를 점유합니다.

---

## 9. Coordinator Service — 단일 진입점

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
```

워커와 달리 **Headless가 아닌 ClusterIP**입니다. 클라이언트/LB가 단일 VIP로 접근하고, 코디네이터는 워커 IP를 직접 호출하기 때문입니다.

---

## 10. Helm Chart 코디네이터 values

```yaml
coordinator:
  jvm:
    maxHeapSize: "24G"
  config:
    query.max-memory: "20GB"
    query.max-memory-per-node: "8GB"
  resources:
    requests: { cpu: "4", memory: "28Gi" }
    limits:   { cpu: "8", memory: "32Gi" }
```

---

## 11. 코디네이터 튜닝 체크리스트

| 영역 | 설정 | 기본값 | 튜닝 포인트 |
|------|------|--------|-----------|
| Task 배분 | `query.max-remote-task-request-size` | 8MB | Split 많은 쿼리 → 확대 |
| Task 배분 | `query.remote-task-adaptive-update-request-size-enabled` | true | 그대로 유지 권장 |
| 상태 폴링 | `task.status-refresh-max-wait` | 1초 | 작은 쿼리 지연 민감 시 단축 |
| 메모리 집계 | `query.max-memory` / `query.max-total-memory` | 20GB / 40GB | 워크로드에 맞게 |
| 킬러 정책 | `query.low-memory-killer.policy` | TOTAL_RESERVATION_ON_BLOCKED_NODES | 기본 유지 |
| 킬러 정책 | `task.low-memory-killer.policy` | TOTAL_RESERVATION_ON_BLOCKED_NODES | 소규모 쿼리 보호 시 `LEAST_WASTE` |
| K8s 리소스 | coordinator limits | — | `Xmx + 30% headroom + 2GB` |
| K8s Service | coordinator | — | ClusterIP (worker는 Headless) |

---

## 12. 코디네이터 이중화 — 결론: **네이티브로는 불가능**

Trino는 근본적으로 **단일 코디네이터(single-coordinator) 아키텍처**입니다. 소스 확인 결과:

### 12.1 코디네이터는 boolean 플래그일 뿐

`core/trino-main/src/main/java/io/trino/server/ServerConfig.java`에서 `coordinator=true/false`는 단순 역할 구분 플래그입니다. 여러 코디네이터가 **서로를 인식하거나 협업하는 로직이 없습니다.**

```java
// ServerConfig.java
private boolean coordinator = true;
```

### 12.2 쿼리 상태가 로컬 메모리에만 존재

```java
// QueryTracker.java
private final ConcurrentMap<QueryId, T> queries = new ConcurrentHashMap<>();

// DispatchManager.java
private final QueryTracker<DispatchQuery> queryTracker;
```

- `SqlQueryManager`, `DispatchManager`, `QueryStateMachine` 모두 **JVM 힙에만** 상태 보관
- 외부 저장소(DB, Redis, ZK) 공유 메커니즘 부재
- 코디네이터가 죽으면 **진행 중이던 모든 쿼리 손실**

### 12.3 리소스 그룹도 공유되지 않음

```java
// InternalResourceGroupManager.java
private final ConcurrentMap<ResourceGroupId, InternalResourceGroup> groups = new ConcurrentHashMap<>();
```

리소스 그룹을 로컬 ConcurrentMap으로만 관리 → 여러 코디네이터 간 **쿼리 큐/동시성 제한이 공유되지 않아** 리소스 그룹 정책이 깨집니다.

### 12.4 Discovery도 단일 구조

내장 Discovery 서버는 단일 URI 집합만 다루며, 워커들은 `discovery.uri`에 지정된 **단 하나의 코디네이터**를 바라봅니다.

```java
// NodeInventory.java
public interface NodeInventory {
    Set<URI> getNodes();
}
```

---

## 13. 실무적 대안 — Active/Standby 또는 Trino Gateway

| 방식 | 설명 | 한계 |
|------|------|------|
| **Trino Gateway** (권장) | 별도 OSS 프로젝트. 여러 독립 Trino 클러스터 앞에 두는 L7 라우터 — 클러스터 단위 페일오버/라우팅 | 쿼리 상태는 공유 안 됨. 장애 시 해당 쿼리는 실패, 재실행 필요 |
| **Active/Standby** | 코디네이터 2대를 구성하되 한 번에 1대만 활성 (VIP/LB로 트래픽 스위칭) | Standby가 쿼리 상태를 모름 → 전환 시 실행 중 쿼리 모두 실패 |
| **K8s Deployment + Service** | Pod 1개로 유지, 죽으면 재생성 (빠른 복구) | 재생성 중 downtime. 쿼리 손실 발생 |
| **클러스터 다중화 + 앞단 LB** | 독립 Trino 클러스터 N개를 Gateway/nginx로 라우팅 | 카탈로그/캐시 중복 관리. 쿼리 affinity 필요 |

### Trino Gateway 개요 (별도 프로젝트)

- 리포: `https://github.com/trinodb/trino-gateway` (Trino 공식 생태계)
- 기능: 라우팅 규칙(쿼리 타입/유저별), 헬스체크 기반 백엔드 자동 제외, 관리자 API, 세션 sticky
- **하지만 쿼리-레벨 HA는 아님** — 백엔드 Trino가 죽으면 그 위의 쿼리는 실패

---

## 14. 현실적 운영 패턴

1. **분석 워크로드**: Trino Gateway 앞단 + 뒤에 Trino 클러스터 2~3개 → 클러스터 장애 시 새 쿼리는 다른 클러스터로 라우팅
2. **K8s 배포**: 코디네이터 단일 Pod + readinessProbe + `ExitOnOutOfMemoryError`로 빠른 재시작 (실행 중 쿼리 손실 수용)
3. **세션 스토리지 확장**: `access-control`, `event-listener` 같은 **외부 상태 의존 컴포넌트만** DB로 이관 — 나머지는 재시작 후 복구

**핵심:** Trino는 "stateless 워커 + stateful 단일 코디네이터" 설계라서 전통적 DB HA처럼 **"코디네이터 자체 이중화"는 없습니다.** HA가 필요하면 **Trino Gateway 기반 클러스터 다중화**가 사실상 유일한 공식 패턴입니다.
