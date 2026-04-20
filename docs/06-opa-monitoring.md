# 3단계-C': OPA 접근제어 + 모니터링 (Ranger 대안)

[06-ranger-monitoring.md](06-ranger-monitoring.md)의 Ranger 대신 **OPA(Open Policy Agent)**
를 사용하는 가이드. Trino 480에 OPA plugin이 내장되어 있어 별도 이미지 빌드 불필요.

> **이 문서는 docs/06과 동일한 모니터링/검증 구조를 공유**.
> §6 모니터링, §7 검증, §8 운영 가이드는 [06-ranger-monitoring.md](06-ranger-monitoring.md)와
> 100% 동일. 본 문서는 §4 (접근제어)만 OPA 방식으로 대체한 버전.

> 3단계 전체 흐름과 다른 파트는 아래 참고:
> - [04-keycloak-oauth2.md](04-keycloak-oauth2.md): §0 현황 정리 + §1 Keycloak 인증
> - [05-resource-groups-quota.md](05-resource-groups-quota.md): §2 Resource Groups + §3 K8s Quota + §5 Session 제어
> - [06-ranger-monitoring.md](06-ranger-monitoring.md): §4 Ranger 방식 + §6~§8 모니터링/검증/문서화
> - **본 문서**: §4 OPA 방식 (Ranger 대안)

---

## 0. OPA vs Ranger — 선택 가이드

### 0-1. 공통점

| 항목 | 동일 |
|---|---|
| Trino 480 내장 plugin | 둘 다 별도 tar.gz 설치 불필요 |
| HTTP 통신 | 둘 다 REST API로 정책 조회 |
| Keycloak 인증과 독립 | 둘 다 사용자 인증 계층(①)과 무관한 인가 계층(③) |

### 0-2. 차이점 (선택 기준)

| 항목 | Ranger | OPA |
|---|---|---|
| **이미지 크기** | `apache/ranger:2.8.0` 990MB | `openpolicyagent/opa:edge-static` 24MB |
| **메타데이터 DB** | PostgreSQL 필수 (CNPG 1Pod) | **불필요** (정책 in-memory) |
| **Pod 수 추가** | 2개 (Admin + PG) | **1개** (OPA만) |
| **메모리** | ~3Gi | **~50MB** |
| **사용자/그룹 관리** | Ranger DB에 별도 등록 (G37 동기화) | Rego 내부 정적 매핑 (Trino 480 OAuth2의 groups-field 미지원 워크어라운드, §4-6) |
| **정책 형식** | UI + REST API (정책 ID 기반) | **Rego DSL** (Git 버전관리 친화) |
| **정책 변경 반영** | 30초 poll | 즉시 (ConfigMap 업데이트 시) |
| **Web UI** | Ranger Admin Console (정책 편집 GUI) | **없음** (Rego 코드 직접 편집) |
| **감사 로그** | Log4J/Solr (Trino 측) | OPA decision logs (HTTP/file/Kafka) |

### 0-3. 권장 시나리오

| 상황 | 권장 |
|---|---|
| 사용자/팀이 적고 (~50명), Trino만 사용 | **OPA** |
| 정책을 Git/CI로 관리하고 싶음 | **OPA** |
| 비개발자가 Web UI로 정책 편집 | Ranger |
| Hive/HDFS/Spark 등 다중 컴포넌트 통합 정책 | Ranger (Ranger plugin이 있는 컴포넌트 모두 지원) |
| 본 POC 기준 | **OPA** (운영 단순성 + 리소스 절감) |

---

## 4. OPA 연동 — 카탈로그·스키마별 접근제어

> **결정**: OPA로 lightweight 접근제어. Rego 정책을 ConfigMap으로 관리.

### 4-1. 아키텍처

```
[OPA Deployment]  ← openpolicyagent/opa:edge-static (24MB, stateless)
       │
       └── [Rego 정책]  ← ConfigMap으로 마운트 (예: trino-opa-policy)
              │
              ▼ HTTP REST API (POST /v1/data/trino/allow)
[Trino 480 — 내장 OPA Plugin]  ← Dockerfile 수정 불필요
       │
       ▼ 매 쿼리마다 OPA에 인가 요청 (캐시 가능)
[Trino Query] → 허용/거부
```

핵심 차이:
- **DB 없음** — Rego 정책 파일이 OPA 메모리에 로드됨
- **사용자 동기화 없음** — Trino가 Keycloak JWT를 그대로 OPA에 전달
- **stateless** — Pod 재시작 시 ConfigMap에서 정책만 로드하면 됨

> **OPA-G1. Trino 480은 OPA plugin이 내장**: `access-control.name=opa` + `opa.policy.uri`
> 만으로 동작. 별도 jar 추가 불필요.

> **OPA-G2. Trino → OPA 통신은 HTTP**: 같은 namespace 내부에서는
> `http://opa:8181`로 충분. 외부 노출 시에만 HTTPS 검토.

### 4-2. OPA Docker 이미지

| 이미지 | 태그 | 크기 | 비고 |
|---|---|---|---|
| `openpolicyagent/opa` | `edge-static` | 24MB | static 빌드 (의존성 적음) |
| `openpolicyagent/opa` | `edge` | 35MB | 동적 빌드 (debug 도구 포함) |
| `openpolicyagent/opa` | `1.16.0-static` | ~25MB | 안정 버전 (운영 권장) |

> Docker Hub 직접 pull 가능 (Harbor 미러링 불필요 — Ranger와 동일 G34 근거).

---

### 4-3. OPA Deployment 배포

#### 디렉토리 구조 (계획)

```
manifests/opa/
├── opa-deployment.yaml      # OPA Deployment + Service (PG 불필요)
├── opa-policy-configmap.yaml # Rego 정책 (ConfigMap)
└── opa-ingress.yaml         # 외부 디버깅용 (선택)
```

#### 의존 컴포넌트

| 컴포넌트 | 용도 | 배포 방법 | 리소스 |
|---|---|---|---|
| **OPA** | 정책 평가 엔진 | Deployment | 0.1/0.5 CPU, 128Mi/256Mi MEM |

> Ranger 대비 절감: PG 1 Pod + Admin 1 Pod (~3Gi 메모리) → OPA 1 Pod (~256Mi).

#### ResourceQuota 영향

| 항목 | Ranger 기준 | OPA 기준 | 절감 |
|---|---|---|---|
| pods | +2 | +1 | -1 |
| limits.memory | +5Gi | +0.25Gi | -4.75Gi |
| limits.cpu | +3 | +0.5 | -2.5 |

#### Deployment 매니페스트 (예시)

```yaml
# manifests/opa/opa-deployment.yaml
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: opa
  labels:
    app: opa
spec:
  replicas: 1
  selector:
    matchLabels:
      app: opa
  template:
    metadata:
      labels:
        app: opa
      annotations:
        sidecar.istio.io/inject: "false"
    spec:
      containers:
        - name: opa
          image: openpolicyagent/opa:1.16.0-static
          args:
            - "run"
            - "--server"
            - "--addr=0.0.0.0:8181"
            - "--log-level=info"
            - "--log-format=json"
            - "/policies/trino.rego"
          ports:
            - name: http
              containerPort: 8181
          volumeMounts:
            - name: policies
              mountPath: /policies
          readinessProbe:
            httpGet:
              path: /health?bundles=true
              port: 8181
            initialDelaySeconds: 5
            periodSeconds: 10
          livenessProbe:
            httpGet:
              path: /health
              port: 8181
            initialDelaySeconds: 30
            periodSeconds: 30
          resources:
            requests:
              cpu: "100m"
              memory: "128Mi"
            limits:
              cpu: "500m"
              memory: "256Mi"
      volumes:
        - name: policies
          configMap:
            name: trino-opa-policy
---
apiVersion: v1
kind: Service
metadata:
  name: opa
spec:
  type: ClusterIP
  selector:
    app: opa
  ports:
    - name: http
      port: 8181
      targetPort: 8181
```

---

### 4-4. Rego 정책 — ConfigMap

OPA는 [Rego](https://www.openpolicyagent.org/docs/latest/policy-language/) DSL로
정책을 정의. Trino가 매 인가 요청마다 OPA에 JSON을 보내고, Rego가 `allow=true/false`를
응답.

#### Trino → OPA 요청 형식 (예시)

```json
{
  "input": {
    "context": {
      "identity": {
        "user": "etl_user1",
        "groups": ["trino-etl"]
      },
      "softwareStack": {
        "trinoVersion": "480"
      }
    },
    "action": {
      "operation": "SelectFromColumns",
      "resource": {
        "table": {
          "catalogName": "hive",
          "schemaName": "default",
          "tableName": "orders",
          "columns": ["id", "amount"]
        }
      }
    }
  }
}
```

OPA는 위 input을 받아 `allow` boolean을 반환. Rego 정책에서 `input.context.identity.groups`로
Keycloak에서 받은 그룹을 직접 평가 가능.

#### Rego 정책 예시 — `manifests/opa/opa-policy-configmap.yaml`

```yaml
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: trino-opa-policy
data:
  trino.rego: |
    package trino

    import rego.v1

    # 기본은 거부
    default allow := false

    # ─── 그룹 정의 ───
    admin_groups := {"trino-admin"}
    etl_groups := {"trino-etl"}
    readonly_groups := {"trino-analyst", "trino-bi"}

    # 사용자 그룹 (Keycloak JWT의 groups claim → Trino → OPA)
    user_groups := {g | g := input.context.identity.groups[_]}

    # ─── 헬퍼: 사용자가 특정 그룹에 속하는가 ───
    is_admin if {
        some g in admin_groups
        g in user_groups
    }
    is_etl if {
        some g in etl_groups
        g in user_groups
    }
    is_readonly if {
        some g in readonly_groups
        g in user_groups
    }

    # ─── 정책 1: admin은 모든 작업 허용 ───
    allow if is_admin

    # ─── 정책 2: etl은 hive/iceberg/postgresql에 대한 모든 작업 ───
    allow if {
        is_etl
        catalog := input.action.resource.table.catalogName
        catalog in {"hive", "iceberg", "postgresql"}
    }
    allow if {
        is_etl
        catalog := input.action.resource.schema.catalogName
        catalog in {"hive", "iceberg", "postgresql"}
    }
    allow if {
        is_etl
        catalog := input.action.resource.catalog.name
        catalog in {"hive", "iceberg", "postgresql"}
    }

    # ─── 정책 3: analyst/bi는 read-only ───
    read_only_ops := {
        "SelectFromColumns", "ShowSchemas", "ShowTables",
        "ShowColumns", "ShowCatalogs", "FilterCatalogs",
        "FilterSchemas", "FilterTables", "ExecuteQuery",
        "AccessCatalog"
    }

    allow if {
        is_readonly
        input.action.operation in read_only_ops
    }

    # ─── 정책 4: 모든 사용자는 자기 자신을 impersonate 가능 ───
    allow if {
        input.action.operation == "ImpersonateUser"
        input.action.resource.user.user == input.context.identity.user
    }

    # ─── 정책 5: 민감 schema 차단 (analyst/bi) ───
    allow := false if {
        is_readonly
        input.action.resource.table.catalogName == "postgresql"
        input.action.resource.table.schemaName in {"internal", "hr_payroll"}
    }
```

> **OPA-G3. Rego는 default allow := false가 기본**: 명시적으로 매칭되는 규칙이
> 없으면 거부. Ranger와 달리 별도의 "deny" 정책 없이 화이트리스트로만 작성.

> **OPA-G4. Trino → OPA의 input 스키마는 operation에 따라 다름**:
> `SelectFromColumns`는 `input.action.resource.table`,
> `ShowCatalogs`는 `input.action.resource.catalog`,
> `ImpersonateUser`는 `input.action.resource.user`. Rego에서 `if` 가드로 분기 필요.

---

### 4-5. Trino values.yaml 변경 (Ranger → OPA)

Trino 480은 OPA plugin도 내장이므로 Dockerfile 수정 불필요.

```yaml
# helm/values.yaml — Ranger 설정 제거 후 OPA로 교체

# 기존 (Ranger):
# accessControl:
#   type: properties
#   properties: |
#     access-control.name=ranger
#     ranger.service.name=trino-braveji
#     ranger.plugin.config.resource=/etc/trino/ranger/...

# 신규 (OPA):
accessControl:
  type: properties
  properties: |
    access-control.name=opa
    opa.policy.uri=http://opa:8181/v1/data/trino/allow
    # opa.policy.row-filters-uri=http://opa:8181/v1/data/trino/rowFilters    # 선택
    # opa.policy.column-masking-uri=http://opa:8181/v1/data/trino/columnMask # 선택
    # opa.policy.batched-uri=http://opa:8181/v1/data/trino/batch             # 성능 최적화
    # opa.allow-permission-management-operations=false                       # 기본값
    # opa.log-requests=false                                                 # 디버깅 시 true

# coordinator의 ranger-config volume 제거 (XML 마운트 불필요)
coordinator:
  additionalVolumes:
    # ranger-config 항목 제거 — OPA는 별도 마운트 필요 없음
```

---

### 4-6. Keycloak 그룹 → OPA 전달 — Rego 정책 내부 정적 매핑 (워크어라운드)

> **OPA-G5 (실측). Trino 480 OAuth2 모듈은 JWT의 `groups` claim을 identity로 자동
> 추출하지 못한다.** OPA decision log를 보면 `"groups":[]` 로 비어 옴.

**확인 방법**:
```bash
kubectl -n user-braveji logs deploy/opa | grep '"path":"trino/allow"' | tail -3
# {"input":{"action":...,"context":{"identity":{"groups":[],"user":"admin_trino"},...}},"result":false}
```

**원인**:
- OAuth2Config는 `principal-field`(username용)만 설정 가능, `groups-field` 미지원 (Trino 480 기준)
- 정식 해결은 group provider (file/ldap/http) — `etc/group-provider.properties` 자동 로드 필요
- Trino chart 1.42는 `/etc/trino` 전체를 ConfigMap으로 마운트 → subPath로 `group-provider.properties` 추가 시 mount 충돌 (`not a directory` 에러)

**채택한 워크어라운드**: Rego 정책 내부에 username → groups 정적 매핑.

```rego
user_to_groups := {
    "admin_trino":    {"trino-admin"},
    "etl_user1":      {"trino-etl"},
    ...
}

# Trino가 identity.groups를 채워주면 그것을 우선, 비어있으면 정적 매핑 사용
user_groups := groups if {
    input_groups := {g | some g in input.context.identity.groups}
    count(input_groups) > 0
    groups := input_groups
} else := groups if {
    groups := user_to_groups[input.context.identity.user]
} else := set()
```

**장점**:
- chart/PV 마운트 변경 없이 OPA ConfigMap 수정만으로 적용
- 정책과 매핑이 한 파일 → 코드리뷰 단일화
- 향후 Trino가 OAuth2 groups-field를 지원하면 `if` 분기가 자동으로 JWT를 우선 사용

**단점 (수용)**:
- Keycloak 사용자 추가 시 두 곳 갱신 필요 (Keycloak Realm + Rego `user_to_groups`)
- 매핑 행 수가 늘어나면 Rego 가독성 저하 → 50명 초과 시 file group provider로 전환 검토

---

### 4-7. 정책 변경 절차

#### 즉시 반영 방법

```bash
# 1. ConfigMap 수정
vi manifests/opa/opa-policy-configmap.yaml
kubectl -n user-braveji apply -f manifests/opa/opa-policy-configmap.yaml

# 2. OPA Pod에서 정책 reload (또는 Pod 재시작)
kubectl -n user-braveji exec deploy/opa -- \
  curl -s -X PUT http://localhost:8181/v1/policies/trino \
  --data-binary @/policies/trino.rego
```

또는 OPA를 `--watch` 플래그로 실행하면 ConfigMap 변경 감지 가능 (sidecar 패턴).

> **OPA-G6. Trino plugin이 OPA 응답을 캐시하지 않음**: 정책 변경 즉시 반영.
> Ranger의 30초 poll 지연이 없음.

---

### 4-8. 검증 방법 (Ranger 검증과 동일 시나리오)

스크립트 패턴은 [scripts/setup-ranger-users.sh](../scripts/setup-ranger-users.sh)와
유사하지만, 사용자/그룹 등록 단계 없이 **OPA Pod 배포 + Rego ConfigMap 적용 + 검증**만
수행하면 됨.

#### 자동 검증 (계획)

```bash
./scripts/setup-opa.sh   # (작성 필요)
```

수행 단계:
1. `manifests/opa/` 매니페스트 적용 (Deployment + ConfigMap + Service)
2. OPA Pod Ready 대기
3. OPA REST API 직접 테스트 (`curl http://opa:8181/v1/data/trino/allow -d '{...}'`)
4. Trino를 통한 사용자별 쿼리 검증 (V1~V5)

#### 수동 검증 — OPA 직접 테스트

```bash
NS=user-braveji

# OPA에 직접 인가 요청 (Trino 거치지 않고)
kubectl -n $NS exec deploy/opa -- curl -s -X POST \
  http://localhost:8181/v1/data/trino/allow \
  -H "Content-Type: application/json" \
  -d '{
    "input": {
      "context": {
        "identity": {"user": "etl_user1", "groups": ["trino-etl"]}
      },
      "action": {
        "operation": "SelectFromColumns",
        "resource": {"table": {"catalogName": "hive", "schemaName": "default", "tableName": "t1", "columns": ["id"]}}
      }
    }
  }'
# 기대: {"result": true}
```

#### 수동 검증 — Trino 쿼리 (V1~V5)

[06-ranger-monitoring.md §4-8](06-ranger-monitoring.md)의 V1~V5와 **동일**한 결과 기대:

| # | 사용자 | 쿼리 | 기대 |
|---|---|---|---|
| V1 | analyst_user1 | `SELECT count(*) FROM tpch.tiny.nation` | 25 |
| V2 | analyst_user1 | `CREATE SCHEMA hive.opa_test ...` | Access Denied |
| V3 | etl_user1 | `SELECT count(*) FROM tpch.tiny.nation` | 25 |
| V4 | admin_trino | `SELECT count(*) FROM tpch.tiny.nation` | 25 |
| V5 | bi_superset | `SELECT count(*) FROM tpch.tiny.nation` | 25 |

---

### 4-9. 진행 순서 요약

| 순서 | 작업 | Ranger 대비 |
|---|---|---|
| 1 | (선택) 기존 Ranger Pod 삭제 + values.yaml에서 Ranger 설정 제거 | Ranger 마이그레이션 시 |
| 2 | `manifests/opa/opa-policy-configmap.yaml` Rego 정책 작성 | 신규 (Ranger 정책 UI 작업 대체) |
| 3 | `manifests/opa/opa-deployment.yaml` 적용 | 1 Pod (Ranger는 2 Pod) |
| 4 | OPA Pod Ready 대기 (~10초) | Ranger Admin 2분 대비 빠름 |
| 5 | `helm/values.yaml`의 `accessControl.properties`를 OPA로 교체 | XML ConfigMap 마운트 불필요 |
| 6 | `helm upgrade` → coordinator 재시작 | Ranger와 동일 |
| 7 | 검증 (V1~V5) | Ranger와 동일 |

---

## 5. 마이그레이션 시 추가 고려사항

### 5-1. Ranger → OPA 전환 시 정리할 리소스

```bash
# Ranger 관련 리소스 삭제
kubectl -n user-braveji delete deploy/ranger-admin
kubectl -n user-braveji delete svc/ranger-admin
kubectl -n user-braveji delete ingress/ranger-admin
kubectl -n user-braveji delete configmap/ranger-admin-config
kubectl -n user-braveji delete configmap/trino-ranger-config
kubectl -n user-braveji delete cluster.postgresql.cnpg.io/ranger-postgres
kubectl -n user-braveji delete secret/ranger-postgres-app
```

ResourceQuota 회수: `pods -2`, `limits.memory -5Gi`, `limits.cpu -3`.

### 5-2. 정책 마이그레이션 매핑

| Ranger 정책 | Rego 규칙 |
|---|---|
| 정책 1 (admin all) | `allow if is_admin` |
| 정책 2 (etl readwrite) | `allow if { is_etl; catalog in {"hive",...} }` |
| 정책 3 (analyst readonly) | `allow if { is_readonly; input.action.operation in read_only_ops }` |
| 정책 4 (bi readonly) | (위와 동일 — `readonly_groups`에 trino-bi 포함) |
| 정책 5 (deny sensitive) | `allow := false if { is_readonly; ... internal/hr_payroll ... }` |

### 5-3. 추가 기능 활용 (OPA 우위)

- **Row filtering**: `opa.policy.row-filters-uri`로 행 단위 필터링 정책 작성 가능
- **Column masking**: `opa.policy.column-masking-uri`로 컬럼 마스킹 가능
- **시간 기반 정책**: Rego에서 `time.now_ns()`로 업무 시간 외 차단 등 동적 정책 작성

---

## 6~8. 모니터링 / 검증 / 운영 가이드

§6~§8은 [06-ranger-monitoring.md](06-ranger-monitoring.md)와 **100% 동일**.
접근제어 plugin이 Ranger인지 OPA인지와 무관하게:

- §6 모니터링: JMX Exporter + Grafana 대시보드 + 알림 규칙
- §7 검증: T1~T12 시나리오 (T4의 "Ranger 거부"를 "OPA 거부"로 읽기)
- §8 운영 가이드: [docs/07-operations-guide.md](07-operations-guide.md)

> 단, §3의 "Ranger 정책 관리" 섹션은 OPA 사용 시 "Rego 정책 관리"로 대체:
> - Ranger Admin UI 대신 ConfigMap (`kubectl edit configmap/trino-opa-policy`)
> - 30초 poll 대신 즉시 반영

---

## 진행 체크리스트 (OPA 도입 시)

**§4 OPA 연동**:
- [ ] 4-a. `manifests/opa/` 디렉토리 생성 + Deployment/Service/ConfigMap 매니페스트 작성
- [ ] 4-b. Rego 정책 작성 (admin/etl/analyst+bi 그룹 + 민감 데이터 차단)
- [ ] 4-c. OPA 배포 + REST API 직접 검증
- [ ] 4-d. `helm/values.yaml`의 `accessControl`을 OPA로 교체 + helm upgrade
- [ ] 4-e. 접근제어 검증 (V1~V5)
- [ ] 4-f. (선택) Ranger 관련 리소스 정리

**§6~§8**: docs/06-ranger-monitoring.md와 동일하므로 별도 작업 없음.

---

## 결론

| 항목 | 평가 |
|---|---|
| **현재 POC 적합성** | OPA가 더 적합 (사용자 13명, namespace 1개, Trino만 사용) |
| **운영 단순성** | OPA 우위 (DB 없음, Pod 1개, stateless) |
| **정책 표현력** | OPA 우위 (Rego의 시간/조건/계산 가능) |
| **GUI 정책 편집** | Ranger 우위 (비개발자 친화) |
| **다중 컴포넌트** | Ranger 우위 (Hive/HDFS/Spark 통합) |

**권장**: 본 POC는 OPA로 전환하면 **Pod 2개 + 메모리 ~3Gi 절감 + 사용자 동기화 작업 제거**.
운영 환경에서 비개발자가 정책을 편집해야 하는 경우에만 Ranger 유지.
