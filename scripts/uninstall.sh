#!/usr/bin/env bash
# Trino 클러스터 전체 삭제 스크립트
# install.sh / install-monitor.sh / install-keycloak-ranger.sh / setup-opa.sh 로
# 배포된 모든 컴포넌트를 역순으로 정리.
#
# 사용법:
#   ./scripts/uninstall.sh                          # config.env 기본값, 확인 프롬프트
#   ./scripts/uninstall.sh foo                      # 첫 인자로 namespace 지정
#   NAMESPACE=foo ./scripts/uninstall.sh            # 환경변수로 override
#   YES=1 ./scripts/uninstall.sh                    # 확인 프롬프트 생략
#   DRY_RUN=1 ./scripts/uninstall.sh                # 실제 삭제 없이 명령만 출력
#   KEEP_PVC=1 ./scripts/uninstall.sh               # PVC 보존 (데이터 유지)
#   DELETE_NAMESPACE=1 ./scripts/uninstall.sh       # namespace까지 삭제
#   KEEP_HARBOR_SECRET=1 ./scripts/uninstall.sh     # harbor imagePullSecret 보존
#
# 보존 대상 (이 스크립트는 건드리지 않음):
#   - cluster-scoped operator: cert-manager, cloudnative-pg, nginx-ingress
#   - kube-system, default 등 시스템 namespace
#   - 다른 namespace의 리소스
#
# 안전 장치:
#   - 기본적으로 namespace는 삭제하지 않음 (DELETE_NAMESPACE=1로 명시 필요)
#   - 삭제 전 대상 namespace와 컴포넌트를 출력하고 확인 요청
#   - 존재하지 않는 리소스는 조용히 건너뜀 (--ignore-not-found)

set -uo pipefail

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
TRINO_RELEASE="${RELEASE_NAME:-my-trino}"
PROM_RELEASE="${PROM_RELEASE:-prom}"
GRAF_RELEASE="${GRAF_RELEASE:-graf}"
HARBOR_SECRET="${HARBOR_SECRET:-harbor-akashiq}"

DRY_RUN="${DRY_RUN:-}"
KEEP_PVC="${KEEP_PVC:-}"
DELETE_NAMESPACE="${DELETE_NAMESPACE:-}"
KEEP_HARBOR_SECRET="${KEEP_HARBOR_SECRET:-}"
YES="${YES:-}"

# ── 보호 namespace 가드 ──────────────────────────────────────────────
case "$NS" in
  kube-system|kube-public|kube-node-lease|default|cert-manager|ingress-nginx|cnpg-system)
    echo "ERROR: 보호 namespace는 삭제 불가: $NS" >&2
    exit 1
    ;;
  "")
    echo "ERROR: NAMESPACE가 비어 있음" >&2
    exit 1
    ;;
esac

# ── helper ────────────────────────────────────────────────────────────
run() {
  if [[ -n "$DRY_RUN" ]]; then
    echo "  [dry-run] $*"
  else
    echo "  $ $*"
    "$@" || true
  fi
}

section() {
  echo ""
  echo "==> $*"
}

# ── 사전 정보 출력 + 확인 ────────────────────────────────────────────
echo "============================================="
echo " Trino 스택 삭제"
echo "============================================="
echo " namespace          : $NS"
echo " trino release      : $TRINO_RELEASE"
echo " prometheus release : $PROM_RELEASE"
echo " grafana release    : $GRAF_RELEASE"
echo " DRY_RUN            : ${DRY_RUN:-0}"
echo " KEEP_PVC           : ${KEEP_PVC:-0}"
echo " DELETE_NAMESPACE   : ${DELETE_NAMESPACE:-0}"
echo " KEEP_HARBOR_SECRET : ${KEEP_HARBOR_SECRET:-0}"
echo "============================================="

if ! kubectl get namespace "$NS" >/dev/null 2>&1; then
  echo "namespace '$NS'가 존재하지 않음 — 종료."
  exit 0
fi

if [[ -z "$YES" && -z "$DRY_RUN" ]]; then
  echo ""
  echo "이 작업은 위 namespace의 Trino/HMS/Postgres/MinIO/Keycloak/Ranger/OPA/모니터링을 모두 삭제합니다."
  if [[ -z "$KEEP_PVC" ]]; then
    echo 'PVC도 함께 삭제되어 데이터가 영구 손실됩니다 (KEEP_PVC=1로 보존 가능).'
  fi
  read -r -p '정말 진행하시겠습니까? [yes/NO] ' confirm
  if [[ "$confirm" != "yes" ]]; then
    echo "취소됨."
    exit 0
  fi
fi

# ── 1) Helm release: Trino ───────────────────────────────────────────
section "1) Helm uninstall — Trino ($TRINO_RELEASE)"
if helm -n "$NS" status "$TRINO_RELEASE" >/dev/null 2>&1; then
  run helm -n "$NS" uninstall "$TRINO_RELEASE" --wait
else
  echo "  release 없음 — 건너뜀"
fi

# ── 2) OPA ───────────────────────────────────────────────────────────
section "2) OPA Deployment / Service / 정책 ConfigMap"
run kubectl -n "$NS" delete -f "$ROOT/manifests/opa/opa-deployment.yaml" --ignore-not-found
run kubectl -n "$NS" delete -f "$ROOT/manifests/opa/opa-policy-configmap.yaml" --ignore-not-found
run kubectl -n "$NS" delete -f "$ROOT/manifests/opa/trino-group-provider-configmap.yaml" --ignore-not-found

# ── 3) Ranger ────────────────────────────────────────────────────────
section "3) Ranger Admin / Ingress / PG"
run kubectl -n "$NS" delete -f "$ROOT/manifests/ranger/ranger-admin-ingress.yaml" --ignore-not-found
run kubectl -n "$NS" delete -f "$ROOT/manifests/ranger/ranger-admin-deployment.yaml" --ignore-not-found
run kubectl -n "$NS" delete -f "$ROOT/manifests/ranger/ranger-trino-config.yaml" --ignore-not-found
run kubectl -n "$NS" delete -f "$ROOT/manifests/ranger/ranger-postgres.yaml" --ignore-not-found

# ── 4) Keycloak ──────────────────────────────────────────────────────
section "4) Keycloak Ingress / Deployment / PG"
run kubectl -n "$NS" delete -f "$ROOT/manifests/keycloak/keycloak-ingress.yaml" --ignore-not-found
run kubectl -n "$NS" delete -f "$ROOT/manifests/keycloak/keycloak-deployment.yaml" --ignore-not-found
run kubectl -n "$NS" delete -f "$ROOT/manifests/keycloak/keycloak-postgres.yaml" --ignore-not-found

# Trino OAuth2 연동 시 생성되는 보조 Secret (setup-keycloak-realm.sh 산출물)
run kubectl -n "$NS" delete secret trino-oauth2 --ignore-not-found

# ── 5) 모니터링 (Grafana / Prometheus / Ingress / ConfigMap) ─────────
section "5) Grafana / Prometheus helm release + 모니터링 매니페스트"
run kubectl -n "$NS" delete -f "$ROOT/manifests/monitoring/ingress.yaml" --ignore-not-found

if helm -n "$NS" status "$GRAF_RELEASE" >/dev/null 2>&1; then
  run helm -n "$NS" uninstall "$GRAF_RELEASE" --wait
else
  echo "  grafana release 없음 — 건너뜀"
fi

if helm -n "$NS" status "$PROM_RELEASE" >/dev/null 2>&1; then
  run helm -n "$NS" uninstall "$PROM_RELEASE" --wait
else
  echo "  prometheus release 없음 — 건너뜀"
fi

run kubectl -n "$NS" delete -f "$ROOT/manifests/monitoring/grafana-dashboard-trino.yaml" --ignore-not-found
run kubectl -n "$NS" delete -f "$ROOT/manifests/monitoring/trino-jmx-exporter-config.yaml" --ignore-not-found

# Prometheus 커스텀 ConfigMap (release prefix 포함된 이름들 모두 정리)
echo "  Prometheus 커스텀 ConfigMap 정리 (모든 *-prometheus-custom-config)"
if [[ -z "$DRY_RUN" ]]; then
  for cm in $(kubectl -n "$NS" get cm -o name 2>/dev/null \
                | grep -E 'prometheus-custom-config' || true); do
    run kubectl -n "$NS" delete "$cm" --ignore-not-found
  done
else
  echo "  [dry-run] kubectl -n $NS get cm | grep prometheus-custom-config | xargs delete"
fi

# ── 6) Hive Metastore ────────────────────────────────────────────────
section "6) Hive Metastore"
run kubectl -n "$NS" delete -f "$ROOT/manifests/hive-metastore/hive-metastore.yaml" --ignore-not-found

# ── 7) CNPG PostgreSQL 클러스터 (HMS / analytics) ────────────────────
# CNPG Cluster 삭제 시 연결된 PVC도 함께 정리됨.
section "7) CNPG PostgreSQL — analytics, hms"
run kubectl -n "$NS" delete -f "$ROOT/manifests/postgres/analytics-postgres.yaml" --ignore-not-found
run kubectl -n "$NS" delete -f "$ROOT/manifests/postgres/hms-postgres.yaml" --ignore-not-found

# ── 8) MinIO ─────────────────────────────────────────────────────────
section "8) MinIO StatefulSet / Service / Job / Secret"
run kubectl -n "$NS" delete -f "$ROOT/manifests/minio/minio.yaml" --ignore-not-found

# ── 9) cert-manager Issuer / Certificate ─────────────────────────────
# operator는 보존, 이 namespace의 Issuer/Certificate만 삭제.
section "9) cert-manager Issuer / Certificate (namespace-scoped)"
run kubectl -n "$NS" delete -f "$ROOT/manifests/cert/issuer.yaml" --ignore-not-found

# ── 10) ResourceQuota / LimitRange / Trino spill PVC ─────────────────
section "10) ResourceQuota / LimitRange / Trino spill PVC"
run kubectl -n "$NS" delete -f "$ROOT/manifests/trino/resource-quota.yaml" --ignore-not-found
if [[ -z "$KEEP_PVC" ]]; then
  run kubectl -n "$NS" delete -f "$ROOT/manifests/trino/trino-spill-pvc.yaml" --ignore-not-found
fi

# ── 11) Harbor imagePullSecret ───────────────────────────────────────
if [[ -z "$KEEP_HARBOR_SECRET" ]]; then
  section "11) Harbor imagePullSecret ($HARBOR_SECRET)"
  run kubectl -n "$NS" delete secret "$HARBOR_SECRET" --ignore-not-found
fi

# ── 12) 잔여 PVC 정리 (helm uninstall은 PVC를 남김) ──────────────────
if [[ -z "$KEEP_PVC" ]]; then
  section "12) 잔여 PVC 정리"
  if [[ -z "$DRY_RUN" ]]; then
    PVCS=$(kubectl -n "$NS" get pvc -o name 2>/dev/null || true)
    if [[ -n "$PVCS" ]]; then
      while IFS= read -r pvc; do
        run kubectl -n "$NS" delete "$pvc" --ignore-not-found
      done <<< "$PVCS"
    else
      echo "  남은 PVC 없음"
    fi
  else
    echo "  [dry-run] kubectl -n $NS get pvc -o name | xargs delete"
  fi
else
  section "12) 잔여 PVC — KEEP_PVC=1 설정으로 보존"
  run kubectl -n "$NS" get pvc
fi

# ── 13) Namespace 삭제 (옵션) ────────────────────────────────────────
if [[ -n "$DELETE_NAMESPACE" ]]; then
  section "13) Namespace 삭제 ($NS)"
  run kubectl delete namespace "$NS" --ignore-not-found
else
  section "13) Namespace 보존 (DELETE_NAMESPACE=1로 삭제 가능)"
  echo "  namespace '$NS'는 보존됨"
fi

# ── 마무리 — 잔여물 점검 안내 ────────────────────────────────────────
section "Done."
cat <<EOF

남아 있을 수 있는 항목 점검:
  kubectl -n $NS get all,pvc,secret,cm,ingress
  kubectl -n $NS get clusters.postgresql.cnpg.io
  kubectl -n $NS get certificates.cert-manager.io,issuers.cert-manager.io
  helm -n $NS list

cluster-scoped 컴포넌트는 보존됨 (의도적):
  - cert-manager / cloudnative-pg / nginx-ingress operator
  - StorageClass, ClusterRole, CRD
EOF
