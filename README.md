# Trino Runtime on Kubernetes

온프렘 Kubernetes 위에 Trino 480 클러스터를 구축하고 멀티테넌시까지 적용한 프로젝트.

## 구성

- **Trino**: 480 (공식 Helm Chart) + JMX Exporter javaagent (커스텀 이미지 `harbor.quantumcns.ai/akashiq/trino:480-jmx`)
- **인증**: Keycloak OAuth2/OIDC (사용자 13명, 그룹 4종)
- **인가**: OPA (Open Policy Agent) — Rego 정책으로 카탈로그/스키마/세션 접근제어 (Ranger에서 전환, [docs/06-opa-monitoring.md](docs/06-opa-monitoring.md) 참고)
- **리소스 격리**: Trino Resource Groups (root.etl / root.interactive.{analyst,bi} / root.admin)
- **K8s 격리**: ResourceQuota + LimitRange (namespace 레벨)
- **TLS**: Ingress termination (외부 LB의 *.quantumcns.ai 와일드카드)
- **Catalogs**: Hive, Iceberg, PostgreSQL, TPCH, JMX, Memory
- **Metastore**: Standalone Hive Metastore + CNPG PostgreSQL HA(3 instances)
- **Object Storage**: MinIO (S3 호환)
- **모니터링**: Prometheus + Grafana (16패널 + 알림 3종)

## 디렉토리 구조

```
trino-k8s/
├── helm/
│   └── values.yaml                    # Trino Helm chart values (resourceGroups, accessControl 포함)
├── catalogs/                          # Trino catalog properties (가독성용 사본, 실제는 values.yaml에 주입)
├── manifests/
│   ├── namespace/                     # Namespace, RBAC
│   ├── cert/                          # cert-manager Issuer
│   ├── minio/                         # MinIO StatefulSet
│   ├── postgres/                      # CNPG Cluster (HMS + analytics backend)
│   ├── hive-metastore/                # Standalone HMS
│   ├── monitoring/                    # JMX Exporter ConfigMap, Prometheus scrape config, Grafana dashboard
│   ├── keycloak/                      # Keycloak CNPG + Deployment + Ingress
│   ├── opa/                           # OPA Deployment + Service + Rego 정책 ConfigMap
│   ├── ranger/                        # (deprecated) OPA로 전환 — 참고용으로만 보존
│   └── trino/                         # ResourceQuota + LimitRange + Resource Groups JSON 사본
├── docker/
│   └── trino-with-jmx/                # Trino 480 + JMX javaagent Dockerfile
├── docs/                              # 단계별 구축 기록 (아래 참고)
└── scripts/                           # 배포/설정/검증 스크립트 (scripts/README.md 참고)
```

## 문서

### 1단계 — 클러스터 구축

- [01. Trino Cluster 구축](docs/01-trino-cluster-setup.md) — 아키텍처, 설계 결정, 13가지 함정(G1~G13)
- [02. Federated Query Demo](docs/02-federated-query-demo.md) — postgresql/iceberg/hive/tpch 4-catalog JOIN 검증

### 2단계 — 리소스 튜닝

- [03. Resource 튜닝 진행 계획](docs/03-resource-tuning-plan.md) — 베이스라인 측정 → 메모리/JVM/디스크/워커/커넥터 로드맵
- [03-02. 노드 튜닝](docs/03-02-node-tuning-plan.md)
- [03-04. JVM 튜닝](docs/03-04-jvm-tuning-plan.md)
- [03-05. 디스크/Spill 튜닝](docs/03-05-disk-spill-tuning-plan.md)
- [03-07. 커넥터 튜닝](docs/03-07-connector-tuning-plan.md)

### 3단계 — 멀티테넌시 (인증 + 인가 + 격리)

- [04. Keycloak OAuth2 인증](docs/04-keycloak-oauth2.md) — Keycloak 설치, Realm/Client/Group 설정, Trino OAuth2 연동 (G14~G22)
- [04. Resource Quota Query Demo](docs/04-resource-quota-query-demo.md) — OAuth2 + Resource Groups 환경의 federated query
- [05. Resource Groups + K8s Quota + Session 제어](docs/05-resource-groups-quota.md) — Trino 내부 격리 + K8s 인프라 격리 + Session Property 제한 (G23~G31)
- [06. **OPA 접근제어** + 모니터링 + 검증](docs/06-opa-monitoring.md) — OPA Deployment, Rego 정책, Grafana 대시보드, V1~V5 시나리오 (현재 운영 중)
- [06-ranger. (deprecated) Ranger 접근제어](docs/06-ranger-monitoring.md) — 초기 Ranger 방식 기록 (G32~G50)
- [07. 운영 가이드 + 사용자 온보딩](docs/07-operations-guide.md) — 사용자 추가/삭제, 정책 변경, 장애 대응, 접속 가이드

### 스크립트

- [scripts/README.md](scripts/README.md) — 8개 스크립트의 실행 순서, 환경변수, 의존 관계

## 빠른 시작

### 1단계 (클러스터 구축)

```bash
./scripts/install.sh
```

### 2단계 (모니터링 + 튜닝)

```bash
./scripts/install-monitor.sh
```

### 3단계 (멀티테넌시 — Keycloak + OPA)

```bash
./scripts/install-keycloak-ranger.sh                       # Keycloak 인프라 (Ranger 부분은 무시 가능)
./scripts/setup-keycloak-realm.sh                          # Keycloak Realm/사용자
# (Client Secret을 helm/values.yaml에 반영 후)
kubectl apply -f manifests/opa/opa-policy-configmap.yaml   # Rego 정책
kubectl apply -f manifests/opa/opa-deployment.yaml         # OPA Deployment + Service
./scripts/install.sh                                       # OAuth2 + OPA 적용 helm upgrade
./scripts/verify-multitenancy.sh                           # 전체 시나리오 검증
```

## 시스템 접속

| 서비스 | URL | 인증 |
|---|---|---|
| Trino Web UI | https://braveji.trino.quantumcns.ai/ui/ | Keycloak OAuth2 |
| Keycloak Admin | https://braveji-keycloak.trino.quantumcns.ai/admin/ | admin / changeme-keycloak-admin |
| OPA REST API | http://opa.user-braveji.svc:8181/ (cluster 내부) | (인증 없음, 정책 ConfigMap으로 관리) |
| Grafana | https://braveji-grafana.trino.quantumcns.ai/ | admin / changeme-grafana |
| Prometheus | https://braveji-prom.trino.quantumcns.ai/ | (인증 없음) |

상세는 [docs/07-operations-guide.md](docs/07-operations-guide.md) 참고.

## 진행 상태

| 단계 | 상태 | 주요 산출물 |
|---|---|---|
| 1. 클러스터 구축 | **완료** | Trino 480 + HMS + MinIO + CNPG PG |
| 2. 리소스 튜닝 | **완료** | JMX Exporter, Grafana 대시보드, JVM/Spill 튜닝 |
| 3. 멀티테넌시 | **완료** | Keycloak + OPA(Rego) + Resource Groups + ResourceQuota + 검증 (V1~V5/T3~T6 PASS) |
