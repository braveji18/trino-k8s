#!/usr/bin/env bash
# Trino Gateway 설치 스크립트
# docs/08-trino-gateway.md 의 §2 절차를 자동화.
#
# 수행 단계:
#   [1/5] gateway-postgres (CNPG) 적용 + Ready 대기
#   [2/5] RSA 키쌍 생성 + trino-gateway-auth Secret
#   [3/5] DB / Admin 비밀번호 준비
#   [4/5] helm install/upgrade trino-gateway
#   [5/5] 기존 my-trino 클러스터를 백엔드로 등록 + 검증
#
# 사전 요구:
#   - install.sh로 1단계 Trino 스택이 정상 동작 중
#   - CNPG operator 설치 완료
#   - openssl 로컬 설치 (RSA 키 생성)
#   - *.trino.quantumcns.ai DNS 와일드카드 설정 완료
#
# 사용법:
#   ./scripts/install-gateway.sh                    # config.env 기본값
#   NAMESPACE=foo ./scripts/install-gateway.sh      # 환경변수 override
#   ./scripts/install-gateway.sh foo                # 첫 인자로 namespace 지정
#
# 환경변수:
#   ADMIN_PW=<pw>            관리자 비밀번호. 미설정 시 자동 생성 + 출력
#   GATEWAY_RELEASE=tg       helm release 이름 (기본: trino-gateway)
#   GATEWAY_CHART_VERSION    chart 버전 (기본: 1.18.0)
#   TRINO_BACKEND_NAME       등록할 백엔드 이름 (기본: my-trino)
#   TRINO_BACKEND_URL        백엔드 proxyTo URL (기본: http://my-trino-trino:8080)
#   ROUTING_GROUP            백엔드 routingGroup (기본: adhoc)
#
# Skip 플래그:
#   SKIP_PG=1                gateway-postgres 적용 건너뜀
#   SKIP_AUTH_SECRET=1       RSA 키/Secret 재생성 건너뜀 (이미 있으면 자동 skip됨)
#   SKIP_HELM=1              helm 설치 건너뜀 (정책/백엔드만 갱신)
#   SKIP_BACKEND=1           백엔드 등록 건너뜀
#   SKIP_VERIFY=1            검증 단계 건너뜀

set -euo pipefail

ROOT="$(pwd)"

# 설정 로드
# shellcheck disable=SC1091
source "$ROOT/scripts/config.env"

# CLI 인자가 있으면 namespace override
if [[ $# -ge 1 && -n "$1" ]]; then
  NAMESPACE="$1"
fi

NS="$NAMESPACE"
GATEWAY_RELEASE="${GATEWAY_RELEASE:-trino-gateway}"
GATEWAY_CHART_VERSION="${GATEWAY_CHART_VERSION:-1.18.0}"
TRINO_BACKEND_NAME="${TRINO_BACKEND_NAME:-my-trino}"
TRINO_BACKEND_URL="${TRINO_BACKEND_URL:-http://my-trino-trino:8080}"
ROUTING_GROUP="${ROUTING_GROUP:-adhoc}"

SKIP_PG="${SKIP_PG:-}"
SKIP_AUTH_SECRET="${SKIP_AUTH_SECRET:-}"
SKIP_HELM="${SKIP_HELM:-}"
SKIP_BACKEND="${SKIP_BACKEND:-}"
SKIP_VERIFY="${SKIP_VERIFY:-}"

echo "============================================="
echo " Trino Gateway 설치"
echo "============================================="
echo " namespace      : $NS"
echo " release        : $GATEWAY_RELEASE"
echo " chart version  : $GATEWAY_CHART_VERSION"
echo " backend        : $TRINO_BACKEND_NAME → $TRINO_BACKEND_URL"
echo " routing group  : $ROUTING_GROUP"
echo "============================================="

# ── [1/5] gateway-postgres ──────────────────────────────────────────
if [[ -n "$SKIP_PG" ]]; then
  echo ""
  echo "=== [1/5] gateway-postgres — SKIP ==="
else
  echo ""
  echo "=== [1/5] gateway-postgres (CNPG) 적용 ==="
  kubectl apply -n "$NS" -f "$ROOT/manifests/trino-gateway/gateway-postgres.yaml"

  echo "    gateway-postgres Ready 대기 (최대 5분)..."
  for i in $(seq 1 60); do
    READY=$(kubectl -n "$NS" get cluster.postgresql.cnpg.io gateway-postgres \
              -o jsonpath='{.status.readyInstances}' 2>/dev/null || echo "")
    if [[ "$READY" = "1" ]]; then
      echo "    gateway-postgres Ready"
      break
    fi
    sleep 5
  done

  if [[ "$READY" != "1" ]]; then
    echo "    ERROR: gateway-postgres가 5분 내에 Ready 상태가 되지 않음" >&2
    exit 1
  fi
fi

# ── [2/5] RSA 키쌍 + trino-gateway-auth Secret ──────────────────────
if [[ -n "$SKIP_AUTH_SECRET" ]]; then
  echo ""
  echo "=== [2/5] trino-gateway-auth Secret — SKIP ==="
elif kubectl -n "$NS" get secret trino-gateway-auth >/dev/null 2>&1; then
  echo ""
  echo "=== [2/5] trino-gateway-auth Secret 이미 존재 — 재사용 ==="
else
  echo ""
  echo "=== [2/5] RSA 키쌍 생성 + trino-gateway-auth Secret ==="
  TMPDIR=$(mktemp -d)
  trap 'rm -rf "$TMPDIR"' EXIT

  openssl genrsa -out "$TMPDIR/gw-key.pem" 2048 2>/dev/null
  openssl rsa -in "$TMPDIR/gw-key.pem" -pubout -out "$TMPDIR/gw-pub.pem" 2>/dev/null

  kubectl -n "$NS" create secret generic trino-gateway-auth \
    --from-file=privateKey.pem="$TMPDIR/gw-key.pem" \
    --from-file=publicKey.pem="$TMPDIR/gw-pub.pem" \
    --dry-run=client -o yaml | kubectl apply -f -

  echo "    trino-gateway-auth Secret 생성 완료"
fi

# ── [3/5] DB / Admin 비밀번호 준비 ──────────────────────────────────
echo ""
echo "=== [3/5] DB / Admin 비밀번호 준비 ==="

DB_PW=$(kubectl -n "$NS" get secret gateway-postgres-app \
        -o jsonpath='{.data.password}' 2>/dev/null | base64 -d || echo "")
if [[ -z "$DB_PW" ]]; then
  echo "    ERROR: gateway-postgres-app Secret에서 password를 읽을 수 없음" >&2
  echo "           [1/5]를 먼저 실행하거나 SKIP_PG 해제 필요" >&2
  exit 1
fi
echo "    DB password    : (gateway-postgres-app Secret에서 로드)"

if [[ -z "${ADMIN_PW:-}" ]]; then
  # zsh/bash 호환 — head -c 사용
  ADMIN_PW=$(openssl rand -base64 24 | tr -d '/+=' | head -c 20)
  echo "    Admin password : 자동 생성됨 → $ADMIN_PW"
  echo "    ⚠️  이 값을 안전한 곳에 보관하세요. 잃어버리면:"
  echo "         kubectl -n $NS get secret trino-gateway-configuration \\"
  echo "           -o jsonpath='{.data.config\\.yaml}' | base64 -d | grep -A2 presetUsers"
else
  echo "    Admin password : 환경변수 ADMIN_PW 사용"
fi

# ── [4/5] helm install/upgrade ──────────────────────────────────────
if [[ -n "$SKIP_HELM" ]]; then
  echo ""
  echo "=== [4/5] helm install — SKIP ==="
else
  echo ""
  echo "=== [4/5] helm install/upgrade trino-gateway ==="
  helm repo add my-trino https://trinodb.github.io/charts >/dev/null 2>&1 || true
  helm repo update my-trino >/dev/null

  helm upgrade --install "$GATEWAY_RELEASE" my-trino/trino-gateway \
    -n "$NS" \
    -f "$ROOT/helm/trino-gateway-values.yaml" \
    --set "config.dataStore.password=$DB_PW" \
    --set "config.presetUsers.admin.password=$ADMIN_PW" \
    --version "$GATEWAY_CHART_VERSION" \
    --wait --timeout 5m

  kubectl -n "$NS" rollout status "deploy/$GATEWAY_RELEASE" --timeout=180s

  # sidecar 자동 주입이 켜져 있으면 Pod이 2/2로 뜸 → 명시적 안내
  READY=$(kubectl -n "$NS" get pod -l "app.kubernetes.io/instance=$GATEWAY_RELEASE" \
            -o jsonpath='{.items[0].status.containerStatuses[*].ready}' 2>/dev/null || echo "")
  COUNT=$(echo "$READY" | wc -w | tr -d ' ')
  if [[ "$COUNT" -gt 1 ]]; then
    echo ""
    echo "    ⚠️  Pod 컨테이너가 ${COUNT}개입니다 (Istio sidecar 자동 주입 의심)."
    echo "         helm/trino-gateway-values.yaml의 podAnnotations.sidecar.istio.io/inject"
    echo "         설정을 확인하세요. ingress가 403 RBAC denied로 막힐 수 있음."
  fi
fi

# ── [5/5] 백엔드 등록 ───────────────────────────────────────────────
if [[ -n "$SKIP_BACKEND" ]]; then
  echo ""
  echo "=== [5/5] 백엔드 등록 — SKIP ==="
else
  echo ""
  echo "=== [5/5] 백엔드 등록: $TRINO_BACKEND_NAME → $TRINO_BACKEND_URL ==="

  # /gateway/backend/modify/* 는 ADMIN 권한 필요 → port-forward 사용
  PF_PORT=18080
  kubectl -n "$NS" port-forward "svc/$GATEWAY_RELEASE" "${PF_PORT}:8080" \
    >/dev/null 2>&1 &
  PF_PID=$!
  trap 'kill $PF_PID 2>/dev/null || true; rm -rf "${TMPDIR:-/dev/null}"' EXIT
  sleep 3

  # 이미 등록된 백엔드가 있는지 확인 (idempotent)
  EXISTING=$(curl -s "http://localhost:${PF_PORT}/gateway/backend/all" \
             | grep -o "\"name\":\"$TRINO_BACKEND_NAME\"" || echo "")

  if [[ -n "$EXISTING" ]]; then
    echo "    백엔드 '$TRINO_BACKEND_NAME' 이미 존재 — 갱신"
    METHOD=update
  else
    echo "    백엔드 '$TRINO_BACKEND_NAME' 신규 등록"
    METHOD=add
  fi

  RESP=$(curl -s -w "\nHTTP_CODE:%{http_code}" \
    -X POST "http://localhost:${PF_PORT}/gateway/backend/modify/$METHOD" \
    -H 'Content-Type: application/json' \
    -d "{
      \"name\": \"$TRINO_BACKEND_NAME\",
      \"proxyTo\": \"$TRINO_BACKEND_URL\",
      \"active\": true,
      \"routingGroup\": \"$ROUTING_GROUP\"
    }")

  CODE=$(echo "$RESP" | grep -o 'HTTP_CODE:[0-9]*' | cut -d: -f2)
  if [[ "$CODE" = "200" ]]; then
    echo "    백엔드 등록 OK (HTTP 200)"
  else
    echo "    ERROR: 백엔드 등록 실패 (HTTP $CODE)" >&2
    echo "$RESP" >&2
    kill $PF_PID 2>/dev/null || true
    exit 1
  fi

  kill $PF_PID 2>/dev/null || true
fi

# ── 검증 ────────────────────────────────────────────────────────────
if [[ -n "$SKIP_VERIFY" ]]; then
  echo ""
  echo "=== 검증 — SKIP ==="
else
  echo ""
  echo "=== 검증 ==="

  # 1) 외부 ingress에서 /api/public/backends
  GW_HOST=$(kubectl -n "$NS" get ingress "$GATEWAY_RELEASE" \
             -o jsonpath='{.spec.rules[0].host}' 2>/dev/null || echo "")
  if [[ -n "$GW_HOST" ]]; then
    echo "    [1] GET http://$GW_HOST/api/public/backends"
    BACKENDS=$(curl -s -w "\nHTTP_CODE:%{http_code}" "http://$GW_HOST/api/public/backends" || echo "")
    BCODE=$(echo "$BACKENDS" | grep -o 'HTTP_CODE:[0-9]*' | cut -d: -f2)
    if [[ "$BCODE" = "200" ]]; then
      echo "        OK (HTTP 200)"
      echo "$BACKENDS" | grep -v 'HTTP_CODE:' | head -3
    else
      echo "        ERROR (HTTP $BCODE) — Istio sidecar 또는 ingress 점검"
    fi
  else
    echo "    [1] ingress 호스트를 찾을 수 없음 — 외부 검증 생략"
  fi

  # 2) 백엔드 헬스체크 로그
  echo ""
  echo "    [2] 백엔드 헬스체크 로그 (최근 50줄):"
  kubectl -n "$NS" logs "deploy/$GATEWAY_RELEASE" --tail=50 \
    | grep -i 'isHealthy\|backend' | tail -5 || echo "    (헬스체크 로그 아직 없음)"
fi

echo ""
echo "============================================="
echo " Trino Gateway 설치 완료"
echo "============================================="
GW_HOST=$(kubectl -n "$NS" get ingress "$GATEWAY_RELEASE" \
           -o jsonpath='{.spec.rules[0].host}' 2>/dev/null || echo "<ingress 없음>")
echo " Web UI : http://$GW_HOST/   (admin / \$ADMIN_PW)"
echo " API    : http://$GW_HOST/api/public/backends"
echo ""
echo " 다음 단계:"
echo "  - Trino CLI에서 라우팅: trino --server http://$GW_HOST"
echo "  - 라우팅 그룹: --http-header 'X-Trino-Routing-Group: etl'"
echo "  - 운영 가이드: docs/08-trino-gateway.md §3 (알려진 함정), §5 (blue/green)"
