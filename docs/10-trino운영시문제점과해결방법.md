# Trino 운영 시 문제점과 해결 방법

운영 환경에서 자주 보고되는 Trino 문제와 해결 방안. 가능한 한 이 프로젝트의
기존 설정/문서와 연결합니다. 출처는 본 문서 끝의 Sources 절에 정리.

---

## 1. 메모리·OOM (가장 흔하고 가장 치명적)

| 증상 | 원인 | 해결 |
|---|---|---|
| Coordinator OOM-kill | DBeaver 같은 툴이 거대한 Iceberg 테이블 메타데이터를 fetch | Trino 480에서도 재현. coordinator JVM heap 증가 + `query.max-memory-per-node` 조정 |
| Worker silent disappear (CLUSTER_OUT_OF_MEMORY) | DictionaryValuesWriter가 logical size 보다 훨씬 큰 buffer를 차지 | Trino 481+ 패치 적용 또는 `query.max-memory-per-node`를 보수적으로 |
| 468↔467 회귀로 OOM | coordinator 메모리 사용량 증가 회귀 | 마이너 버전 업그레이드 시 coordinator 메모리 모니터링 강화 |
| 대용량 클러스터에서도 CLUSTER_OUT_OF_MEMORY | `query.max-memory-per-node × 워커 수`만 보고 설정 | per-node 한도와 cluster-wide 한도 분리 — JVM heap의 70%를 넘기지 말 것 (OS/오퍼레이터 여유 필수) |

**이 프로젝트와의 연결**: [03-04-jvm-tuning-plan.md](03-04-jvm-tuning-plan.md),
[03-resource-tuning-plan.md](03-resource-tuning-plan.md)에 JVM 튜닝 계획이 있음.
추가로 권장:

- `coordinator`와 `worker`의 `XX:MaxRAMPercentage`를 70 이하로 (현재 80이면 노드 OOM 위험)
- Prometheus 알림: `jvm_memory_pool_used_bytes / jvm_memory_pool_max_bytes > 0.85` 5분 지속 시 경보

---

## 2. 쿼리 성능 — 느린 쿼리 트러블슈팅

### 2-1. JOIN이 가장 큰 비용

- Build side가 큰 테이블이면 `broadcast` 대신 `partitioned` join 사용
  — `join_distribution_type=PARTITIONED` session property
- Star schema는 fact 테이블 기준으로 `join-reordering-strategy=AUTOMATIC` + 통계 수집(`ANALYZE`) 필수

### 2-2. 테이블 스캔

- Hive/Iceberg는 파티션 + columnar (Parquet/ORC) 활용 필수
- `hive.pushdown-filter-enabled=true`, `hive.projection-pushdown-enabled=true` 활성화
- Iceberg에서 작은 파일 많으면 1-1 split 매핑 때문에 plan latency 폭증
  → 정기적으로 `OPTIMIZE` (compact) 실행

### 2-3. Iceberg 통계 함정 (실측 회귀)

- Trino 358 → 414 업그레이드 시 Iceberg planning이 매우 느려진 사례 보고
- 통계가 stale하거나 거대 테이블이면 일시적으로 `iceberg.use-table-statistics=false` 검토

### 2-4. 진단 시작 명령

```sql
EXPLAIN ANALYZE SELECT ... ;
-- blocked rows / spilled / cpu time 분포 확인
```
Trino UI의 query detail에서 stage별 wall time을 보고 hotspot stage 식별.

---

## 3. Spill / GC

- Spill은 **쿼리 실패 방지용**이지 빠르게 만들기 위한 게 아님 — 큰 aggregation/sort에서만 켜라
- 이 프로젝트는 [03-05-disk-spill-tuning-plan.md](03-05-disk-spill-tuning-plan.md) 참고
- GC 분석: [scripts/gc_analysis.sh](../scripts/gc_analysis.sh) 이미 보유.
  G1 → ZGC 전환을 480에서 검토 가치 있음 (long-pause 제거)

---

## 4. 커넥터·메타스토어 일관성

### Iceberg + HMS 분산 일관성 문제 (실제 사고 사례)

- Trino/Iceberg는 storage와 catalog 간 transaction coordination 안 함
  → **storage write가 끝나기 전에 catalog 업데이트 가능**
- 클라우드 outage 시 storage가 일시 unavailable인데 HMS는 살아 있으면
  **테이블 깨짐 / 데이터 누락**
- 완화책:
  - HMS 쪽에 정기 백업 (이 프로젝트는 [manifests/postgres/hms-postgres.yaml](../manifests/postgres/hms-postgres.yaml)에 ScheduledBackup 적용 ✅)
  - 정기적으로 Iceberg `expire_snapshots` + `remove_orphan_files` 실행
  - critical 테이블은 `iceberg.commit.retry.num-retries` 늘리기

### 페일오버 시 task 누수

- worker fail 시 TaskInfoFetcher thread가 정리 안 되는 이슈 보고
  — long-running 워커 reboot 주기 도입(주 1회)으로 완화

---

## 5. Resource Groups — 알려진 한계 (2026 신규)

### 드라이버 saturation 문제

- `hardConcurrencyLimit: 5`인 그룹이 각 쿼리당 200+ driver를 들고 있으면 task slot 전체 점유
  → **다른 가벼운 그룹이 굶음** (issue [#28373](https://github.com/trinodb/trino/issues/28373))
- 현재 Trino는 그룹별 "총 driver 수" 제한이 없음
- 임시 완화: 무거운 워크로드 그룹은 `hardConcurrencyLimit`를 낮게 + soft/hard memory 제한 강제

### Fault-tolerant execution과 충돌

- `retry-policy: TASK` 설정 시 **fault-tolerant 미지원 커넥터에서 쿼리 실패**
  (`This connector does not support query retries`)
- per-catalog로 retry-policy 분리 필요 (Iceberg/Hive는 지원, JDBC catalog는 미지원)

---

## 6. Kubernetes 특화 운영 함정

### Graceful shutdown 누락

- worker가 SIGTERM 받을 때 진행 중 task를 끝낼 시간이 필요
- `terminationGracePeriodSeconds`를 워크로드 평균 쿼리 시간 + 30s 이상으로 설정
- helm chart의 `worker.lifecycle.preStop`에 sleep + Trino graceful shutdown REST 호출 추가

```yaml
worker:
  terminationGracePeriodSeconds: 600
  lifecycle:
    preStop:
      exec:
        command:
          - /bin/sh
          - -c
          - |
            curl -X PUT -d '"SHUTTING_DOWN"' \
              -H 'Content-Type:application/json' \
              http://localhost:8080/v1/info/state
            sleep 540
```

### Coordinator 단일 장애점

- Trino는 active-active coordinator 미지원 — 단일 coordinator가 죽으면 모든 in-flight 쿼리 실패
- 완화: **Trino Gateway 앞에 두 coordinator(blue/green) 배치 + KEDA로 워커 오토스케일**
  ([08-trino-gateway.md §5](08-trino-gateway.md) 참고)

### 오토스케일 — KEDA 권장

- BestSecret 사례: CPU 사용률 + memory pressure index + queued query 수를 KEDA scaler로 사용
- HPA만으로는 query 큐를 못 봄 → KEDA로 Prometheus 메트릭 기반 스케일

---

## 7. 모니터링 — 빠짐없이 보아야 할 메트릭 12개

이 프로젝트는 [scripts/install-monitor.sh](../scripts/install-monitor.sh)로
Prometheus + Grafana + JMX exporter가 이미 적용되어 있음. 알림 룰만 추가하면 됨.

| 카테고리 | 메트릭 | 임계값 (참고) |
|---|---|---|
| 클러스터 | `trino_cluster_active_workers` | 기대치 미만 5분 지속 |
| 메모리 | `jvm_memory_pool_used_bytes / max` (heap, old gen) | > 0.85 5분 |
| GC | `jvm_gc_collection_seconds_sum` rate | old gen GC > 5초/분 |
| 쿼리 | `trino_execution_running_queries`, `trino_execution_queued_queries` | queued > 50 5분 |
| 쿼리 실패 | `trino_execution_failed_queries_total` rate | > 5/분 |
| Coordinator | `trino_failuredetector_active_count` | > 0 |
| HMS | `trino_hive_metastore_*_failures` rate | > 1/분 |
| Spill | `trino_spiller_total_spilled_bytes` rate | 급증 감시 |
| 워커 통신 | `jvm_threads_state{state="BLOCKED"}` | 급증 감시 |
| 디스크 | spill 디렉터리 사용률 | > 80% |
| Catalog | `trino_split_manager_*_split_count` per source | 급증 감시 (small file 폭발) |
| TLS/Auth | nginx-ingress `nginx_ingress_controller_response_size` | 401/403 비율 급증 |

권장 Grafana dashboard: ID **20208** (Trino Cluster JMX),
**20207** (Trino Cluster Pod JMX), **14845** (JMX 메트릭).

---

## 8. 인증·네트워크

### OAuth 토큰 만료

- Keycloak 기본 access token TTL 30분 → BI 도구는 client_credentials grant + refresh token 필수
- Trino UI는 cookie 기반 세션 유지 — `http-server.authentication.type=oauth2,jwt` 동시 설정으로 API/UI 모두 커버

### Ingress 헤더 함정 — 이 프로젝트 특화

- nginx-ingress 뒤에 있을 때 `http-server.process-forwarded=true` 누락하면 406
  — [CLAUDE.md](../CLAUDE.md) 함정 #2에 이미 기록
- Istio sidecar 자동 주입 시 외부 ingress가 403 RBAC denied
  — [08-trino-gateway.md §3-1](08-trino-gateway.md) 참고

---

## 9. 이 프로젝트에 즉시 적용 가능한 단기 액션 5가지

| 우선순위 | 작업 | 영향 |
|---|---|---|
| P1 | Prometheus 알림 룰 12종 추가 (위 표) | 사고 조기 감지 |
| P1 | worker `terminationGracePeriodSeconds` + preStop hook 추가 | rolling restart 시 쿼리 실패 방지 |
| P2 | Iceberg 정기 `OPTIMIZE` + `expire_snapshots` cron | small file 폭증 / 메타데이터 비대 방지 |
| P2 | KEDA 도입 검토 — queued query 기반 워커 스케일 | 트래픽 spike 대응 |
| P3 | Trino Gateway에 `QueryCountBasedRouter` 모듈 적용 ([08-trino-gateway.md §3-5](08-trino-gateway.md)) | 부하 분산 정상화 |
| P3 | HMS PG 백업 복구 drill (이미 백업은 있음 — 복원 절차 검증 필요) | 메타데이터 disaster recovery |

---

## Sources

- [Trino Coordinator OOM Issue #25696](https://github.com/trinodb/trino/issues/25696)
- [Out of Memory on Trino Pod Discussion #24196](https://github.com/trinodb/trino/discussions/24196)
- [Building a Production-Ready Trino Cluster — Vivek Jain](https://medium.com/@vjain143/building-a-production-ready-trino-cluster-for-heavy-workloads-a-guide-to-right-sizing-your-0cd8b0908be0)
- [Coordinator OOM with DBeaver Issue #13194](https://github.com/trinodb/trino/issues/13194)
- [Coordinator crashes with OOM in 468 Issue #24572](https://github.com/trinodb/trino/issues/24572)
- [Solving capacity management for Trino — Starburst](https://www.starburst.io/blog/solving-capacity-management-problems-for-trino-clusters/)
- [Worker OOM in DictionaryValuesWriter Issue #21745](https://github.com/trinodb/trino/issues/21745)
- [Trino Query Performance Optimization Guide — e6data](https://www.e6data.com/query-and-cost-optimization-hub/how-to-optimize-trino-query-performance)
- [Slow Iceberg planning Issue #26563](https://github.com/trinodb/trino/issues/26563)
- [Iceberg Partitioning and Performance — Starburst](https://www.starburst.io/blog/iceberg-partitioning-and-performance-optimizations-in-trino-partitioning/)
- [Speed Trino Queries — The New Stack](https://thenewstack.io/speed-trino-queries-with-these-performance-tuning-tips/)
- [Iceberg HMS GCS inconsistency Issue #26262](https://github.com/trinodb/trino/issues/26262)
- [TaskInfoFetcher thread leak Issue #18779](https://github.com/trinodb/trino/issues/18779)
- [Resource groups driver-level admission Issue #28373](https://github.com/trinodb/trino/issues/28373)
- [Resource groups documentation — Trino 480](https://trino.io/docs/current/admin/resource-groups.html)
- [Fault-tolerant execution — Trino 480](https://trino.io/docs/current/admin/fault-tolerant-execution.html)
- [Trinetes I: Trino on Kubernetes — Trino podcast](https://trino.io/episodes/24.html)
- [Scaling Trino with KEDA — BESTSECRET](https://medium.com/bestsecret-tech/maximize-performance-the-bestsecret-to-scaling-trino-clusters-with-keda-c209efe4a081)
- [Optimizing Trino on Kubernetes — Trino Summit 2024](https://trino.io/assets/blog/trino-summit-2024/trino-summit-2024-cardoai.pdf)
- [Monitoring with JMX — Trino 480](https://trino.io/docs/current/admin/jmx.html)
- [Trino metrics with OpenMetrics — Trino 480](https://trino.io/docs/current/admin/openmetrics.html)
- [Trino JMX Monitoring — nil1729](https://github.com/nil1729/trino-jmx-monitoring)
- [Trino Cluster JMX Grafana Dashboard 20208](https://grafana.com/grafana/dashboards/20208-trino-cluster-jmx/)
