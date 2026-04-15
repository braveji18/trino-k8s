#!/usr/bin/env bash
# user-braveji 네임스페이스 Prometheus + Grafana + Trino 메트릭 연동 스크립트
# (Trino 튜닝 측정 전용, 가벼운 구성)
#
# 단계:
#   0) JMX Exporter ConfigMap 적용
#   1) Prometheus server 설치
#   2) Grafana 설치
#   3) Prometheus/Grafana Ingress
#   4) Trino 커스텀 이미지 빌드/푸시 (JMX javaagent jar 포함)
#   5) Harbor imagePullSecret 생성
#   6) Trino helm upgrade (JMX exporter + prometheus annotation 반영)
#   7) 설치 검증 안내
#
# 사전 요구:
#   - kubectl, helm, docker(+buildx) 설치
#   - 동적 PV 프로비저너 (qks-ceph-block 등)
#   - user-braveji namespace 존재 (install.sh로 생성)
#   - Harbor 프로젝트 'akashiq' 쓰기 권한
#
# 사용법:
#   ./scripts/install-monitor.sh                   # 모든 단계 실행
#   SKIP_TRINO_BUILD=1 ./scripts/install-monitor.sh  # 이미지 빌드 스킵
#   SKIP_TRINO_UPGRADE=1 ./scripts/install-monitor.sh # Trino helm upgrade 스킵
#   NAMESPACE=foo ./scripts/install-monitor.sh
#   ./scripts/install-monitor.sh foo               # 첫 인자로 namespace 지정
#
# Harbor 자격증명:
#   HARBOR_USER / HARBOR_PASSWORD 환경변수로 제공하거나,
#   미설정 시 Secret 생성 단계만 안내 출력하고 건너뜀.

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
PROM_RELEASE="${PROM_RELEASE:-prom}"
GRAF_RELEASE="${GRAF_RELEASE:-graf}"
TRINO_RELEASE="${RELEASE_NAME:-my-trino}"
TRINO_IMAGE="${TRINO_IMAGE:-harbor.quantumcns.ai/akashiq/trino:480-jmx}"
HARBOR_SERVER="${HARBOR_SERVER:-harbor.quantumcns.ai}"
HARBOR_SECRET="${HARBOR_SECRET:-harbor-akashiq}"
SKIP_TRINO_BUILD="${SKIP_TRINO_BUILD:-}"
SKIP_TRINO_UPGRADE="${SKIP_TRINO_UPGRADE:-}"

echo "==> Target namespace  : $NS"
echo "==> Prometheus release: $PROM_RELEASE"
echo "==> Grafana    release: $GRAF_RELEASE"
echo "==> Trino      release: $TRINO_RELEASE"
echo "==> Trino      image  : $TRINO_IMAGE"

# ---------------------------------------------------------------------------
echo "==> 0a) Trino JMX Exporter ConfigMap 적용"
kubectl apply -n "$NS" -f "$ROOT/manifests/monitoring/trino-jmx-exporter-config.yaml"

echo "==> 0a') Prometheus 커스텀 config ConfigMap 적용 (chart default scrape 대체)"
# ConfigMap 이름에 PROM_RELEASE prefix가 필요 (chart의 fullname 규칙).
# __PROM_RELEASE__ placeholder를 실제 값으로 치환한 뒤 apply.
sed "s|__PROM_RELEASE__|${PROM_RELEASE}|g" \
    "$ROOT/manifests/monitoring/prometheus-custom-config.yaml" \
  | kubectl apply -n "$NS" -f -

# 이전 release 이름으로 만들어진 stale ConfigMap 정리 (이름이 바뀐 경우만)
for stale in $(kubectl -n "$NS" get cm -o name 2>/dev/null \
                 | grep -E 'prometheus-custom-config' \
                 | grep -v "${PROM_RELEASE}-prometheus-custom-config" || true); do
  echo "    remove stale: $stale"
  kubectl -n "$NS" delete "$stale" --ignore-not-found
done

echo "==> 0b) Helm repo 추가/업데이트"
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null 2>&1 || true
helm repo add grafana              https://grafana.github.io/helm-charts              >/dev/null 2>&1 || true
helm repo update prometheus-community grafana

# ---------------------------------------------------------------------------
echo "==> 1) Prometheus server 설치 (server only, Trino scrape job 포함)"
helm upgrade --install "$PROM_RELEASE" prometheus-community/prometheus \
  -n "$NS" \
  -f "$ROOT/helm/prometheus-values.yaml" \
  --wait --timeout 10m

echo "    Prometheus 서비스 확인:"
kubectl -n "$NS" get svc -l app.kubernetes.io/name=prometheus

# ---------------------------------------------------------------------------
echo "==> 2) Grafana 설치 (Prometheus datasource 자동 구성)"
helm upgrade --install "$GRAF_RELEASE" grafana/grafana \
  -n "$NS" \
  -f "$ROOT/helm/grafana-values.yaml" \
  --wait --timeout 10m

echo "    Grafana 서비스 확인:"
kubectl -n "$NS" get svc -l app.kubernetes.io/name=grafana

# ---------------------------------------------------------------------------
echo "==> 3) 외부 노출 Ingress 적용"
# manifests/monitoring/ingress.yaml의 Service 이름이
# 실제 helm release 이름과 일치해야 함. 기본값(prom/graf) 기준.
kubectl apply -n "$NS" -f "$ROOT/manifests/monitoring/ingress.yaml"

# ---------------------------------------------------------------------------
echo "==> 4) Trino 커스텀 이미지 빌드/푸시 (JMX javaagent jar 포함)"
if [[ -n "$SKIP_TRINO_BUILD" ]]; then
  echo "    SKIP_TRINO_BUILD 설정 — 건너뜀"
else
  pushd "$ROOT/docker/trino-with-jmx" >/dev/null

  if [[ ! -s jmx_prometheus_javaagent.jar ]]; then
    echo "    jar 다운로드 중..."
    curl -fsSL -o jmx_prometheus_javaagent.jar \
      https://repo1.maven.org/maven2/io/prometheus/jmx/jmx_prometheus_javaagent/1.0.1/jmx_prometheus_javaagent-1.0.1.jar
  else
    echo "    jar 이미 존재 — 재다운로드 생략"
  fi

  echo "    docker buildx build --platform linux/amd64 --push ..."
  docker buildx build \
    --platform linux/amd64 \
    -t "$TRINO_IMAGE" \
    --push .

  echo "    manifest 검증:"
  docker buildx imagetools inspect "$TRINO_IMAGE" | grep -E 'Platform|MediaType' || true

  popd >/dev/null
fi

# ---------------------------------------------------------------------------
echo "==> 5) Harbor imagePullSecret 생성 ($HARBOR_SECRET)"
if kubectl -n "$NS" get secret "$HARBOR_SECRET" >/dev/null 2>&1; then
  echo "    이미 존재 — 건너뜀. 재생성하려면 먼저 삭제:"
  echo "      kubectl -n $NS delete secret $HARBOR_SECRET"
elif [[ -n "${HARBOR_USER:-}" && -n "${HARBOR_PASSWORD:-}" ]]; then
  kubectl -n "$NS" create secret docker-registry "$HARBOR_SECRET" \
    --docker-server="$HARBOR_SERVER" \
    --docker-username="$HARBOR_USER" \
    --docker-password="$HARBOR_PASSWORD" \
    --dry-run=client -o yaml | kubectl apply -f -
  echo "    생성 완료"
else
  cat <<EOF
    HARBOR_USER / HARBOR_PASSWORD 환경변수가 없어 건너뜀.
    수동 생성 명령:
      read -s HARBOR_PW
      kubectl -n $NS create secret docker-registry $HARBOR_SECRET \\
        --docker-server=$HARBOR_SERVER \\
        --docker-username=<your-user> \\
        --docker-password="\$HARBOR_PW" \\
        --dry-run=client -o yaml | kubectl apply -f -
      unset HARBOR_PW
EOF
fi

# ---------------------------------------------------------------------------
echo "==> 6) Trino helm upgrade (JMX exporter + prometheus annotation 반영)"
if [[ -n "$SKIP_TRINO_UPGRADE" ]]; then
  echo "    SKIP_TRINO_UPGRADE 설정 — 건너뜀"
else
  helm repo add my-trino https://trinodb.github.io/charts >/dev/null 2>&1 || true
  helm repo update my-trino
  helm upgrade --install "$TRINO_RELEASE" my-trino/trino \
    -n "$NS" \
    -f "$ROOT/helm/values.yaml" \
    --wait --timeout 15m

  echo "    pod 상태 확인:"
  kubectl -n "$NS" get pod -l app.kubernetes.io/name=trino
fi

# ---------------------------------------------------------------------------
echo "==> 7) 설치 검증 명령"
cat <<EOF

  # Prometheus targets (self scrape + trino pods 확인)
  kubectl -n $NS port-forward svc/${PROM_RELEASE}-prometheus-server 9090:80
  # → http://localhost:9090/targets

  # Trino /metrics 직접 확인
  POD=\$(kubectl -n $NS get pod -l app.kubernetes.io/component=coordinator -o name | head -1)
  kubectl -n $NS exec \$POD -c trino-coordinator -- ls -l /opt/jmx-exporter/
  kubectl -n $NS port-forward \$POD 5556:5556 &
  sleep 2 && curl -s http://localhost:5556/metrics | head -40 ; kill %1

  # Grafana datasource 테스트
  #   URL : https://braveji-grafana.trino.quantumcns.ai
  #   user: admin
  #   pass: (helm/grafana-values.yaml의 adminPassword)

  # Prometheus 외부 접속
  #   URL : https://braveji-prom.trino.quantumcns.ai

EOF

echo "==> Done."


# ---------------------------------------------------------------------------
echo "==> 7) 설치 검증 명령"

NS=user-braveji
kubectl -n $NS port-forward svc/prom-prometheus-server 9090:80 &
sleep 2

# 1) Trino job이 UP 인가
curl -s http://localhost:9090/api/v1/targets | \
  jq '.data.activeTargets[] | select(.labels.job=="trino") | {pod:.labels.pod, health}'

# 2) Trino 관련 메트릭이 실제로 있나
curl -sG http://localhost:9090/api/v1/label/__name__/values | \
  jq -r '.data[]' | grep -E '^(trino_|jvm_)' | head -20

# 3) 샘플 query
curl -sG http://localhost:9090/api/v1/query \
  --data-urlencode 'query=trino_execution_running_queries' | jq
kill %1

