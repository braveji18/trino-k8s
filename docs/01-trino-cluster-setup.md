# 1단계: Trino Cluster 구축 기록

온프렘 Kubernetes 위에 Trino 480 클러스터를 구축한 과정과 그 과정에서 마주친
함정들을 정리한 문서. 2단계(리소스 튜닝), 3단계(멀티테넌시 설계)의 출발점.

---

## 최종 구성

| 컴포넌트 | 버전/설정 |
|---|---|
| Kubernetes | 온프렘 (qcs cluster), namespace `user-braveji` (Istio injection ON) |
| Trino | 480 (Helm chart `trino/trino` 1.42.x), coordinator 1 + workers 3 |
| Hive Metastore | 3.1.3 (standalone, SERVICE_NAME=metastore) |
| HMS Backend PG | CloudNativePG `hms-postgres`, HA 3 instances, WAL 백업 → MinIO |
| Analytics PG (catalog) | CloudNativePG `analytics-postgres`, 1 instance (POC), 10Gi |
| Object Storage | MinIO (single-node, POC) |
| Catalogs | tpch, hive, iceberg, postgresql |
| 외부 노출 | `https://braveji.trino.quantumcns.ai/` (qks-ingress-nginx) |
| 인증 | 없음 (1단계 POC, 2단계에서 추가 예정) |

## 아키텍처

```
[외부 사용자]
     │ HTTPS (LE *.trino.quantumcns.ai)
     ▼
[외부 LB 115.71.7.200]  ── TLS termination
     │ HTTP
     ▼
[qks-ingress-controller (qks-system)]
     │ HTTP (X-Forwarded-For 포함)
     ▼
[Trino Coordinator]  ── shared secret ──┐
     │                                   │
     ▼                                   ▼
[Trino Workers x3]                  [Trino Workers x3]
     │
     ├── hive       → HMS(thrift:9083) → CNPG(hms-postgres-rw:5432)
     ├── iceberg    → HMS 공유 (hive_metastore catalog type)
     │              ↓
     │            [MinIO (s3://warehouse, s3://iceberg)]
     ├── postgresql → CNPG(analytics-postgres-rw:5432, DB: analytics)
     └── tpch
```

## 주요 설계 결정

### 1. 인증은 나중에, HTTPS는 외부 LB에서
- 외부 LB가 이미 `*.trino.quantumcns.ai` LE wildcard 인증서로 TLS termination.
- Trino coordinator 자체는 HTTP로 두고, 내부 통신은 shared secret.
- 1단계는 접속/쿼리 동작만 검증. OAuth2/LDAP은 2단계 이후.

### 2. Hive + Iceberg가 동일 HMS 공유
- `iceberg.catalog.type=hive_metastore`로 설정해 HMS 하나로 양쪽 테이블 관리.
- 운영 단순화 목적. Iceberg REST catalog로의 분리는 필요 시 3단계에서 검토.

### 3. HMS backend PG는 CloudNativePG (HA + 백업)
- POC라도 메타스토어 유실은 치명적이라 처음부터 HA 3 인스턴스.
- WAL 아카이빙 대상은 MinIO 버킷 `hms-pg-backup` 재사용 (별도 S3 없이).
- PodMonitor는 Prometheus Operator 미설치로 OFF.

### 3b. 분석용 PG는 HMS PG와 분리
- Trino `postgresql` catalog 대상은 별도 CNPG Cluster `analytics-postgres`.
- 이유: 메타데이터(HMS)와 사용자 데이터(catalog 대상) 격리. HMS PG에 분석 데이터를
  올리면 스키마/권한/백업 정책이 섞여 운영이 지저분해짐.
- POC 스펙: 1 인스턴스, 10Gi, 백업 없음. 운영 전환 시 HMS PG와 동일한 HA + WAL 백업.
- Bootstrap 시 샘플 스키마 `sales.orders`와 3 rows를 `postInitApplicationSQL`로 주입.

### 4. 데이터 인프라 컴포넌트 전원 Istio sidecar 비활성화
- `user-braveji` namespace는 Istio injection ON이지만, 데이터 인프라는 mesh 밖에 둠.
- 이유: (1) 일회성 Job이 sidecar로 인해 Complete 안 되는 문제, (2) CNPG/HMS init
  container가 sidecar 시작 전에 통신해야 하는 경우, (3) Trino shuffle 트래픽에
  대한 sidecar 오버헤드 회피.
- 적용 방식:
  - MinIO, HMS Deployment: `template.metadata.annotations`
  - CNPG Cluster: `spec.inheritedMetadata.annotations`
  - Trino: Helm chart `coordinator.annotations`, `worker.annotations`

### 5. Config/배포 변수화
- [scripts/config.env](../scripts/config.env): `NAMESPACE`, `RELEASE_NAME`
- 매니페스트에서 하드코딩된 `namespace: trino` 전부 제거 → `kubectl apply -n`으로 주입
- 설치는 [scripts/install.sh](../scripts/install.sh) 한 방에 6단계 순차 실행

---

## 구축 과정에서 마주친 함정들 (Gotchas)

다음 섹션은 "왜 지금 이렇게 구성됐는가"의 근거. 동일한 함정을 피하려면 꼭 읽을 것.

### G1. Istio sidecar가 Job의 Complete를 막는다
- **증상**: `minio-create-buckets` Job의 `mc` 컨테이너는 Exit 0으로 끝났지만
  `istio-proxy` sidecar가 계속 살아서 Pod가 Running 상태로 영원히 머묾 →
  Job이 Complete 되지 않음.
- **해결**: Job pod template에 `sidecar.istio.io/inject: "false"` annotation.
- **확장 적용**: 데이터 인프라 전체를 mesh 밖으로 뺌(설계 결정 #4).

### G2. CNPG Cluster 이름이 Cluster API와 충돌
- **증상**: `kubectl ... wait cluster/hms-postgres` →
  `Error from server (NotFound): clusters.cluster.x-k8s.io "hms-postgres" not found`
- **원인**: 클러스터에 `cluster.x-k8s.io`(Cluster API CRD)와 `postgresql.cnpg.io`
  두 CRD가 공존. 짧은 이름 `cluster`는 Cluster API로 해석됨.
- **해결**: Fully qualified name 사용.
  ```bash
  kubectl wait --for=condition=Ready clusters.postgresql.cnpg.io/hms-postgres -n $NS
  ```

### G3. CNPG는 PVC 축소 불가
- **증상**: storage 50Gi → 10Gi로 줄이면
  `Invalid value ... can't shrink existing storage from 50Gi to 10Gi`.
- **원인**: CNPG(그리고 대부분의 StorageClass)는 volume expansion만 허용.
- **해결**: 축소하려면 Cluster + PVC 삭제 후 재생성. 운영에선 처음부터 여유 있게.

### G4. apache/hive:4.0.1의 Java 8이 CNPG TLS와 handshake 실패
- **증상**: HMS schematool 실행 시
  `SSLHandshakeException: Received fatal alert: protocol_version`
- **원인**: CNPG는 PG에 TLS 자동 활성화. postgres JDBC 42.7의 기본
  `sslmode=prefer`가 TLS를 먼저 시도하는데, apache/hive 이미지 번들 Java 8이
  CNPG의 최신 TLS 버전과 협상 실패.
- **해결**: JDBC URL에 `?sslmode=disable` 추가. 내부 cluster network이라 POC 수용.
- **부채**: 운영에선 newer JDK 기반 HMS 이미지로 교체해 PG↔HMS 구간 암호화 복구.

### G5. apache/hive 이미지는 postgres JDBC 드라이버를 번들하지 않거나 구버전만 있다
- **증상 1 (4.0.1)**: `ClassNotFoundException: org.postgresql.Driver`.
- **증상 2 (3.1.3)**: `The authentication type 10 is not supported`
  (= SCRAM-SHA-256. 번들된 postgresql-9.4.jar이 PG 14+ 인증 실패.)
- **해결 패턴 (최종)**:
  1. initContainer `download-jdbc`: postgres JDBC 42.7.4를 emptyDir로 다운로드
  2. initContainer `prepare-lib`: `/opt/hive/lib` 전체를 다른 emptyDir로 복사,
     기존 `postgresql*.jar` 전부 삭제 후 42.7.4 추가
  3. main 컨테이너는 해당 emptyDir을 `/opt/hive/lib`에 마운트 (원본 lib 가리지 않도록
     전체 복사 후 오버레이)
- **주의**: `cp -a`는 non-root 사용자에서 timestamp 보존 실패. `cp -r` 사용.

### G6. HMS에 s3a FileSystem 클래스가 기본 classpath에 없다
- **증상**: `ClassNotFoundException: org.apache.hadoop.fs.s3a.S3AFileSystem`
  (HMS가 warehouse.dir `s3a://` 경로로 기동할 때).
- **원인**: `hadoop-aws.jar`, `aws-java-sdk-*.jar`는 `/opt/hadoop/share/hadoop/tools/lib/`에
  번들되어 있지만 Hive classpath에는 포함 안 됨.
- **해결**: `prepare-lib` initContainer에서 해당 jar들을 hive-lib emptyDir로 함께 복사.

### G7. apache/hive:3.1.3 entrypoint가 SKIP_SCHEMA_INIT을 무시하고 매번 init 실행
- **증상**: `Error: ERROR: relation "BUCKETING_COLS" already exists`.
- **원인**: 이미지 entrypoint script가 `SKIP_SCHEMA_INIT=false`를 **하드코딩**.
  환경변수로 `SKIP_SCHEMA_INIT=true` 또는 `IS_RESUME=true`를 줘도 덮어씌워짐.
- **해결**: container `command`를 override해서 buggy entrypoint 우회, metastore를
  직접 기동:
  ```yaml
  command:
    - /bin/bash
    - -c
    - |
      export HIVE_CONF_DIR=/opt/hive/conf
      exec /opt/hive/bin/hive --service metastore
  ```
  스키마 초기화는 initContainer에서 `-info`로 존재 여부 확인 후 필요 시에만 실행.

### G8. Hive 3.1.3는 설정 property 이름이 3.x 스타일
- **잘못 사용한 이름**: `metastore.thrift.uris`, `metastore.warehouse.dir`
- **올바른 이름**: `hive.metastore.uris`, `hive.metastore.warehouse.dir`
- **추가 필요**: `hive.metastore.event.db.notification.api.auth=false`

### G9. Ingress + 외부 프록시 = Trino 406 (X-Forwarded-For 거부)
- **증상**: qks-ingress를 통과한 요청에 `HTTP 406 Server configuration does not
  allow processing of the X-Forwarded-For header`.
- **원인**: Trino의 `RejectForwardedRequestCustomizer`가 기본 활성화. 프록시 뒤에서
  쓰려면 명시적 허용 필요.
- **해결**: 아래 두 가지 방식 병행(chart 버전에 따라 하나만 인식될 수 있음).
  ```yaml
  server:
    config:
      http:
        processForwarded: true
  additionalConfigProperties:
    - http-server.process-forwarded=true
  ```

### G10. 외부 LB는 hostname 단위 등록제, 와일드카드 서브존은 별개
- **증상**: `mytrino.quantumcns.ai` → 404 default backend. qks-ingress access log에도 요청 없음.
- **원인**: 외부 LB가 hostname별로 등록된 트래픽만 qks-ingress로 포워딩.
  새 hostname은 운영자 등록이 필요. 하지만 `*.trino.quantumcns.ai`는 별도 LB IP
  (115.71.7.200)에 와일드카드 DNS + LE 인증서가 이미 존재.
- **해결**: hostname을 `braveji.trino.quantumcns.ai`로 변경. 운영자 개입 없이 즉시 동작.
- **일반 원칙**: 신규 서비스를 띄울 때는 이미 와일드카드로 열린 서브존을 먼저 찾자.

### G13. Hive 3.1.3 스키마의 `TAB_COL_STATS.ENGINE` NOT NULL 제약
- **증상**: Trino에서 hive CTAS 직후
  ```
  ERROR: null value in column "ENGINE" of relation "TAB_COL_STATS"
         violates not-null constraint
  ```
  데이터(3 rows)는 정상적으로 써졌지만 column statistics INSERT 단계에서 실패.
- **원인**: Hive 3.1.3의 `hive-schema-3.1.0.postgres.sql`이 `TAB_COL_STATS`와
  `PART_COL_STATS`의 `ENGINE` 컬럼을 NOT NULL + DEFAULT 없이 생성. HMS runtime
  코드는 INSERT 시 ENGINE 컬럼을 명시하지 않아 NOT NULL 위반.
- **해결책 A (비침습적, 즉시 적용)**: Trino hive catalog에서 쓰기 시 통계 수집을 끈다.
  ```properties
  hive.collect-column-statistics-on-write=false
  ```
  POC/분석 용도엔 영향 거의 없음.
- **해결책 B (영구 수정, 통계 유지)**: HMS PG 스키마 직접 패치.
  ```sql
  UPDATE "TAB_COL_STATS"  SET "ENGINE" = 'hive' WHERE "ENGINE" IS NULL;
  ALTER  TABLE "TAB_COL_STATS"  ALTER COLUMN "ENGINE" SET DEFAULT 'hive';
  UPDATE "PART_COL_STATS" SET "ENGINE" = 'hive' WHERE "ENGINE" IS NULL;
  ALTER  TABLE "PART_COL_STATS" ALTER COLUMN "ENGINE" SET DEFAULT 'hive';
  ```
  적용 후 A 설정 제거 가능.
- **채택**: 1단계는 A로 빠르게 해결, 2단계 튜닝 때 B로 전환 예정.

### G12. CNPG `postInitApplicationSQL`은 superuser로 실행 → 소유권 불일치
- **증상**: analytics-postgres에 샘플 스키마를 bootstrap으로 넣었는데, Trino로 쿼리하면
  `ERROR: permission denied for schema sales`.
- **원인**: `bootstrap.initdb`의 `postInitApplicationSQL`은 superuser(`postgres`) 세션으로
  실행됨. 결과적으로 `sales` 스키마 소유자가 `postgres`가 되고, catalog 계정 `trino_ro`는
  읽기 권한이 없음.
- **해결**:
  1. 매니페스트 수정 — SQL에 `CREATE SCHEMA ... AUTHORIZATION trino_ro` +
     `ALTER TABLE ... OWNER TO trino_ro` 명시
  2. 이미 생성된 클러스터는 `postInitApplicationSQL`이 재실행되지 않으므로 직접 GRANT:
     ```sql
     ALTER SCHEMA sales OWNER TO trino_ro;
     ALTER TABLE  sales.orders OWNER TO trino_ro;
     GRANT USAGE ON SCHEMA sales TO trino_ro;
     GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA sales TO trino_ro;
     ```
- **원칙**: CNPG bootstrap SQL에서 객체를 만들 때는 **반드시 소유자를 app user로 지정**.

### G11. Trino Helm chart release name ≠ service name
- **맥락**: `trino`라는 release가 이미 클러스터에 있어 `my-trino`로 우회 설치.
- **주의점**: Helm chart가 생성하는 coordinator service 이름이 `<release>-trino`,
  `<release>-trino-coordinator` 형태로 달라짐. 인증서 SAN / 내부 DNS / 문서 URL 등
  여러 곳에 release name이 퍼진다는 점을 인식하고 일괄 관리.

---

## 파일 참조

| 파일 | 역할 |
|---|---|
| [scripts/config.env](../scripts/config.env) | NAMESPACE, RELEASE_NAME 설정값 |
| [scripts/install.sh](../scripts/install.sh) | 1~6단계 순차 설치 |
| [manifests/cert/issuer.yaml](../manifests/cert/issuer.yaml) | cert-manager Issuer + Certificate (현재 미사용, 내부 HTTPS 대비 유지) |
| [manifests/postgres/hms-postgres.yaml](../manifests/postgres/hms-postgres.yaml) | CNPG Cluster, HA 3 + WAL backup |
| [manifests/postgres/analytics-postgres.yaml](../manifests/postgres/analytics-postgres.yaml) | CNPG Cluster, 분석용 PG (Trino postgresql catalog 대상) |
| [manifests/minio/minio.yaml](../manifests/minio/minio.yaml) | MinIO + 버킷 초기화 Job |
| [manifests/hive-metastore/hive-metastore.yaml](../manifests/hive-metastore/hive-metastore.yaml) | HMS 3.1.3 + JDBC/s3a jar 주입 + entrypoint 우회 |
| [helm/values.yaml](../helm/values.yaml) | Trino Helm chart override |

---

## 미결 / 2단계 이후 작업

- [ ] 리소스 튜닝: `query.max-memory`, `memory.heap-headroom-per-node`, JVM G1 파라미터
- [ ] Spill/Exchange: emptyDir → hostPath/local PV
- [ ] Worker HPA 또는 고정 수 결정
- [ ] 인증 도입: LDAP → OAuth2 (OIDC)
- [ ] PG↔HMS 구간 TLS 복구 (newer JDK HMS 이미지)
- [ ] PodMonitor 활성화 (kube-prometheus-stack 도입 시)
- [ ] 멀티테넌시: ResourceQuota, Trino resource group, Ranger/OPA 접근 제어
- [ ] analytics-postgres HA 승격 (instances 3 + WAL backup)
- [ ] 실제 외부 PG 연동 (사내 데이터 소스와 연결)
- [ ] Hive `TAB_COL_STATS.ENGINE` 스키마 패치 (G13 해결책 B) 후 `hive.collect-column-statistics-on-write=false` 제거
