#!/usr/bin/env bash
# 3단계 멀티테넌시 컴포넌트 설치 스크립트
# Keycloak (인증) + Ranger (인가) 배포
#
# 사전 요구:
#   - install.sh로 1단계 Trino 스택이 정상 동작 중
#   - CNPG operator 설치 완료
#   - *.trino.quantumcns.ai DNS 와일드카드 설정 완료
#
# 사용법:
#   ./scripts/install-keycloak-ranger.sh                  # config.env 기본값
#   NAMESPACE=foo ./scripts/install-keycloak-ranger.sh    # 환경변수로 override
#   ./scripts/install-keycloak-ranger.sh foo              # 첫 인자로 namespace 지정

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
echo "==> Target namespace: $NS"

# ── 1. Keycloak PostgreSQL (CNPG) ──────────────────────────────────
echo "==> 1) Keycloak PostgreSQL (CloudNativePG)"
kubectl apply -n "$NS" -f "$ROOT/manifests/keycloak/keycloak-postgres.yaml"
echo "    keycloak-postgres CNPG 클러스터 Ready 대기..."
kubectl -n "$NS" wait --for=condition=Ready \
  clusters.postgresql.cnpg.io/keycloak-postgres --timeout=300s

# ── 2. Keycloak Deployment + Service ───────────────────────────────
echo "==> 2) Keycloak Deployment + Service"
kubectl apply -n "$NS" -f "$ROOT/manifests/keycloak/keycloak-deployment.yaml"
echo "    Keycloak Pod Ready 대기..."
kubectl -n "$NS" rollout status deployment/keycloak --timeout=300s

# ── 3. Keycloak Ingress ────────────────────────────────────────────
echo "==> 3) Keycloak Ingress"
kubectl apply -n "$NS" -f "$ROOT/manifests/keycloak/keycloak-ingress.yaml"

# ── 4. Ranger PostgreSQL (CNPG) ───────────────────────────────────
echo "==> 4) Ranger PostgreSQL (CloudNativePG)"
kubectl apply -n "$NS" -f "$ROOT/manifests/ranger/ranger-postgres.yaml"
echo "    ranger-postgres CNPG 클러스터 Ready 대기..."
# CNPG CRD의 condition 이름이 다를 수 있으므로 polling으로 대기
for i in $(seq 1 30); do
  READY=$(kubectl -n "$NS" get cluster.postgresql.cnpg.io ranger-postgres \
    -o jsonpath='{.status.readyInstances}' 2>/dev/null || echo "")
  if [ "$READY" = "1" ]; then
    echo "    ranger-postgres Ready"
    break
  fi
  sleep 10
done

# ── 5. Ranger Admin Deployment + Service + Ingress ────────────────
echo "==> 5) Ranger Admin Deployment + Service"
kubectl apply -n "$NS" -f "$ROOT/manifests/ranger/ranger-admin-deployment.yaml"
echo "==> 5b) Ranger Admin Ingress"
kubectl apply -n "$NS" -f "$ROOT/manifests/ranger/ranger-admin-ingress.yaml"
echo "    Ranger Admin Pod Ready 대기 (setup.sh + Tomcat ~2분)..."
kubectl -n "$NS" rollout status deployment/ranger-admin --timeout=300s || true

echo ""
echo "==> Done."
echo "    Keycloak Admin Console: https://braveji-keycloak.trino.quantumcns.ai/admin/"
echo "    Ranger  Admin Console: https://braveji-ranger.trino.quantumcns.ai/"
echo ""
echo "다음 단계:"
echo "  1) Keycloak Realm/Client/그룹 설정: ./scripts/setup-keycloak-realm.sh"
echo "  2) Ranger 사용자/그룹/정책 설정: ./scripts/setup-ranger-users.sh"
echo "  3) Trino OAuth2 + Ranger 연동: helm/values.yaml 수정 후 ./scripts/install.sh"
