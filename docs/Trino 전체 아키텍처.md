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
