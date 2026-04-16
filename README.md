# Trino Runtime on Kubernetes

온프렘 Kubernetes 위에 Trino 480 클러스터를 구축하는 프로젝트.

## 구성

- **Trino**: 480 (공식 Helm Chart 사용)
- **인증/보안**: HTTPS only (TLS termination at Ingress)
- **Catalogs**: Hive, Iceberg, PostgreSQL, S3(MinIO)
- **Metastore**: Hive Metastore (Standalone) + PostgreSQL backend
- **Object Storage**: MinIO (S3 호환)

## 디렉토리 구조

```
trino-runtime/
├── helm/
│   └── values.yaml              # Trino Helm chart values
├── catalogs/                    # Trino catalog properties (values.yaml에 주입됨)
│   ├── hive.properties
│   ├── iceberg.properties
│   ├── postgresql.properties
│   └── tpch.properties
├── manifests/
│   ├── namespace/               # Namespace, RBAC
│   ├── cert/                    # cert-manager Issuer, Certificate
│   ├── minio/                   # MinIO 배포 매니페스트 (또는 helm values)
│   ├── postgres/                # HMS backend PG
│   └── hive-metastore/          # Standalone HMS
├── docs/                        # 단계별 구축 기록
└── scripts/                     # 배포/검증 스크립트
```

## 문서

- [1단계 Trino Cluster 구축 기록](docs/01-trino-cluster-setup.md) — 아키텍처, 설계 결정, 구축 중 마주친 13가지 함정과 해결법
- [Federated Query Demo (4-catalog JOIN)](docs/02-federated-query-demo.md) — postgresql/iceberg/hive/tpch를 한 쿼리로 조인하는 검증 스크립트
- [2단계 Resource 튜닝 진행 계획](docs/03-resource-tuning-plan.md) — 베이스라인 측정 → 메모리/JVM/디스크/워커/커넥터 순서로 조정하는 로드맵
- [3단계 Resource Quota / Multi-tenancy 설계](docs/04-resource-quota-multitenancy-plan.md) — 인증 → Resource Group → K8s Quota → 권한 분리 → 모니터링 순서의 멀티테넌시 로드맵

## 구축 단계 (1단계: Cluster 구축)

순서대로 진행:

1. Namespace + cert-manager Issuer
2. PostgreSQL (HMS backend)
3. MinIO
4. Hive Metastore
5. Trino (Helm)
6. Catalog 검증

자세한 명령은 [scripts/](scripts/) 참고.

## 다음 단계

- 2단계: Trino Resource 튜닝
- 3단계: Resource Quota / Multi-tenancy 설계
