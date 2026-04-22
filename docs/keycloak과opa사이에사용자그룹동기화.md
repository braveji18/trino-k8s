# Keycloak ↔ OPA 사용자 그룹 동기화 — 대안과 권장 방안

[06-opa-monitoring.md §4-6](06-opa-monitoring.md)에 적힌 대로 Trino 480 OAuth2 모듈이
JWT의 `groups` claim을 자동으로 identity에 못 넣고, chart 1.42는 file group
provider 마운트가 충돌합니다. 본 문서는 이 문제의 6가지 대안을 비교하고,
LDAP 통합이 실제로 해결책이 되는지를 분석합니다.

---

## 1. 문제 요약

### 1-1. 무엇이 안 되는가
- Trino 480 OAuth2 모듈의 `principal-field`만 설정 가능, `groups-field` 미지원
- 결과: OPA decision log의 `input.context.identity.groups`가 항상 `[]`
- 정식 해결책(file/ldap/http group provider)은 `etc/group-provider.properties` 자동 로드 필요
- Trino chart 1.42는 `/etc/trino` 전체를 ConfigMap으로 마운트
  → subPath 추가 시 `not a directory` 에러로 실패

### 1-2. 현재 워크어라운드
[manifests/opa/opa-policy-configmap.yaml](../manifests/opa/opa-policy-configmap.yaml)의
Rego 정책 안에 `user_to_groups` 정적 매핑.

```rego
user_to_groups := {
    "admin_trino":    {"trino-admin"},
    "etl_user1":      {"trino-etl"},
    ...
}
```

문제점:
- Keycloak 사용자 추가 시 **두 곳을 동시에 수정**해야 함
- 50명 초과 시 가독성 저하 + 운영 부담 누적

---

## 2. 6가지 대안 비교표

| # | 방식 | 동기화 위치 | 자동화 | 실시간성 | 구현 난이도 | 이 프로젝트 적합도 |
|---|---|---|---|---|---|---|
| A | **OPA bundle from Keycloak** (CronJob) | OPA 데이터 | ✅ 자동 | 5~15분 지연 | 낮음 | ★★★★★ |
| B | **OPA의 외부 data fetch** (decision_logs polling) | OPA 데이터 | ✅ 자동 | 폴링 주기 | 낮음 | ★★★★ |
| C | **Trino HTTP group provider** + Keycloak 어댑터 | Trino identity | ✅ 자동 | 실시간 | 중간 (chart 마운트 해결 필요) | ★★★ |
| D | **Trino file group provider** + initContainer 워크어라운드 | Trino identity | 반자동 | reload 시점 | 중간 | ★★ |
| E | **Trino 자체 OAuth2 groups-field 지원 대기** | Trino identity | ✅ 자동 | 실시간 | 0 (대기) | ★ (시점 불명) |
| F | **OIDC userinfo endpoint 호출** (Trino auth filter 커스텀) | Trino identity | ✅ 자동 | 실시간 | 높음 (Trino plugin 개발) | ★ |
| G | **LDAP 통합 (Keycloak User Federation + Trino LDAP group provider)** | LDAP (SSOT) | ✅ 자동 | 실시간 (캐시) | 높음 (LDAP 운영 추가) | ★★ |
| H | **LDAP만 사용 (Keycloak 제거)** | LDAP (SSOT) | ✅ 자동 | 실시간 | 높음 (기존 자산 폐기) | ★ |

---

## 3. 가장 권장 — A: Keycloak → OPA Bundle 동기화 CronJob

OPA는 **bundle data 메커니즘**으로 외부 JSON을 정책 데이터로 주입할 수 있습니다.
CronJob이 Keycloak Admin API에서 사용자→그룹 매핑을 가져와 ConfigMap으로 저장하면,
OPA가 ConfigMap을 reload합니다.

### 3-1. 아키텍처

```
[CronJob: keycloak-sync] ─────► Keycloak Admin API
       │                          (GET /admin/realms/trino/users + groups)
       │ jq로 user→groups JSON 변환
       ▼
[ConfigMap: trino-opa-userdata] ── data.json
       │ (volumeMount)
       ▼
[OPA Pod] ───► trino.rego가 data.users[user].groups 참조
```

### 3-2. 구현 골격

**(1) ServiceAccount + Role**:
```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: keycloak-opa-sync
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: keycloak-opa-sync
rules:
  - apiGroups: [""]
    resources: ["secrets"]
    resourceNames: ["keycloak-admin"]
    verbs: ["get"]
  - apiGroups: [""]
    resources: ["configmaps"]
    resourceNames: ["trino-opa-userdata"]
    verbs: ["get", "create", "update", "patch"]
  - apiGroups: ["apps"]
    resources: ["deployments"]
    resourceNames: ["opa"]
    verbs: ["get", "patch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: keycloak-opa-sync
subjects:
  - kind: ServiceAccount
    name: keycloak-opa-sync
roleRef:
  kind: Role
  name: keycloak-opa-sync
  apiGroup: rbac.authorization.k8s.io
```

**(2) CronJob (5분마다 동기화)**:
```yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  name: keycloak-opa-sync
spec:
  schedule: "*/5 * * * *"
  jobTemplate:
    spec:
      template:
        metadata:
          annotations:
            sidecar.istio.io/inject: "false"
        spec:
          serviceAccountName: keycloak-opa-sync
          restartPolicy: OnFailure
          containers:
            - name: sync
              image: alpine/k8s:1.30.0    # kubectl + curl + jq 포함
              env:
                - name: KC_URL
                  value: http://keycloak:8080
                - name: REALM
                  value: trino
                - name: KC_USER
                  valueFrom:
                    secretKeyRef:
                      name: keycloak-admin
                      key: KC_BOOTSTRAP_ADMIN_USERNAME
                - name: KC_PW
                  valueFrom:
                    secretKeyRef:
                      name: keycloak-admin
                      key: KC_BOOTSTRAP_ADMIN_PASSWORD
              command:
                - /bin/sh
                - -c
                - |
                  set -e
                  TOKEN=$(curl -sf -X POST \
                    "$KC_URL/realms/master/protocol/openid-connect/token" \
                    -d grant_type=password -d client_id=admin-cli \
                    -d "username=$KC_USER" -d "password=$KC_PW" \
                    | jq -r .access_token)

                  USERS=$(curl -sf "$KC_URL/admin/realms/$REALM/users?max=1000" \
                    -H "Authorization: Bearer $TOKEN")

                  echo "$USERS" | jq -r '.[].id' | while read UID; do
                    UNAME=$(echo "$USERS" | jq -r ".[] | select(.id==\"$UID\") | .username")
                    GROUPS=$(curl -sf "$KC_URL/admin/realms/$REALM/users/$UID/groups" \
                      -H "Authorization: Bearer $TOKEN" | jq -r '[.[].name]')
                    echo "{\"user\":\"$UNAME\",\"groups\":$GROUPS}"
                  done | jq -s 'map({(.user): .groups}) | add | {users: .}' > /tmp/data.json

                  kubectl create configmap trino-opa-userdata \
                    --from-file=data.json=/tmp/data.json \
                    --dry-run=client -o yaml | kubectl apply -f -

                  # OPA가 ConfigMap을 즉시 인식하도록 rollout
                  kubectl rollout restart deploy/opa
```

**(3) OPA Deployment에 ConfigMap 추가 마운트**:
```yaml
volumes:
  - name: policies
    configMap:
      name: trino-opa-policy
  - name: userdata           # 추가
    configMap:
      name: trino-opa-userdata
volumeMounts:
  - name: policies
    mountPath: /policies
  - name: userdata           # 추가
    mountPath: /data
args:
  - run
  - --server
  - --addr=0.0.0.0:8181
  - /policies/trino.rego
  - /data/data.json          # 추가 — JSON을 data.users로 로드
```

**(4) Rego 정책 수정** — 정적 매핑을 data 참조로 교체:
```rego
# 기존: user_to_groups := { "etl_user1": {"trino-etl"}, ... }
# 변경:
user_to_groups[user] := groups if {
    groups := data.users[user]
}

user_groups := groups if {
    input_groups := {g | some g in input.context.identity.groups}
    count(input_groups) > 0
    groups := input_groups
} else := groups if {
    groups := user_to_groups[input.context.identity.user]
} else := set()
```

### 3-3. 장점 (이 프로젝트에 가장 잘 맞는 이유)
- **Trino chart 변경 없음** — file group provider 마운트 충돌 회피
- **Keycloak이 단일 진실 공급원** — 사용자 추가/그룹 변경은 Keycloak에서만, 5분 안에 자동 반영
- **모든 컴포넌트가 이미 namespace 내부** — 외부 의존성 0
- **롤백 쉬움** — CronJob 끄면 즉시 정적 매핑으로 폴백
- **이 프로젝트의 install.sh 패턴 그대로** — 새 매니페스트 1개 + 기존 OPA Deployment 패치 1줄

### 3-4. 단점
- 5분 지연 (실시간 아님). Keycloak에서 즉시 권한 변경한 사용자는 다음 sync까지
  구권한 사용 가능 → 민감 작업이면 sync 주기를 1분으로 줄이거나
  Keycloak admin event hook으로 즉시 트리거
- Keycloak admin 비밀번호가 CronJob에 노출 → 별도 service account + role 권한 제한 필요

---

## 4. 차선 — C: Trino HTTP Group Provider

가장 "올바른" 해결책. Trino가 매 요청마다 HTTP 엔드포인트로 사용자→그룹을 조회.
하지만 chart 마운트 충돌이 걸림.

### 4-1. 우회 방법 — initContainer로 emptyDir에 properties 복사

```yaml
coordinator:
  additionalConfigFiles:    # chart가 지원하면 사용
    group-provider.properties: |
      group-provider.name=http
      http.group-provider.uri=http://kc-group-adapter:8080/groups/${USER}

# 또는 chart 미지원 시 init container로 우회
coordinator:
  initContainers:
    - name: setup-group-provider
      image: busybox
      command:
        - sh
        - -c
        - cp /tmp/group-provider.properties /etc/trino/
      volumeMounts:
        - name: group-provider-src
          mountPath: /tmp
        - name: trino-config-shared    # /etc/trino emptyDir
          mountPath: /etc/trino
```

별도 어댑터 서비스 (`kc-group-adapter`)가 Keycloak Admin API를 호출:
```python
# 약 30줄짜리 FastAPI 서비스
@app.get("/groups/{username}")
async def get_groups(username: str):
    token = get_kc_admin_token()
    user_id = lookup_user_id(username, token)
    groups = kc_get(f"/users/{user_id}/groups", token)
    return {"groups": [g["name"] for g in groups]}
```

→ 실시간성 100%, 하지만 Trino chart 우회 + 새 마이크로서비스 운영 부담.

---

## 5. 차차선 — F: OIDC userinfo endpoint 호출

OPA Rego에서 `http.send`로 Keycloak userinfo 엔드포인트 호출:

```rego
user_groups := groups if {
    response := http.send({
        "method": "POST",
        "url": "http://keycloak:8080/realms/trino/protocol/openid-connect/userinfo",
        "headers": {"Authorization": sprintf("Bearer %v", [input.context.identity.accessToken])}
    })
    groups := {g | g := response.body.groups[_]}
}
```

문제: Trino가 `accessToken`을 OPA input에 안 넘겨줌. 추가로 OPA가 매 요청마다
Keycloak 호출 → 부하. **권장 안 함**.

---

## 6. LDAP 통합 분석 — G/H 패턴

### 6-1. 핵심 결론

> **LDAP은 enterprise 표준 패턴이지만, 이 프로젝트가 풀려고 한 "그룹 동기화 자동화"
> 문제만 본다면 LDAP을 추가해도 chart 마운트 문제가 그대로 남아 결과적으로
> 같은 양의 우회 작업이 필요합니다.**

### 6-2. 패턴 G — Keycloak User Federation + Trino LDAP Group Provider (병행)

```
              ┌──────────────────────┐
              │       LDAP           │ ← SSOT (사용자/그룹)
              │  (OpenLDAP / 389-ds) │
              └─────────┬────────────┘
                        │
        ┌───────────────┴────────────────┐
        │                                │
        ▼                                ▼
┌─────────────────┐              ┌──────────────────┐
│   Keycloak      │              │   Trino          │
│  User Federation│              │  group-provider  │
│  (READ_ONLY)    │              │  .name=ldap      │
└─────────┬───────┘              └────────┬─────────┘
          │ OAuth2 flow                   │ 매 쿼리마다
          │ JWT (sub=user)                │ LDAP 조회
          ▼                               ▼
        Trino auth                     identity.groups
                                          │
                                          ▼
                                        OPA
```

- Keycloak: 인증(SSO)만
- Trino: LDAP에서 그룹 직접 조회 → OPA에 전달
- 사용자 추가/그룹 변경은 **LDAP 한 곳**

### 6-3. 패턴 H — Keycloak 제거, LDAP만 사용

Trino가 LDAP password-authenticator + LDAP group provider를 직접 사용. Keycloak 스택 전체 제거.

```
LDAP ───► Trino (LDAP authn + LDAP groups) ───► OPA
```

- 가장 단순한 아키텍처 (2 시스템)
- **잃는 것**: SSO, 소셜 로그인, MFA, 기존 [04-keycloak-oauth2.md](04-keycloak-oauth2.md) 자산 폐기

### 6-4. 두 패턴 모두 풀어야 하는 chart 마운트 문제

LDAP을 쓰든 안 쓰든 Trino에 다음 파일을 마운트해야 함:

```properties
# /etc/trino/group-provider.properties
group-provider.name=ldap
ldap.url=ldaps://ldap.user-braveji.svc:636
ldap.admin-user=cn=admin,dc=trino,dc=local
ldap.admin-password=${ENV:LDAP_ADMIN_PW}
ldap.user-base-dn=ou=people,dc=trino,dc=local
ldap.group-base-dn=ou=groups,dc=trino,dc=local
ldap.group-search-filter=(member=uid=${USER},ou=people,dc=trino,dc=local)
ldap.group-name-attribute=cn
ldap.cache-ttl=10m
```

이 파일은 Trino chart 1.42의 `/etc/trino` ConfigMap 마운트와 충돌해서
이미 포기한 그 문제입니다. 해결하려면 §4-1과 동일한 initContainer + emptyDir 우회 필요
→ chart의 정상 ConfigMap 마운트 흐름을 깨고 emptyDir로 우회 → 향후 chart upgrade 시 깨질 위험.

### 6-5. LDAP 도입 시 추가로 운영해야 할 것

| 항목 | 비용 |
|---|---|
| OpenLDAP/389-ds Pod 배포 | StatefulSet + PVC + (HA 시) replication |
| LDAP DIT(스키마) 설계 | `dc=trino,dc=local` 트리, `ou=people`, `ou=groups`, posixAccount/groupOfNames 결정 |
| LDAP admin Secret 관리 | `ldap-admin` Secret + 회전 절차 |
| Keycloak User Federation 설정 | Sync Period, Edit Mode, Bind credentials, mappers |
| Trino LDAP TLS | `ldaps://` 위해 cert-manager 인증서 발급 |
| 백업/복구 | LDAP DB(BDB/MDB) 또는 LDIF 정기 dump |
| 13명 사용자 마이그레이션 | Keycloak 사용자 → LDAP entry 1회 일괄 변환 |

→ Pod 추가 +1, 운영 학습 곡선 큼, namespace 복잡도 증가.

### 6-6. LDAP을 도입해야 하는 정당한 시나리오

다음 중 하나라도 해당하면 LDAP 도입이 정당화됩니다:

1. **사내에 이미 운영 중인 LDAP/AD가 있음** → Keycloak User Federation으로 연결,
   Trino도 동일 LDAP 조회. 이때는 LDAP 추가 운영 비용 없음.
2. **Trino 외 다른 컴포넌트(HDFS/Spark/Hive Beeline/Airflow 등)도 같은 사용자 DB가 필요**
   → LDAP이 자연스러운 SSOT
3. **사용자 500명+** → CronJob 동기화 폴링 시간/ConfigMap 크기/OPA reload 비용이
   LDAP per-query 조회 캐시보다 비싸지는 분기점
4. **권한 변경의 즉각 반영이 보안상 필수** (예: 퇴사자 즉시 차단)
   → 5분 지연 못 견딤

### 6-7. 만약 그래도 LDAP 도입을 결정한다면

추천 진행 순서:
1. **POC**: OpenLDAP을 namespace 안에 1 Pod로 배포 (Bitnami chart 또는 osixia/openldap)
2. **스키마**: `dc=trino,dc=local`, `ou=people` (posixAccount), `ou=groups` (groupOfNames)
3. **Keycloak User Federation**: READ_ONLY 모드로 LDAP 연결 → 기존 13명을 LDAP에 미리 적재 후 Keycloak에서 import
4. **Trino chart 우회**: §4-1의 initContainer 패턴 적용
5. **검증**: [verify-opa.sh](../scripts/verify-opa.sh)의 V1~V8을 그대로 돌려 회귀 확인
6. **롤백 경로 확보**: LDAP 죽어도 Keycloak이 자체 사용자로 폴백할 수 있도록 설정

---

## 7. 의사결정 권장

| 사용자 규모 / 컨텍스트 | 권장 방안 |
|---|---|
| ~50명 (현재) | **A: CronJob bundle sync** — 가장 실용적 |
| 50~500명, 권한 변경 빈번 | **C: HTTP group provider** (chart 우회 감수) |
| 사내 LDAP/AD 이미 존재 | **G: LDAP 패턴** (운영 부담 0) |
| 500명+, multi-tenant 운영 | Trino 자체에 group provider plugin 자체 개발 (E 대기 또는 F의 변형) |
| Trino 외 시스템도 같은 LDAP 필요 | **G: LDAP 패턴** |

이 프로젝트는 13명 시작 → 50명까지는 **A로 충분**. 그 이후 chart upgrade
또는 Trino native 지원 시점에 C로 마이그레이션하는 단계적 전환을 권장합니다.

---

## 8. 한 줄 결론

> **현재 13명 규모에서는 CronJob bundle sync (A)가 최선입니다.**
> LDAP 통합(G/H)은 사내에 이미 LDAP이 있거나 Trino 외 다른 시스템도 같은
> 사용자 DB를 공유해야 할 때만 정당화되고, 그 외에는 동일한 chart 마운트
> 문제 + LDAP 운영 비용을 새로 짊어지는 결과가 됩니다.

---

## 9. 관련 문서

- [04-keycloak-oauth2.md](04-keycloak-oauth2.md) — Keycloak Realm/Client 설정
- [06-opa-monitoring.md §4-6](06-opa-monitoring.md) — 현재 정적 매핑 워크어라운드
- [scripts/setup-keycloak-realm.sh](../scripts/setup-keycloak-realm.sh) — 13명 자동 생성 + trino-oauth2 Secret
- [scripts/setup-opa.sh](../scripts/setup-opa.sh) — OPA 배포 + Rego 정책 적용
- [scripts/verify-opa.sh](../scripts/verify-opa.sh) — V1~V8 시나리오 검증
