# 3단계: Resource Quota / Multi-tenancy 설계 — 진행 순서

2단계에서 단일 사용자 기준 성능을 확보했다면, 3단계는 **"여러 사용자/팀이 같은
클러스터를 안전하게 공유"**하는 것. 인증 → 리소스 격리 → 권한 분리 → 모니터링의
순서로 진행.

**핵심 원칙**: 한 사용자의 대형 쿼리가 다른 사용자의 쿼리를 밀어내지 못하도록
리소스 경계를 만들고, 카탈로그/스키마 단위로 접근을 제어.

---

## 전체 흐름

```
[0. 현황 정리]        요구사항 확정 + 팀/사용자 매트릭스 작성
     │
[1. Keycloak 설치+연동] CNPG PG → Keycloak 배포 → Realm/Client 설정 → Trino OAuth2
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
| 인증 | 없음 (anonymous) | Keycloak OAuth2/OIDC |
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
  KEYCLOAK_ADMIN: admin
  KEYCLOAK_ADMIN_PASSWORD: changeme-keycloak-admin   # 운영 시 반드시 변경
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
            - name: KEYCLOAK_ADMIN
              valueFrom:
                secretKeyRef:
                  name: keycloak-admin
                  key: KEYCLOAK_ADMIN
            - name: KEYCLOAK_ADMIN_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: keycloak-admin
                  key: KEYCLOAK_ADMIN_PASSWORD
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
            - name: KC_HOSTNAME
              value: braveji-keycloak.trino.quantumcns.ai
            - name: KC_HOSTNAME_STRICT
              value: "false"
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

#### Step 5 — install.sh에 Keycloak 단계 추가

[scripts/install.sh](../scripts/install.sh)에 Keycloak 설치 단계를 추가하여
전체 스택과 함께 멱등 배포 가능하게:

```bash
# ── 6. Keycloak (인증) ──────────────────────────────────
echo "▶ [6/7] Keycloak PostgreSQL + Keycloak 배포"
kubectl -n "$NS" apply -f manifests/keycloak/keycloak-postgres.yaml
echo "  ⏳ keycloak-postgres Ready 대기..."
kubectl -n "$NS" wait cluster/keycloak-postgres \
  --for=condition=Ready --timeout=300s 2>/dev/null || true
kubectl -n "$NS" apply -f manifests/keycloak/keycloak-deployment.yaml
kubectl -n "$NS" apply -f manifests/keycloak/keycloak-ingress.yaml
echo "  ⏳ Keycloak Pod Ready 대기..."
kubectl -n "$NS" wait deployment/keycloak \
  --for=condition=Available --timeout=300s
echo "  ✅ Keycloak: https://braveji-keycloak.trino.quantumcns.ai/"
```

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

1. **Realm 생성** (또는 기존 realm 사용)
2. **Client 생성**: `trino` (confidential, Standard Flow + Direct Access Grants)
   - Valid Redirect URIs: `https://braveji.trino.quantumcns.ai/*`
   - Web Origins: `https://braveji.trino.quantumcns.ai`
3. **그룹 생성**: `trino-etl`, `trino-analyst`, `trino-bi`, `trino-admin`
4. **사용자 할당**: 각 사용자를 해당 그룹에 배정
5. **Group Mapper 추가**: Client Scope에 `groups` claim 매핑
   - Mapper Type: Group Membership
   - Token Claim Name: `groups`
   - Full group path: OFF (그룹 이름만)

### 1-2. Helm values 반영

```yaml
server:
  config:
    authenticationType: "OAUTH2"

additionalConfigProperties:
  # 기존 설정 유지
  - http-server.process-forwarded=true
  - query.max-memory=88GB
  # ... (기존 spill 설정 등)
  
  # OAuth2/OIDC 인증
  - http-server.authentication.type=OAUTH2
  - http-server.authentication.oauth2.issuer=https://<KEYCLOAK_HOST>/realms/<REALM>
  - http-server.authentication.oauth2.client-id=trino
  - http-server.authentication.oauth2.client-secret=${ENV:OAUTH2_CLIENT_SECRET}
  - http-server.authentication.oauth2.scopes=openid,profile
  - http-server.authentication.oauth2.principal-field=preferred_username
  # groups claim을 Trino group으로 매핑
  - http-server.authentication.oauth2.groups-field=groups
```

Client Secret은 K8s Secret으로 관리:
```bash
kubectl -n $NS create secret generic trino-oauth2 \
  --from-literal=OAUTH2_CLIENT_SECRET='<keycloak-client-secret>' \
  --dry-run=client -o yaml | kubectl apply -f -
```

Coordinator에 환경변수 주입:
```yaml
coordinator:
  additionalEnv:
    - name: OAUTH2_CLIENT_SECRET
      valueFrom:
        secretKeyRef:
          name: trino-oauth2
          key: OAUTH2_CLIENT_SECRET
```

### 1-3. JDBC/CLI 접근 — 서비스 계정 (BI 도구용)

BI 도구는 OAuth2 브라우저 플로우를 쓸 수 없으므로 **서비스 계정** 또는
**Direct Access Grant (Resource Owner Password)** 사용:

```bash
# Direct Access Grant로 토큰 획득
TOKEN=$(curl -s -X POST \
  "https://<KEYCLOAK_HOST>/realms/<REALM>/protocol/openid-connect/token" \
  -d "grant_type=password" \
  -d "client_id=trino" \
  -d "client_secret=<secret>" \
  -d "username=bi_superset" \
  -d "password=<password>" \
  | jq -r '.access_token')

# Trino CLI에서 사용
trino --server https://braveji.trino.quantumcns.ai \
  --access-token "$TOKEN" \
  --execute "SELECT current_user"
```

JDBC 연결 (BI 도구 설정):
```
jdbc:trino://braveji.trino.quantumcns.ai:443?SSL=true
  &accessToken=<TOKEN>
```

> **주의**: Direct Access Grant는 Keycloak에서 비권장 추세. 장기적으로는
> Service Account (Client Credentials Grant) + Trino의 `HEADER` 인증 조합이나,
> BI 도구가 OAuth2 플로우를 직접 지원하는 경우 그쪽을 사용.

### 1-4. (대체) Password file 방식 — Keycloak 연동 전 임시

Keycloak 연동에 시간이 걸리면, 우선 password file로 동작만 검증하고 전환 가능:

```yaml
server:
  config:
    authenticationType: "PASSWORD"

additionalConfigProperties:
  - http-server.authentication.type=PASSWORD
  - password-authenticator.name=file
  - file.password-file=/etc/trino/password.db
```

```bash
# 팀별 테스트 계정 생성
htpasswd -Bbn etl_user1  '<password>' >> password.db
htpasswd -Bbn analyst1   '<password>' >> password.db
htpasswd -Bbn bi_superset '<password>' >> password.db
htpasswd -Bbn admin       '<password>' >> password.db

kubectl -n $NS create secret generic trino-password-db \
  --from-file=password.db --dry-run=client -o yaml | kubectl apply -f -
```

> Password file은 Keycloak 연동 완료 후 제거. 두 방식을 동시에 쓰려면
> `http-server.authentication.type=OAUTH2,PASSWORD` (쉼표 구분)로 다중 인증 가능.

### 1-5. 검증

```bash
# (1) 인증 없이 접속 → 401 또는 OAuth2 리다이렉트 확인
curl -s -o /dev/null -w "%{http_code}" \
  https://braveji.trino.quantumcns.ai/v1/info

# (2) 브라우저에서 Trino Web UI 접속 → Keycloak 로그인 페이지 리다이렉트 확인
#     https://braveji.trino.quantumcns.ai/ui/

# (3) 토큰으로 CLI 접속
trino --server https://braveji.trino.quantumcns.ai \
  --access-token "$TOKEN" \
  --execute "SELECT current_user"
# 기대: Keycloak 사용자 이름 반환

# (4) 그룹 매핑 확인 (Trino 480+)
trino --server https://braveji.trino.quantumcns.ai \
  --access-token "$TOKEN" \
  --execute "SELECT current_groups()"
# 기대: ['trino-etl'] 또는 ['trino-analyst'] 등
```

### 주의

- TLS는 이미 Ingress에서 termination → Trino 자체에 TLS 설정 불필요
- `http-server.process-forwarded=true`는 반드시 유지 (G3 함정 참고)
- Keycloak의 issuer URL이 Trino coordinator에서 접근 가능해야 함
  (내부 DNS 또는 네트워크 정책 확인)
- 토큰 만료 시간(default 5분)이 ETL 장시간 쿼리에 충분한지 확인 →
  Keycloak에서 access token lifespan을 30분~1시간으로 조정 고려
- BI 도구는 토큰 갱신(refresh token) 로직이 내장된지 확인 필요

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
> 제한하는 것이 보완책 (5단계에서 다룸).

### 2-4. Helm values 반영

```yaml
additionalConfigProperties:
  # ... 기존 설정 유지 ...
  - resource-groups.configuration-manager=file
  - resource-groups.config-file=/etc/trino/resource-groups.json

coordinator:
  additionalVolumes:
    # ... 기존 volume 유지 ...
    - name: resource-groups
      configMap:
        name: trino-resource-groups
  additionalVolumeMounts:
    # ... 기존 mount 유지 ...
    - name: resource-groups
      mountPath: /etc/trino/resource-groups.json
      subPath: resource-groups.json
      readOnly: true
```

ConfigMap 생성:
```bash
kubectl -n $NS create configmap trino-resource-groups \
  --from-file=resource-groups.json=manifests/trino/resource-groups.json \
  --dry-run=client -o yaml | kubectl apply -f -
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
-- Resource Group 상태 확인
SELECT
  resource_group_id,
  running_queries,
  queued_queries,
  soft_memory_limit,
  hard_concurrency_limit
FROM system.runtime.resource_group_state;

-- 특정 사용자 그룹 배정 확인 (etl_user1로 접속 후)
SELECT query_id, "user", resource_group_id, state
FROM system.runtime.queries
WHERE state IN ('RUNNING', 'QUEUED')
ORDER BY created DESC;
```

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

- `docs/05-multitenancy-results.md`에 각 단계 적용 결과 + 테스트 결과 기록
- 발견된 함정이 있으면 01 문서의 Gotchas 목록에 추가

---

## 진행 체크리스트

- [x] 0. 사용자/팀/워크로드 현황 조사 + 요구사항 확정
- [ ] 1-0a. Keycloak용 CNPG PostgreSQL 배포 (`manifests/keycloak/keycloak-postgres.yaml`)
- [ ] 1-0b. Keycloak Deployment + Service 배포 (`manifests/keycloak/keycloak-deployment.yaml`)
- [ ] 1-0c. Keycloak Ingress 배포 + Admin Console 접근 확인
- [ ] 1-0d. install.sh에 Keycloak 단계 추가
- [ ] 1-a. Keycloak Realm/Client/그룹 설정
- [ ] 1-b. Trino OAuth2 연동 + Helm values 반영
- [ ] 1-c. BI 도구용 서비스 계정 + 토큰 발급 절차 확립
- [ ] 1-d. 인증 검증 (T1~T2)
- [ ] 2-a. resource-groups.json 작성 (etl/interactive.analyst/interactive.bi/admin/default)
- [ ] 2-b. ConfigMap + Helm values 반영 + coordinator 재배포
- [ ] 2-c. Resource Group 배정 검증
- [ ] 3. K8s ResourceQuota + LimitRange 적용
- [ ] 4-a. Ranger Admin에 Trino 서비스 등록
- [ ] 4-b. Ranger Trino Plugin 설치 (커스텀 이미지 빌드)
- [ ] 4-c. Ranger 정책 5개 생성
- [ ] 4-d. 접근제어 검증 (T3~T5) + 감사 로그 확인 (T12)
- [ ] 5. Session Property 제한 + 그룹별 쿼리 시간 제한
- [ ] 6-a. JMX Exporter에 resource group rule 추가
- [ ] 6-b. Grafana 멀티테넌시 대시보드 패널 추가
- [ ] 6-c. 알림 규칙 설정 (큐 포화, SLA 위반)
- [ ] 7. 전체 시나리오 테스트 (T1~T12) + SLA 전용 테스트
- [ ] 8. 운영 가이드 + 사용자 온보딩 문서 작성
