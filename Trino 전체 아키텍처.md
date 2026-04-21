# Trino 전체 아키텍처

## 1. 핵심 구조 — 모듈 계층

```
trino-src/
├── core/trino-spi/       ← 플러그인 계약 (인터페이스만 존재)
├── core/trino-main/      ← 쿼리 엔진 본체
├── core/trino-server/    ← HTTP 서버 / 서버 부트스트랩
├── core/trino-parser/    ← SQL 파서 (ANTLR4 생성)
├── lib/                  ← ORC, Parquet, 캐시, 파일시스템 등 유틸
└── plugin/               ← 커넥터 구현체 (BigQuery, Hive, Delta 등)
```

`trino-spi`가 모든 커넥터가 구현해야 하는 안정적 경계입니다. `trino-main`이 엔진 본체이며, 커넥터는 `plugin/` 아래에 독립 모듈로 존재합니다.

---

## 2. SQL → 결과까지의 쿼리 생명주기

```
클라이언트 SQL
    ↓
DispatchManager.submitQuery()         [진입점 / 리소스 그룹 라우팅]
    ↓
QueryPreparer.prepareQuery()          [파싱: String → Statement AST]
    ↓
Analyzer.analyze()                    [의미 분석: Statement → Analysis]
    ↓
LogicalPlanner.plan()                 [논리 플랜: Analysis → Plan (PlanNode 트리)]
    ↓
PlanFragmenter.fragment()             [분산 플랜: Plan → PlanFragment 목록]
    ↓
QueryScheduler.schedule()             [스케줄링: 워커 노드에 Stage/Task 배분]
    ↓
SqlTask (워커)
  └─ Driver × N (Split당 1개)
      └─ TableScanOperator → FilterOperator → AggregationOperator → OutputOperator
           ↓ (Page 단위 컬럼형 데이터 흐름)
OutputBuffer → ExchangeOutput → 다음 Stage 소비 → 최종 결과 반환
```

---

## 3. 각 단계별 주요 클래스

### 파싱 / 분석

| 클래스 | 경로 | 역할 |
|--------|------|------|
| `QueryPreparer` | `core/trino-main/.../execution/QueryPreparer.java` | SQL 문자열 → `Statement` AST 변환 |
| `Analyzer` | `core/trino-main/.../sql/analyzer/Analyzer.java` | 의미 분석 — 테이블/컬럼 해석, 타입 검사 |
| `Analysis` | `core/trino-main/.../sql/analyzer/Analysis.java` | 분석 결과 컨테이너 (컬럼 참조, 함수 해석 등) |

### 플랜 생성 / 최적화

| 클래스 | 경로 | 역할 |
|--------|------|------|
| `LogicalPlanner` | `core/trino-main/.../sql/planner/LogicalPlanner.java` | `Analysis` → `Plan` (PlanNode 트리) |
| `PlanFragment` | `core/trino-main/.../sql/planner/PlanFragment.java` | 워커 1개에 보낼 실행 단위 |
| `PlanFragmenter` | `core/trino-main/.../sql/planner/PlanFragmenter.java` | 논리 플랜 → 분산 PlanFragment 목록 분할 |
| `IterativeOptimizer` | `core/trino-main/.../sql/planner/` | 규칙 기반 반복 최적화 |

### 실행 조율 (코디네이터)

| 클래스 | 경로 | 역할 |
|--------|------|------|
| `DispatchManager` | `core/trino-main/.../dispatcher/DispatchManager.java` | 쿼리 진입 / QueryId 생성 / 리소스 그룹 라우팅 |
| `SqlQueryExecution` | `core/trino-main/.../execution/SqlQueryExecution.java` | 쿼리 전체 생명주기 관리 |
| `QueryStateMachine` | `core/trino-main/.../execution/QueryStateMachine.java` | `QUEUED→PLANNING→RUNNING→FINISHED` 상태 전이 |
| `SqlStage` | `core/trino-main/.../execution/SqlStage.java` | PlanFragment 1개에 대응하는 Stage, RemoteTask 모음 |

### 실행 (워커)

| 클래스 | 경로 | 역할 |
|--------|------|------|
| `SqlTask` | `core/trino-main/.../execution/SqlTask.java` | 워커에서 실행되는 태스크 |
| `SqlTaskExecution` | `core/trino-main/.../execution/SqlTaskExecution.java` | Split당 Driver 생성/관리 |
| `Driver` | `core/trino-main/.../operator/Driver.java` | Operator 파이프라인을 단일 스레드로 실행 |
| `Operator` (인터페이스) | `core/trino-main/.../operator/Operator.java` | 실행 단계 (Scan, Filter, Join, Agg...) |

---

## 4. 실행 계층 구조

```
Query
 └─ Stage (PlanFragment 1개 = 1 Stage)
     └─ RemoteTask × N (워커 노드 수)
         └─ SqlTask (워커측)
             └─ SqlTaskExecution
                 └─ Driver × N (Split 수)
                     └─ Operator 파이프라인
                         TableScanOperator  ← ConnectorPageSource.getNextPage()
                         FilterOperator
                         ProjectOperator
                         AggregationOperator
                         OutputOperator → OutputBuffer
```

- **Page**: 컬럼형 데이터 단위 (`Block[]` 배열 + 행 수). Operator 간에는 Page 단위로 데이터가 흐릅니다.
- **Split**: 데이터 파티션 1개. `SplitManager.getSplits()` → `ConnectorSplitManager`가 생성합니다.

### Operator 인터페이스

```java
interface Operator {
    boolean needsInput()
    void addInput(Page page)
    Page getOutput()
    void finish()
    boolean isFinished()
    ListenableFuture<Void> isBlocked()
}
```

### Split 개수 결정 — 3단계 제어

Split은 `ConnectorSplitManager`가 만들지만, **실제 병렬도**는 커넥터 분할 × 스케줄러 throttling × Task 동시성의 결합으로 정해집니다.

#### 1단계 — 커넥터가 총 Split 개수를 결정

`ConnectorSplitManager.getSplits()` (`core/trino-spi/.../connector/ConnectorSplitManager.java`)가 데이터를 파티션 단위로 쪼갭니다. Hive/Delta/Iceberg 등 파일 기반 커넥터는 파일 크기를 기준으로 분할합니다.

| 설정 (Hive 기준) | 기본값 | 의미 |
|------|--------|------|
| `hive.max-split-size` | 64MB | 한 Split의 최대 바이트 |
| `hive.max-initial-split-size` | 32MB | 쿼리 시작 시 초기 Split 크기 |
| `hive.max-initial-splits` | 200 | "초기 크기"로 만들 Split 개수 |
| `max_split_size` (Delta 세션) | — | 세션 단위 오버라이드 |

**총 Split ≈ (파일 크기 / max-split-size) × 파티션 필터링된 파일 수**

#### 2단계 — 스케줄러가 동시 실행 Split을 제한

`SourcePartitionedScheduler`(`core/trino-main/.../execution/scheduler/SourcePartitionedScheduler.java`)가 `SplitSource`에서 Split을 당겨 Task에 배분할 때 다음 한도로 throttling합니다.

`NodeSchedulerConfig` (`core/trino-main/.../execution/scheduler/NodeSchedulerConfig.java`):

| 설정 | 기본값 | 역할 |
|------|--------|------|
| `node-scheduler.max-splits-per-node` | 256 | 워커 1개에 동시 할당 가능한 최대 Split |
| `node-scheduler.min-pending-splits-per-task` | 16 | Task당 최소 대기 Split |
| `node-scheduler.max-adjusted-pending-splits-per-task` | 2000 | Task당 최대 대기 Split (적응형) |
| `node-scheduler.max-unacknowledged-splits-per-task` | 2000 | Task가 ACK하지 않은 Split 상한 |

큐가 포화되면 스케줄러는 `SPLIT_QUEUES_FULL` 상태로 대기합니다.

#### 3단계 — Task 안에서 동시에 도는 Driver 수

Split 1개 = Driver 1개지만, 한 Task 안에서 동시에 실행되는 Driver 수는 `task_concurrency`로 제한됩니다.

`TaskManagerConfig` (`core/trino-main/.../execution/TaskManagerConfig.java`):

| 설정 | 기본값 | 의미 |
|------|--------|------|
| `task.concurrency` | `min(2^n ≤ CPU코어, 32)` | Task당 동시 Driver 수 (Join/Agg 병렬도) |
| `task.max-worker-threads` | CPU × 2 | 워커 전체 Driver 스레드 풀 |
| `task.initial-splits-per-node` | `max-worker-threads`와 동일 | 워커 시작 시 초기 배정량 |

#### 정리

```
[쿼리 전체 Split 총량]
 ← 커넥터가 결정 (파일 크기 / max-split-size, 파티션 수, Bucket 수)

[한 번에 실행 중인 Split 수]
 ← min( 노드수 × max-splits-per-node,
        노드수 × task_concurrency,
        총 Split 개수 )

[나머지 Split] ← SplitSource 큐에서 대기 → Driver가 비면 순차 투입
```

**튜닝 가이드:**
- 쿼리가 소수 노드에 몰림 → `node-scheduler.max-splits-per-node` 낮춰 분산 유도
- CPU가 놀고 있음 → `task_concurrency` 증가, 또는 `max-split-size` 감소로 Split 잘게 쪼개기
- Small file 문제 (Split 수만 개) → `hive.max-initial-split-size` 증가 또는 파일 컴팩션
- 워커 메모리 압박 → `node-scheduler.max-splits-per-node` 감소

---

## 5. SPI — 커넥터가 구현해야 하는 인터페이스

```
Plugin.getConnectorFactories()
  └─ ConnectorFactory.create() → Connector
      ├─ Connector.getMetadata()           → ConnectorMetadata
      │    ├─ listSchemaNames()
      │    ├─ listTables()
      │    ├─ getTableHandle()
      │    └─ getColumns()
      ├─ Connector.getSplitManager()       → ConnectorSplitManager
      │    └─ getSplits()                  → ConnectorSplitSource
      └─ Connector.getPageSourceProvider() → ConnectorPageSourceProvider
           └─ createPageSource()           → ConnectorPageSource
                └─ getNextPage()           → Page  (실제 데이터 읽기)
```

| 단계 | 호출되는 SPI |
|------|-------------|
| 플래닝 | `ConnectorMetadata` (테이블/컬럼 정보) |
| 스케줄링 | `ConnectorSplitManager` (데이터 파티션 생성) |
| 실행 | `ConnectorPageSource` (실제 데이터 읽기) |

---

## 6. 플러그인 로딩

`PluginManager`(`core/trino-main/.../server/PluginManager.java`)가 서버 시작 시 Java `ServiceLoader`로 `Plugin` 구현체를 탐색합니다.

- 각 플러그인은 격리된 ClassLoader로 로드
- 등록 대상: `ConnectorFactory`, `Type`, `SystemAccessControlFactory`, `EventListenerFactory` 등
- 카탈로그 설정 파일에 따라 `CatalogFactory`가 `ConnectorFactory.create()`를 호출해 `Connector` 인스턴스 생성

---

## 7. 요약

| 모듈 | 역할 |
|------|------|
| `trino-spi` | 커넥터 계약 (인터페이스 전용, 안정적 경계) |
| `trino-main` | 파싱 → 분석 → 플랜 → 스케줄 → 실행 전 과정 |
| `plugin/*` | 각 데이터 소스 커넥터 구현체 |
| `lib/*` | ORC/Parquet 포맷, 파일시스템, 캐시 등 공유 라이브러리 |

- **데이터 흐름 단위** = `Page` (컬럼형 `Block[]`)
- **병렬 단위** = `Split` (데이터 파티션)
- **실행 단위** = `Driver` (Operator 파이프라인 단일 스레드)
- 코디네이터는 플랜/스케줄만 담당, 워커는 `Driver`로 실제 연산 수행
