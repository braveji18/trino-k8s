# Trino 동시 작업 수 증대 — 계층별 설정 가이드

"동시 작업"이 무엇을 의미하느냐에 따라 건드릴 설정이 다릅니다. **위에서 아래로** 계층별로 정리합니다.

---

## 1. 클러스터 레벨 — 동시 실행 쿼리 수

**리소스 그룹(`etc/resource-groups.json`)으로 제어** — 이게 가장 먼저 손대는 레버입니다.

```json
{
  "rootGroups": [{
    "name": "global",
    "softMemoryLimit": "80%",
    "hardConcurrencyLimit": 50,     // 동시 실행 쿼리 상한 ← 핵심
    "softConcurrencyLimit": 30,     // 이 값 초과 시 새 쿼리 낮은 우선순위
    "maxQueued": 200,               // 대기 큐 크기
    "schedulingPolicy": "weighted_fair"
  }]
}
```

근거: `core/trino-main/src/main/java/io/trino/execution/resourcegroups/InternalResourceGroup.java:96-100`

**튜닝 포인트:**
- 동시 쿼리가 큐에서 오래 대기 → `hardConcurrencyLimit` ↑, `maxQueued` ↑
- 큰 쿼리와 작은 쿼리 혼재 → 서브그룹으로 분리 (adhoc/etl)

---

## 2. 쿼리 레벨 — 쿼리 1개의 병렬도

`core/trino-main/src/main/java/io/trino/execution/QueryManagerConfig.java`:

| 설정 | 기본값 | 효과 |
|------|--------|------|
| `query.max-hash-partition-count` | 100 | 해시 셔플 파티션 최대 수 ↑ = 병렬 Stage 폭 ↑ |
| `query.min-hash-partition-count` | 4 | 해시 셔플 파티션 최소 수 |
| `query.max-writer-task-count` | 100 | 쓰기(INSERT) 병렬 Task 수 |

**세션 속성으로 쿼리별 조정 가능** (`SystemSessionProperties.java`):

```sql
SET SESSION hash_partition_count = 64;
SET SESSION task_concurrency = 16;
```

---

## 3. Task 레벨 — Task 내 Driver 동시성

`core/trino-main/src/main/java/io/trino/execution/TaskManagerConfig.java`:

| 설정 | 기본값 | 의미 |
|------|--------|------|
| `task.concurrency` | `min(2^n ≤ CPU, 32)` | **Join/Aggregation의 병렬 Driver 수** (2의 거듭제곱만 허용) |
| `task.max-worker-threads` | CPU × 2 | 워커 전체 Driver 스레드 풀 |
| `task.min-drivers` | `2 × max-worker-threads` | 최소 동시 Driver |
| `task.max-drivers-per-task` | `Integer.MAX_VALUE` | Task당 Driver 상한 |
| `task.min-drivers-per-task` | 3 | Task당 최소 Driver |
| `task.initial-splits-per-node` | `max-worker-threads` | 워커 시작 시 초기 배정 |

**⚠️ 주의:** `task.concurrency`는 2, 4, 8, 16, 32만 유효 (2의 거듭제곱 강제).

---

## 4. 노드 스케줄링 — 노드당 동시 Split 수

`core/trino-main/src/main/java/io/trino/execution/scheduler/NodeSchedulerConfig.java`:

| 설정 | 기본값 | 효과 |
|------|--------|------|
| `node-scheduler.max-splits-per-node` | **256** | 한 워커에 동시 할당 가능한 Split 최대 — **가장 큰 영향력** |
| `node-scheduler.min-pending-splits-per-task` | 16 | Task당 최소 대기 Split |
| `node-scheduler.max-adjusted-pending-splits-per-task` | 2000 | Task당 최대 대기 Split (적응형) |
| `node-scheduler.max-unacknowledged-splits-per-task` | 2000 | Task가 ACK 안 한 Split 상한 |

**튜닝:** CPU가 놀고 있고 Split이 많다면 `max-splits-per-node`를 512~1024로 증가. 단, 메모리 압박 주의.

---

## 5. 네트워크/Exchange 동시성

`core/trino-main/src/main/java/io/trino/operator/DirectExchangeClientConfig.java`:

| 설정 | 기본값 | 효과 |
|------|--------|------|
| `exchange.client-threads` | 25 | Exchange HTTP 클라이언트 스레드 |
| `exchange.concurrent-request-multiplier` | 3 | 버퍼 잔여 용량 × 3 만큼 병렬 요청 |
| `task.http-response-threads` | 100 | HTTP 응답 처리 스레드 |

**튜닝:** 대규모 클러스터(50+ 워커)에선 `exchange.client-threads`를 50~100으로 증가.

---

## 6. 커넥터 레벨 — Split 생성 속도 (Hive 예)

| 설정 | 기본값 | 효과 |
|------|--------|------|
| `hive.split-loader-concurrency` | 64 | Split 로더 스레드 수 |
| `hive.max-outstanding-splits` | 1000 | 생성 후 대기 Split 상한 |
| `hive.max-outstanding-splits-size` | 256MB | 대기 Split 총 메모리 |
| `hive.max-splits-per-second` | 무제한 | Split 생성 속도 제한 |

Hive처럼 파일이 많은 커넥터에서 **Split 로딩이 병목이면** `split-loader-concurrency` 증가.

---

## 7. 목적별 "어디를 건드릴까" 의사결정

| 증상 | 건드릴 설정 |
|------|-----------|
| **큐에 쿼리가 쌓임** | 리소스 그룹 `hardConcurrencyLimit` ↑ |
| **CPU가 놀고 있음** | `task.concurrency` ↑, `node-scheduler.max-splits-per-node` ↑ |
| **네트워크 셔플이 느림** | `exchange.client-threads` ↑, `exchange.concurrent-request-multiplier` ↑ |
| **쿼리 내 병렬도 부족** | `hash_partition_count` 세션 속성 ↑ |
| **Split 생성이 느림 (Hive)** | `hive.split-loader-concurrency` ↑ |
| **쓰기(INSERT) 느림** | `query.max-writer-task-count` ↑, `task_writer_count` 세션 ↑ |

---

## 8. 권장 순서 (안전한 튜닝 루트)

1. **먼저 측정** — `SHOW QUERIES`, Web UI Stage 탭에서 병목 계층 확인
2. **리소스 그룹** — 큐가 차면 여기부터
3. **`task.concurrency`** — 조인/집계 병렬도, CPU 활용률이 낮으면 ↑
4. **`max-splits-per-node`** — Split 스케줄링 병목 시
5. **Exchange 스레드** — 네트워크 셔플이 병목일 때만
6. **커넥터별 로더** — Split 로딩이 병목일 때

**⚠️ 주의사항:**
- 동시성 ↑ = 메모리 사용 ↑ → `query.max-memory-per-node`와 `memory.heap-headroom-per-node` 함께 검토
- 스레드 ↑ = 컨텍스트 스위치 ↑ → CPU가 남지 않으면 오히려 역효과
- 한꺼번에 여러 설정을 바꾸지 말고 **하나씩 변경 후 측정**

---

## 9. Small vs Heavy Query — 쿼리 크기별 메모리 차등 설정

**전제:** Trino는 small/heavy를 자동 구분하지 않습니다. **리소스 그룹 + 세션 속성 + resource estimate**로 사용자가 분류해 다른 설정을 적용해야 합니다.

### 9.1 리소스 그룹으로 쿼리 분리

`etc/resource-groups.json`에 그룹별 **다른 메모리/동시성 제한**을 정의하고 selector로 라우팅합니다.

```json
{
  "rootGroups": [{
    "name": "global",
    "softMemoryLimit": "80%",
    "hardConcurrencyLimit": 100,
    "maxQueued": 1000,
    "subGroups": [
      {
        "name": "small",
        "softMemoryLimit": "20%",        // 작은 쿼리는 메모리 제한 낮게
        "hardConcurrencyLimit": 50,      // 동시 실행 많이
        "maxQueued": 500,
        "schedulingPolicy": "fair"
      },
      {
        "name": "heavy",
        "softMemoryLimit": "60%",        // 큰 쿼리는 메모리 많이
        "hardConcurrencyLimit": 5,       // 동시 실행 적게
        "maxQueued": 50,
        "schedulingPolicy": "query_priority"
      }
    ]
  }],

  "selectors": [
    { "source": "trino-cli",           "group": "global.small" },
    { "resourceEstimates": { "peakMemory": "10GB" },
                                        "group": "global.heavy" },
    { "queryType": "SELECT",            "group": "global.small" },
    { "queryType": "INSERT",            "group": "global.heavy" }
  ]
}
```

#### Selector 기준 (분류 조건)

| selector 필드 | 의미 | 예 |
|--------------|------|-----|
| `user` / `userGroup` | 유저/그룹 | 분석팀 vs ETL 봇 |
| `source` | 클라이언트 | trino-cli vs airflow |
| `queryType` | 쿼리 종류 | SELECT, INSERT, EXPLAIN |
| `resourceEstimates` | **예상 사용량** | `peakMemory`, `cpuTime`, `executionTime` |
| `clientTags` | 세션 태그 | `--client-tags=etl,nightly` |

`resourceEstimates`가 핵심 — 클라이언트가 EXPLAIN으로 예상 크기를 추정해 힌트로 제공하면 자동 분기 가능.

---

### 9.2 세션 속성으로 쿼리당 메모리 오버라이드

heavy 쿼리에 한해 개별 상한을 완화할 수 있습니다.

```sql
-- heavy 쿼리: 더 많은 메모리 허용
SET SESSION query_max_memory = '40GB';
SET SESSION query_max_memory_per_node = '16GB';
SET SESSION query_max_total_memory = '80GB';

-- small 쿼리: 기본값 (별도 설정 불필요)
```

**관련 세션 속성** (`SystemSessionProperties.java`):

| 세션 속성 | 시스템 설정 | 용도 |
|----------|------------|------|
| `query_max_memory` | `query.max-memory` | 쿼리당 User 메모리 상한 (클러스터) |
| `query_max_total_memory` | `query.max-total-memory` | User + Revocable 합산 상한 |
| `query_max_memory_per_node` | `query.max-memory-per-node` | 노드당 쿼리 메모리 상한 |
| `spill_enabled` | `spill-enabled` | **heavy 쿼리만 스필** |
| `aggregation_operator_unspill_memory_limit` | — | 스필 역방향 해제 한도 |

---

### 9.3 스필 — heavy 쿼리만 켜는 게 표준

small 쿼리에 스필을 켜면 디스크 I/O 오버헤드만 늘어납니다.

```sql
-- heavy 쿼리에만 적용
SET SESSION spill_enabled = true;
SET SESSION spill_operator_memory_limit_threshold = 0.9;
```

혹은 리소스 그룹별로 기본 스필 정책을 다르게 운영 (클러스터 기본 OFF, heavy 그룹 유저가 SET).

---

### 9.4 실행 정책 — `query.execution-policy`

```
query.execution-policy:
  phased        # 기본 — 스테이지를 순차 실행, 메모리 절약
  all-at-once   # 모든 스테이지 동시 실행, 빠르지만 메모리 ↑
```

small 쿼리는 `all-at-once`가 빠르고, heavy 쿼리는 `phased`가 안전. **클러스터 전역 설정**이라 세션 단위 변경은 제한적.

---

### 9.5 병렬도도 크기별로 조정

```sql
-- heavy 쿼리: 병렬도 ↑
SET SESSION task_concurrency = 32;
SET SESSION hash_partition_count = 200;

-- small 쿼리: 기본값 유지 (오버헤드 ↓)
SET SESSION task_concurrency = 4;
SET SESSION hash_partition_count = 8;
```

---

### 9.6 실전 구성 — 3-tier 분리

| Tier | 동시성 | 메모리 상한 | 스필 | 대상 |
|------|--------|-------------|------|------|
| **dashboard** (초저지연) | 100 | 2GB/쿼리 | OFF | BI 툴, 실시간 모니터 |
| **adhoc** (대화형) | 30 | 20GB/쿼리 | OFF | 분석가 SQL |
| **etl** (배치) | 5 | 100GB/쿼리 | **ON** | 야간 배치, INSERT |

```json
"subGroups": [
  { "name": "dashboard", "softMemoryLimit": "10%", "hardConcurrencyLimit": 100 },
  { "name": "adhoc",     "softMemoryLimit": "40%", "hardConcurrencyLimit": 30 },
  { "name": "etl",       "softMemoryLimit": "70%", "hardConcurrencyLimit": 5 }
]
```

selector로 `source=tableau → dashboard`, `source=airflow → etl` 자동 라우팅.

---

### 9.7 주의 — 노드 레벨 상한은 공통

쿼리 분리와 **무관하게 모든 쿼리가 공통**으로 제약받는 값:

- `query.max-memory-per-node` — 노드 1대가 한 쿼리에 내줄 수 있는 최대
- `memory.heap-headroom-per-node` — 미추적 예비 공간

**세션으로 `query_max_memory_per_node`를 높여도 노드 물리 한도는 못 넘습니다.** heavy 쿼리가 많다면 워커 자체 힙을 키워야 합니다.

---

### 9.8 차등 설정 레이어 정리

| 분리 수준 | 방법 | 용도 |
|----------|------|------|
| **그룹 단위** | 리소스 그룹 + selector | 동시성/총 메모리 분리 (정책) |
| **쿼리 단위** | 세션 속성 | 특정 쿼리만 완화/강화 |
| **엔진 단위** | `query.execution-policy` | 실행 전략 (phased vs all-at-once) |
| **오퍼레이터 단위** | `spill_enabled` 등 | 메모리 부족 시 디스크 폴백 |

**권장 적용 순서:**
1. 리소스 그룹으로 dashboard/adhoc/etl 3분할
2. selector로 `source`/`clientTags`/`resourceEstimates` 기반 라우팅
3. 각 그룹에 `softMemoryLimit`, `hardConcurrencyLimit` 차등 설정
4. heavy 그룹에만 세션 속성으로 `spill_enabled=true`, 높은 `query_max_memory`
