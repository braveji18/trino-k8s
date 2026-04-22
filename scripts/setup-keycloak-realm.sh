#!/usr/bin/env bash
# Keycloak Realm/Client/그룹/사용자 자동 설정
# docs/04-resource-quota-multitenancy-plan.md §1-1 구현
#
# 사전 요구:
#   - Keycloak이 배포되어 있고 Admin Console 접근 가능
#   - jq 설치 (로컬)
#
# 사용법:
#   ./scripts/setup-keycloak-realm.sh
#
# 환경변수로 override 가능:
#   KEYCLOAK_URL       — Keycloak 내부 URL (기본: http://keycloak:8080, 클러스터 내부)
#   KEYCLOAK_ADMIN     — Admin 사용자 (기본: admin)
#   KEYCLOAK_ADMIN_PW  — Admin 비밀번호 (기본: changeme-keycloak-admin)
#   REALM_NAME         — Realm 이름 (기본: trino)
#   DEFAULT_PASSWORD   — 테스트 사용자 초기 비밀번호 (기본: changeme-user)

set -euo pipefail

# ── 설정 ────────────────────────────────────────────────────────────
ROOT="$(pwd)"
source "$ROOT/scripts/config.env"
NS="$NAMESPACE"

KEYCLOAK_URL="${KEYCLOAK_URL:-http://keycloak:8080}"
KEYCLOAK_ADMIN="${KEYCLOAK_ADMIN:-admin}"
KEYCLOAK_ADMIN_PW="${KEYCLOAK_ADMIN_PW:-changeme-keycloak-admin}"
REALM_NAME="${REALM_NAME:-trino}"
DEFAULT_PASSWORD="${DEFAULT_PASSWORD:-changeme-user}"

TRINO_REDIRECT_URI="https://braveji.trino.quantumcns.ai/*"
TRINO_WEB_ORIGIN="https://braveji.trino.quantumcns.ai"

# 팀/사용자 매트릭스 (docs/04 §0 요구사항 기반)
# 형식: "username:group"
  # 데이터 엔지니어팀 (5명) — etl_ 접두사
  # 분석가팀 (5명) — analyst_ 접두사  
  # BI 도구 서비스 계정 (2개) — bi_ 접두사  
  # 관리자  
USERS=(
  "etl_user1:trino-etl"
  "etl_user2:trino-etl"
  "etl_user3:trino-etl"
  "etl_user4:trino-etl"
  "etl_user5:trino-etl"
  "analyst_user1:trino-analyst"
  "analyst_user2:trino-analyst"
  "analyst_user3:trino-analyst"
  "analyst_user4:trino-analyst"
  "analyst_user5:trino-analyst"
  "bi_superset:trino-bi"
  "bi_redash:trino-bi"
  "admin_trino:trino-admin"
)

KC_GROUPS=("trino-etl" "trino-analyst" "trino-bi" "trino-admin")

# ── 헬퍼 함수 ──────────────────────────────────────────────────────

# 상주 curl Pod — 매번 Pod를 생성/삭제하지 않고 하나의 Pod를 재사용
CURL_POD="kc-setup-curl"

  # 이미 있으면 재사용
setup_curl_pod() {
  if kubectl -n "$NS" get pod "$CURL_POD" &>/dev/null; then
    return 0
  fi
  kubectl -n "$NS" run "$CURL_POD" \
    --image=curlimages/curl:8.5.0 \
    --overrides='{"metadata":{"annotations":{"sidecar.istio.io/inject":"false"}}}' \
    --restart=Never \
    --command -- sleep 3600 >/dev/null 2>&1
  kubectl -n "$NS" wait --for=condition=Ready "pod/$CURL_POD" --timeout=60s >/dev/null 2>&1
}

cleanup_curl_pod() {
  kubectl -n "$NS" delete pod "$CURL_POD" --ignore-not-found >/dev/null 2>&1
}
trap cleanup_curl_pod EXIT

# Keycloak API 호출 — 상주 Pod에서 curl 실행 (출력이 깨끗함)
kc_api() {
  local method="$1"
  local path="$2"
  shift 2
  kubectl -n "$NS" exec -i "$CURL_POD" -- \
    curl -s -X "$method" \
    "${KEYCLOAK_URL}/admin/realms${path}" \
    -H "Authorization: Bearer ${TOKEN}" \
    -H "Content-Type: application/json" \
    "$@"
}

# 토큰 획득
get_admin_token() {
  kubectl -n "$NS" exec -i "$CURL_POD" -- \
    curl -s -X POST \
    "${KEYCLOAK_URL}/realms/master/protocol/openid-connect/token" \
    -d "grant_type=password" \
    -d "client_id=admin-cli" \
    -d "username=${KEYCLOAK_ADMIN}" \
    -d "password=${KEYCLOAK_ADMIN_PW}" \
    | jq -r '.access_token'
}

echo "==> Keycloak Realm 설정 시작"
echo "    Keycloak URL : ${KEYCLOAK_URL}"
echo "    Realm        : ${REALM_NAME}"
echo "    Namespace    : ${NS}"

# 상주 curl Pod 생성
echo ""
echo "==> 0) curl Pod 준비"
setup_curl_pod
echo "    ${CURL_POD} Ready"

# ── 1. Admin 토큰 획득 ─────────────────────────────────────────────
echo ""
echo "==> 1) Admin 토큰 획득"
TOKEN=$(get_admin_token)
if [[ -z "$TOKEN" || "$TOKEN" == "null" ]]; then
  echo "ERROR: Admin 토큰 획득 실패. Keycloak이 실행 중인지 확인하세요."
  exit 1
fi
echo "    토큰 획득 완료"

# ── 2. Realm 생성 ──────────────────────────────────────────────────
REALM_CONFIG="{
  \"realm\": \"${REALM_NAME}\",
  \"enabled\": true,
  \"displayName\": \"Trino Data Platform\",
  \"accessTokenLifespan\": 1800,
  \"ssoSessionIdleTimeout\": 3600,
  \"ssoSessionMaxLifespan\": 36000
}"

#  Realm은 수동 생성 필요 
echo ""
echo "==> 2) Realm '${REALM_NAME}' 생성"
EXISTING_REALM=$(kc_api GET "/${REALM_NAME}" 2>/dev/null | grep -o '"realm":"[^"]*"' | cut -d'"' -f4)
if [[ "$EXISTING_REALM" == "$REALM_NAME" ]]; then
  echo "    이미 존재 — 설정값 업데이트"
  kc_api PUT "/${REALM_NAME}" -d "$REALM_CONFIG" >/dev/null 2>&1
  echo "    업데이트 완료 (accessTokenLifespan=30분, ssoSessionIdleTimeout=1시간)"
else
  kc_api POST "" -d "$REALM_CONFIG"
  echo "    생성 완료 (accessTokenLifespan=30분)"
fi

# 토큰 갱신 (realm 생성 후 시간이 걸릴 수 있음)
TOKEN=$(get_admin_token)

# ── 3. Client 생성 ─────────────────────────────────────────────────
echo ""
echo "==> 3) Client 'trino' 생성"
EXISTING_CLIENT=$(kc_api GET "/${REALM_NAME}/clients?clientId=trino" | jq -r '.[0].id // empty')
if [[ -n "$EXISTING_CLIENT" ]]; then
  echo "    이미 존재 (id=${EXISTING_CLIENT}) — 건너뜀"
  CLIENT_ID="$EXISTING_CLIENT"
else
  kc_api POST "/${REALM_NAME}/clients" -d "{
    \"clientId\": \"trino\",
    \"name\": \"Trino Query Engine\",
    \"enabled\": true,
    \"protocol\": \"openid-connect\",
    \"publicClient\": false,
    \"clientAuthenticatorType\": \"client-secret\",
    \"standardFlowEnabled\": true,
    \"directAccessGrantsEnabled\": true,
    \"serviceAccountsEnabled\": true,
    \"redirectUris\": [\"${TRINO_REDIRECT_URI}\"],
    \"webOrigins\": [\"${TRINO_WEB_ORIGIN}\"],
    \"defaultClientScopes\": [\"openid\", \"profile\", \"email\"]
  }"
  CLIENT_ID=$(kc_api GET "/${REALM_NAME}/clients?clientId=trino" | jq -r '.[0].id')
  echo "    생성 완료 (id=${CLIENT_ID})"
fi

# Client Secret 조회
CLIENT_SECRET=$(kc_api GET "/${REALM_NAME}/clients/${CLIENT_ID}/client-secret" | jq -r '.value')
echo "    Client Secret: ${CLIENT_SECRET}"
echo "    ⚠️  이 값을 Trino OAuth2 설정에 사용해야 합니다"

# ── 4. Groups claim Mapper 추가 ────────────────────────────────────
echo ""
echo "==> 4) 'groups' claim Protocol Mapper 추가"

# Client의 dedicated scope에 mapper 추가
DEDICATED_SCOPE_ID=$(kc_api GET "/${REALM_NAME}/client-scopes" \
  | jq -r ".[] | select(.name==\"trino-dedicated\") | .id // empty")

# dedicated scope이 없으면 client의 protocol mapper에 직접 추가
EXISTING_MAPPER=$(kc_api GET "/${REALM_NAME}/clients/${CLIENT_ID}/protocol-mappers/models" \
  | jq -r '.[] | select(.name=="groups") | .id // empty')

if [[ -n "$EXISTING_MAPPER" ]]; then
  echo "    이미 존재 — 건너뜀"
else
  kc_api POST "/${REALM_NAME}/clients/${CLIENT_ID}/protocol-mappers/models" -d '{
    "name": "groups",
    "protocol": "openid-connect",
    "protocolMapper": "oidc-group-membership-mapper",
    "consentRequired": false,
    "config": {
      "full.path": "false",
      "introspection.token.claim": "true",
      "userinfo.token.claim": "true",
      "id.token.claim": "true",
      "access.token.claim": "true",
      "claim.name": "groups"
    }
  }'
  echo "    생성 완료 (claim.name=groups, full.path=false)"
fi

# 그룹 ID 조회 함수 (bash 3.x 호환 — declare -A 사용 불가)
get_group_id() {
  kc_api GET "/${REALM_NAME}/groups?search=${1}&exact=true" | jq -r ".[0].id // empty"
}

# ── 5. 그룹 생성 ───────────────────────────────────────────────────
echo ""
echo "==> 5) 그룹 생성"
for group in "${KC_GROUPS[@]}"; do
  EXISTING_GID=$(get_group_id "$group")
  if [[ -n "$EXISTING_GID" ]]; then
    echo "    ${group} — 이미 존재 (id=${EXISTING_GID})"
  else
    kc_api POST "/${REALM_NAME}/groups" -d "{\"name\": \"${group}\"}" >/dev/null
    GID=$(get_group_id "$group")
    echo "    ${group} — 생성 완료 (id=${GID})"
  fi
done

# ── 6. 사용자 생성 + 그룹 배정 ─────────────────────────────────────
echo ""
echo "==> 6) 사용자 생성 + 그룹 배정"
for entry in "${USERS[@]}"; do
  username="${entry%%:*}"
  group="${entry##*:}"

  # 사용자 존재 확인
  EXISTING_UID=$(kc_api GET "/${REALM_NAME}/users?username=${username}&exact=true" \
    | jq -r '.[0].id // empty')

  if [[ -n "$EXISTING_UID" ]]; then
    echo "    ${username} — 이미 존재, 프로필 보완 + 그룹 확인"
    USER_ID="$EXISTING_UID"
    # 프로필 미완성 시 보완 (Keycloak 26.x "Account not fully set up" 방지)
    kc_api PUT "/${REALM_NAME}/users/${USER_ID}" -d "{
      \"firstName\": \"${username}\",
      \"lastName\": \"user\",
      \"email\": \"${username}@trino.local\",
      \"emailVerified\": true,
      \"requiredActions\": []
    }" >/dev/null 2>&1
  else
    # 사용자 생성 (firstName/lastName/email 필수 — Keycloak 26.x 프로필 정책)
    kc_api POST "/${REALM_NAME}/users" -d "{
      \"username\": \"${username}\",
      \"enabled\": true,
      \"emailVerified\": true,
      \"firstName\": \"${username}\",
      \"lastName\": \"user\",
      \"email\": \"${username}@trino.local\",
      \"credentials\": [{
        \"type\": \"password\",
        \"value\": \"${DEFAULT_PASSWORD}\",
        \"temporary\": false
      }]
    }" >/dev/null
    USER_ID=$(kc_api GET "/${REALM_NAME}/users?username=${username}&exact=true" \
      | jq -r '.[0].id')
    echo "    ${username} — 생성 완료 (password: ${DEFAULT_PASSWORD})"
  fi

  # 그룹 배정
  GID=$(get_group_id "$group")
  kc_api PUT "/${REALM_NAME}/users/${USER_ID}/groups/${GID}" >/dev/null 2>&1 || true
  echo "    ${username} → ${group} 배정 완료"
done

# ── 7. trino-oauth2 K8s Secret 생성 ────────────────────────────────
# helm/values.yaml의 envFrom이 참조하는 Secret. Client Secret을
# OAUTH2_CLIENT_SECRET 키로 저장 — install.sh 재실행 시 Trino Pod에 주입됨.
echo ""
echo "==> 7) trino-oauth2 K8s Secret 생성/갱신"
kubectl -n "${NS}" create secret generic trino-oauth2 \
  --from-literal=OAUTH2_CLIENT_SECRET="${CLIENT_SECRET}" \
  --dry-run=client -o yaml | kubectl apply -f -
echo "    완료 — keys: OAUTH2_CLIENT_SECRET"

# ── 8. 결과 요약 ───────────────────────────────────────────────────
echo ""
echo "=========================================="
echo "  Keycloak Realm 설정 완료"
echo "=========================================="
echo ""
echo "  Realm           : ${REALM_NAME}"
echo "  Client ID       : trino"
echo "  Client Secret   : ${CLIENT_SECRET}"
echo "  K8s Secret      : ${NS}/trino-oauth2 (OAUTH2_CLIENT_SECRET)"
echo "  Groups          : trino-etl, trino-analyst, trino-bi, trino-admin"
echo "  Users           : ${#USERS[@]}명"
echo "  Default Password: ${DEFAULT_PASSWORD}"
echo ""
echo "  OIDC Discovery (외부) : https://braveji-keycloak.trino.quantumcns.ai/realms/${REALM_NAME}/.well-known/openid-configuration"
echo "  OIDC Discovery (내부) : http://keycloak:8080/realms/${REALM_NAME}/.well-known/openid-configuration"
echo "  Trino issuer 설정    : https://braveji-keycloak.trino.quantumcns.ai/realms/${REALM_NAME}"
echo ""
echo "다음 단계:"
echo "  1) helm/values.yaml에 OAuth2 설정 적용 후 ./scripts/install.sh 재실행 (§1-2)"
echo ""
echo "  2) 토큰 테스트 (KC_HOSTNAME 설정으로 내부/외부 동일 issuer):"
echo "     TOKEN=\$(kubectl -n ${NS} run kc-tok --rm -i --restart=Never \\"
echo "       --overrides='{\"metadata\":{\"annotations\":{\"sidecar.istio.io/inject\":\"false\"}}}' \\"
echo "       --image=curlimages/curl:8.5.0 -- \\"
echo "       curl -s -X POST 'http://keycloak:8080/realms/${REALM_NAME}/protocol/openid-connect/token' \\"
echo "       -d 'grant_type=password&client_id=trino&client_secret=${CLIENT_SECRET}&username=admin_trino&password=${DEFAULT_PASSWORD}' \\"
echo "       2>/dev/null | grep -o '\"access_token\":\"[^\"]*\"' | cut -d'\"' -f4)"
echo ""
echo "  4) Trino REST API로 인증 확인:"
echo "     kubectl -n ${NS} exec deploy/my-trino-trino-coordinator -- \\"
echo "       curl -s -X POST http://localhost:8080/v1/statement \\"
echo "       -H 'Authorization: Bearer '\$TOKEN \\"
echo "       -H 'X-Trino-User: admin_trino' \\"
echo "       -d 'SELECT current_user'"
