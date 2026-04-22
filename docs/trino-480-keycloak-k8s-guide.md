# Trino 480 + Keycloak OIDC 인증 연동 가이드 (Kubernetes)

> Kubernetes 환경에서 Trino 480을 배포하고 Keycloak을 OIDC(OAuth 2.0) Identity Provider로 사용하여 인증을 구성하는 Step-by-Step 가이드

---

## 목차

1. [개요 및 아키텍처](#1-개요-및-아키텍처)
2. [사전 준비 사항](#2-사전-준비-사항)
3. [Step 1 — Keycloak Realm 및 Client 설정](#step-1--keycloak-realm-및-client-설정)
4. [Step 2 — TLS 인증서 및 Shared Secret 준비](#step-2--tls-인증서-및-shared-secret-준비)
5. [Step 3 — Kubernetes Secret 생성](#step-3--kubernetes-secret-생성)
6. [Step 4 — Trino Helm values.yaml 작성](#step-4--trino-helm-valuesyaml-작성)
7. [Step 5 — Helm으로 Trino 배포](#step-5--helm으로-trino-배포)
8. [Step 6 — Ingress / Service 노출](#step-6--ingress--service-노출)
9. [Step 7 — 동작 검증](#step-7--동작-검증)
10. [Step 8 — CLI / JDBC 클라이언트 접속](#step-8--cli--jdbc-클라이언트-접속)
11. [User Mapping (선택)](#user-mapping-선택)
12. [Troubleshooting](#troubleshooting)
13. [참고 링크](#참고-링크)

---

## 1. 개요 및 아키텍처

### 1.1 인증 흐름 (Authorization Code Flow)

```
┌─────────┐   1) /ui 요청          ┌───────────────────┐
│ Browser │ ────────────────────► │ Trino Coordinator │
│         │ ◄──── 2) 302 Redirect │  (HTTPS :8443)    │
└─────────┘                       └───────────────────┘
     │                                      ▲
     │ 3) 로그인/동의                        │ 6) code → token 교환
     ▼                                      │
┌─────────────────┐                         │
│    Keycloak     │ ── 7) access/ID token ──┘
│ (Realm/Client)  │
└─────────────────┘
```

- **Trino Coordinator**에만 인증 설정을 적용합니다. Worker는 변경 불필요.
- OAuth 2.0 사용 시 **TLS(HTTPS)는 필수**이며, 클러스터 내부 통신용 **shared secret**도 반드시 필요합니다.
- Trino는 OIDC Discovery(`.well-known/openid-configuration`)를 통해 엔드포인트를 자동 탐색합니다.

### 1.2 주요 요구사항

| 항목 | 내용 |
|---|---|
| Trino 버전 | 480 |
| Helm Chart | `trino/trino` (v1.42.x 이상 권장) |
| Keycloak | 22+ (OIDC Discovery 지원 필수) |
| 필수 조건 | Coordinator HTTPS, Shared Secret, Keycloak Realm/Client |
| 인증 타입 | `OAUTH2` (OIDC discovery 자동) |

---

## 2. 사전 준비 사항

- 동작 중인 Kubernetes 클러스터 (1.26+ 권장)
- `kubectl`, `helm` 3.x CLI
- 외부에서 접근 가능한 Keycloak (예: `https://keycloak.example.com`)
- Trino Coordinator에 붙일 **DNS 이름** (예: `trino.example.com`)
  - Keycloak의 Redirect URI와 반드시 일치해야 함
- 유효한 TLS 인증서 (Let's Encrypt, 회사 CA 등)

---

## Step 1 — Keycloak Realm 및 Client 설정

### 1.1 Realm 생성 (필요 시)

Keycloak Admin Console 접속 → 좌측 상단 Realm 드롭다운 → **Create Realm**

- Name: `trino` (예시)

### 1.2 OIDC Client 생성

Clients → **Create client**

| 필드 | 값 |
|---|---|
| Client type | `OpenID Connect` |
| Client ID | `trino` |
| Name | `Trino Coordinator` |
| Client authentication | `On` (Confidential client) |
| Authorization | `Off` |
| Authentication flow | `Standard flow` 체크, `Direct access grants` 체크 해제 권장 |

**Valid redirect URIs**(중요):

```
https://trino.example.com/oauth2/callback
```

**Valid post logout redirect URIs**(Web UI 로그아웃용):

```
https://trino.example.com/ui/logout/logout.html
```

**Web origins**:

```
https://trino.example.com
```

### 1.3 Client Secret 확인

Client → **Credentials** 탭 → `Client secret` 값 복사.
이 값은 이후 Kubernetes Secret으로 관리합니다.

### 1.4 Refresh Token(선택, 권장)

Trino는 access token이 만료되면 refresh token으로 자동 갱신합니다.

- Realm settings → Tokens → `SSO Session Idle` / `SSO Session Max` 를 원하는 수명으로 설정
- Client → Advanced → `Client Session Idle` / `Client Session Max` 조정
- Trino 쪽에서는 `scopes`에 `offline_access` 추가 (Step 4 참조)

### 1.5 사용자 생성 및 username claim 설정

- Users → **Add user** 로 테스트 유저 생성, Credentials 탭에서 비밀번호 설정
- Client → **Client scopes** → `trino-dedicated` → **Add mapper** → `User Property`
  - Name: `username`
  - Property: `username`
  - Token Claim Name: `preferred_username` (기본값, 이미 있다면 그대로 둠)
  - Add to ID token / Access token / Userinfo: 모두 On

> 이 claim 이름(`preferred_username` 또는 `email` 등)은 Step 4의 `principal-field` 값과 반드시 일치해야 합니다.

### 1.6 OIDC Issuer URL 확인

Realm 설정 화면 우측 → **OpenID Endpoint Configuration** 링크 클릭.
`issuer` 값을 복사해 둡니다. 예:

```
https://keycloak.example.com/realms/trino
```

---

## Step 2 — TLS 인증서 및 Shared Secret 준비

### 2.1 TLS 인증서

Trino Coordinator는 HTTPS로 노출되어야 합니다. 두 가지 방식이 있습니다.

**(A) Ingress에서 TLS 종료 (권장)**

- `cert-manager` + `nginx-ingress` 조합이 가장 일반적
- Trino 내부는 HTTP로 두되, Ingress에서 HTTPS 종료 + X-Forwarded-Proto 전달
- `http-server.process-forwarded=true` 필수

**(B) Trino Coordinator 자체에서 TLS 종료**

- PKCS#12 keystore 파일을 Secret으로 마운트
- `http-server.https.enabled=true`, `http-server.https.keystore.path=...` 설정

본 가이드는 **(A) Ingress TLS termination** 방식을 기준으로 설명합니다.

### 2.2 Shared Secret 생성

Coordinator ↔ Worker 내부 인증용 공유 시크릿:

```bash
openssl rand 64 | base64 -w 0 > shared-secret.txt
```

---

## Step 3 — Kubernetes Secret 생성

네임스페이스 생성:

```bash
kubectl create namespace trino
```

Keycloak Client 자격증명 + Shared Secret을 Kubernetes Secret으로 저장:

```bash
kubectl -n trino create secret generic trino-oauth2 \
  --from-literal=CLIENT_ID='trino' \
  --from-literal=CLIENT_SECRET='<keycloak-client-secret-값>' \
  --from-literal=SHARED_SECRET="$(openssl rand 64 | base64 -w 0)"
```

확인:

```bash
kubectl -n trino get secret trino-oauth2 -o jsonpath='{.data}' | jq 'keys'
# ["CLIENT_ID", "CLIENT_SECRET", "SHARED_SECRET"]
```

---

## Step 4 — Trino Helm values.yaml 작성

Trino 공식 Helm chart(`trinodb/charts`)의 `additionalConfigProperties`, `coordinator.additionalEnvFrom`, `coordinatorExtraConfig` 등을 활용합니다.

`values.yaml`:

```yaml
image:
  tag: "480"

server:
  workers: 3

  config:
    # Ingress에서 TLS 종료하므로 HTTPS는 Trino에서 미사용
    https:
      enabled: false
    # X-Forwarded-* 헤더를 신뢰 (Ingress에서 전달)
    authenticationType: OAUTH2

  # 모든 노드(coordinator/worker)에 공통 적용
  additionalConfigProperties:
    - http-server.process-forwarded=true
    - internal-communication.shared-secret=${ENV:SHARED_SECRET}
    - web-ui.authentication.type=oauth2

  # Coordinator에만 적용될 OAuth2/OIDC 관련 설정
  coordinatorExtraConfig: |
    http-server.authentication.type=OAUTH2
    http-server.authentication.oauth2.issuer=https://keycloak.example.com/realms/trino
    http-server.authentication.oauth2.client-id=${ENV:CLIENT_ID}
    http-server.authentication.oauth2.client-secret=${ENV:CLIENT_SECRET}
    http-server.authentication.oauth2.principal-field=preferred_username
    http-server.authentication.oauth2.scopes=openid,email,profile,offline_access
    http-server.authentication.oauth2.oidc.discovery=true
    http-server.authentication.oauth2.oidc.use-userinfo-endpoint=false
    http-server.authentication.oauth2.refresh-tokens=true
    http-server.authentication.oauth2.user-mapping.pattern=(.*)

# 환경변수로 Secret 값을 주입 (모든 노드)
coordinator:
  envFrom:
    - secretRef:
        name: trino-oauth2
  jvm:
    maxHeapSize: "8G"

worker:
  envFrom:
    - secretRef:
        name: trino-oauth2
  jvm:
    maxHeapSize: "8G"

service:
  type: ClusterIP
  port: 8080

# Ingress는 별도 Step 6에서 설정하거나 여기에서 정의
ingress:
  enabled: false
```

### 4.1 주요 속성 설명

| 속성 | 역할 |
|---|---|
| `http-server.authentication.type=OAUTH2` | 인증 방식 OAuth 2.0으로 설정 |
| `...oauth2.issuer` | Keycloak Realm의 issuer URL (OIDC Discovery의 기준) |
| `...oauth2.client-id` / `client-secret` | Keycloak Client 자격증명 |
| `...oauth2.principal-field` | JWT의 어떤 claim을 Trino 사용자명으로 쓸지 지정 (기본 `sub`). Keycloak 사용자명 사용하려면 `preferred_username` 권장 |
| `...oauth2.scopes` | 요청 scope. `offline_access`는 refresh token용 |
| `...oidc.discovery=true` | `.well-known/openid-configuration`에서 엔드포인트 자동 수집 |
| `...oidc.use-userinfo-endpoint=false` | Keycloak이 JWT를 발급하므로 로컬 검증 사용. `true`로 두면 userinfo 조회 실패로 인증 실패 가능 |
| `...oauth2.refresh-tokens=true` | access token 만료 시 refresh token으로 자동 갱신 |
| `web-ui.authentication.type=oauth2` | Trino Web UI도 OAuth2로 인증 |
| `http-server.process-forwarded=true` | Ingress에서 TLS 종료 시 필수 |
| `internal-communication.shared-secret` | Coordinator ↔ Worker 인증용 |

> **주의**: `coordinatorExtraConfig` 내부에서 `${ENV:VAR}` 치환을 쓰려면, 해당 환경변수가 Coordinator 컨테이너에 반드시 주입되어야 합니다 (`coordinator.envFrom` 참조). `additionalConfigProperties`에 넣을 때도 동일합니다.

### 4.2 principal-field 결정 가이드

| 기준 | 값 |
|---|---|
| Keycloak 기본 username 사용 | `preferred_username` (가장 흔함) |
| 이메일로 식별 | `email` (Keycloak에서 email verified 필수 설정 권장) |
| 변경 불가능한 UUID | `sub` (기본값, 하지만 사람이 읽기 어려움) |

> 과거 버전에서는 기본값이 `sub`이어서 사용자명이 UUID로 보이는 문제가 자주 있었습니다. 명시적으로 `preferred_username` 지정이 권장됩니다.

---

## Step 5 — Helm으로 Trino 배포

Helm repo 추가:

```bash
helm repo add trino https://trinodb.github.io/charts
helm repo update
helm search repo trino/trino -l | head
```

설치:

```bash
helm upgrade --install trino trino/trino \
  --namespace trino \
  --version 1.42.1 \
  -f values.yaml
```

배포 확인:

```bash
kubectl -n trino get pods
kubectl -n trino logs -l app.kubernetes.io/component=coordinator --tail=200
```

정상 기동 시 로그에 아래와 유사한 라인이 보입니다:

```
======== SERVER STARTED ========
```

---

## Step 6 — Ingress / Service 노출

Coordinator를 외부 도메인으로 노출하고 TLS를 적용합니다. 예시는 nginx-ingress + cert-manager 기준.

`ingress.yaml`:

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: trino
  namespace: trino
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-prod
    nginx.ingress.kubernetes.io/backend-protocol: "HTTP"
    nginx.ingress.kubernetes.io/proxy-body-size: "0"
    nginx.ingress.kubernetes.io/proxy-buffer-size: "16k"
    # Trino는 큰 응답/긴 쿼리 고려 필요
    nginx.ingress.kubernetes.io/proxy-read-timeout: "3600"
    nginx.ingress.kubernetes.io/proxy-send-timeout: "3600"
spec:
  ingressClassName: nginx
  tls:
    - hosts:
        - trino.example.com
      secretName: trino-tls
  rules:
    - host: trino.example.com
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: trino
                port:
                  number: 8080
```

적용:

```bash
kubectl apply -f ingress.yaml
```

**필수 확인사항**:

- DNS `trino.example.com` → Ingress LB IP
- Keycloak Client의 Valid redirect URI가 `https://trino.example.com/oauth2/callback` 과 정확히 일치
- 인증서가 정상 발급되었는지 (`kubectl -n trino describe certificate trino-tls`)

---

## Step 7 — 동작 검증

### 7.1 Web UI 로그인

브라우저에서 `https://trino.example.com` 접속
→ Keycloak 로그인 페이지로 자동 리디렉션
→ 사용자 로그인 + 동의
→ Trino Web UI로 복귀하며 우측 상단에 사용자명 표시

### 7.2 로그로 확인

```bash
kubectl -n trino logs -l app.kubernetes.io/component=coordinator --tail=100 | grep -i oauth
```

정상 시:

- `OAuth2 discovery` 관련 로그에 issuer, endpoints 출력
- 로그인 후 `Authenticated user: <username>` 로그 확인

### 7.3 디버그 로깅 (필요 시)

`values.yaml`에 추가:

```yaml
server:
  additionalLogProperties:
    - io.trino.server.security.oauth2=DEBUG
    - io.trino.server.ui.OAuth2WebUiAuthenticationFilter=DEBUG
```

또는 Coordinator의 `etc/log.properties`에 동일 항목 추가 후 rollout.

---

## Step 8 — CLI / JDBC 클라이언트 접속

### 8.1 Trino CLI (external authentication)

```bash
trino \
  --server https://trino.example.com \
  --external-authentication
```

실행 시 브라우저가 열리고 Keycloak 로그인 → CLI 프롬프트로 복귀합니다.

### 8.2 JDBC URL

```
jdbc:trino://trino.example.com:443?SSL=true&externalAuthentication=true
```

DBeaver 등의 툴에서도 동일 옵션을 사용하면 팝업 브라우저로 Keycloak 인증이 진행됩니다.

### 8.3 자동화/서비스 계정 (주의)

**Trino OAuth2 인증은 Authorization Code Flow만 지원**합니다. Client Credentials Flow는 미지원이므로, 자동화 파이프라인에서는 아래 중 택1:

1. Keycloak에서 직접 JWT를 발급받아 **Trino JWT authentication**(별도 설정) 사용
2. `PASSWORD` 인증기를 추가로 구성하여 서비스 계정용으로 사용

예: 다중 인증 타입 동시 구성

```
http-server.authentication.type=OAUTH2,JWT
```

---

## User Mapping (선택)

Keycloak의 claim 값을 Trino 내부 사용자명으로 변환할 때 사용합니다.

### 예시 1: 이메일에서 로컬 파트만 추출

```
http-server.authentication.oauth2.principal-field=email
http-server.authentication.oauth2.user-mapping.pattern=([^@]+)@.*
```

→ `alice@example.com` 로그인 시 Trino 사용자명은 `alice`

### 예시 2: 파일 기반 매핑

ConfigMap으로 `user-mapping.json` 제공:

```json
{
  "rules": [
    {
      "pattern": "(.*)@example\\.com",
      "user": "$1"
    },
    {
      "pattern": "svc_(.*)",
      "user": "$1",
      "allow": true
    }
  ]
}
```

`values.yaml`:

```yaml
coordinator:
  additionalConfigFiles:
    user-mapping.json: |
      { "rules": [ ... ] }

server:
  coordinatorExtraConfig: |
    http-server.authentication.oauth2.user-mapping.file=/etc/trino/user-mapping.json
```

---

## Troubleshooting

| 증상 | 원인 / 해결 |
|---|---|
| `Invalid redirect_uri` (Keycloak) | Keycloak Client의 Valid redirect URIs가 `https://<host>/oauth2/callback`과 정확히 일치하는지 확인 (스킴/포트 포함) |
| 로그인 후 `401 Unauthorized` | `oidc.use-userinfo-endpoint=false` 설정 여부 확인. Keycloak은 JWT를 발급하므로 userinfo 호출 시 실패할 수 있음 |
| 사용자명이 UUID로 표시됨 | `principal-field=preferred_username` 명시 |
| Web UI에서 무한 리다이렉트 | `http-server.process-forwarded=true` 누락 또는 Ingress에서 `X-Forwarded-Proto` 전달 안 됨 |
| `Shared secret is required` | `internal-communication.shared-secret` 미설정. 모든 노드에 동일 값 주입 필요 |
| `coordinatorExtraConfig`의 `${ENV:VAR}` 치환 안됨 | Trino는 특정 속성에서만 ENV 치환을 허용. 공식적으로 `internal-communication.shared-secret`은 지원. `client-id/client-secret`은 최신 버전에서 지원되나, 안 될 경우 `additionalConfigFiles`로 secret을 파일 마운트하여 사용 |
| Access Denied: User X cannot impersonate user Y | `--user` 옵션이 principal과 다름. 동일하게 맞추거나 file-based system access control로 impersonation 허용 규칙 추가 |
| Refresh token 미동작 | Keycloak Client에 `offline_access` 동의 또는 `scopes`에 포함, 토큰 수명 설정 확인 |
| `discovery` 실패 | Coordinator Pod에서 Keycloak issuer URL로 HTTPS 접근 가능한지 확인 (`kubectl exec`로 `curl` 테스트), DNS/CoreDNS/Network Policy 점검 |
| 인증서 체인 오류 | Keycloak이 사설 CA면 Coordinator에 `cacerts`로 CA 등록 필요 (`JAVA_OPTS`/`-Djavax.net.ssl.trustStore`) |

### 디버그 체크리스트

```bash
# 1. Pod 로그
kubectl -n trino logs -l app.kubernetes.io/component=coordinator

# 2. 실제 주입된 config
kubectl -n trino exec deploy/trino-coordinator -- cat /etc/trino/config.properties

# 3. 환경변수
kubectl -n trino exec deploy/trino-coordinator -- env | grep -E 'CLIENT|SHARED'

# 4. Keycloak 연결 테스트
kubectl -n trino exec deploy/trino-coordinator -- \
  curl -sS https://keycloak.example.com/realms/trino/.well-known/openid-configuration | head
```

---

## 참고 링크

- Trino 480 OAuth 2.0 공식 문서: <https://trino.io/docs/current/security/oauth2.html>
- Trino Authentication Types: <https://trino.io/docs/current/security/authentication-types.html>
- Trino Helm Chart: <https://github.com/trinodb/charts>
- Trino Helm values reference: <https://github.com/trinodb/charts/blob/main/charts/trino/values.yaml>
- Keycloak OIDC 문서: <https://www.keycloak.org/docs/latest/server_admin/#_oidc>

---

> **Tip**: 운영 환경에서는 Keycloak Realm/Client 설정을 GitOps(ArgoCD + Keycloak Operator 혹은 Terraform `keycloak` provider)로 관리하고, Trino의 `values.yaml`은 환경별로 분리(dev/stg/prd)하여 CI/CD 파이프라인에서 동일 템플릿으로 배포하는 것을 권장합니다.
