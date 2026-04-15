#!/usr/bin/env bash
# Trino Runtime 1단계 설치 스크립트
# 사전 요구:
#   - kubectl, helm 설치
#   - cert-manager 클러스터에 설치 완료
#   - nginx-ingress 클러스터에 설치 완료
#   - 동적 PV 프로비저너 (longhorn/ceph 등) 동작 중
#
# 사용법:
#   ./scripts/install.sh                       # config.env 기본값 사용
#   NAMESPACE=foo ./scripts/install.sh         # 환경변수로 override
#   ./scripts/install.sh foo                   # 첫 인자로 namespace 지정

set -euo pipefail

#ROOT="$(cd "$(dirname -- "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
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
echo "==> Helm release    : $RELEASE_NAME"

echo "==> 1) Namespace"
kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f -

echo "==> 2) cert-manager Issuer + Trino TLS Certificate"
kubectl apply -n "$NS" -f "$ROOT/manifests/cert/issuer.yaml"

echo "==> 3) MinIO (HMS PG backup 버킷이 cnpg backup의 의존성이므로 먼저 배포)"
kubectl apply -n "$NS" -f "$ROOT/manifests/minio/minio.yaml"
kubectl -n "$NS" rollout status statefulset/minio --timeout=300s
kubectl -n "$NS" wait --for=condition=complete job/minio-create-buckets --timeout=300s

echo "==> 4) HMS PostgreSQL (CloudNativePG)"
# 사전 요구:
#   - cnpg operator 설치
#       kubectl apply --server-side -f \
#         https://raw.githubusercontent.com/cloudnative-pg/cloudnative-pg/release-1.24/releases/cnpg-1.24.1.yaml
kubectl apply -n "$NS" -f "$ROOT/manifests/postgres/hms-postgres.yaml"
echo "    waiting for hms-postgres cnpg cluster to be ready (HA: 3 instances)..."
kubectl -n "$NS" wait --for=condition=Ready clusters.postgresql.cnpg.io/hms-postgres --timeout=900s

echo "==> 4b) Analytics PostgreSQL (Trino postgresql catalog 대상)"
kubectl apply -n "$NS" -f "$ROOT/manifests/postgres/analytics-postgres.yaml"
echo "    waiting for analytics-postgres cnpg cluster to be ready..."
kubectl -n "$NS" wait --for=condition=Ready clusters.postgresql.cnpg.io/analytics-postgres --timeout=600s

echo "==> 5) Hive Metastore"
kubectl apply -n "$NS" -f "$ROOT/manifests/hive-metastore/hive-metastore.yaml"
kubectl -n "$NS" rollout status deployment/hive-metastore --timeout=600s

echo "==> 6) Trino (Helm)"
helm repo add my-trino https://trinodb.github.io/charts >/dev/null 2>&1 || true
helm repo update my-trino
helm upgrade --install "$RELEASE_NAME" my-trino/trino \
  -n "$NS" \
  -f "$ROOT/helm/values.yaml" \
  --wait --timeout 10m

echo "==> Done. Trino UI: https://braveji.trino.quantumcns.ai/"
echo ""
echo "검증 쿼리 (coordinator에서 직접 실행):"
cat <<EOF
  kubectl -n $NS exec -it deploy/${RELEASE_NAME}-trino-coordinator -- \
    trino --execute 'SHOW CATALOGS'

  # tpch (내장)
  kubectl -n $NS exec -it deploy/${RELEASE_NAME}-trino-coordinator -- \
    trino --execute 'SELECT count(*) FROM tpch.tiny.nation'

  # postgresql catalog (analytics-postgres 샘플)
  kubectl -n $NS exec -it deploy/${RELEASE_NAME}-trino-coordinator -- \
    trino --execute 'SELECT * FROM postgresql.sales.orders'

  # iceberg catalog (MinIO 경유)
  kubectl -n $NS exec -it deploy/${RELEASE_NAME}-trino-coordinator -- \
    trino --execute "CREATE SCHEMA IF NOT EXISTS iceberg.test WITH (location = 's3a://iceberg/test/')"
  kubectl -n $NS exec -it deploy/${RELEASE_NAME}-trino-coordinator -- \
    trino --execute 'CREATE TABLE IF NOT EXISTS iceberg.test.t1 AS SELECT * FROM tpch.tiny.nation'
  kubectl -n $NS exec -it deploy/${RELEASE_NAME}-trino-coordinator -- \
    trino --execute 'SELECT * FROM iceberg.test.t1 LIMIT 50'
EOF