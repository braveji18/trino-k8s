# Trino Gateway 적용 가이드

여러 Trino 클러스터 앞단에 라우팅/로드밸런서 게이트웨이를 두어 단일 엔드포인트로 묶고,
blue/green 무중단 업그레이드와 routingGroup별 워크로드 격리(adhoc/etl 등)를 제공.

참고: <https://trinodb.github.io/trino-gateway/>

> **2026-04-20 적용 완료**: chart `my-trino/trino-gateway` 1.18.0 (appVersion 18)으로
> `user-braveji` namespace에 배포. 백엔드 `my-trino` 등록 후
> `http://braveji-gw.trino.quantumcns.ai/api/public/backends`에서 정상 응답 확인.

---

## 1. 사전 충족 (이 프로젝트 상태 점검)

| 요구사항 | 이 프로젝트 상태 |
|---|---|
| Java 25 런타임 | 공식 이미지 `trinodb/trino-gateway` 사용 → 무관 |
| 백엔드 DB (PG/MySQL/Oracle) | **CNPG operator 이미 설치** → 새 `Cluster` 1개 추가 |
| `http-server.process-forwarded=true` on 모든 백엔드 Trino | [helm/values.yaml](../helm/values.yaml)에 이미 설정 (CLAUDE.md 함정 #2) |
| nginx-ingress + cert-manager | 이미 사용 중 |
| Helm repo | `helm repo add trino https://trinodb.github.io/charts` (이미 `my-trino` alias로 추가됨) |
| Trino 버전 | 480 (chart 1.42.x) — Gateway 18은 354 이상이면 OK |
| Istio mesh | namespace에 sidecar 자동 주입 + AuthorizationPolicy로 ingress 차단 → **Pod에 sidecar 비활성화 필수** (§2-2 참고) |

---

## 2. 적용 절차

### 2-1. Gateway 전용 PostgreSQL (CNPG)

기존 `hms-postgres`/`keycloak-postgres` 패턴을 그대로 따라
[manifests/trino-gateway/gateway-postgres.yaml](../manifests/trino-gateway/gateway-postgres.yaml)
신규 생성. 핵심 포인트:

- `instances: 1` (POC), `storage.size: 5Gi`, `storageClass: qks-ceph-block`
- `bootstrap.initdb`로 `gateway` DB + `gateway` 소유자 자동 생성
- Gateway는 최초 기동 시 Flyway로 스키마를 자동 만들기 때문에 추가 init 불필요
- `inheritedMetadata.annotations`로 CNPG가 만드는 PG Pod에도
  `sidecar.istio.io/inject: "false"` 전파

### 2-2. Helm values 작성 — `helm/trino-gateway-values.yaml`

**중요한 실측 사항**:

1. chart 1.18 default values는 `config.dataStore.password`를 평문 string으로 기대
   (Secret 참조 미지원). 평문을 values.yaml에 박지 말고 **`--set`으로 설치 시 주입**.
2. `envFrom`은 init/main 컨테이너에 env var를 주입할 뿐, `config.yaml`에 자동
   치환되지 않음 → Gateway server는 그 env var를 읽지 못함.
3. `podAnnotations.sidecar.istio.io/inject: "false"` **필수** — 빠뜨리면 ingress가
   `403 RBAC: access denied`로 막힘 (Istio Envoy의 응답이지 Gateway의 RBAC 아님).
4. 폼 인증 + admin 프리셋 사용자 + RSA 키쌍이 있어야 UI/Admin API 접근 가능.
   `/api/public/*`는 인증 없이도 열림.

```yaml
replicaCount: 1
image:
  repository: trinodb/trino-gateway
  tag: "18"

# 데이터 인프라 일괄 정책: Istio sidecar 비활성화
# (안 끄면 namespace AuthorizationPolicy가 ingress 트래픽 차단 → 403)
podAnnotations:
  sidecar.istio.io/inject: "false"

config:
  serverConfig:
    node.environment: prod
    http-server.http.port: 8080
    http-server.http.enabled: true
    http-server.process-forwarded: true   # ingress 종단이라 필수
  dataStore:
    jdbcUrl: jdbc:postgresql://gateway-postgres-rw.user-braveji.svc:5432/gateway
    user: gateway
    password: ""        # 설치 시 --set으로 주입
    driver: org.postgresql.Driver
  clusterStatsConfiguration:
    # 기본값 INFO_API는 코디네이터 시작 중에도 healthy로 오판함 (§3-4 참고).
    # UI_API는 /ui/api/cluster의 activeWorkers를 확인하므로 워커 등록 전엔 unhealthy.
    monitorType: UI_API

  # 부하 기반 라우팅 활성화 (§3-5 참고).
  # 기본 StochasticRoutingManager는 무작위 선택만 함 → 큐/실행 쿼리 수를 본
  # QueryCountBasedRouter로 교체.
  modules:
    - io.trino.gateway.ha.module.HaGatewayProviderModule
    - io.trino.gateway.ha.module.QueryCountBasedRouterProvider

  # 폼 인증 + admin 프리셋 사용자. ADMIN_USER 권한은 admin/user/api 모두 매칭.
  presetUsers:
    admin:
      password: ""      # 설치 시 --set으로 주입
      privileges: ADMIN_USER
  authentication:
    defaultType: form
    form:
      selfSignKeyPair:
        privateKeyRsa: /etc/trino-gateway/auth/privateKey.pem
        publicKeyRsa: /etc/trino-gateway/auth/publicKey.pem
  authorization:
    admin: (.*)ADMIN(.*)
    user: (.*)USER(.*)
    api: (.*)API(.*)

# RSA 키쌍 Secret 마운트 (사전 생성 필요)
volumes:
  - name: gateway-auth
    secret:
      secretName: trino-gateway-auth
volumeMounts:
  - name: gateway-auth
    mountPath: /etc/trino-gateway/auth
    readOnly: true

ingress:
  enabled: true
  className: nginx
  annotations:
    nginx.ingress.kubernetes.io/proxy-body-size: "0"
  hosts:
    - host: braveji-gw.trino.quantumcns.ai
      paths:
        - path: /
          pathType: Prefix
  tls: []   # 자체서명 cert-manager 연동은 후속 작업

resources:
  requests: { cpu: 250m, memory: 512Mi }
  limits:   { cpu: "1",  memory: 1Gi }

podDisruptionBudget:
  minAvailable: 0   # replicaCount=1이라 PDB 비활성화
```

### 2-3. RSA 키쌍 + Secret 준비

```bash
NS=user-braveji

# 키쌍 생성
openssl genrsa -out /tmp/gw-key.pem 2048
openssl rsa -in /tmp/gw-key.pem -pubout -out /tmp/gw-pub.pem

# K8s Secret으로 등록
kubectl -n $NS create secret generic trino-gateway-auth \
  --from-file=privateKey.pem=/tmp/gw-key.pem \
  --from-file=publicKey.pem=/tmp/gw-pub.pem \
  --dry-run=client -o yaml | kubectl apply -f -

# 안전 정리
rm -f /tmp/gw-key.pem /tmp/gw-pub.pem
```

### 2-4. 설치 + 백엔드 등록

```bash
NS=user-braveji

# (1) Gateway용 PostgreSQL
kubectl apply -n $NS -f manifests/trino-gateway/gateway-postgres.yaml
until [[ "$(kubectl -n $NS get cluster.postgresql.cnpg.io gateway-postgres \
            -o jsonpath='{.status.readyInstances}')" = "1" ]]; do sleep 5; done

# (2) Helm 설치 — DB/Admin 비밀번호를 --set으로 주입
DB_PW=$(kubectl -n $NS get secret gateway-postgres-app \
        -o jsonpath='{.data.password}' | base64 -d)
ADMIN_PW=$(openssl rand -base64 24 | tr -d '/+=' | head -c 20)
echo "Gateway admin password: $ADMIN_PW"   # 안전한 곳에 보관
# o9pVgrl0beLW4hDcgfrV

helm upgrade --install trino-gateway my-trino/trino-gateway \
  -n $NS \
  -f helm/trino-gateway-values.yaml \
  --set "config.dataStore.password=$DB_PW" \
  --set "config.presetUsers.admin.password=$ADMIN_PW" \
  --version 1.18.0 \
  --wait --timeout 5m

# (3) 기존 my-trino 클러스터를 백엔드로 등록 (관리 API)
# /gateway/backend/modify/* 는 ADMIN 권한 필요 → port-forward로 우회 (mesh 내부)
kubectl -n $NS port-forward svc/trino-gateway 18080:8080 >/dev/null 2>&1 &
sleep 3
curl -s -X POST http://localhost:18080/gateway/backend/modify/add \
  -H 'Content-Type: application/json' \
  -d '{
    "name": "my-trino",
    "proxyTo": "http://my-trino-trino:8080",
    "active": true,
    "routingGroup": "adhoc"
  }'
kill %1
```

### 2-5. 검증

```bash
# 외부에서 인증 없이 — 백엔드 목록 조회
curl http://braveji-gw.trino.quantumcns.ai/api/public/backends
# → [{"active":true,"routingGroup":"adhoc",
#     "externalUrl":"http://my-trino-trino:8080","name":"my-trino",
#     "proxyTo":"http://my-trino-trino:8080"}]

# Web UI
open http://braveji-gw.trino.quantumcns.ai/    # admin / $ADMIN_PW

# 백엔드 헬스체크 로그
kubectl -n user-braveji logs deploy/trino-gateway --tail=20 \
  | grep 'isHealthy'
# → "backend my-trino isHealthy HEALTHY"
```

### 2-6. 라우팅 그룹 활용 (옵션)

`X-Trino-Routing-Group` 헤더로 ETL/Adhoc 분리:

```bash
trino --server http://braveji-gw.trino.quantumcns.ai \
      --http-header "X-Trino-Routing-Group: etl" \
      --execute 'SELECT 1'
```

2개 이상 Trino helm release(`my-trino-adhoc`, `my-trino-etl`)를 띄워
routingGroup별로 분리하면 워크로드 격리 가능.

---

## 3. 알려진 함정 (실제 적용 중 마주친 것들)

### 3-1. `403 RBAC: access denied` — Istio sidecar 함정

**증상**: ingress로 어떤 경로(`/`, `/api/public/*`, `/login` 모두)를 호출해도
`403 RBAC: access denied`. 응답 헤더에 `x-envoy-decorator-operation:
trino-gateway.user-braveji.svc.cluster.local:8080/*` 가 보임.

**원인**: namespace에 `ns-owner-access-istio` AuthorizationPolicy가 걸려 있고,
chart 기본 설정으로는 sidecar(`istio-proxy`)가 자동 주입되어 외부 ingress
트래픽을 막음. `kubectl get pod`에서 `2/2 READY`가 단서 (chart 1.18은 본래
단일 컨테이너).

**해결**: values.yaml에
```yaml
podAnnotations:
  sidecar.istio.io/inject: "false"
```
추가 후 helm upgrade. Pod이 `1/1 READY`로 뜨면 OK.

### 3-2. `password`를 values.yaml에 평문 박지 말 것

chart는 `config.dataStore.password`를 그대로 ConfigMap/Secret에 렌더링.
`envFrom`이나 secretKeyRef 직접 지원 없음. 설치 시 `--set`으로 주입하고
values.yaml에는 빈 문자열만 두는 패턴 사용.

### 3-3. `/api/public/*` vs `/gateway/backend/modify/*`

전자는 **인증 불요** (백엔드 목록 조회용), 후자는 **ADMIN 권한 필요**
(백엔드 추가/변경). 외부에서 backend 등록은 안 되고 in-cluster
port-forward 또는 인증 토큰으로만 가능.

### 3-4. 헬스체크가 코디네이터 시작 중에도 HEALTHY 오판

**증상**: Trino 코디네이터가 아직 워커 등록을 끝내지 않은 상태인데도
Gateway가 백엔드를 HEALTHY로 표시하고 쿼리를 보냄. 사용자가 받는 응답은
`No nodes available` 또는 무한 QUEUED.

**원인**: chart 1.18 기본값 `clusterStatsConfiguration.monitorType: INFO_API`는
백엔드의 `/v1/info`에 HTTP 200만 떨어져도 healthy로 판정. `/v1/info`는
코디네이터 부팅 직후부터 200을 반환하지만 그 시점엔 워커가 아직 등록되지 않음.

**해결**: `monitorType`을 더 엄격한 값으로 변경.

| monitorType | 검사 방법 | 시작 중 오탐 차단 | 추가 설정 |
|---|---|---|---|
| `NOOP` | 항상 healthy | ❌ | — |
| `INFO_API` (기본) | `/v1/info` HTTP 200 + `starting` 필드 | ❌ 부분적 | — |
| `METRICS` | `/metrics`의 `trino_cluster_active_workers` 검사 | ✅ | JMX exporter (이 프로젝트는 [manifests/monitoring/trino-jmx-exporter-config.yaml](../manifests/monitoring/trino-jmx-exporter-config.yaml) 적용 완료) |
| `UI_API` | `/ui/api/cluster`의 `activeWorkers > 0` 검사 | ✅ **권장** | — |
| `JDBC` | 실제 `SELECT 1` 실행 | ✅ 가장 엄격 | `backendState.username/password` 필요 (현재 OAuth2 only라 추가 작업 큼) |

이 프로젝트는 `UI_API`가 비용 대비 효과 최선이라 §2-2 values.yaml 예시에 이미 반영됨.

검증:

```bash
# Trino 일부러 재시작해서 헬스체크 transition 관찰
kubectl -n user-braveji rollout restart deploy/my-trino-trino-coordinator
kubectl -n user-braveji logs deploy/trino-gateway -f | grep 'isHealthy\|backend my-trino'
# 정상 시퀀스:
#   backend my-trino isHealthy UNHEALTHY    ← 코디네이터 시작 중
#   backend my-trino isHealthy UNHEALTHY    ← 워커 0
#   backend my-trino isHealthy HEALTHY      ← 워커 등록 완료
```

폴링 주기 조정이 필요하면 동일 섹션에 `monitor.intervalMillis`(기본 60초) 등을
추가할 수 있지만, 본질적인 문제는 주기가 아니라 monitor type의 엄격함이었음.
주기를 너무 줄이면 백엔드 코디네이터에 불필요한 부하만 늘어남.

### 3-5. 기본 라우터는 부하를 안 본다 — 큐/실행 쿼리 수 무시

**증상**: 백엔드가 N개일 때 쿼리가 큐 길이/실행 쿼리 수와 상관없이 분산되어
한쪽 백엔드가 overload되는 동안 다른 백엔드는 idle. resource group queueing은
백엔드 안에서만 동작해서 Gateway 단의 분산이 깨지면 의미 없음.

**원인**: chart 1.18에 별도 `modules` 설정이 없으면 기본 `RoutingManager`가
`StochasticRoutingManager`로 바인딩됨. 이 클래스의 `selectBackend()` 구현은
다음 한 줄이 전부:

```java
int backendId = Math.abs(RANDOM.nextInt()) % backends.size();
return Optional.of(backends.get(backendId));
```

백엔드 stats(`queuedQueryCount`, `runningQueryCount` 등)를 일절 참조하지 않음.
이 클러스터의 `trino-gateway-configuration` Secret을 봐도 `modules` 블록 없음
→ 기본 무작위 라우팅이 동작 중.

GitHub 트래커 교차 검증:

| # | 상태 | 의미 |
|---|---|---|
| [#77](https://github.com/trinodb/trino-gateway/issues/77) "Routing based on queued and running queries" | closed | 무작위 라우팅 한계 인정 → `QueryCountBasedRouter` 도입 모티브 |
| [#801](https://github.com/trinodb/trino-gateway/issues/801) "Gateway-Level Query Queue" | open | "centralized traffic management 부재"가 한계로 인정됨 |
| [#702](https://github.com/trinodb/trino-gateway/issues/702) "Reformat Cache in RoutingManager" | open | stats 캐시 stale 이슈 |
| [#1029](https://github.com/trinodb/trino-gateway/issues/1029) "Update backendToStatus in-memory cache immediately" | open | 백엔드 상태 캐시 즉시 갱신 미구현 |

**해결**: chart values의 `config.modules`에 `QueryCountBasedRouterProvider` 추가
(이 프로젝트는 §2-2 values.yaml 예시에 이미 반영됨):

```yaml
config:
  modules:
    - io.trino.gateway.ha.module.HaGatewayProviderModule       # 기본
    - io.trino.gateway.ha.module.QueryCountBasedRouterProvider # 추가
```

`OptionalBinder.setBinding().to(QueryCountBasedRouter.class)` 패턴으로
`RoutingManager` 바인딩이 override되어 다음 우선순위로 백엔드 선택:

1. **userQueuedCount** — 사용자별 대기 쿼리 수가 가장 적은 백엔드
2. **queuedQueryCount** — (1)이 동률이면 클러스터 전체 대기 쿼리 수
3. **runningQueryCount** — (2)도 동률이면 실행 쿼리 수 (tiebreaker)

검증:

```bash
# 라우터 활성화 확인
kubectl -n user-braveji logs deploy/trino-gateway \
  | grep -i 'QueryCountBased\|RoutingManager' | head

# 부하 분산 동작 확인 (백엔드 N개 등록 후)
for i in $(seq 1 20); do
  trino --server http://braveji-gw.trino.quantumcns.ai \
        --execute 'SELECT 1' &
done
wait
# 각 백엔드 my-trino*의 query log를 비교 → 큐가 짧은 쪽으로 더 많이 갔는지
```

**남는 한계 (이걸로도 안 풀리는 부분)**:

1. **Stats refresh 주기 의존** — 백엔드 stats는 `monitorType` 폴링 주기(기본 60초)로
   갱신. 그 사이 들어오는 쿼리는 모두 stale 데이터 기반으로 라우팅 결정
   → 짧은 시간에 한 백엔드로 몰릴 수 있음.
2. **Optimistic local update** — Gateway가 라우팅 직후 in-memory에서 카운터를
   `+= 1`로 자체 추정. 백엔드 실제 처리(거부/실패/queued)와 다를 수 있음.
3. **Gateway-level queue 부재** — issue [#801](https://github.com/trinodb/trino-gateway/issues/801)
   open. 단일 백엔드 보호는 백엔드 자체의 Resource Groups soft/hard concurrency
   limit으로 보완 ([docs/05-resource-groups-quota.md](05-resource-groups-quota.md)).
4. **per-user 비교 한계** — userQueuedCount=0인 신규 사용자는 cluster-wide
   큐만 비교 → spike 시 hot user가 한 백엔드 점유.

---

## 4. 이 프로젝트와의 통합 체크리스트

- [ ] [scripts/install.sh](../scripts/install.sh)에 gateway-postgres / helm 단계 추가하거나,
      별도 `install-gateway.sh` 스크립트 분리 (기존 패턴 따라)
- [ ] [scripts/uninstall.sh](../scripts/uninstall.sh)에 helm uninstall + `gateway-postgres`
      Cluster + `trino-gateway-auth` Secret 삭제 추가
- [ ] **인증 통합**: 현재 OAuth2(Keycloak)가 백엔드 Trino에 직접 붙어 있음.
      Gateway 앞단 통합 시 Gateway에서 OAuth2 처리 (`config.authentication.defaultType: oauth`)
      후 토큰을 백엔드로 pass-through하는 구성 검증 필요.
      [docs/04-keycloak-oauth2.md](04-keycloak-oauth2.md) 와 충돌 가능성 있으니 별도 검증 단계 권장
- [ ] **OPA**: Gateway는 라우팅만 담당 — 권한 체크는 여전히 백엔드 Trino + OPA에서
      수행되므로 [scripts/setup-opa.sh](../scripts/setup-opa.sh)는 그대로 유지
- [ ] **Ingress 충돌 정리**: 기존 `braveji.trino.quantumcns.ai`가 my-trino를 직접 가리킴
      ([helm/values.yaml](../helm/values.yaml)). Gateway 도입 시 이 호스트를 Gateway로
      돌리고 백엔드 Trino는 ClusterIP만 노출하도록 정리 필요
- [ ] **TLS 활성화**: 현재 ingress `tls: []`. cert-manager + 기존 `trino-ca-issuer`
      재활용해서 `braveji-gw.trino.quantumcns.ai`에 서명서 발급 필요

---

## 5. blue/green 무중단 업그레이드 시나리오

Gateway의 핵심 가치 중 하나. 두 개의 Trino release를 띄워 두고 백엔드 active 토글로 전환:

```bash
NS=user-braveji

# 1) green release 신규 설치 (예: 새 chart 버전 / 새 Trino 버전)
helm install my-trino-green my-trino/trino -n $NS \
  -f helm/values.yaml --set image.tag=481-jmx

# 2) Gateway에 green 백엔드 추가 (active=false)
kubectl -n $NS port-forward svc/trino-gateway 18080:8080 >/dev/null 2>&1 &
sleep 3
curl -X POST http://localhost:18080/gateway/backend/modify/add \
  -H 'Content-Type: application/json' \
  -d '{"name":"my-trino-green","proxyTo":"http://my-trino-green-trino:8080",
       "active":false,"routingGroup":"adhoc"}'

# 3) 기존 쿼리 drain 후 토글 (blue → false, green → true)
curl -X POST http://localhost:18080/gateway/backend/modify/update \
  -H 'Content-Type: application/json' \
  -d '{"name":"my-trino","active":false}'
curl -X POST http://localhost:18080/gateway/backend/modify/update \
  -H 'Content-Type: application/json' \
  -d '{"name":"my-trino-green","active":true}'

# 4) blue 제거
helm uninstall my-trino -n $NS
kill %1
```

---

## 6. 추가 참조

- 공식 문서: <https://trinodb.github.io/trino-gateway/>
- Helm chart 소스: <https://github.com/trinodb/charts/tree/main/charts/gateway>
- 인증/인가 설정: <https://trinodb.github.io/trino-gateway/security/>
- 라우팅 규칙(파일/DB 기반, MVEL 표현식): 공식 문서 "Reference → Routing rules" 항목 참고
- 기존 OAuth2 통합 가이드: [docs/04-keycloak-oauth2.md](04-keycloak-oauth2.md)
