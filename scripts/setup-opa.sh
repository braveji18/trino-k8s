#!/bin/bash
# OPA(Open Policy Agent) 배포 + Rego 정책 적용 + Trino helm upgrade
# Ranger 대안으로 사용. docs/06-opa-monitoring.md 참고.
#
# 수행 단계:
#   [1/5] OPA Policy ConfigMap 적용 (trino.rego)
#   [2/5] OPA Deployment + Service 배포
#   [3/5] OPA Ready 대기 + /health 체크
#   [4/5] Trino helm upgrade (helm/values.yaml의 accessControl=opa 반영)
#   [5/5] 스모크 테스트 — admin_trino 토큰으로 SELECT 1
#
# 사전 요구:
#   - Trino + Keycloak 배포 완료
#   - helm/values.yaml의 accessControl이 opa로 설정되어 있음
#   - trino-oauth2 K8s Secret 존재
#
# 사용법:
#   ./scripts/setup-opa.sh
#   NAMESPACE=other-ns ./scripts/setup-opa.sh
#   SKIP_HELM_UPGRADE=1 ./scripts/setup-opa.sh   # helm upgrade 생략 (정책만 갱신)
#   SKIP_SMOKE=1 ./scripts/setup-opa.sh          # 스모크 테스트 생략

set -eu

ROOT="$(pwd)"

# config.env가 있으면 source
if [ -f "$ROOT/scripts/config.env" ]; then
  # shellcheck disable=SC1091
  . "$ROOT/scripts/config.env"
fi

NAMESPACE="${NAMESPACE:-user-braveji}"
RELEASE_NAME="${RELEASE_NAME:-my-trino}"
CHART_VERSION="${CHART_VERSION:-1.42.1}"
SKIP_HELM_UPGRADE="${SKIP_HELM_UPGRADE:-0}"
SKIP_SMOKE="${SKIP_SMOKE:-0}"

NS="$NAMESPACE"

echo "============================================="
echo " OPA 접근제어 배포"
echo " namespace:     $NS"
echo " release:       $RELEASE_NAME"
echo " chart version: $CHART_VERSION"
echo "============================================="
echo ""

# ── [1/5] OPA Policy ConfigMap ────────────────────────────────────
echo "=== [1/5] OPA Policy ConfigMap 적용 ==="
kubectl -n "$NS" apply -f "$ROOT/manifests/opa/opa-policy-configmap.yaml"
echo ""

# ── [2/5] OPA Deployment + Service ────────────────────────────────
echo "=== [2/5] OPA Deployment + Service 배포 ==="
kubectl -n "$NS" apply -f "$ROOT/manifests/opa/opa-deployment.yaml"
echo ""

# ── [3/5] OPA Ready 대기 ──────────────────────────────────────────
echo "=== [3/5] OPA Ready 대기 ==="
kubectl -n "$NS" rollout status deploy/opa --timeout=120s

# 정책 업데이트된 경우 pod 재시작으로 반영 (ConfigMap watch는 OPA 1.x에선 수동)
# rollout restart 후 다시 대기
if [ -n "${OPA_RESTART:-}" ]; then
  echo "  OPA_RESTART=1 — rollout restart 수행"
  kubectl -n "$NS" rollout restart deploy/opa
  kubectl -n "$NS" rollout status deploy/opa --timeout=120s
fi

# /health 스모크 체크 (OPA static 이미지는 wget/curl 없음 → ephemeral pod 사용)
echo "  OPA /health 체크 ..."
HEALTH=$(kubectl -n "$NS" run "opa-health-$(date +%s)" \
  --rm -i --restart=Never --quiet \
  --overrides='{"metadata":{"annotations":{"sidecar.istio.io/inject":"false"}}}' \
  --image=curlimages/curl:8.5.0 -- \
  curl -s -o /dev/null -w '%{http_code}' http://opa:8181/health 2>/dev/null || echo "000")
if [ "$HEALTH" = "200" ]; then
  echo "  OPA /health → HTTP 200 (정상)"
else
  echo "  OPA /health → HTTP $HEALTH (비정상)"
  exit 1
fi
echo ""

# ── [4/5] Trino helm upgrade ──────────────────────────────────────
if [ "$SKIP_HELM_UPGRADE" = "1" ]; then
  echo "=== [4/5] Trino helm upgrade — SKIP ==="
  echo ""
else
  echo "=== [4/5] Trino helm upgrade (accessControl=opa 반영) ==="
  helm upgrade "$RELEASE_NAME" "$RELEASE_NAME/trino" \
    -n "$NS" \
    -f "$ROOT/helm/values.yaml" \
    --version "$CHART_VERSION" \
    | tail -5
  kubectl -n "$NS" rollout status deploy/${RELEASE_NAME}-trino-coordinator --timeout=180s
  echo ""
fi

# ── [5/5] 스모크 테스트 ──────────────────────────────────────────
if [ "$SKIP_SMOKE" = "1" ]; then
  echo "=== [5/5] 스모크 테스트 — SKIP ==="
  echo ""
else
  echo "=== [5/5] 스모크 테스트 — admin_trino SELECT 1 ==="
  CLIENT_SECRET=$(kubectl -n "$NS" get secret trino-oauth2 \
    -o jsonpath='{.data.OAUTH2_CLIENT_SECRET}' 2>/dev/null | base64 -d 2>/dev/null || echo "")
  if [ -z "$CLIENT_SECRET" ]; then
    echo "  WARN: trino-oauth2 Secret 없음 — 스모크 테스트 생략"
  else
    TOKEN=$(kubectl -n "$NS" run "kc-smoke-$(date +%s)" \
      --rm -i --restart=Never --quiet \
      --overrides='{"metadata":{"annotations":{"sidecar.istio.io/inject":"false"}}}' \
      --image=curlimages/curl:8.5.0 -- \
      curl -s -X POST "http://keycloak:8080/realms/trino/protocol/openid-connect/token" \
      -d "grant_type=password" -d "client_id=trino" \
      -d "client_secret=$CLIENT_SECRET" \
      -d "username=admin_trino" -d "password=changeme-user" \
      2>/dev/null | grep -o '"access_token":"[^"]*"' | cut -d'"' -f4)

    if [ -z "$TOKEN" ]; then
      echo "  FAIL: admin_trino 토큰 발급 실패"
      exit 1
    fi

    RESP=$(kubectl -n "$NS" exec "deploy/${RELEASE_NAME}-trino-coordinator" -- \
      curl -s -X POST http://localhost:8080/v1/statement \
      -H "Authorization: Bearer $TOKEN" \
      -H "X-Trino-User: admin_trino" \
      -d "SELECT 1")
    NEXT=$(echo "$RESP" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("nextUri",""))' 2>/dev/null || echo "")

    STATE="QUEUED"
    for i in $(seq 1 15); do
      [ -z "$NEXT" ] && break
      sleep 1
      RESP=$(kubectl -n "$NS" exec "deploy/${RELEASE_NAME}-trino-coordinator" -- \
        curl -s "$NEXT" -H "Authorization: Bearer $TOKEN" -H "X-Trino-User: admin_trino")
      STATE=$(echo "$RESP" | python3 -c 'import sys,json; print(json.load(sys.stdin)["stats"]["state"])' 2>/dev/null || echo "?")
      [ "$STATE" = "FINISHED" ] && break
      [ "$STATE" = "FAILED" ] && break
      NEXT=$(echo "$RESP" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("nextUri",""))' 2>/dev/null || echo "")
    done

    if [ "$STATE" = "FINISHED" ]; then
      echo "  PASS: admin_trino SELECT 1 → FINISHED"
    else
      ERR=$(echo "$RESP" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("error",{}).get("message",""))' 2>/dev/null || echo "")
      echo "  FAIL: state=$STATE err=$ERR"
      exit 1
    fi
  fi
  echo ""
fi

echo "============================================="
echo " OPA 배포 완료"
echo "============================================="
echo ""
echo " - OPA 정책:     kubectl -n $NS edit cm trino-opa-policy"
echo " - OPA 로그:     kubectl -n $NS logs deploy/opa -f"
echo " - Decision log: kubectl -n $NS logs deploy/opa | grep 'trino/allow'"
echo " - 검증:         ./scripts/verify-opa.sh"
