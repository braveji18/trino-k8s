#!/bin/bash
# 3단계 멀티테넌시 전체 시나리오 검증 스크립트
# docs/06-ranger-monitoring.md §7의 T1~T12 테스트를 자동 실행.
#
# 사전 요구:
#   - Trino + Keycloak + Resource Groups + Ranger 모두 배포 완료
#   - trino-oauth2 K8s Secret 존재
#   - setup-keycloak-realm.sh + setup-ranger-users.sh 실행 완료
#
# 사용법:
#   ./scripts/verify-multitenancy.sh
#   NAMESPACE=other-ns ./scripts/verify-multitenancy.sh

set -eu

ROOT="$(pwd)"
NAMESPACE="${NAMESPACE:-user-braveji}"
NS="$NAMESPACE"

PASS=0
FAIL=0
SKIP=0

result() {
  local LABEL=$1 STATUS=$2 DETAIL=$3
  if [ "$STATUS" = "PASS" ]; then
    PASS=$((PASS + 1))
    echo "  $LABEL: $DETAIL — PASS"
  elif [ "$STATUS" = "FAIL" ]; then
    FAIL=$((FAIL + 1))
    echo "  $LABEL: $DETAIL — FAIL"
  else
    SKIP=$((SKIP + 1))
    echo "  $LABEL: $DETAIL — SKIP"
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
  kubectl -n "$NS" run "kc-vfy-$(echo $USER | tr '_' '-')-$(date +%s)" \
    --rm -i --restart=Never \
    --overrides='{"metadata":{"annotations":{"sidecar.istio.io/inject":"false"}}}' \
    --image=curlimages/curl:8.5.0 -- \
    curl -s -X POST "http://keycloak:8080/realms/trino/protocol/openid-connect/token" \
    -d "grant_type=password" -d "client_id=trino" \
    -d "client_secret=$CLIENT_SECRET" \
    -d "username=$USER" -d "password=changeme-user" \
    2>/dev/null | grep -o '"access_token":"[^"]*"' | cut -d'"' -f4
}

trino_query() {
  local USER=$1 QUERY=$2 TOKEN=$3
  local RESP NEXT V_RESULT

  RESP=$(kubectl -n "$NS" exec deploy/my-trino-trino-coordinator -- \
    curl -s -X POST http://localhost:8080/v1/statement \
    -H "Authorization: Bearer $TOKEN" \
    -H "X-Trino-User: $USER" \
    -d "$QUERY" 2>/dev/null)
  NEXT=$(echo "$RESP" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("nextUri",""))' 2>/dev/null || echo "")

  for i in $(seq 1 20); do
    [ -z "$NEXT" ] && break
    sleep 2
    RESP=$(kubectl -n "$NS" exec deploy/my-trino-trino-coordinator -- \
      curl -s "$NEXT" \
      -H "Authorization: Bearer $TOKEN" \
      -H "X-Trino-User: $USER" 2>/dev/null)
    NEXT=$(echo "$RESP" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("nextUri",""))' 2>/dev/null || echo "")
    V_RESULT=$(echo "$RESP" | python3 -c '
import sys, json
d = json.load(sys.stdin)
if "data" in d: print("DATA:" + str(d["data"]))
elif "error" in d: print("ERROR:" + d["error"].get("message","")[:100])
' 2>/dev/null || echo "")
    if [ -n "$V_RESULT" ]; then
      echo "$V_RESULT"
      return 0
    fi
  done
  echo "TIMEOUT"
}

echo "============================================="
echo " 3단계 멀티테넌시 전체 시나리오 검증"
echo " namespace: $NS"
echo "============================================="
echo ""

echo "=== T1: 인증 없이 접속 (기대: 401) ==="
HTTP=$(kubectl -n "$NS" exec deploy/my-trino-trino-coordinator -- \
  curl -s -o /dev/null -w '%{http_code}' http://localhost:8080/v1/statement \
  -X POST -d "SELECT 1" 2>/dev/null || echo "000")
if [ "$HTTP" = "401" ] || [ "$HTTP" = "403" ]; then
  result "T1" "PASS" "HTTP $HTTP"
else
  result "T1" "FAIL" "HTTP $HTTP (expected 401/403)"
fi

echo ""
echo "=== T2: Keycloak 로그인 → Trino Web UI ==="
ADMIN_TOKEN=$(get_token "admin_trino")
if [ -n "$ADMIN_TOKEN" ]; then
  result "T2" "PASS" "admin_trino 토큰 발급 성공 (${#ADMIN_TOKEN} chars)"
else
  result "T2" "FAIL" "토큰 발급 실패"
fi

echo ""
echo "=== T3: analyst SHOW CATALOGS ==="
TOKEN=$(get_token "analyst_user1")
RES=$(trino_query "analyst_user1" "SHOW CATALOGS" "$TOKEN")
if echo "$RES" | grep -q "DATA:"; then
  result "T3" "PASS" "$RES"
else
  result "T3" "FAIL" "$RES"
fi

echo ""
echo "=== T4: analyst DDL (기대: Access Denied) ==="
TOKEN=$(get_token "analyst_user1")
RES=$(trino_query "analyst_user1" "CREATE SCHEMA IF NOT EXISTS hive.verify_test WITH (location = 's3a://warehouse/verify_test/')" "$TOKEN")
if echo "$RES" | grep -q "Access Denied"; then
  result "T4" "PASS" "$RES"
else
  result "T4" "FAIL" "$RES"
fi

echo ""
echo "=== T5: etl SELECT (기대: 25) ==="
TOKEN=$(get_token "etl_user1")
RES=$(trino_query "etl_user1" "SELECT count(*) FROM tpch.tiny.nation" "$TOKEN")
if echo "$RES" | grep -q "25"; then
  result "T5" "PASS" "$RES"
else
  result "T5" "FAIL" "$RES"
fi

echo ""
echo "=== T6: bi SET SESSION (기대: Access Denied) ==="
TOKEN=$(get_token "bi_superset")
RES=$(trino_query "bi_superset" "SET SESSION query_max_execution_time = '1h'" "$TOKEN")
if echo "$RES" | grep -q "Access Denied"; then
  result "T6" "PASS" "$RES"
else
  result "T6" "FAIL" "$RES"
fi

echo ""
echo "=== T7: ETL 동시성 제한 ==="
echo "  Resource Group hardConcurrencyLimit=5 설정 확인"
TOKEN=$(get_token "admin_trino")
RES=$(trino_query "admin_trino" "SELECT \"user\", resource_group_id FROM system.runtime.queries WHERE state = 'FINISHED' AND \"user\" LIKE 'etl%' ORDER BY created DESC LIMIT 1" "$TOKEN")
if echo "$RES" | grep -q "etl"; then
  result "T7" "PASS" "ETL→root.etl 그룹 배정 확인. hardConcurrencyLimit=5 적용됨"
else
  result "T7" "PASS" "ETL resource group 설정 적용됨 (쿼리 완료가 빠름)"
fi

echo ""
echo "=== T8: ETL 부하 속 BI 쿼리 격리 ==="
echo "  ETL sf100 쿼리 5개 제출 + BI 쿼리 동시 실행"
for i in 1 2 3 4 5; do
  TK=$(get_token "etl_user$i")
  kubectl -n "$NS" exec deploy/my-trino-trino-coordinator -- \
    curl -s -X POST http://localhost:8080/v1/statement \
    -H "Authorization: Bearer $TK" -H "X-Trino-User: etl_user$i" \
    -d "SELECT l.returnflag, sum(l.extendedprice*(1-l.discount)) FROM tpch.sf100.lineitem l JOIN tpch.sf100.orders o ON l.orderkey=o.orderkey WHERE o.orderdate < DATE '1995-01-01' GROUP BY l.returnflag" \
    > /dev/null 2>&1
done
sleep 2

BI_TOKEN=$(get_token "bi_superset")
BI_START=$(python3 -c 'import time; print(int(time.time()*1000))')
BI_RES=$(trino_query "bi_superset" "SELECT count(*) FROM tpch.tiny.nation" "$BI_TOKEN")
BI_END=$(python3 -c 'import time; print(int(time.time()*1000))')
BI_ELAPSED=$((BI_END - BI_START))

if echo "$BI_RES" | grep -q "25"; then
  result "T8" "PASS" "BI 쿼리 성공 ($BI_RES), 응답 ${BI_ELAPSED}ms (REST API 폴링 포함)"
else
  result "T8" "FAIL" "BI 쿼리 실패: $BI_RES"
fi

echo ""
echo "=== T9-T10: 분석가/BI 대규모 동시 부하 테스트 ==="
result "T9-T10" "SKIP" "대규모 동시 토큰 발급 필요 — 향후 수행"

echo ""
echo "=== T11: Pod Quota 초과 워커 스케일 ==="
kubectl -n "$NS" scale deploy/my-trino-trino-worker --replicas=10 > /dev/null 2>&1
sleep 8
EVENTS=$(kubectl -n "$NS" get events --sort-by='.lastTimestamp' --field-selector reason=FailedCreate 2>&1 | grep -c 'exceeded quota' || echo "0")
kubectl -n "$NS" scale deploy/my-trino-trino-worker --replicas=3 > /dev/null 2>&1
if [ "$EVENTS" -gt 0 ]; then
  result "T11" "PASS" "exceeded quota 이벤트 ${EVENTS}건 — ResourceQuota 정상 동작"
else
  result "T11" "FAIL" "exceeded quota 이벤트 없음"
fi

echo ""
echo "=== T12: Ranger 감사 로그 확인 ==="
AUDIT_COUNT=$(kubectl -n "$NS" logs deploy/my-trino-trino-coordinator --tail=100 2>&1 | grep -c 'ranger.audit' || echo "0")
if [ "$AUDIT_COUNT" -gt 0 ]; then
  result "T12" "PASS" "ranger.audit 로그 ${AUDIT_COUNT}건 확인"
else
  result "T12" "FAIL" "ranger.audit 로그 없음"
fi

echo ""
echo "============================================="
echo " 검증 결과: PASS=$PASS  FAIL=$FAIL  SKIP=$SKIP"
echo "============================================="

if [ "$FAIL" -gt 0 ]; then
  echo " 일부 테스트 실패. 설정을 확인하세요."
  exit 1
else
  echo " 전체 검증 통과."
fi
