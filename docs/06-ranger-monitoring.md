# 3단계-C: Ranger 접근제어 + 모니터링 + 검증

3단계(멀티테넌시)의 세 번째 파트. Apache Ranger 접근제어 + 테넌트별 모니터링 + 통합 검증.

> 3단계 전체 흐름과 다른 파트는 아래 참고:
> - [04-keycloak-oauth2.md](04-keycloak-oauth2.md): §0 현황 정리 + §1 Keycloak 인증
> - [05-resource-groups-quota.md](05-resource-groups-quota.md): §2 Resource Groups + §3 K8s Quota + §5 Session 제어
> - **본 문서**: §4 Ranger + §6 모니터링 + §7 검증 + §8 문서화

---

## 4. Ranger 연동 — 카탈로그·스키마별 접근제어

> **결정**: Apache Ranger로 중앙 집중 접근제어.
> Ranger는 UI 기반 정책 관리 + 감사 로그를 제공하므로 운영 편의성이 높음.

### 4-1. Ranger 아키텍처

```
[Ranger Admin (Web UI)]
       │
       ▼ 정책 배포
[Ranger Plugin (Trino coordinator에 내장)]
       │
       ▼ 정책 캐싱 + 접근 판단
[Trino Query] → 허용/거부
       │
       ▼ 감사 로그
[Ranger Audit (Solr/ES/HDFS)]
```

### 4-2. Ranger Admin 배포

Ranger Admin은 별도 서비스로 배포 (Trino namespace 밖 가능):

```bash
# Ranger Admin이 이미 배포되어 있다면 URL 확인
RANGER_URL="https://<ranger-admin-host>:6080"

# Ranger Admin에 Trino 서비스 등록
curl -u admin:admin -X POST \
  "$RANGER_URL/service/public/v2/api/service" \
  -H "Content-Type: application/json" \
  -d '{
    "name": "trino-braveji",
    "type": "trino",
    "configs": {
      "jdbc.url": "jdbc:trino://braveji.trino.quantumcns.ai:443",
      "jdbc.driverClassName": "io.trino.jdbc.TrinoDriver",
      "username": "admin"
    }
  }'
```

### 4-3. Trino에 Ranger Plugin 설치

Ranger Trino Plugin은 coordinator에 설치해야 함. 커스텀 이미지에 포함하거나
initContainer로 주입:

**방법 A — 커스텀 이미지에 포함 (권장)**:

[docker/trino-with-jmx/Dockerfile](../docker/trino-with-jmx/Dockerfile)에 추가:
```dockerfile
# Ranger Trino Plugin
ARG RANGER_VERSION=2.4.0
ADD https://downloads.apache.org/ranger/${RANGER_VERSION}/ranger-${RANGER_VERSION}-trino-plugin.tar.gz /tmp/
RUN tar -xzf /tmp/ranger-${RANGER_VERSION}-trino-plugin.tar.gz -C /opt/ \
    && ln -s /opt/ranger-${RANGER_VERSION}-trino-plugin /opt/ranger-trino-plugin \
    && rm /tmp/ranger-${RANGER_VERSION}-trino-plugin.tar.gz
```

**방법 B — initContainer로 주입**:
```yaml
coordinator:
  initContainers:
    - name: ranger-plugin
      image: harbor.quantumcns.ai/akashiq/ranger-trino-plugin:2.4.0
      command: ['cp', '-r', '/opt/ranger-trino-plugin', '/shared/']
      volumeMounts:
        - name: ranger-plugin
          mountPath: /shared
  additionalVolumes:
    - name: ranger-plugin
      emptyDir: {}
  additionalVolumeMounts:
    - name: ranger-plugin
      mountPath: /opt/ranger-trino-plugin
```

### 4-4. Ranger Plugin 설정

`install.properties` (ConfigMap으로 마운트):
```properties
POLICY_MGR_URL=https://<ranger-admin-host>:6080
REPOSITORY_NAME=trino-braveji
COMPONENT_INSTALL_DIR_NAME=/opt/ranger-trino-plugin

# Trino access-control 설정에 ranger 지정
# access-control.properties에 아래 내용이 자동 생성됨:
#   access-control.name=ranger
#   ranger.plugin.policy.rest.url=https://<ranger-admin-host>:6080
#   ranger.plugin.policy.cache.dir=/tmp/ranger-trino-policy-cache
#   ranger.plugin.audit.solr.urls=http://<solr-host>:8983/solr/ranger_audits
```

Helm values 반영:
```yaml
additionalConfigProperties:
  # ... 기존 설정 유지 ...
  - access-control.name=ranger
  - ranger.plugin.policy.rest.url=https://<ranger-admin-host>:6080
  - ranger.plugin.policy.source.impl=rest
  - ranger.plugin.policy.rest.ssl.config.file=/etc/trino/ranger-ssl.xml
  - ranger.plugin.policy.pollIntervalMs=30000
  - ranger.plugin.policy.cache.dir=/tmp/ranger-trino-policy-cache
```

### 4-5. Ranger 정책 설계

Ranger Admin UI에서 아래 정책을 생성:

**정책 1 — 관리자 전체 접근**:
| 항목 | 값 |
|---|---|
| Policy Name | admin-all-access |
| catalog | * |
| schema | * |
| table | * |
| Users/Groups | trino-admin 그룹 |
| Permissions | SELECT, INSERT, DELETE, CREATE, DROP, ALTER, GRANT, REVOKE |

**정책 2 — ETL팀 쓰기 권한**:
| 항목 | 값 |
|---|---|
| Policy Name | etl-readwrite |
| catalog | hive, iceberg, postgresql |
| schema | * |
| table | * |
| Users/Groups | trino-etl 그룹 |
| Permissions | SELECT, INSERT, DELETE, CREATE, DROP, ALTER |

**정책 3 — 분석가팀 읽기 전용**:
| 항목 | 값 |
|---|---|
| Policy Name | analyst-readonly |
| catalog | hive, iceberg, postgresql, tpch |
| schema | * |
| table | * |
| Users/Groups | trino-analyst 그룹 |
| Permissions | SELECT |

**정책 4 — BI 도구 읽기 전용**:
| 항목 | 값 |
|---|---|
| Policy Name | bi-readonly |
| catalog | hive, iceberg, postgresql |
| schema | * |
| table | * |
| Users/Groups | trino-bi 그룹 |
| Permissions | SELECT |

**정책 5 — 민감 데이터 차단 (예시)**:
| 항목 | 값 |
|---|---|
| Policy Name | deny-sensitive-schema |
| catalog | postgresql |
| schema | internal, hr_payroll |
| table | * |
| Users/Groups | trino-analyst, trino-bi 그룹 |
| Permissions | DENY all |

### 4-6. (대체) File-based 접근제어 — Ranger 연동 전 임시

Ranger 연동에 시간이 걸리면, 동일한 정책을 `rules.json`으로 먼저 적용:

```json
{
  "catalogs": [
    {
      "user": "admin.*",
      "catalog": ".*",
      "allow": "all"
    },
    {
      "user": "etl_.*",
      "catalog": "(hive|iceberg|postgresql)",
      "allow": "all"
    },
    {
      "user": "(analyst.*|bi_.*)",
      "catalog": "(hive|iceberg|postgresql|tpch)",
      "allow": "read-only"
    },
    {
      "catalog": "system",
      "allow": "read-only"
    }
  ]
}
```

Helm values:
```yaml
additionalConfigProperties:
  - access-control.name=file
  - security.config-file=/etc/trino/rules.json
  - security.refresh-period=5m
```

> Ranger 연동 완료 후 `access-control.name=ranger`로 교체.

### 4-7. 검증

```sql
-- analyst1 로 접속
SHOW CATALOGS;
-- 기대: hive, iceberg, postgresql, tpch만 표시

-- 쓰기 시도 → Ranger가 거부
CREATE TABLE hive.default.test_deny (id INT);
-- 기대: Access Denied (Ranger audit 로그에도 기록됨)

-- etl_user1 로 접속
CREATE TABLE hive.default.test_allow (id INT);
DROP TABLE hive.default.test_allow;
-- 기대: 성공

-- Ranger Admin UI에서 감사 로그 확인
-- Access → Audit → 거부된 접근 이력 확인
```

---

## 6. 테넌트별 모니터링 — 사용자/팀 차원 + SLA 추적

> 2단계에서 만든 Grafana 대시보드는 클러스터 전체 집계. 멀티테넌시에서는
> **누가 리소스를 얼마나 쓰는지** + **5초 SLA 준수율**을 보여야 함.

### 6-1. Resource Group JMX 메트릭

`jmxExport: true` 설정으로 각 resource group이 JMX에 노출됨:

```
trino.execution:name=resourcegroup,type=root.interactive.bi
  → RunningQueries, QueuedQueries, SoftMemoryLimit, ...
```

JMX Exporter config에 rule 추가
([manifests/monitoring/trino-jmx-exporter-config.yaml](../manifests/monitoring/trino-jmx-exporter-config.yaml)):
```yaml
rules:
  # ... 기존 rule 유지 ...
  - pattern: 'trino.execution<name=resourcegroup, type=(.+)><>(\w+): (.*)'
    name: trino_resourcegroup_$2
    labels:
      resource_group: $1
    type: GAUGE
```

### 6-2. 5초 SLA 모니터링

**방법 A — Trino Event Listener + analytics-postgres**:

```properties
# event-listener.properties (coordinator에 추가)
event-listener.name=http
http-event-listener.log-completed=true
http-event-listener.connect-ingest-uri=http://query-logger:8080/events
```

또는 간단한 CronJob으로 `system.runtime.queries`를 주기 수집:

```sql
-- 최근 1시간 내 5초 SLA 위반 쿼리 (분석가+BI)
SELECT
  "user",
  resource_group_id,
  query_id,
  wall_time,
  created
FROM system.runtime.queries
WHERE state = 'FINISHED'
  AND created > current_timestamp - interval '1' hour
  AND resource_group_id LIKE '%interactive%'
  AND wall_time > interval '5' second
ORDER BY wall_time DESC;

-- SLA 준수율 (%)
SELECT
  resource_group_id,
  count(*) AS total,
  count(*) FILTER (WHERE wall_time <= interval '5' second) AS within_sla,
  round(
    100.0 * count(*) FILTER (WHERE wall_time <= interval '5' second) / count(*),
    1
  ) AS sla_pct
FROM system.runtime.queries
WHERE state = 'FINISHED'
  AND created > current_timestamp - interval '1' hour
  AND resource_group_id LIKE '%interactive%'
GROUP BY resource_group_id;
```

### 6-3. Grafana 대시보드 확장

기존 "Trino Cluster Overview"에 **멀티테넌시 Row** 추가:

| 패널 | PromQL / 데이터 소스 | 용도 |
|---|---|---|
| Resource Group별 Running Queries | `trino_resourcegroup_RunningQueries` | 그룹별 현재 부하 |
| Resource Group별 Queued Queries | `trino_resourcegroup_QueuedQueries` | 큐잉 발생 감지 |
| Resource Group별 Memory Usage | `trino_resourcegroup_SoftMemoryLimit` | 메모리 포화 감시 |
| BI/Analyst SLA 준수율 (%) | Event Listener → PG | 5초 SLA 실시간 추적 |
| 그룹별 쿼리 실패율 | Event Listener → PG | 안정성 문제 조기 감지 |

### 6-4. 알림 설정

```yaml
# Grafana Alert Rules
- alert: InteractiveQueueSaturated
  expr: trino_resourcegroup_QueuedQueries{resource_group=~"root.interactive.*"} > 10
  for: 2m
  labels:
    severity: warning
  annotations:
    summary: "분석가/BI 큐 포화 — 5초 SLA 위반 가능성"

- alert: ETLConcurrencyFull
  expr: trino_resourcegroup_RunningQueries{resource_group="root.etl"} >= 5
  for: 5m
  labels:
    severity: info
  annotations:
    summary: "ETL 동시 실행 한도 도달 — 큐잉 시작 가능"

- alert: SLAViolationHigh
  # Event Listener 기반 custom metric (Pushgateway 경유)
  expr: trino_sla_violation_rate{group="interactive"} > 0.1
  for: 5m
  labels:
    severity: critical
  annotations:
    summary: "5초 SLA 위반율 10% 초과 — 즉시 조치 필요"
```

### 6-5. Ranger 감사 로그 모니터링

Ranger가 감사 로그를 Solr/ES에 기록하면, 거부된 접근 시도도 시각화 가능:

| 감시 항목 | 소스 | 의미 |
|---|---|---|
| 시간당 Access Denied 횟수 | Ranger Audit → Solr | 권한 설정 미비 또는 오남용 |
| 사용자별 쿼리 패턴 | Ranger Audit | 이상 행동 탐지 |

---

## 7. 검증 — 멀티테넌시 시나리오 테스트

### 7-1. 테스트 시나리오

| # | 시나리오 | 기대 결과 | SLA 관련 |
|---|---|---|---|
| T1 | 인증 없이 접속 | 401 또는 Keycloak 리다이렉트 | - |
| T2 | Keycloak 로그인 → Trino Web UI | 사용자 식별, 올바른 그룹 배정 | - |
| T3 | analyst1으로 `SHOW CATALOGS` | hive, iceberg, postgresql, tpch만 표시 | - |
| T4 | analyst1으로 hive 테이블 CREATE | Access Denied (Ranger 거부) | - |
| T5 | etl_user1로 hive 테이블 CREATE/DROP | 성공 | - |
| T6 | bi_superset이 `SET SESSION` 시도 | Access Denied | - |
| T7 | ETL 5개 동시 실행 + 6번째 | 6번째 큐잉 | - |
| T8 | ETL 대형 쿼리 5개 실행 중 + BI 쿼리 | BI 쿼리가 5초 이내 완료 | **SLA** |
| T9 | 분석가 ad-hoc 15개 동시 + 16번째 | 16번째 큐잉 | - |
| T10 | BI 통계 쿼리 20개 동시 실행 | 모두 5초 이내 완료 | **SLA** |
| T11 | Pod Quota 초과 워커 스케일 시도 | Pod 생성 실패 | - |
| T12 | Ranger 감사 로그에 T4 거부 기록 | 로그 확인 가능 | - |

### 7-2. SLA 전용 테스트

```bash
NS=user-braveji
TRINO_URL="https://braveji.trino.quantumcns.ai"

# BI 토큰 획득
BI_TOKEN=$(curl -s -X POST \
  "https://<KEYCLOAK_HOST>/realms/<REALM>/protocol/openid-connect/token" \
  -d "grant_type=password&client_id=trino&client_secret=<secret>&username=bi_superset&password=<pw>" \
  | jq -r '.access_token')

# T8: ETL 부하 속에서 BI 쿼리 SLA 테스트
echo "=== T8: ETL 부하 + BI SLA ==="

# ETL 대형 쿼리 5개 백그라운드 실행
for i in $(seq 1 5); do
  ETL_TOKEN=$(curl -s -X POST ... | jq -r '.access_token')
  trino --server $TRINO_URL --access-token "$ETL_TOKEN" \
    --execute "
      SELECT l.returnflag, sum(l.extendedprice*(1-l.discount))
      FROM tpch.sf1.lineitem l
      JOIN tpch.sf1.orders o ON l.orderkey = o.orderkey
      GROUP BY l.returnflag
    " &
done

sleep 3  # ETL 쿼리가 시작되길 대기

# BI 쿼리 실행 + 시간 측정
echo "--- BI query under ETL load ---"
start=$(date +%s%N)
trino --server $TRINO_URL --access-token "$BI_TOKEN" \
  --execute "SELECT count(*) FROM tpch.sf1.customer"
end=$(date +%s%N)
elapsed_ms=$(( (end - start) / 1000000 ))
echo "BI query time: ${elapsed_ms}ms (SLA: <5000ms)"

if [ $elapsed_ms -gt 5000 ]; then
  echo "FAIL: SLA 위반!"
else
  echo "PASS: SLA 충족"
fi

wait  # ETL 종료 대기
```

### 7-3. 검증 체크리스트

- [ ] T1~T12 전체 시나리오 통과
- [ ] Keycloak 로그인 → Trino 사용자/그룹 매핑 정상
- [ ] Resource Group 배정이 의도대로 동작
- [ ] Ranger 정책에 따라 접근제어 동작
- [ ] Ranger 감사 로그에 접근 이력 기록
- [ ] ETL 부하 속에서 BI/분석가 5초 SLA 충족
- [ ] Grafana에서 Resource Group별 메트릭 확인 가능
- [ ] BI 도구 (Superset 등) 연동 시 OAuth2 토큰 인증 정상 동작

---

## 8. 문서화

### 8-1. 운영 가이드

- Keycloak 사용자 추가/그룹 변경 절차
- Ranger 정책 추가/변경 절차 (UI 스크린샷 포함)
- Resource Group 변경 시 반영 방법 (ConfigMap 업데이트 → coordinator 재시작)
- Quota 조정 가이드라인
- SLA 위반 시 대응 절차 (쿼리 킬, 그룹 한도 조정 등)

### 8-2. 사용자 온보딩 문서

- 접속 방법:
  - 브라우저: `https://braveji.trino.quantumcns.ai/ui/` → Keycloak 로그인
  - CLI: `trino --server ... --access-token <TOKEN>`
  - JDBC (BI 도구): `jdbc:trino://...?SSL=true&accessToken=<TOKEN>`
- 본인 그룹에 허용된 카탈로그/스키마 목록
- 쿼리 제한 사항 (동시 실행 수, 실행 시간, 메모리)
- 5초 SLA 가이드: BI/분석 쿼리가 느릴 때 확인사항

### 8-3. 결과 기록

- `docs/07-multitenancy-results.md`에 각 단계 적용 결과 + 테스트 결과 기록
- 발견된 함정이 있으면 01 문서의 Gotchas 목록에 추가

---

## 진행 체크리스트 (본 문서 범위)

- [ ] 4-a. Ranger Admin에 Trino 서비스 등록
- [ ] 4-b. Ranger Trino Plugin 설치 (커스텀 이미지 빌드)
- [ ] 4-c. Ranger 정책 5개 생성
- [ ] 4-d. 접근제어 검증 (T3~T5) + 감사 로그 확인 (T12)
- [ ] 6-a. JMX Exporter에 resource group rule 추가
- [ ] 6-b. Grafana 멀티테넌시 대시보드 패널 추가
- [ ] 6-c. 알림 규칙 설정 (큐 포화, SLA 위반)
- [ ] 7. 전체 시나리오 테스트 (T1~T12) + SLA 전용 테스트
- [ ] 8. 운영 가이드 + 사용자 온보딩 문서 작성
