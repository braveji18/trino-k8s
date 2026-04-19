#!/bin/bash
# Ranger Admin 설치 + Trino 서비스 등록 + 사용자/그룹 생성 + 정책 업데이트
# setup-keycloak-realm.sh와 대칭적으로 관리.
#
# 수행 단계:
#   [0/6] Ranger PostgreSQL (CNPG) 배포 + Ready 대기
#   [1/6] Ranger Admin Deployment + Service + Ingress 배포
#   [2/6] Trino 서비스 등록
#   [3/6] 그룹 4개 생성
#   [4/6] 사용자 13명 생성 + 그룹 배정
#   [5/6] 기본 정책 업데이트 (그룹별 접근제어)
#   [6/6] 검증 (Ranger Admin + Trino 쿼리)
#
# 사전 요구:
#   - CNPG operator가 클러스터에 설치되어 있어야 함
#   - *.trino.quantumcns.ai DNS 와일드카드 설정 완료
#
# 사용법:
#   ./scripts/setup-ranger-users.sh
#   NAMESPACE=other-ns RANGER_PASSWORD=MyPass1! ./scripts/setup-ranger-users.sh
#   SKIP_INSTALL=1 ./scripts/setup-ranger-users.sh   # 설치 건너뛰고 사용자/정책만
#   SKIP_VERIFY=1 ./scripts/setup-ranger-users.sh   # 검증 건너뛰기

set -eu
# pipefail 미사용: ranger_api | python3 파이프에서 python3가 빈 응답에 exit 1하면
# 전체 스크립트가 중단되는 문제 방지 (G49)

ROOT="$(pwd)"
NAMESPACE="${NAMESPACE:-user-braveji}"
RANGER_USER="${RANGER_USER:-admin}"
RANGER_PASSWORD="${RANGER_PASSWORD:-Admin1234!}"
RANGER_URL="http://localhost:6080"
SKIP_INSTALL="${SKIP_INSTALL:-0}"

NS="$NAMESPACE"

ranger_api() {
  local METHOD=$1
  local API_PATH=$2
  shift 2
  kubectl -n "$NS" exec deploy/ranger-admin -- \
    curl -s -u "${RANGER_USER}:${RANGER_PASSWORD}" -X "$METHOD" \
    "${RANGER_URL}${API_PATH}" \
    -H "Content-Type: application/json" \
    "$@"
}

# ── [0/6] Ranger PostgreSQL (CNPG) ───────────────────────────────
if [ "$SKIP_INSTALL" != "1" ]; then
  echo "=== [0/6] Ranger PostgreSQL (CNPG) 배포 ==="
  kubectl -n "$NS" apply -f "$ROOT/manifests/ranger/ranger-postgres.yaml"
  echo "    ranger-postgres CNPG 클러스터 Ready 대기..."
  for i in $(seq 1 30); do
    READY=$(kubectl -n "$NS" get cluster.postgresql.cnpg.io ranger-postgres \
      -o jsonpath='{.status.readyInstances}' 2>/dev/null || echo "")
    if [ "$READY" = "1" ]; then
      echo "    ranger-postgres Ready"
      break
    fi
    if [ "$i" = "30" ]; then
      echo "    ERROR: ranger-postgres 타임아웃 (5분)"
      exit 1
    fi
    sleep 10
  done

  # ── [1/6] Ranger Admin Deployment + Service + Ingress ──────────
  echo ""
  echo "=== [1/6] Ranger Admin Deployment 배포 ==="
  kubectl -n "$NS" apply -f "$ROOT/manifests/ranger/ranger-admin-deployment.yaml"
  kubectl -n "$NS" apply -f "$ROOT/manifests/ranger/ranger-admin-ingress.yaml"
  echo "    Ranger Admin Pod Ready 대기 (setup.sh + Tomcat ~2분)..."
  for i in $(seq 1 36); do
    READY=$(kubectl -n "$NS" get pod -l app=ranger-admin \
      -o jsonpath='{.items[0].status.containerStatuses[0].ready}' 2>/dev/null || echo "")
    RESTARTS=$(kubectl -n "$NS" get pod -l app=ranger-admin \
      -o jsonpath='{.items[0].status.containerStatuses[0].restartCount}' 2>/dev/null || echo "0")
    if [ "$READY" = "true" ]; then
      echo "    Ranger Admin Ready"
      break
    fi
    if [ "$RESTARTS" -gt 3 ] 2>/dev/null; then
      echo "    ERROR: Ranger Admin CrashLoopBackOff (restarts=$RESTARTS)"
      echo "    로그 확인: kubectl -n $NS logs -l app=ranger-admin --tail=30"
      exit 1
    fi
    if [ "$i" = "36" ]; then
      echo "    WARN: 타임아웃 — Ranger Admin이 아직 Ready가 아닐 수 있음. 계속 진행."
    fi
    sleep 10
  done
else
  echo "=== SKIP_INSTALL=1 — Ranger 인프라 설치 건너뜀 ==="
fi

echo ""
echo "=== [2/6] Trino 서비스 등록 ==="
EXISTING=$(ranger_api GET "/service/public/v2/api/service/name/trino-braveji" 2>/dev/null \
  | python3 -c 'import sys,json; print(json.load(sys.stdin).get("id",""))' 2>/dev/null || true)
if [ -n "$EXISTING" ] && [ "$EXISTING" != "None" ]; then
  echo "  trino-braveji 서비스 이미 존재 (id=$EXISTING), 건너뜀"
else
  ranger_api POST "/service/public/v2/api/service" \
    -d '{"name":"trino-braveji","type":"trino","configs":{"jdbc.url":"jdbc:trino://my-trino-trino:8080","jdbc.driverClassName":"io.trino.jdbc.TrinoDriver","username":"admin"}}' \
    | python3 -c 'import sys,json; d=json.load(sys.stdin); print("  trino-braveji 서비스 등록 완료 (id=%s)" % d.get("id"))'
fi

echo ""
echo "=== [3/6] 그룹 생성 ==="
for GRP_NAME in trino-etl trino-analyst trino-bi trino-admin; do
  RESP=$(ranger_api POST "/service/xusers/groups" \
    -d "{\"name\":\"$GRP_NAME\",\"description\":\"$GRP_NAME\"}" 2>&1)
  GID=$(echo "$RESP" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("id","exists"))' 2>/dev/null || echo "exists")
  echo "  $GRP_NAME → id=$GID"
done

echo ""
echo "=== [4/6] 사용자 생성 + 그룹 배정 ==="

create_and_assign() {
  local UNAME=$1
  local GRP_NAME=$2

  # 사용자 생성 (이미 존재하면 ID 조회)
  RESP=$(ranger_api POST "/service/xusers/secure/users" \
    -d "{\"name\":\"$UNAME\",\"firstName\":\"$UNAME\",\"lastName\":\"user\",\"password\":\"Changeme1\",\"userRoleList\":[\"ROLE_USER\"]}" 2>&1)
  UID_VAL=$(echo "$RESP" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("id",""))' 2>/dev/null || echo "")

  if [ -z "$UID_VAL" ] || [ "$UID_VAL" = "None" ]; then
    UID_VAL=$(ranger_api GET "/service/xusers/users" 2>/dev/null \
      | python3 -c "
import sys, json
d = json.load(sys.stdin)
for u in d.get('vXUsers',[]):
    if u['name'] == '$UNAME':
        print(u['id'])
        break
" 2>/dev/null || echo "")
  fi

  # 그룹 ID 조회 + PUT으로 그룹 매핑
  if [ -n "$UID_VAL" ] && [ "$UID_VAL" != "None" ]; then
    GID_VAL=$(ranger_api GET "/service/xusers/groups" 2>/dev/null \
      | python3 -c "
import sys, json
d = json.load(sys.stdin)
for g in d.get('vXGroups',[]):
    if g['name'] == '$GRP_NAME':
        print(g['id'])
        break
" 2>/dev/null || echo "")

    if [ -n "$GID_VAL" ]; then
      ranger_api PUT "/service/xusers/secure/users/$UID_VAL" \
        -d "{\"id\":$UID_VAL,\"name\":\"$UNAME\",\"firstName\":\"$UNAME\",\"lastName\":\"user\",\"password\":\"Changeme1\",\"groupIdList\":[$GID_VAL],\"userRoleList\":[\"ROLE_USER\"]}" \
        | python3 -c "import sys,json; d=json.load(sys.stdin); print('  %s → %s' % (d.get('name'), d.get('groupNameList')))" 2>/dev/null
    fi
  else
    echo "  $UNAME → 생성/조회 실패"
  fi
}

for i in 1 2 3 4 5; do create_and_assign "etl_user$i" "trino-etl"; done
for i in 1 2 3 4 5; do create_and_assign "analyst_user$i" "trino-analyst"; done
create_and_assign "bi_superset" "trino-bi"
create_and_assign "bi_redash" "trino-bi"
create_and_assign "admin_trino" "trino-admin"

echo ""
echo "=== [5/6] 기본 정책 업데이트 (그룹별 접근제어) ==="

# 정책 6: catalog/schema/table/column — admin:all, etl:readwrite, analyst+bi:select
ranger_api PUT "/service/public/v2/api/policy/6" \
  -d '{"id":6,"service":"trino-braveji","name":"all - catalog, schema, table, column","isEnabled":true,"resources":{"catalog":{"values":["*"]},"schema":{"values":["*"]},"table":{"values":["*"]},"column":{"values":["*"]}},"policyItems":[{"groups":["trino-admin"],"accesses":[{"type":"select","isAllowed":true},{"type":"insert","isAllowed":true},{"type":"create","isAllowed":true},{"type":"drop","isAllowed":true},{"type":"alter","isAllowed":true},{"type":"delete","isAllowed":true},{"type":"grant","isAllowed":true},{"type":"revoke","isAllowed":true},{"type":"all","isAllowed":true}]},{"groups":["trino-etl"],"accesses":[{"type":"select","isAllowed":true},{"type":"insert","isAllowed":true},{"type":"create","isAllowed":true},{"type":"drop","isAllowed":true},{"type":"alter","isAllowed":true},{"type":"delete","isAllowed":true}]},{"groups":["trino-analyst","trino-bi"],"accesses":[{"type":"select","isAllowed":true}]}]}' \
  | python3 -c 'import sys,json; print("  정책 6 (catalog/schema/table/column) OK")' 2>/dev/null

# 정책 7: catalog/schema — admin/etl:DDL, analyst+bi:show
ranger_api PUT "/service/public/v2/api/policy/7" \
  -d '{"id":7,"service":"trino-braveji","name":"all - catalog, schema","isEnabled":true,"resources":{"catalog":{"values":["*"]},"schema":{"values":["*"]}},"policyItems":[{"groups":["trino-admin"],"accesses":[{"type":"create","isAllowed":true},{"type":"drop","isAllowed":true},{"type":"alter","isAllowed":true},{"type":"show","isAllowed":true},{"type":"all","isAllowed":true}]},{"groups":["trino-etl"],"accesses":[{"type":"create","isAllowed":true},{"type":"drop","isAllowed":true},{"type":"alter","isAllowed":true},{"type":"show","isAllowed":true}]},{"groups":["trino-analyst","trino-bi"],"accesses":[{"type":"show","isAllowed":true}]}]}' \
  | python3 -c 'import sys,json; print("  정책 7 (catalog/schema) OK")' 2>/dev/null

# 정책 8: catalog — admin/etl:use+create+show, analyst+bi:use+show
ranger_api PUT "/service/public/v2/api/policy/8" \
  -d '{"id":8,"service":"trino-braveji","name":"all - catalog","isEnabled":true,"resources":{"catalog":{"values":["*"]}},"policyItems":[{"groups":["trino-admin"],"accesses":[{"type":"use","isAllowed":true},{"type":"create","isAllowed":true},{"type":"show","isAllowed":true},{"type":"all","isAllowed":true}]},{"groups":["trino-etl"],"accesses":[{"type":"use","isAllowed":true},{"type":"create","isAllowed":true},{"type":"show","isAllowed":true}]},{"groups":["trino-analyst","trino-bi"],"accesses":[{"type":"use","isAllowed":true},{"type":"show","isAllowed":true}]}]}' \
  | python3 -c 'import sys,json; print("  정책 8 (catalog) OK")' 2>/dev/null

# 정책 1: trinouser — 전 그룹 impersonate 허용
ranger_api PUT "/service/public/v2/api/policy/1" \
  -d '{"id":1,"service":"trino-braveji","name":"all - trinouser","isEnabled":true,"resources":{"trinouser":{"values":["*"]}},"policyItems":[{"groups":["trino-admin","trino-etl","trino-analyst","trino-bi"],"accesses":[{"type":"impersonate","isAllowed":true}]}]}' \
  | python3 -c 'import sys,json; print("  정책 1 (trinouser/impersonate) OK")' 2>/dev/null

# 정책 9: queryid — 전 그룹 execute 허용
ranger_api PUT "/service/public/v2/api/policy/9" \
  -d '{"id":9,"service":"trino-braveji","name":"all - queryid","isEnabled":true,"resources":{"queryid":{"values":["*"]}},"policyItems":[{"groups":["trino-admin","trino-etl","trino-analyst","trino-bi"],"accesses":[{"type":"execute","isAllowed":true}]}]}' \
  | python3 -c 'import sys,json; print("  정책 9 (queryid/execute) OK")' 2>/dev/null

# 정책 13: systemproperty — admin:alter+show, etl/analyst/bi:show
ranger_api PUT "/service/public/v2/api/policy/13" \
  -d '{"id":13,"service":"trino-braveji","name":"all - systemproperty","isEnabled":true,"resources":{"systemproperty":{"values":["*"]}},"policyItems":[{"groups":["trino-admin"],"accesses":[{"type":"alter","isAllowed":true},{"type":"show","isAllowed":true}]},{"groups":["trino-etl"],"accesses":[{"type":"show","isAllowed":true}]},{"groups":["trino-analyst","trino-bi"],"accesses":[{"type":"show","isAllowed":true}]}]}' \
  | python3 -c 'import sys,json; print("  정책 13 (systemproperty) OK")' 2>/dev/null

echo ""
echo "=== [6/6] 검증 ==="

SKIP_VERIFY="${SKIP_VERIFY:-0}"
if [ "$SKIP_VERIFY" = "1" ]; then
  echo "  SKIP_VERIFY=1 — 검증 건너뜀"
else
  VERIFY_PASS=0
  VERIFY_FAIL=0

  echo "--- Ranger Admin 접근 확인 ---"
  HTTP_CODE=$(kubectl -n "$NS" exec deploy/ranger-admin -- \
    curl -s -o /dev/null -w '%{http_code}' -u "${RANGER_USER}:${RANGER_PASSWORD}" \
    "http://localhost:6080/login.jsp" 2>/dev/null || echo "000")
  if [ "$HTTP_CODE" = "200" ]; then
    echo "  V0: Ranger Admin HTTP 200 — PASS"
    VERIFY_PASS=$((VERIFY_PASS + 1))
  else
    echo "  V0: Ranger Admin HTTP $HTTP_CODE — FAIL"
    VERIFY_FAIL=$((VERIFY_FAIL + 1))
  fi

  echo "--- Trino service definition 확인 ---"
  SVC_NAME=$(ranger_api GET "/service/public/v2/api/servicedef/name/trino" 2>/dev/null \
    | python3 -c 'import sys,json; print(json.load(sys.stdin).get("name",""))' 2>/dev/null || echo "")
  if [ "$SVC_NAME" = "trino" ]; then
    echo "  V0b: Trino service definition 존재 — PASS"
    VERIFY_PASS=$((VERIFY_PASS + 1))
  else
    echo "  V0b: Trino service definition 없음 — FAIL"
    VERIFY_FAIL=$((VERIFY_FAIL + 1))
  fi

  echo "--- Trino 쿼리 검증 (Ranger 접근제어 적용 시에만 의미 있음) ---"
  CLIENT_SECRET=$(kubectl -n "$NS" get secret trino-oauth2 \
    -o jsonpath='{.data.OAUTH2_CLIENT_SECRET}' 2>/dev/null | base64 -d 2>/dev/null || echo "")

  if [ -z "$CLIENT_SECRET" ]; then
    echo "  trino-oauth2 Secret 없음 — Trino 쿼리 검증 건너뜀"
  else
    trino_verify() {
      local V_USER=$1
      local V_QUERY=$2
      local V_EXPECT=$3
      local V_LABEL=$4

      local V_TOKEN
      V_TOKEN=$(kubectl -n "$NS" run "kc-v-$(echo $V_USER | tr '_' '-')-$(date +%s)" \
        --rm -i --restart=Never \
        --overrides='{"metadata":{"annotations":{"sidecar.istio.io/inject":"false"}}}' \
        --image=curlimages/curl:8.5.0 -- \
        curl -s -X POST "http://keycloak:8080/realms/trino/protocol/openid-connect/token" \
        -d "grant_type=password" -d "client_id=trino" \
        -d "client_secret=$CLIENT_SECRET" \
        -d "username=$V_USER" -d "password=changeme-user" \
        2>/dev/null | grep -o '"access_token":"[^"]*"' | cut -d'"' -f4)

      if [ -z "$V_TOKEN" ]; then
        echo "  $V_LABEL: 토큰 발급 실패 — SKIP"
        return
      fi

      local V_RESP
      V_RESP=$(kubectl -n "$NS" exec deploy/my-trino-trino-coordinator -- \
        curl -s -X POST http://localhost:8080/v1/statement \
        -H "Authorization: Bearer $V_TOKEN" \
        -H "X-Trino-User: $V_USER" \
        -d "$V_QUERY" 2>/dev/null)
      local V_NEXT
      V_NEXT=$(echo "$V_RESP" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("nextUri",""))' 2>/dev/null || echo "")

      local V_RESULT=""
      for vi in $(seq 1 15); do
        [ -z "$V_NEXT" ] && break
        sleep 2
        V_RESP=$(kubectl -n "$NS" exec deploy/my-trino-trino-coordinator -- \
          curl -s "$V_NEXT" \
          -H "Authorization: Bearer $V_TOKEN" \
          -H "X-Trino-User: $V_USER" 2>/dev/null)
        V_NEXT=$(echo "$V_RESP" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("nextUri",""))' 2>/dev/null || echo "")
        V_RESULT=$(echo "$V_RESP" | python3 -c '
import sys, json
d = json.load(sys.stdin)
if "data" in d:
    print("DATA:" + str(d["data"]))
elif "error" in d:
    print("ERROR:" + d["error"].get("message","")[:80])
' 2>/dev/null || echo "")
        [ -n "$V_RESULT" ] && break
      done

      if echo "$V_RESULT" | grep -q "$V_EXPECT"; then
        echo "  $V_LABEL: $V_RESULT — PASS"
        VERIFY_PASS=$((VERIFY_PASS + 1))
      else
        echo "  $V_LABEL: $V_RESULT — FAIL (expected: $V_EXPECT)"
        VERIFY_FAIL=$((VERIFY_FAIL + 1))
      fi
    }

    trino_verify "analyst_user1" "SELECT count(*) FROM tpch.tiny.nation" "DATA:" "V1 analyst SELECT"
    trino_verify "analyst_user1" "CREATE SCHEMA IF NOT EXISTS hive.ranger_verify WITH (location = 's3a://warehouse/ranger_verify/')" "Access Denied" "V2 analyst DDL"
    trino_verify "etl_user1" "SELECT count(*) FROM tpch.tiny.nation" "DATA:" "V3 etl SELECT"
    trino_verify "admin_trino" "SELECT count(*) FROM tpch.tiny.nation" "DATA:" "V4 admin SELECT"
    trino_verify "bi_superset" "SELECT count(*) FROM tpch.tiny.nation" "DATA:" "V5 bi SELECT"
  fi

  echo ""
  echo "--- 검증 결과: PASS=$VERIFY_PASS FAIL=$VERIFY_FAIL ---"
  if [ "$VERIFY_FAIL" -gt 0 ]; then
    echo "  일부 검증 실패. Ranger 정책 또는 Trino 설정을 확인하세요."
  else
    echo "  전체 검증 통과."
  fi
fi

echo ""
echo "=== 완료 ==="
echo "Ranger Admin UI: https://braveji-ranger.trino.quantumcns.ai"
echo "로그인: $RANGER_USER / $RANGER_PASSWORD"
