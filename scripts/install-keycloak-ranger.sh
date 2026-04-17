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

# ── 4. Ranger (향후 추가) ──────────────────────────────────────────
# TODO: Ranger Admin 배포 + Trino Plugin 설치
# echo "==> 4) Ranger Admin"
# kubectl apply -n "$NS" -f "$ROOT/manifests/ranger/ranger-admin.yaml"

echo ""
echo "==> Done."
echo "    Keycloak Admin Console: https://braveji-keycloak.trino.quantumcns.ai/admin/"
echo ""
echo "다음 단계:"
echo "  1) 브라우저에서 Keycloak Admin Console 접속 → Realm/Client/그룹 설정 (1-1)"
echo "  2) Trino OAuth2 연동 — helm/values.yaml 수정 후 install.sh 재실행 (1-2)"
echo "  3) Ranger 연동 (4단계)"
