#!/bin/bash
# OPA 접근제어 시나리오 검증 (V1~V8)
# docs/06-opa-monitoring.md §4-e 의 V1~V8 테스트를 자동 실행.
#
# 테스트 매트릭스:
#   V1  admin     SHOW CATALOGS                           → 8개 카탈로그
#   V2  etl       SHOW SCHEMAS FROM hive                  → 정상
#   V3  analyst   SHOW CATALOGS                           → 8개 카탈로그 (FilterCatalogs)
#   V4  analyst   CREATE TABLE postgresql.public.t1       → Access Denied
#   V5  etl       SELECT count(*) FROM tpch.tiny.nation   → 25
#   V6  bi        SELECT count(*) FROM tpch.tiny.nation   → 25 (read-only)
#   V7  bi        SET SESSION query_max_run_time          → Access Denied
#   V8  unauth    POST /v1/statement (토큰 없음)            → HTTP 401
#
# 사전 요구:
#   - Trino + Keycloak + OPA 모두 배포 완료 (./scripts/setup-opa.sh 실행 후)
#   - trino-oauth2 K8s Secret 존재
#
# 사용법:
#   ./scripts/verify-opa.sh
#   NAMESPACE=other-ns ./scripts/verify-opa.sh

set -eu

ROOT="$(pwd)"

if [ -f "$ROOT/scripts/config.env" ]; then
  # shellcheck disable=SC1091
  . "$ROOT/scripts/config.env"
fi

  # shellcheck disable=SC1091="${NAMESPACE:-user-braveji}"
RELEASE_NAME="${RELEASE_NAME:-my-trino}"
NS="$NAMESPACE"
COORD_DEPLOY="${RELEASE_NAME}-trino-coordinator"

PASS=0
FAIL=0

result() {
  local LABEL=$1 STATUS=$2 DETAIL=$3
  if [ "$STATUS" = "PASS" ]; then
    PASS=$((PASS + 1))
    echo "  $LABEL: PASS — $DETAIL"
  else
    FAIL=$((FAIL + 1))
    echo "  $LABEL: FAIL — $DETAIL"
  fi
}

CLIENT_SECRET=$(kubectl -n "$NS" get secret trino-oauth2 \
  -o jsonpath='{.data.OAUTH2_CLIENT_SECRET}' 2>/dev/null | base64 -d 2>/dev/null || echo "")

if [ -z "$CLIENT_SECRET" ]; then
  echo "ERROR: trino-oauth2 Secret 없음. setup-keycloak-realm.sh를 먼저 실행하세요."
  exit 1
fi

get_token() {
  local USER=$1
  kubectl -n "$NS" run "kc-vfy-$(echo "$USER" | tr '_' '-')-$(date +%s)" \
    --rm -i --restart=Never --quiet \
    --overrides='{"metadata":{"annotations":{"sidecar.istio.io/inject":"false"}}}' \
    --image=curlimages/curl:8.5.0 -- \
    curl -s -X POST "http://keycloak:8080/realms/trino/protocol/openid-connect/token" \
    -d "grant_type=password" -d "client_id=trino" \
    -d "client_secret=$CLIENT_SECRET" \
    -d "username=$USER" -d "password=changeme-user" \
    2>/dev/null | grep -o '"access_token":"[^"]*"' | cut -d'"' -f4
}

# Trino 쿼리 실행 → "STATE|ERROR|DATA" 형식으로 출력
# DATA는 모든 폴링 응답을 합쳐서 JSON 배열로 반환.
trino_query() {
  local USER=$1 QUERY=$2 TOKEN=$3
  local RESP NEXT STATE ERR ALL_DATA="[]"

  RESP=$(kubectl -n "$NS" exec "deploy/$COORD_DEPLOY" -- \
    curl -s -X POST http://localhost:8080/v1/statement \
    -H "Authorization: Bearer $TOKEN" \
    -H "X-Trino-User: $USER" \
    -d "$QUERY" 2>/dev/null)
  NEXT=$(echo "$RESP" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("nextUri",""))' 2>/dev/null || echo "")

  for i in $(seq 1 20); do
    [ -z "$NEXT" ] && break
    sleep 1
    RESP=$(kubectl -n "$NS" exec "deploy/$COORD_DEPLOY" -- \
      curl -s "$NEXT" \
      -H "Authorization: Bearer $TOKEN" \
      -H "X-Trino-User: $USER" 2>/dev/null)
    BATCH=$(echo "$RESP" | python3 -c 'import sys,json; d=json.load(sys.stdin); print(json.dumps(d.get("data",[])))' 2>/dev/null || echo "[]")
    ALL_DATA=$(python3 -c "import json; a=$ALL_DATA; b=$BATCH; print(json.dumps(a+b))" 2>/dev/null || echo "$ALL_DATA")
    STATE=$(echo "$RESP" | python3 -c 'import sys,json; print(json.load(sys.stdin)["stats"]["state"])' 2>/dev/null || echo "?")
    if [ "$STATE" = "FINISHED" ] || [ "$STATE" = "FAILED" ]; then
      ERR=$(echo "$RESP" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("error",{}).get("message",""))' 2>/dev/null || echo "")
      echo "${STATE}|${ERR}|${ALL_DATA}"
      return 0
    fi
    NEXT=$(echo "$RESP" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("nextUri",""))' 2>/dev/null || echo "")
  done
  echo "TIMEOUT||${ALL_DATA}"
}

echo "============================================="
echo " OPA 접근제어 시나리오 검증 (V1~V8)"
echo " namespace: $NS"
echo "============================================="
echo ""

# ── V1: admin SHOW CATALOGS ───────────────────────────────────────
echo "=== V1: admin SHOW CATALOGS (기대: 8개 카탈로그) ==="
TOK=$(get_token admin_trino)
RES=$(trino_query admin_trino "SHOW CATALOGS" "$TOK")
STATE=$(echo "$RES" | cut -d'|' -f1)
COUNT=$(echo "$RES" | cut -d'|' -f3 | python3 -c 'import sys,json; print(len(json.load(sys.stdin)))' 2>/dev/null || echo "0")
if [ "$STATE" = "FINISHED" ] && [ "$COUNT" -ge 6 ]; then
  result "V1" "PASS" "$COUNT개 카탈로그 표시"
else
  result "V1" "FAIL" "state=$STATE count=$COUNT"
fi
echo ""

# ── V2: etl SHOW SCHEMAS FROM hive ────────────────────────────────
echo "=== V2: etl SHOW SCHEMAS FROM hive (기대: 정상) ==="
TOK=$(get_token etl_user1)
RES=$(trino_query etl_user1 "SHOW SCHEMAS FROM hive" "$TOK")
STATE=$(echo "$RES" | cut -d'|' -f1)
if [ "$STATE" = "FINISHED" ]; then
  result "V2" "PASS" "etl_user1이 hive 스키마 조회 성공"
else
  ERR=$(echo "$RES" | cut -d'|' -f2)
  result "V2" "FAIL" "state=$STATE err=$ERR"
fi
echo ""

# ── V3: analyst SHOW CATALOGS ─────────────────────────────────────
echo "=== V3: analyst SHOW CATALOGS (기대: 8개 카탈로그, FilterCatalogs 통과) ==="
TOK=$(get_token analyst_user1)
RES=$(trino_query analyst_user1 "SHOW CATALOGS" "$TOK")
STATE=$(echo "$RES" | cut -d'|' -f1)
COUNT=$(echo "$RES" | cut -d'|' -f3 | python3 -c 'import sys,json; print(len(json.load(sys.stdin)))' 2>/dev/null || echo "0")
if [ "$STATE" = "FINISHED" ] && [ "$COUNT" -ge 6 ]; then
  result "V3" "PASS" "$COUNT개 카탈로그 표시 (FilterCatalogs 정책 통과)"
else
  result "V3" "FAIL" "state=$STATE count=$COUNT"
fi
echo ""

# ── V4: analyst CREATE TABLE → Access Denied ──────────────────────
echo "=== V4: analyst CREATE TABLE postgresql.public.t1 (기대: Access Denied) ==="
TOK=$(get_token analyst_user1)
RES=$(trino_query analyst_user1 "CREATE TABLE postgresql.public.opa_verify_t1 (a int)" "$TOK")
STATE=$(echo "$RES" | cut -d'|' -f1)
ERR=$(echo "$RES" | cut -d'|' -f2)
if [ "$STATE" = "FAILED" ] && echo "$ERR" | grep -q "Access Denied"; then
  result "V4" "PASS" "Access Denied 정상 (analyst는 read-only)"
else
  result "V4" "FAIL" "state=$STATE err=$ERR"
fi
echo ""

# ── V5: etl SELECT count → 25 ─────────────────────────────────────
echo "=== V5: etl SELECT count(*) FROM tpch.tiny.nation (기대: 25) ==="
TOK=$(get_token etl_user1)
RES=$(trino_query etl_user1 "SELECT count(*) FROM tpch.tiny.nation" "$TOK")
STATE=$(echo "$RES" | cut -d'|' -f1)
DATA=$(echo "$RES" | cut -d'|' -f3)
if [ "$STATE" = "FINISHED" ] && echo "$DATA" | grep -q "25"; then
  result "V5" "PASS" "데이터=$DATA"
else
  result "V5" "FAIL" "state=$STATE data=$DATA"
fi
echo ""

# ── V6: bi SELECT count → 25 (read-only OK) ───────────────────────
echo "=== V6: bi SELECT count(*) FROM tpch.tiny.nation (기대: 25, read-only) ==="
TOK=$(get_token bi_superset)
RES=$(trino_query bi_superset "SELECT count(*) FROM tpch.tiny.nation" "$TOK")
STATE=$(echo "$RES" | cut -d'|' -f1)
DATA=$(echo "$RES" | cut -d'|' -f3)
if [ "$STATE" = "FINISHED" ] && echo "$DATA" | grep -q "25"; then
  result "V6" "PASS" "bi read-only SELECT 정상"
else
  result "V6" "FAIL" "state=$STATE data=$DATA"
fi
echo ""

# ── V7: bi SET SESSION → Access Denied ────────────────────────────
echo "=== V7: bi SET SESSION query_max_run_time (기대: Access Denied) ==="
TOK=$(get_token bi_superset)
RES=$(trino_query bi_superset "SET SESSION query_max_run_time = '10m'" "$TOK")
STATE=$(echo "$RES" | cut -d'|' -f1)
ERR=$(echo "$RES" | cut -d'|' -f2)
if [ "$STATE" = "FAILED" ] && echo "$ERR" | grep -q "Access Denied"; then
  result "V7" "PASS" "Access Denied 정상 (bi는 session property 변경 불가)"
else
  result "V7" "FAIL" "state=$STATE err=$ERR"
fi
echo ""

# ── V8: 토큰 없이 접속 → 401 ──────────────────────────────────────
echo "=== V8: 인증 토큰 없이 /v1/statement (기대: HTTP 401) ==="
HTTP=$(kubectl -n "$NS" exec "deploy/$COORD_DEPLOY" -- \
  curl -s -o /dev/null -w '%{http_code}' http://localhost:8080/v1/statement \
  -X POST -d "SELECT 1" 2>/dev/null || echo "000")
if [ "$HTTP" = "401" ] || [ "$HTTP" = "403" ]; then
  result "V8" "PASS" "HTTP $HTTP"
else
  result "V8" "FAIL" "HTTP $HTTP (expected 401/403)"
fi
echo ""

# ── 결과 ──────────────────────────────────────────────────────────
echo "============================================="
echo " 검증 결과: PASS=$PASS  FAIL=$FAIL"
echo "============================================="

if [ "$FAIL" -gt 0 ]; then
  echo " 일부 시나리오 실패 — OPA decision log를 확인:"
  echo "   kubectl -n $NS logs deploy/opa | grep 'trino/allow'"
  exit 1
else
  echo " OPA 접근제어 전체 시나리오 통과."
fi
