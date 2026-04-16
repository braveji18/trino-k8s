# CLAUDE.md

이 파일은 이 저장소에서 작업하는 Claude Code(claude.ai/code)에게 가이드를 제공합니다.

## 이 저장소의 성격

온프렘 Kubernetes 위에서 동작하는 Trino 480 클러스터를 위한 Infrastructure-as-config 저장소입니다. 애플리케이션 코드는 없으며, 전부 Helm values, Kubernetes 매니페스트, 셸 설치 스크립트, 문서로 구성되어 있습니다. 작업 방식은 YAML/셸을 수정한 뒤 설치 스크립트를 실 클러스터에 다시 돌리는 형태입니다.

프로젝트는 빌드 단계(phase) 시퀀스로 조직되어 있습니다(README.md 및 [docs/](docs/) 참고). 1단계(클러스터 구축)는 완료, 2단계(리소스 튜닝, [docs/03-resource-tuning-plan.md](docs/03-resource-tuning-plan.md))가 현재 진행 중, 3단계(쿼터 / 멀티테넌시)는 향후 과제입니다.

## 배포 명령

모든 작업은 `scripts/config.env`를 `source`하는 두 개의 스크립트로 돌아갑니다 (기본값 `NAMESPACE=user-braveji`, `RELEASE_NAME=my-trino`). 두 스크립트 모두 namespace를 첫 번째 인자(`$1`) 또는 환경변수로 override 할 수 있습니다.

- 전체 Trino 스택 설치/업그레이드: `./scripts/install.sh` — cert issuer → MinIO → HMS PostgreSQL(CNPG) → analytics PostgreSQL(CNPG) → Hive Metastore → `helm upgrade --install my-trino my-trino/trino -f helm/values.yaml` 순서로 적용합니다. 멱등적이므로 [helm/values.yaml](helm/values.yaml)이나 매니페스트를 수정한 뒤 그대로 재실행하면 됩니다.
- 모니터링 + JMX 계측된 Trino 이미지: `./scripts/install-monitor.sh` — JMX exporter ConfigMap 적용, Prometheus 커스텀 scrape config(`__PROM_RELEASE__` placeholder를 apply 시점에 sed로 치환), `prom`/`graf` helm release 설치, [docker/trino-with-jmx/](docker/trino-with-jmx/)로부터 `harbor.quantumcns.ai/akashiq/trino:480-jmx` 이미지 빌드 및 푸시, Trino `helm upgrade` 순으로 진행합니다. Skip 플래그: `SKIP_TRINO_BUILD=1`, `SKIP_TRINO_UPGRADE=1`. Harbor 자격증명은 `HARBOR_USER` / `HARBOR_PASSWORD` 환경변수로 전달합니다.
- 테스트 스위트는 없습니다. 검증은 coordinator 파드 내부에서 `trino --execute` SQL을 돌리거나 (`install.sh` 마지막에 예시가 출력됨) [docs/02-federated-query-demo.md](docs/02-federated-query-demo.md)의 federated query 데모를 돌리는 식으로 수행합니다.

## 파일 하나만 봐서는 보이지 않는 아키텍처

- **단일 namespace 스택.** Trino, Hive Metastore, 두 개의 PostgreSQL 클러스터(HMS 백엔드와 analytics 샘플 데이터), MinIO, Prometheus, Grafana가 모두 같은 namespace(`user-braveji` 기본값)에 올라갑니다. 크로스-namespace 연결은 없습니다.
- **TLS는 Ingress에서 종단됩니다 (Trino 자체가 아님).** [helm/values.yaml](helm/values.yaml)에서 `server.config.https.enabled: false`, `authenticationType: ""`로 설정되어 있고, HTTPS는 nginx-ingress가 처리합니다. 프록시 뒤에 있기 때문에 `http-server.process-forwarded=true`가 반드시 설정되어야 하는데 — `server.config.http.processForwarded`와 `additionalConfigProperties` 양쪽에 안전장치로 이중 설정되어 있습니다 (Helm chart가 구조화된 키를 조용히 무시한 이력이 있어서). 없으면 Trino가 406을 반환합니다. 둘 중 하나를 "정리"한답시고 지우지 마세요.
- **카탈로그는 마운트가 아니라 Helm values로 주입됩니다.** [catalogs/](catalogs/) 디렉터리의 파일들 (`hive`, `iceberg`, `postgresql`, `tpch`)은 가독성을 위해 존재하는 것이고, 실제로 배포에 반영되는 사본은 [helm/values.yaml](helm/values.yaml)의 `catalogs:` 아래에 들어 있습니다. 카탈로그를 바꿀 때는 values.yaml 항목을 수정해야 합니다 — `catalogs/` 쪽 파일만 고치면 실 클러스터에 아무 영향이 없습니다.
- **커스텀 Trino 이미지 = stock Trino + JMX Prometheus javaagent.** [docker/trino-with-jmx/Dockerfile](docker/trino-with-jmx/Dockerfile)이 `jmx_prometheus_javaagent.jar`와 [manifests/monitoring/trino-jmx-exporter-config.yaml](manifests/monitoring/trino-jmx-exporter-config.yaml)의 scrape 설정을 추가합니다. Harbor 태그는 `480-jmx`이고, Trino values.yaml이 이 이미지를 pin 하면서 `imagePullSecrets: harbor-akashiq`를 참조합니다.
- **PostgreSQL은 StatefulSet이 아니라 CloudNativePG입니다.** 두 개의 CNPG `Cluster` 리소스가 있습니다: `hms-postgres`(3-instance HA, HMS 백엔드, MinIO의 `hms-pg-backup` 버킷으로 백업 — 이 때문에 `install.sh`에서 MinIO가 Postgres보다 먼저 배포되어야 함)와 `analytics-postgres`(`postgresql` 카탈로그용 샘플 데이터). CNPG operator는 클러스터에 사전 설치되어 있어야 합니다 (`install.sh` 4단계 주석 참고).
- **Iceberg/Hive 스토리지는 MinIO입니다.** `iceberg.properties`와 `hive.properties`가 클러스터 내부 MinIO의 `s3a://`를 바라보고, 스키마는 Hive Metastore가 보관합니다. `postgresql`/`iceberg`/`hive`/`tpch`를 가로지르는 federated query가 이 프로젝트의 핵심 기능입니다 ([docs/02-federated-query-demo.md](docs/02-federated-query-demo.md)).
- **모니터링은 ServiceMonitor가 아니라 Prometheus 커스텀 scrape config를 씁니다.** [manifests/monitoring/prometheus-custom-config.yaml](manifests/monitoring/prometheus-custom-config.yaml)은 chart가 기대하는 ConfigMap 이름 규칙에 맞추기 위해 `__PROM_RELEASE__-prometheus-custom-config` 패턴으로 명명되어 있고, `install-monitor.sh`가 sed로 치환해서 apply 하면서 이전 release 이름으로 남아 있던 stale ConfigMap까지 같이 정리합니다. `PROM_RELEASE`를 바꾸면 cleanup 루프가 옛것을 알아서 지워 줍니다.

## 유지해야 할 관습

- 스크립트는 `ROOT="$(pwd)"`를 씁니다 — `scripts/` 안이 아니라 저장소 루트에서 실행한다는 가정이 깔려 있습니다. 확인 없이 "고치지" 마세요.
- 주석과 문서는 한국어로 작성되어 있습니다. 수정할 때도 한국어를 유지해 주세요.
- [docs/01-trino-cluster-setup.md](docs/01-trino-cluster-setup.md)에는 초기 구축 때 겪은 "13가지 함정" 기록이 남아 있습니다 — 설치 실패를 디버깅하기 전에 먼저 훑어볼 것. 프록시 헤더, CNPG 백업 순서, chart 키 드리프트 등 비자명한 실패 모드가 이미 정리되어 있습니다.
