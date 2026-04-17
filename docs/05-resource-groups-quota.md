# 3단계-B: Resource Groups + K8s Quota + Session 제어

3단계(멀티테넌시)의 두 번째 파트. Trino 내부 리소스 격리 + K8s 인프라 레벨 제한 + 세션 우회 방지.

> 3단계 전체 흐름과 다른 파트는 아래 참고:
> - [04-keycloak-oauth2.md](04-keycloak-oauth2.md): §0 현황 정리 + §1 Keycloak 인증
> - **본 문서**: §2 Resource Groups + §3 K8s Quota + §5 Session 제어
> - [06-ranger-monitoring.md](06-ranger-monitoring.md): §4 Ranger + §6 모니터링 + §7 검증 + §8 문서화

---

## 2. Resource Groups — Trino 내부 리소스 격리

> Trino의 핵심 멀티테넌시 메커니즘. 팀/사용자별로 **동시 쿼리 수, 메모리 한도,
> 큐 대기 시간**을 제어.

### 2-1. 설계 (요구사항 기반)

```
root
├── etl          60% 메모리, 동시 5개, 최대 큐 20
│                → 무거운 쿼리 안정 실행, 메모리 여유 확보
├── interactive  35% 메모리, 동시 40개 (하위 그룹 합)
│   ├── analyst  동시 15개, 최대 큐 30
│   │            → 5초 SLA, 가벼운 쿼리 다수
│   └── bi       동시 20개, 최대 큐 50, 스케줄링 우선
│                → 5초 SLA, 실시간 통계 쿼리, 절대 큐잉 최소화
├── admin        20% 메모리, 동시 10개
└── default       5% 메모리, 동시 2개
```

**BI와 분석가를 interactive 하위로 묶는 이유**:
- 5초 SLA 대상을 하나의 메모리 풀로 관리 → ETL과 명확히 분리
- ETL이 60%를 점유해도 interactive 35%는 보장됨
- BI는 `schedulingWeight`를 높여 analyst보다 우선 스케줄링

### 2-2. resource-groups.json

```json
{
  "cpuQuotaPeriod": "1h",
  "rootGroups": [
    {
      "name": "root",
      "softMemoryLimit": "100%",
      "hardConcurrencyLimit": 60,
      "maxQueued": 150,
      "schedulingPolicy": "weighted",
      "subGroups": [
        {
          "name": "etl",
          "softMemoryLimit": "60%",
          "hardConcurrencyLimit": 5,
          "maxQueued": 20,
          "schedulingWeight": 3,
          "softCpuLimit": "20m",
          "hardCpuLimit": "30m",
          "jmxExport": true
        },
        {
          "name": "interactive",
          "softMemoryLimit": "35%",
          "hardConcurrencyLimit": 40,
          "maxQueued": 100,
          "schedulingPolicy": "weighted",
          "schedulingWeight": 5,
          "jmxExport": true,
          "subGroups": [
            {
              "name": "analyst",
              "softMemoryLimit": "50%",
              "hardConcurrencyLimit": 15,
              "maxQueued": 30,
              "schedulingWeight": 2,
              "jmxExport": true
            },
            {
              "name": "bi",
              "softMemoryLimit": "60%",
              "hardConcurrencyLimit": 20,
              "maxQueued": 50,
              "schedulingWeight": 5,
              "jmxExport": true
            }
          ]
        },
        {
          "name": "admin",
          "softMemoryLimit": "20%",
          "hardConcurrencyLimit": 10,
          "maxQueued": 20,
          "schedulingWeight": 4,
          "jmxExport": true
        },
        {
          "name": "default",
          "softMemoryLimit": "5%",
          "hardConcurrencyLimit": 2,
          "maxQueued": 5,
          "schedulingWeight": 1,
          "jmxExport": true
        }
      ]
    }
  ],
  "selectors": [
    {
      "group": "root.admin",
      "user": "admin.*"
    },
    {
      "group": "root.etl",
      "user": "etl_.*"
    },
    {
      "group": "root.interactive.bi",
      "user": "bi_.*"
    },
    {
      "group": "root.interactive.analyst",
      "user": "analyst.*"
    },
    {
      "group": "root.default"
    }
  ]
}
```

### 2-3. 설계 포인트 — SLA 5초 보장 전략

| 설계 결정 | 설정 | 이유 |
|---|---|---|
| BI `schedulingWeight: 5` | interactive 내 최우선 | ETL과 경합 시에도 BI 쿼리가 먼저 자원 확보 |
| BI `hardConcurrencyLimit: 20` | 높은 동시성 | BI 도구 2개가 각각 ~10개 동시 쿼리 가정 |
| ETL `hardConcurrencyLimit: 5` | 낮은 동시성 | 대형 쿼리 5개면 워커 3대 메모리 대부분 점유 |
| `softMemoryLimit` 합계 > 100% | 의도적 초과 | soft limit은 초과 시 큐잉만 함, hard reject 아님 |
| `jmxExport: true` | 전 그룹 | Prometheus에서 그룹별 메트릭 수집 → Grafana 대시보드 |

> **softMemoryLimit만으로 5초 SLA가 보장되지 않는 경우**:
> ETL 쿼리의 memory reservation이 interactive 그룹까지 침범할 수 있음.
> 이때는 `query.max-memory-per-node`를 ETL 사용자의 session property로
> 제한하는 것이 보완책 (§5에서 다룸).

### 2-4. Helm values 반영

Trino Helm chart는 `resourceGroups:` 키를 네이티브로 지원. `type: configmap`으로
설정하면 chart가 resource-groups.properties + resource-groups.json ConfigMap을
자동 생성하고 coordinator에만 마운트함. 별도 additionalVolumes/ConfigMap 설정 불필요.

```yaml
# helm/values.yaml
resourceGroups:
  type: configmap
  resourceGroupsConfig: |-
    {
      "rootGroups": [ ... ],  # §2-2의 JSON 전체
      "selectors": [ ... ]
    }
```

> **주의**: `manifests/trino/resource-groups.json`은 가독성을 위한 참조 사본.
> 실제 배포에 반영되는 것은 `helm/values.yaml`의 `resourceGroupsConfig` 값.
> 카탈로그 파일(`catalogs/`)과 동일한 관계 — 수정 시 values.yaml을 편집할 것.

적용:
```bash
./scripts/install.sh    # helm upgrade 포함 — resourceGroups ConfigMap 자동 생성
```

### 2-5. Keycloak 그룹 → Resource Group selector 매핑

Keycloak에서 `groups` claim이 `['trino-etl']`로 내려오면, Trino의 `user` 필드로는
직접 매핑이 안 됨. 두 가지 접근:

**방법 A — 사용자 이름 컨벤션 (간단)**:
Keycloak 사용자 이름을 `etl_`, `analyst_`, `bi_` 접두사로 통일.
위 selector의 `user` regex가 그대로 동작.

**방법 B — group selector 사용 (Trino 440+)**:
Trino가 OAuth2 `groups` claim을 인식하면 selector에서 `source: "GROUP"` 사용 가능.
단, Trino 480에서의 resource group selector는 `user` regex 기반이 표준.
Keycloak 그룹 → Trino group mapping은 추가 확인 필요.

> **권장**: 방법 A가 가장 확실. Keycloak 사용자 이름에 접두사 규칙을 적용하면
> resource group selector와 Ranger 정책 모두에서 일관되게 매핑 가능.

### 2-6. 검증

```sql
-- 사용자별 Resource Group 배정 확인 (각 사용자로 접속 후)
-- 참고: system.runtime.resource_group_state 테이블은 Trino 480에서 존재하지 않음 (G24)
SELECT query_id, "user", resource_group_id, state
FROM system.runtime.queries
WHERE state IN ('RUNNING', 'QUEUED')
ORDER BY created DESC;

-- 기대 결과:
-- admin_trino   → ['root', 'admin']
-- etl_user1     → ['root', 'etl']
-- analyst_user1 → ['root', 'interactive', 'analyst']
-- bi_superset   → ['root', 'interactive', 'bi']
```

### 2-7. 주의 — 구현 중 발견한 함정

- **G23. `cpuQuotaPeriod`는 JSON 최상위 프로퍼티**: `cpuQuotaPeriod`를 `rootGroups[0]`
  (root 그룹) 안에 넣으면 `Unknown property: cpuQuotaPeriod` 에러로 coordinator 시작 불가.
  이 프로퍼티는 `ManagerSpec` 레벨(JSON 최상위, `rootGroups`와 동일 레벨)에 위치해야 함.
  동시에, `softCpuLimit`/`hardCpuLimit`를 하위 그룹에 설정했다면 `cpuQuotaPeriod`는 필수
  — 없으면 `cpuQuotaPeriod must be specified to use CPU limits` 에러 발생.

- **G24. `system.runtime.resource_group_state` 테이블 없음**: Trino 480에서
  이 테이블은 존재하지 않음. Resource Group 배정 확인은
  `system.runtime.queries`의 `resource_group_id` 컬럼으로 확인:
  ```sql
  SELECT "user", resource_group_id, state
  FROM system.runtime.queries
  WHERE state = 'RUNNING'
  ORDER BY created DESC;
  ```

- **G25. Chart 네이티브 `resourceGroups:` 사용**: Helm chart의 `resourceGroups:` 키를
  `type: configmap`으로 설정하면 chart가 ConfigMap + Mount를 자동 처리.
  수동으로 `additionalConfigProperties`에 `resource-groups.configuration-manager=file`을
  넣고 ConfigMap/Volume을 따로 만들 필요 없음.

---

## 3. K8s ResourceQuota — Namespace 레벨 리소스 경계

> Trino Resource Group은 쿼리 레벨 격리. K8s Quota는 **인프라 레벨** 격리.
> 의도치 않은 스케일 아웃이나 리소스 누수를 방지.

### 3-1. 현재 리소스 사용량 산정

현재 [helm/values.yaml](../helm/values.yaml) 기준:

| 컴포넌트 | 수 | CPU req/lim | Memory req/lim | 합계 Memory lim |
|---|---|---|---|---|
| Coordinator | 1 | 2/4 | 10Gi/12Gi | 12Gi |
| Worker | 3 | 16/24 | 72Gi/80Gi | 240Gi |
| HMS | 1 | ~0.5/1 | ~1Gi/2Gi | 2Gi |
| hms-postgres (CNPG) | 3 | ~1/2 | ~2Gi/4Gi | 12Gi |
| analytics-postgres | 1 | ~0.5/1 | ~1Gi/2Gi | 2Gi |
| MinIO | 1 | ~0.5/1 | ~1Gi/2Gi | 2Gi |
| Prometheus + Grafana | 2 | ~1/2 | ~2Gi/4Gi | 8Gi |
| Keycloak | 1 | 0.5/2 | 1Gi/2Gi | 2Gi |
| keycloak-postgres (CNPG) | 1 | 0.25/1 | 0.5Gi/1Gi | 1Gi |
| **합계** | | | | **~281Gi** |

```bash
# 실제 확인
NS=user-braveji
kubectl -n $NS describe resourcequota
kubectl -n $NS top pod --sort-by=memory
kubectl get nodes -o custom-columns=\
NAME:.metadata.name,CPU:.status.allocatable.cpu,MEM:.status.allocatable.memory
```

### 3-2. ResourceQuota 설계

```yaml
apiVersion: v1
kind: ResourceQuota
metadata:
  name: trino-resource-quota
  namespace: user-braveji
spec:
  hard:
    # 현재 합계 ~281Gi + 롤링 업데이트 여유 (~80Gi) + HPA 여유 (~80Gi)
    requests.cpu: "80"
    limits.cpu: "120"
    requests.memory: "320Gi"
    limits.memory: "440Gi"
    # Pod 수 제한 (워커 무한 증식 방지)
    pods: "30"
    # PVC 수 제한
    persistentvolumeclaims: "20"
    # Service 수 제한
    services: "15"
```

### 3-3. LimitRange — Pod 기본값 + 최대값

```yaml
apiVersion: v1
kind: LimitRange
metadata:
  name: trino-limit-range
  namespace: user-braveji
spec:
  limits:
    - type: Container
      default:
        cpu: "2"
        memory: "4Gi"
      defaultRequest:
        cpu: "1"
        memory: "2Gi"
      max:
        cpu: "32"
        memory: "96Gi"
    - type: Pod
      max:
        cpu: "48"
        memory: "128Gi"
```

### 3-4. 판단 기준

- **Worker 스케일 상한**: `workers × (worker limit)` ≤ Quota limits
  - 현재: 3 × 80Gi = 240Gi ← quota `limits.memory: 440Gi` 이내
  - HPA 도입 시: max 4 workers × 80Gi = 320Gi + 나머지 서비스 ~78Gi = 398Gi (440Gi 이내)
- **롤링 업데이트 여유**: worker 1대 추가 파드가 잠시 뜰 수 있으므로 +80Gi 확보
- **Coordinator + 보조 서비스**: HMS, MinIO, PG 등의 리소스도 합산됨

---

## 5. Session Property 제어 — 사용자 우회 방지

> Resource Group과 메모리 제한을 설정해도, 사용자가 `SET SESSION`으로
> `query_max_memory_per_node`를 올리면 무의미. 세션 프로퍼티 변경을 제한.

### 5-1. Ranger에서 Session Property 제어

Ranger Trino Plugin은 session property 접근제어도 지원. Ranger Admin UI에서:

| 정책 | 대상 그룹 | Session Property | 허용 |
|---|---|---|---|
| admin-session-all | trino-admin | * | Allow |
| etl-session-limited | trino-etl | query_max_memory_per_node | Deny |
| analyst-session-deny | trino-analyst | * | Deny |
| bi-session-deny | trino-bi | * | Deny |

### 5-2. (File-based 대체) rules.json session_properties 섹션

```json
{
  "sessionProperties": [
    {
      "user": "admin.*",
      "allow": true
    },
    {
      "user": "etl_.*",
      "property": "query_max_memory_per_node",
      "allow": false
    },
    {
      "user": "(analyst.*|bi_.*)",
      "property": ".*",
      "allow": false
    }
  ]
}
```

### 5-3. ETL 그룹 쿼리 시간 제한

ETL은 안정성 중시이므로 쿼리 시간 제한을 넉넉히, 분석가/BI는 5초 SLA에 맞춰 제한:

Resource Group 설정에 세션 프로퍼티 추가:
```json
{
  "name": "etl",
  "softMemoryLimit": "60%",
  "hardConcurrencyLimit": 5,
  "maxQueued": 20,
  "sessionProperties": {
    "query_max_execution_time": "2h",
    "query_max_run_time": "3h"
  }
},
{
  "name": "analyst",
  "softMemoryLimit": "50%",
  "hardConcurrencyLimit": 15,
  "maxQueued": 30,
  "sessionProperties": {
    "query_max_execution_time": "5m",
    "query_max_run_time": "10m"
  }
},
{
  "name": "bi",
  "softMemoryLimit": "60%",
  "hardConcurrencyLimit": 20,
  "maxQueued": 50,
  "sessionProperties": {
    "query_max_execution_time": "30s",
    "query_max_run_time": "1m"
  }
}
```

> **BI `query_max_execution_time: 30s`**: 5초 SLA를 만족하지 못하면 쿼리 자체를
> 최적화해야 함. 30초는 안전 상한으로, 대부분의 통계 쿼리는 이 안에 끝나야 함.

---

## 진행 체크리스트 (본 문서 범위)

- [x] 2-a. resource-groups.json 작성 (etl/interactive.analyst/interactive.bi/admin/default)
- [x] 2-b. Chart 네이티브 `resourceGroups:` 방식으로 Helm values 반영 + coordinator 재배포 (G23: cpuQuotaPeriod 위치 수정)
- [x] 2-c. Resource Group 배정 검증 (admin→root.admin, etl→root.etl, analyst→root.interactive.analyst, bi→root.interactive.bi)
- [ ] 3. K8s ResourceQuota + LimitRange 적용
- [ ] 5. Session Property 제한 + 그룹별 쿼리 시간 제한
