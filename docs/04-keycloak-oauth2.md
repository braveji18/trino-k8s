# 3단계-A: Keycloak OAuth2/OIDC 인증

3단계(멀티테넌시)의 첫 번째 파트. Keycloak 설치 → Realm/Client 설정 → Trino OAuth2 연동.

> 3단계 전체 흐름과 다른 파트는 아래 참고:
> - **본 문서**: §0 현황 정리 + §1 Keycloak 인증
> - [05-resource-groups-quota.md](05-resource-groups-quota.md): §2 Resource Groups + §3 K8s Quota + §5 Session 제어
> - [06-ranger-monitoring.md](06-ranger-monitoring.md): §4 Ranger + §6 모니터링 + §7 검증 + §8 문서화

---

## 전체 흐름

```
[0. 현황 정리]        요구사항 확정 + 팀/사용자 매트릭스 작성
     │
[1. Keycloak 설치+연동] CNPG PG → Keycloak 배포 → Realm/Client 설정 → Trino OAuth2  ← 본 문서
     │
[2. Resource Groups]  Trino 내부 리소스 그룹 → ETL/분석가/BI별 동시 쿼리·메모리 한도
     │
[3. K8s Quota]        Namespace 레벨 ResourceQuota + LimitRange
     │
[4. Ranger 연동]      Apache Ranger로 카탈로그·스키마·테이블별 접근제어
     │
[5. Session 제어]     세션 프로퍼티 제한 → 사용자가 설정을 우회 못하도록
     │
[6. 테넌트별 모니터링]  Grafana에 사용자/그룹 차원 + 5초 SLA 알림
     │
[7. 검증]             멀티 사용자 시나리오 테스트 + SLA 경계 조건 확인
     │
[8. 문서화]           운영 가이드 + 사용자 온보딩 절차 정리
```

각 단계는 **독립 커밋 단위**로 진행. 인증 없이 권한 분리는 의미가 없으므로
1→2 순서는 반드시 지킬 것.

---

## 0. 현황 정리 — 사용자·워크로드 파악

### 현재 상태

| 항목 | 현재 | 목표 |
|---|---|---|
| 인증 | **Keycloak OAuth2/OIDC 완료** | ~~Keycloak OAuth2/OIDC~~ |
| 리소스 격리 | 없음 (모든 쿼리가 동일 풀) | ETL/분석가/BI별 Resource Group |
| 접근 제어 | 없음 (모든 카탈로그 전체 접근) | Apache Ranger |
| K8s Quota | 없음 | Namespace ResourceQuota |
| 모니터링 | 클러스터 전체 집계만 | 사용자/팀별 분리 뷰 + SLA 알림 |

### 요구사항 정리

1. **사용자/팀 목록**: 
   - 데이터 엔지니어팀 5명
   - 분석가팀  5명 
   - BI 도구 2개 
2. **팀별 워크로드 특성**:
   - 데이터 엔지니어팀은 ETL 작업으로 길고 무거움 작업
   - 분석가팀은 짧고 가벼운 작업 
   - BI 도구들은 통계성 쿼리를 실시간 요구
3. **SLA 요구**: 
   - 데이터 엔지니어팀은 안정성을 요구
   - 분석가팀과 BI 도구 빠른 성능 요구하고 5초 이내에 응답
4. **외부 인증 인프라**: 
   - 인증 : Keycloak
   - 인가 : Apache Ranger

### 팀/사용자 매트릭스

| 그룹 | 인원/수 | 워크로드 유형 | SLA | 카탈로그 접근 | 쓰기 권한 |
|---|---|---|---|---|---|
| **데이터 엔지니어** | 5명 | ETL 배치 (길고 무거움) | 안정성 (쿼리 실패 최소화) | hive, iceberg, postgresql | 전체 (DDL+DML) |
| **분석가** | 5명 | ad-hoc 탐색 (짧고 가벼움) | 5초 이내 응답 | hive, iceberg, postgresql, tpch | read-only |
| **BI 도구** | 2개 (서비스 계정) | 통계성 쿼리 (실시간) | 5초 이내 응답 | hive, iceberg, postgresql | read-only |
| **관리자** | 1~2명 | 모니터링, DDL | 없음 | 전체 | 전체 |

### Resource Group 설계 방향

```
root (클러스터 전체: 88GB, 50 concurrent)
├── etl        — 60% 메모리, 동시 5개, 큰 쿼리 안정 실행
├── interactive — 분석가+BI 묶음, 30% 메모리, 높은 동시성, 5초 SLA
│   ├── analyst   — 분석가 5명, 동시 15개
│   └── bi        — BI 도구 2개, 동시 20개, 최우선 스케줄링
├── admin      — 10% 메모리, 제한 완화
└── default    — 5% 메모리, 최소 리소스
```

> **핵심 결정**: 분석가와 BI를 `interactive` 하위 그룹으로 묶어 **5초 SLA 대상
> 그룹을 공동 관리**. ETL이 메모리를 점유해도 interactive 그룹의 softMemoryLimit이
> 별도이므로 BI/분석가 쿼리가 큐잉되지 않음.

---

## 1. Keycloak 설치 및 연동 — OAuth2/OIDC 인증

> **결정**: `user-braveji` namespace에 Keycloak을 직접 설치하고 Trino와 연동.
> 기존 스택과 동일한 패턴(CNPG backend, nginx Ingress, Istio sidecar OFF)을 따름.

### 1-0. Keycloak 설치 (`user-braveji` namespace)

#### 디렉토리 구조

```
manifests/keycloak/
├── keycloak-postgres.yaml    # CNPG Cluster (Keycloak DB backend)
├── keycloak-deployment.yaml  # Keycloak Deployment + Service
└── keycloak-ingress.yaml     # 외부 접근용 Ingress
```

#### Step 1 — Keycloak용 PostgreSQL (CNPG)

기존 `hms-postgres`, `analytics-postgres`와 동일한 CNPG 패턴.
POC 단계이므로 1 인스턴스, 백업 없음.

`manifests/keycloak/keycloak-postgres.yaml`:
```yaml
# Keycloak DB backend — CNPG Cluster
# 사전 요구: CNPG operator가 클러스터에 설치되어 있어야 함
---
apiVersion: v1
kind: Secret
metadata:
  name: keycloak-postgres-app
  labels:
    cnpg.io/cluster: keycloak-postgres
type: kubernetes.io/basic-auth
stringData:
  username: keycloak
  password: changeme-keycloak-pg       # 운영 시 반드시 변경
---
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: keycloak-postgres
spec:
  instances: 1                          # POC: 1 인스턴스. 운영 시 3으로 증설
  imageName: ghcr.io/cloudnative-pg/postgresql:16.4

  inheritedMetadata:
    annotations:
      sidecar.istio.io/inject: "false"  # 데이터 인프라 일괄 정책

  bootstrap:
    initdb:
      database: keycloak
      owner: keycloak
      secret:
        name: keycloak-postgres-app

  storage:
    size: 10Gi
    storageClass: qks-ceph-block

  resources:
    requests:
      cpu: "250m"
      memory: "512Mi"
    limits:
      cpu: "1"
      memory: "1Gi"
```

적용:
```bash
kubectl -n $NS apply -f manifests/keycloak/keycloak-postgres.yaml

# CNPG 클러스터가 Ready 상태가 될 때까지 대기
kubectl -n $NS get cluster keycloak-postgres -w
# 기대: Phase=Cluster in healthy state, instances=1/1

# 테스트 
kubectl -n $NS exec keycloak-postgres-1 -- psql -U postgres -c "SELECT datname FROM pg_database WHERE datname = 'keycloak';" -c "SELECT usename FROM pg_user WHERE usename = 'keycloak';"


kubectl -n $NS run pg-test --rm -i --restart=Never --image=postgres:16 -- psql "postgresql://keycloak:changeme-keycloak-pg@keycloak-postgres-rw:5432/keycloak" -c "SELECT 1 AS connection_ok;"

```

#### Step 2 — Keycloak Deployment + Service

`manifests/keycloak/keycloak-deployment.yaml`:
```yaml
# Keycloak 26.x — production mode, external DB
# CNPG가 keycloak-postgres-rw 서비스를 자동 생성함
---
apiVersion: v1
kind: Secret
metadata:
  name: keycloak-admin
type: Opaque
stringData:
  KC_BOOTSTRAP_ADMIN_USERNAME: admin
  KC_BOOTSTRAP_ADMIN_PASSWORD: changeme-keycloak-admin   # 운영 시 반드시 변경
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: keycloak
  labels:
    app: keycloak
spec:
  replicas: 1
  selector:
    matchLabels:
      app: keycloak
  template:
    metadata:
      labels:
        app: keycloak
      annotations:
        sidecar.istio.io/inject: "false"
    spec:
      containers:
        - name: keycloak
          image: quay.io/keycloak/keycloak:26.0
          args: ["start"]
          env:
            # 관리자 계정
            - name: KC_BOOTSTRAP_ADMIN_USERNAME
              valueFrom:
                secretKeyRef:
                  name: keycloak-admin
                  key: KC_BOOTSTRAP_ADMIN_USERNAME
            - name: KC_BOOTSTRAP_ADMIN_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: keycloak-admin
                  key: KC_BOOTSTRAP_ADMIN_PASSWORD
            # DB 연결 — CNPG 자동 생성 서비스 (keycloak-postgres-rw)
            - name: KC_DB
              value: postgres
            - name: KC_DB_URL
              value: jdbc:postgresql://keycloak-postgres-rw:5432/keycloak
            - name: KC_DB_USERNAME
              valueFrom:
                secretKeyRef:
                  name: keycloak-postgres-app
                  key: username
            - name: KC_DB_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: keycloak-postgres-app
                  key: password
            # 프록시 설정 — nginx-ingress 뒤에서 동작
            - name: KC_PROXY_HEADERS
              value: xforwarded
            # KC_HOSTNAME을 외부 URL로 고정 — 내부/외부 어디서 접근해도
            # 동일한 issuer(https://braveji-keycloak.trino.quantumcns.ai/realms/trino)를 반환.
            # KC_HOSTNAME_STRICT=false 방식은 Trino Java HTTP client가 OIDC discovery 시
            # 내부 issuer를 받아 JWT issuer 불일치를 일으키므로 사용 불가 (G21).
            - name: KC_HOSTNAME
              value: "https://braveji-keycloak.trino.quantumcns.ai"
            - name: KC_HTTP_ENABLED
              value: "true"
            # Health check 활성화
            - name: KC_HEALTH_ENABLED
              value: "true"
            - name: KC_METRICS_ENABLED
              value: "true"
          ports:
            - name: http
              containerPort: 8080
            - name: health
              containerPort: 9000
          readinessProbe:
            httpGet:
              path: /health/ready
              port: 9000
            initialDelaySeconds: 30
            periodSeconds: 10
          livenessProbe:
            httpGet:
              path: /health/live
              port: 9000
            initialDelaySeconds: 60
            periodSeconds: 30
          resources:
            requests:
              cpu: "500m"
              memory: "1Gi"
            limits:
              cpu: "2"
              memory: "2Gi"
---
apiVersion: v1
kind: Service
metadata:
  name: keycloak
  labels:
    app: keycloak
spec:
  type: ClusterIP
  selector:
    app: keycloak
  ports:
    - name: http
      port: 8080
      targetPort: 8080
```

적용:
```bash
kubectl -n $NS apply -f manifests/keycloak/keycloak-deployment.yaml

# Pod가 Running + Ready 될 때까지 대기
kubectl -n $NS get pod -l app=keycloak -w
# 기대: 1/1 Running

# 로그에서 시작 완료 확인
kubectl -n $NS logs -l app=keycloak --tail=20
# 기대: "Keycloak ... started in ..."
```

#### Step 3 — Keycloak Ingress

기존 Prometheus/Grafana Ingress와 동일한 패턴.
TLS는 외부 LB에서 termination — Ingress는 HTTP routing만 담당.

`manifests/keycloak/keycloak-ingress.yaml`:
```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: keycloak
  annotations:
    nginx.ingress.kubernetes.io/backend-protocol: "HTTP"
    nginx.ingress.kubernetes.io/proxy-body-size: "10m"
    nginx.ingress.kubernetes.io/proxy-read-timeout: "120"
    nginx.ingress.kubernetes.io/proxy-send-timeout: "120"
    # Keycloak은 큰 헤더(JWT 토큰)를 주고받으므로 버퍼 확대
    nginx.ingress.kubernetes.io/proxy-buffer-size: "128k"
    nginx.ingress.kubernetes.io/proxy-buffers-number: "4"
spec:
  ingressClassName: nginx
  rules:
    - host: braveji-keycloak.trino.quantumcns.ai
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: keycloak
                port:
                  number: 8080
```

적용:
```bash
kubectl -n $NS apply -f manifests/keycloak/keycloak-ingress.yaml

# Ingress 확인
kubectl -n $NS get ingress keycloak
# 기대: HOST = braveji-keycloak.trino.quantumcns.ai
```

#### Step 4 — 설치 검증

```bash
# (1) Keycloak Admin Console 접근 확인
curl -s -o /dev/null -w "%{http_code}" \
  https://braveji-keycloak.trino.quantumcns.ai/

# 기대: 200 또는 302 (로그인 페이지 리다이렉트)

# (2) 브라우저에서 Admin Console 로그인
#     https://braveji-keycloak.trino.quantumcns.ai/admin/
#     계정: admin / changeme-keycloak-admin

# (3) 리소스 사용 확인
kubectl -n $NS top pod -l app=keycloak
kubectl -n $NS top pod -l cnpg.io/cluster=keycloak-postgres
```

#### Step 5 — install-keycloak-ranger.sh 배포 스크립트

3단계(멀티테넌시) 컴포넌트를 별도 스크립트로 분리. 기존 `install.sh`(1단계 클러스터)와
독립적으로 실행 가능하며, 동일한 config.env를 공유.

```bash
./scripts/install-keycloak-ranger.sh              # config.env 기본값
NAMESPACE=foo ./scripts/install-keycloak-ranger.sh # override
```

스크립트: [scripts/install-keycloak-ranger.sh](../scripts/install-keycloak-ranger.sh)

#### 주의

- **배포 순서**: CNPG PostgreSQL → Keycloak Deployment 순서 필수 (DB가 먼저 올라와야 함)
- **Istio sidecar OFF**: Deployment와 CNPG Cluster 모두에 annotation 설정 필수
- **프록시 헤더**: `KC_PROXY_HEADERS=xforwarded` 설정 필수 — 없으면 Keycloak이
  리다이렉트 URL을 HTTP로 생성하여 mixed content 에러 발생 (Trino의 G3 함정과 동일 원인)
- **Keycloak 26.x**: `start` 명령이 production mode. dev mode는 `start-dev` (운영에서 사용 금지)
- **DNS**: `braveji-keycloak.trino.quantumcns.ai`가 외부 LB(115.71.7.200)로 해석되는지 확인.
  기존 `*.trino.quantumcns.ai` wildcard가 있으면 별도 설정 불필요.
- **리소스**: Keycloak + PG 추가로 namespace 내 memory ~3Gi 추가 사용.
  3단계 ResourceQuota 산정 시 반영 필요.

### 1-1. Keycloak Realm/Client/그룹 설정

스크립트: [scripts/setup-keycloak-realm.sh](../scripts/setup-keycloak-realm.sh)

```bash
./scripts/setup-keycloak-realm.sh
# 환경변수로 override 가능:
#   KEYCLOAK_URL=http://keycloak:8080  REALM_NAME=trino  DEFAULT_PASSWORD=changeme-user
```

스크립트가 수행하는 작업:

1. **Realm 생성**: `trino` (accessTokenLifespan=30분 — ETL 장시간 쿼리 대비)
2. **Client 생성**: `trino` (confidential, Standard Flow + Direct Access Grants)
   - Valid Redirect URIs: `https://braveji.trino.quantumcns.ai/*`
   - Web Origins: `https://braveji.trino.quantumcns.ai`
   - Service Accounts 활성화 (BI 도구용)
3. **Group Mapper 추가**: Client에 `groups` claim Protocol Mapper
   - Mapper Type: Group Membership
   - Token Claim Name: `groups`
   - Full group path: OFF (그룹 이름만)
4. **그룹 생성**: `trino-etl`, `trino-analyst`, `trino-bi`, `trino-admin`
5. **사용자 생성 + 그룹 배정** (팀/사용자 매트릭스 기반):

| 사용자 | 그룹 | 용도 |
|---|---|---|
| `etl_user1` ~ `etl_user5` | trino-etl | 데이터 엔지니어 5명 |
| `analyst_user1` ~ `analyst_user5` | trino-analyst | 분석가 5명 |
| `bi_superset`, `bi_redash` | trino-bi | BI 도구 서비스 계정 |
| `admin_trino` | trino-admin | 관리자 |

> 사용자 이름에 접두사 규칙(`etl_`, `analyst_`, `bi_`, `admin_`)을 적용하여
> Resource Group selector와 Ranger 정책에서 일관된 매핑이 가능하도록 함 (§2-5 참고).

스크립트 완료 후 출력되는 **Client Secret**을 §1-2에서 사용.

### 1-2. Helm values 반영

**변경 포인트 3개소** ([helm/values.yaml](../helm/values.yaml)):

#### (1) authenticationType + coordinatorExtraConfig

OAuth2 세부 속성은 **coordinator 전용**. `additionalConfigProperties`에 넣으면
worker에도 적용되어 worker startup이 실패함 → `coordinatorExtraConfig` 사용.

```yaml
server:
  config:
    authenticationType: "OAUTH2"
  # OAuth2 세부 설정 — coordinator 전용 (worker에 들어가면 startup 실패)
  # KC_HOSTNAME=https://braveji-keycloak.trino.quantumcns.ai 로 Keycloak이
  # 내부/외부 동일 issuer 반환. OIDC discovery 비활성화 (G21: TLS wildcard 불일치).
  coordinatorExtraConfig: |
    http-server.authentication.oauth2.issuer=https://braveji-keycloak.trino.quantumcns.ai/realms/trino
    http-server.authentication.oauth2.oidc.discovery=false
    http-server.authentication.oauth2.client-id=trino
    http-server.authentication.oauth2.client-secret=${ENV:OAUTH2_CLIENT_SECRET}
    http-server.authentication.oauth2.scopes=openid,profile
    http-server.authentication.oauth2.principal-field=preferred_username
    http-server.authentication.oauth2.auth-url=https://braveji-keycloak.trino.quantumcns.ai/realms/trino/protocol/openid-connect/auth
    http-server.authentication.oauth2.token-url=http://keycloak:8080/realms/trino/protocol/openid-connect/token
    http-server.authentication.oauth2.jwks-url=http://keycloak:8080/realms/trino/protocol/openid-connect/certs
    http-server.authentication.oauth2.userinfo-url=http://keycloak:8080/realms/trino/protocol/openid-connect/userinfo
    web-ui.enabled=true
    web-ui.authentication.type=OAUTH2
    http-server.authentication.allow-insecure-over-http=true
```

> **핵심**:
> - `issuer`를 외부 HTTPS URL로 설정 — KC_HOSTNAME 덕분에 JWT issuer와 일치
> - `oidc.discovery=false` — 외부 URL의 TLS 인증서 wildcard(*.quantumcns.ai)가
>   sub-sub-domain(*.trino.quantumcns.ai)과 매치되지 않아 Java TLS 검증 실패하므로 비활성화
> - `auth-url`만 외부 HTTPS (브라우저 리다이렉트용), `token-url`/`jwks-url`/`userinfo-url`은
>   내부 HTTP (서버간 통신, TLS 불필요)
> - `web-ui.enabled=true` 필수 — HTTP 환경에서 Trino가 Web UI를 기본 비활성화하므로

#### (2) internal-communication.shared-secret

인증 활성화 시 coordinator↔worker 내부 통신에 **반드시 필요**.
없으면 `Shared secret is required when authentication is enabled` 에러로 시작 불가.

```yaml
additionalConfigProperties:
  # ... 기존 설정 유지 ...
  - internal-communication.shared-secret=<openssl rand -base64 32 로 생성>
```

#### (3) envFrom — OAuth2 Client Secret 환경변수 주입

chart의 글로벌 `envFrom`으로 Secret을 모든 Pod에 주입.
`coordinator.additionalEnv`가 아닌 최상위 `envFrom` 사용 (chart 구조 제약).

```yaml
envFrom:
  - secretRef:
      name: trino-oauth2
```

Client Secret은 K8s Secret으로 관리:
```bash
kubectl -n $NS create secret generic trino-oauth2 \
  --from-literal=OAUTH2_CLIENT_SECRET='<setup-keycloak-realm.sh 출력의 Client Secret>' \
  --dry-run=client -o yaml | kubectl apply -f -
```

적용:
```bash
./scripts/install.sh    # helm upgrade 포함
```

### 1-3. JDBC/CLI 접근 — 서비스 계정 (BI 도구용)

BI 도구는 OAuth2 브라우저 플로우를 쓸 수 없으므로 **Direct Access Grant** 사용.
`KC_HOSTNAME=https://braveji-keycloak.trino.quantumcns.ai` 설정 덕분에 내부/외부
어디서 토큰을 발급해도 issuer가 `https://braveji-keycloak.trino.quantumcns.ai/realms/trino`로
동일. 클러스터 내부 URL(`http://keycloak:8080`)로 발급하는 것이 네트워크상 간단.

```bash
NS=user-braveji

# Direct Access Grant로 토큰 획득 (클러스터 내부)
TOKEN=$(kubectl -n $NS run kc-tok --rm -i --restart=Never \
  --overrides='{"metadata":{"annotations":{"sidecar.istio.io/inject":"false"}}}' \
  --image=curlimages/curl:8.5.0 -- \
  curl -s -X POST "http://keycloak:8080/realms/trino/protocol/openid-connect/token" \
  -d "grant_type=password" -d "client_id=trino" \
  -d "client_secret=<CLIENT_SECRET>" \
  -d "username=bi_superset" -d "password=changeme-user" \
  2>/dev/null | grep -o '"access_token":"[^"]*"' | cut -d'"' -f4)

# coordinator REST API로 쿼리 (Trino CLI는 HTTP에서 token 전송 거부)
kubectl -n $NS exec deploy/my-trino-trino-coordinator -- \
  curl -s -X POST http://localhost:8080/v1/statement \
  -H "Authorization: Bearer $TOKEN" \
  -H "X-Trino-User: bi_superset" \
  -d "SELECT current_user"
```

JDBC 연결 (BI 도구 설정 — 외부 HTTPS):
```
jdbc:trino://braveji.trino.quantumcns.ai:443?SSL=true
  &accessToken=<TOKEN>
```

> **주의**:
> - `KC_HOSTNAME` 설정으로 내부/외부 어디서 발급해도 issuer는 항상
>   `https://braveji-keycloak.trino.quantumcns.ai/realms/trino` — Trino의 issuer 설정과 일치.
> - Direct Access Grant는 Keycloak에서 비권장 추세. 장기적으로는 Service Account
>   (Client Credentials Grant) + Trino의 `HEADER` 인증 조합 검토.

### 1-4. (참고) Password file 방식 — Keycloak 없이 인증만 필요할 때

> Keycloak OAuth2 연동이 완료되었으므로 이 방식은 현재 사용하지 않음.
> Keycloak이 불가한 환경에서의 대체 방안으로 참고용으로 남김.

```yaml
server:
  config:
    authenticationType: "PASSWORD"
  coordinatorExtraConfig: |
    password-authenticator.name=file
    file.password-file=/etc/trino/password.db
```

### 1-5. 검증

```bash
NS=user-braveji

# (1) 인증 없이 coordinator 내부에서 쿼리 → 403 거부 확인
kubectl -n $NS exec deploy/my-trino-trino-coordinator -- \
  trino --execute "SELECT 1"
# 기대: Error 403 Forbidden: Authentication over HTTP is not enabled

# (2) 토큰 발급 (내부 서비스 경유)
TOKEN=$(kubectl -n $NS run kc-tok --rm -i --restart=Never \
  --overrides='{"metadata":{"annotations":{"sidecar.istio.io/inject":"false"}}}' \
  --image=curlimages/curl:8.5.0 -- \
  curl -s -X POST "http://keycloak:8080/realms/trino/protocol/openid-connect/token" \
  -d "grant_type=password" -d "client_id=trino" \
  -d "client_secret=<CLIENT_SECRET>" \
  -d "username=admin_trino" -d "password=changeme-user" \
  2>/dev/null | grep -o '"access_token":"[^"]*"' | cut -d'"' -f4)

# (3) REST API로 current_user 확인 (Trino CLI는 HTTP에서 access token 전송 거부)
kubectl -n $NS exec deploy/my-trino-trino-coordinator -- \
  curl -s -X POST http://localhost:8080/v1/statement \
  -H "Authorization: Bearer $TOKEN" \
  -H "X-Trino-User: admin_trino" \
  -d "SELECT current_user"
# 기대: queryId 발급 + state=QUEUED → data=[["admin_trino"]]

# (4) 각 사용자별 인증 확인
for user in etl_user1 analyst_user1 bi_superset; do
  TOKEN=$(... 동일 방식으로 발급)
  # REST API로 current_user 확인
done
```

### 주의 — 구현 중 발견한 함정

- **G14. `internal-communication.shared-secret` 필수**: OAuth2 인증 활성화 시
  coordinator↔worker 내부 통신에 shared secret이 반드시 필요. 없으면
  `Shared secret is required when authentication is enabled`으로 시작 불가.

- **G15. OAuth2 속성은 coordinator 전용**: `additionalConfigProperties`에 넣으면
  coordinator와 worker 모두에 적용됨. Worker에 OAuth2 속성이 들어가면
  `Configuration property was not used` 에러로 시작 불가. → `coordinatorExtraConfig` 사용.

- **G16. KC_HOSTNAME에는 전체 URL 필수**: `KC_HOSTNAME=braveji-keycloak.trino.quantumcns.ai`
  (hostname만)으로 설정하면 내부 접근 시 `http://braveji-keycloak.trino.quantumcns.ai:8080/realms/trino`이
  issuer가 되어 scheme/port 불일치. → `KC_HOSTNAME=https://braveji-keycloak.trino.quantumcns.ai`로
  전체 URL을 지정해야 내부/외부 어디서든 동일한 issuer 반환.

- **G17. Trino CLI의 HTTP access token 거부**: Trino CLI는 보안상 HTTP에서
  `--access-token` 전송을 거부 (`TLS/SSL required for authentication using an access token`).
  coordinator 내부 테스트는 `curl` REST API로 수행. 외부 HTTPS에서는 CLI 정상 동작.

- **G18. Keycloak 26.x 프로필 정책**: 사용자 생성 시 `firstName`/`lastName`/`email`이
  없으면 `Account is not fully set up` 에러로 토큰 발급 실패. 사용자 생성 API에
  프로필 필드를 반드시 포함.

- **G19. bash `GROUPS` 예약어**: bash에서 `GROUPS`는 현재 사용자의 GID 목록을 담는
  내장 변수. 스크립트에서 그룹 배열 이름으로 사용하면 시스템 GID가 들어감.
  → `KC_GROUPS`로 변경.

- **G20. 브라우저 리다이렉트가 내부 URL로 빠짐**: OIDC discovery 비활성화 시
  `auth-url`을 명시하지 않으면 브라우저가 접근 불가한 내부 URL로 리다이렉트됨.
  → `auth-url`을 외부 HTTPS URL로 명시, `token-url`/`jwks-url`은 내부 URL 유지.

- **G21. OIDC discovery와 TLS wildcard 불일치**: 외부 LB의 TLS 인증서가
  `*.quantumcns.ai` 와일드카드인데, Keycloak 도메인이 `braveji-keycloak.trino.quantumcns.ai`
  (sub-sub-domain)이라 Java TLS hostname 검증 실패. curl은 `-k`로 우회 가능하지만
  Trino의 Java HTTP client는 엄격하게 검증. → `oidc.discovery=false`로 OIDC discovery를
  비활성화하고 모든 endpoint URL을 수동 지정. OIDC discovery property 이름은
  `http-server.authentication.oauth2.oidc.discovery` (`.`으로 구분, `-` 아님).

- **G22. web-ui.enabled=true 필수**: HTTP 환경(Ingress 뒤)에서 Trino는 Web UI를
  기본 비활성화. `web-ui.authentication.type=OAUTH2`만으로는 부족하고
  `web-ui.enabled=true`를 명시해야 함. 없으면 로그인 성공 후 `disabled.html` 페이지 표시.

- `http-server.process-forwarded=true`는 반드시 유지 (G3 함정 참고)
- `allow-insecure-over-http=true` 필수 — Ingress 뒤 HTTP 환경에서 인증 동작에 필요
- 토큰 만료 시간은 Realm 설정에서 `accessTokenLifespan=1800`(30분)으로 조정 완료

---

## 진행 체크리스트 (본 문서 범위)

- [x] 0. 사용자/팀/워크로드 현황 조사 + 요구사항 확정
- [x] 1-0a. Keycloak용 CNPG PostgreSQL 배포 (`manifests/keycloak/keycloak-postgres.yaml`)
- [x] 1-0b. Keycloak Deployment + Service 배포 (`manifests/keycloak/keycloak-deployment.yaml`)
- [x] 1-0c. Keycloak Ingress 배포 + Admin Console 접근 확인
- [x] 1-0d. install-keycloak-ranger.sh 배포 스크립트 작성
- [x] 1-a. Keycloak Realm/Client/그룹 설정 (`scripts/setup-keycloak-realm.sh`)
- [x] 1-b. Trino OAuth2 연동 + Helm values 반영 (KC_HOSTNAME + oidc.discovery=false + coordinatorExtraConfig)
- [x] 1-c. BI 도구용 서비스 계정 + 토큰 발급 절차 확립
- [x] 1-d. 인증 검증 (T1: 401 거부, T2: REST API current_user, 브라우저 OAuth2 로그인 → Web UI)
