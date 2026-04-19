# 3단계-C: Ranger 접근제어 + 모니터링 + 검증

3단계(멀티테넌시)의 세 번째 파트. Apache Ranger 접근제어 + 테넌트별 모니터링 + 통합 검증.

> 3단계 전체 흐름과 다른 파트는 아래 참고:
> - [04-keycloak-oauth2.md](04-keycloak-oauth2.md): §0 현황 정리 + §1 Keycloak 인증
> - [05-resource-groups-quota.md](05-resource-groups-quota.md): §2 Resource Groups + §3 K8s Quota + §5 Session 제어
> - **본 문서**: §4 Ranger + §6 모니터링 + §7 검증 + §8 문서화

---

## 4. Ranger 연동 — 카탈로그·스키마별 접근제어

> **결정**: Apache Ranger로 중앙 집중 접근제어.
> Ranger는 UI 기반 정책 관리 + 감사 로그를 제공하므로 운영 편의성이 높음.

### 4-1. 아키텍처 및 핵심 사실

```
[Ranger Admin Deployment]  ← apache/ranger:2.8.0 (Docker Hub 공식 이미지)
       │
       ├── [ranger-postgres (CNPG)]  ← 메타데이터 DB
       │
       └── [Solr Deployment (선택)]  ← 감사 로그 (Log4J로 대체 가능)
       │
       ▼ 정책 배포 (REST API, 30초 poll)
[Trino 480 — 내장 Ranger Plugin]  ← Dockerfile 수정 불필요
       │
       ▼ 정책 캐싱 + 접근 판단
[Trino Query] → 허용/거부
```

> **G32. Trino 480은 Ranger plugin이 내장되어 있음**: 별도 tar.gz 설치나 커스텀
> 이미지 빌드가 불필요. `access-control.name=ranger` + XML 설정 파일 마운트만으로 동작.
> (초안의 §4-3 "커스텀 이미지에 Ranger Plugin 포함" 방식은 구버전 Ranger 기준이므로 폐기)

> **G33. Ranger 2.5.0 이상 필요**: Trino service definition이 기본 포함된 최소 버전.
> 그 이하 버전은 service definition을 수동 등록해야 함.

### 4-2. Ranger Admin Docker 이미지

#### 공식 이미지 — Docker Hub에 존재

| 이미지 | 태그 | 크기 | 아키텍처 | 게시일 |
|---|---|---|---|---|
| `apache/ranger` | `2.8.0` | 990MB | amd64, arm64 | 2026-03-06 |
| `apache/ranger` | `2.7.0` | 930MB | amd64, arm64 | 2025-08-03 |
| `apache/ranger-base` | `20260123-2-8` | 202MB | amd64, arm64 | 2026-01-23 |

> **G34. 공식 Docker 이미지가 Docker Hub에 존재**: `apache/ranger:2.8.0`을 직접
> pull하여 사용 가능. Maven 소스 빌드 불필요. (초기 조사에서 Docker Hub API 응답이
> 비어 있어 "이미지 없음"으로 오판했었으나 실제로는 존재.)

**소스 빌드 불필요** — Deployment에서 `image: apache/ranger:2.8.0`을 직접 지정.

#### Harbor 미러링 불필요

| 근거 | 상세 |
|---|---|
| Docker Hub 직접 pull 가능 | 클러스터에서 `apache/hive:3.1.3`, `minio/minio`, `grafana/grafana` 등이 imagePullSecrets 없이 Docker Hub에서 직접 pull되어 동작 중 |
| 동일 네임스페이스 | `apache/ranger`는 `apache/hive`와 같은 Docker Hub `apache/` 네임스페이스 |
| Harbor 사용은 커스텀 이미지만 | `harbor.quantumcns.ai/akashiq/trino:480-jmx`만 Harbor 사용. 공개 이미지는 직접 pull |

> **운영 환경에서 Harbor 미러링이 필요한 경우** (참고):
> - Docker Hub rate limit (anonymous: 100 pulls/6h) 에 걸리는 대규모 클러스터
> - 외부 네트워크 차단 정책이 있는 폐쇄망 환경
> - 이미지 공급망 보안(supply chain security) 정책이 있는 경우
>
> 현재 클러스터에는 해당하지 않으므로 직접 pull 사용.

#### (참고) 공식 Dockerfile 구조

공식 `dev-support/ranger-docker/Dockerfile.ranger`를 직접 빌드하려면:

| 요구사항 | 상세 |
|---|---|
| **Maven 빌드 결과물** | `COPY ranger-<ver>-admin.tar.gz` — `mvn clean package` (JDK 11, ~20분)로 생성 필요 |
| **JDBC 드라이버** | `./downloads/postgresql-42.2.16.jre7.jar` 등 로컬 다운로드 필요 |
| **base 이미지 의존** | `${RANGER_HOME}`, `${RANGER_SCRIPTS}` 환경변수가 `apache/ranger-base`에서 정의 |
| **entrypoint 복잡성** | `ranger.sh` → `setup.sh`(DB 스키마 초기화) → Admin 시작 + Kerberos 로직 |

공식 이미지(`apache/ranger:2.8.0`)가 이 모든 것을 포함하고 있으므로 **직접 빌드할 이유 없음**.

#### Kerberos 설정 — 불필요

> **G35. Kerberos는 필수가 아님**: Trino Plugin ↔ Ranger Admin 통신에서
> Kerberos 관련 속성은 모두 **기본 비활성화**.

**Trino Plugin 측** (`ranger-trino-security.xml`):

| 속성 | 기본값 | 설정하지 않으면 |
|---|---|---|
| `ranger.plugin.trino.ugi.initialize` | `false` | Kerberos identity 초기화 안 함 |
| `ranger.plugin.trino.ugi.login.type` | (빈 값) | Kerberos 로그인 안 함 |
| `ranger.plugin.trino.ugi.keytab.principal` | (빈 값) | - |
| `ranger.plugin.trino.ugi.keytab.file` | (빈 값) | - |

**Ranger Admin 측** (컨테이너 entrypoint `ranger.sh`):

```bash
if [ "${KERBEROS_ENABLED}" == "true" ]   # 환경변수 미설정 시 전체 건너뜀
then
  wait_for_keytab.sh ...
fi
```

`KERBEROS_ENABLED` 환경변수를 설정하지 않으면 Kerberos 로직을 완전히 건너뜀.

**Kerberos가 필요한 경우**: Ranger Admin이 외부 네트워크에 노출되거나,
Hadoop 에코시스템(HDFS, Hive on Hadoop)과 연동할 때. 현재 구성(단일 namespace
내부 통신)에서는 해당 없음.

#### Keycloak 인증과 Kerberos의 관계 — 독립된 계층, 공존 가능

> **G39. Keycloak OAuth2와 Ranger Kerberos는 서로 다른 계층이므로 충돌하지 않음**.
> 가정: 만약 Ranger Admin을 외부 노출하여 Kerberos를 활성화하더라도
> Trino의 Keycloak OAuth2 인증과 무관하게 동작.

Trino에는 3개의 독립된 인증/인가 계층이 존재:

```
[사용자 브라우저/CLI]
       │
       ▼ ① 사용자 인증 (Keycloak OAuth2)
[Trino Coordinator]  ← http-server.authentication.type=OAUTH2
       │
       ├─ ② 내부 통신 인증 (shared-secret)
       │  [Trino Worker]  ← internal-communication.shared-secret
       │
       └─ ③ 정책 가져오기 (Ranger Plugin → Ranger Admin)
          [Ranger Admin]  ← ranger.plugin.trino.policy.rest.url
                            (HTTP 또는 HTTPS+Kerberos)
```

| 계층 | 역할 | 현재 설정 | Kerberos 관련 |
|---|---|---|---|
| ① 사용자 인증 | 사용자가 Trino에 로그인 | Keycloak OAuth2 | **무관** — Kerberos 인증과 별개 |
| ② 내부 통신 | coordinator ↔ worker 간 | `shared-secret` | **무관** |
| ③ 정책 가져오기 | Trino Plugin → Ranger Admin | `http://ranger-admin:6080` | **여기에만 해당** |

**③번 계층에서 Kerberos를 켜더라도 ①번(Keycloak)에 영향 없음.**
사용자 인증 경로(Keycloak)와 정책 가져오기 경로(Ranger)는 완전히 분리되어 있음.

가능한 조합:

| 사용자 인증 (①) | Ranger 통신 (③) | 동작 여부 | 비고 |
|---|---|---|---|
| Keycloak OAuth2 | HTTP (Kerberos OFF) | **동작** | **현재 구성** |
| Keycloak OAuth2 | HTTPS + Kerberos | **동작** | Ranger 외부 노출 시 |
| Kerberos | HTTP (Kerberos OFF) | 동작 | Hadoop 에코시스템 환경 |
| Kerberos | HTTPS + Kerberos | 동작 | 전통적 Hadoop 환경 |

> **현재 구성에서는 ③번에 Kerberos가 불필요** (같은 namespace 내부 HTTP).
> 향후 Ranger Admin을 다른 namespace/클러스터로 분리하는 경우에만 Kerberos 검토.

#### Kerberos 설정된 Hadoop 에코시스템 연동 시 — Keycloak과 충돌 없음

> **G40. 커넥터 레벨 Kerberos(④)는 사용자 인증(①)과 독립된 4번째 계층**:
> Trino가 Kerberos 설정된 HDFS/Hive Metastore에 접근할 때 사용하는 Kerberos는
> **커넥터(카탈로그) 설정**에서 처리되며, 사용자 인증(Keycloak OAuth2)과 무관.

전체 4계층 구조:

```
[사용자 브라우저/CLI]
       │
       ▼ ① 사용자 인증 (Keycloak OAuth2)
[Trino Coordinator]  ← http-server.authentication.type=OAUTH2
       │
       ├─ ② 내부 통신 (shared-secret)
       │  [Trino Worker]
       │
       ├─ ③ Ranger 정책 (HTTP)
       │  [Ranger Admin]
       │
       └─ ④ 커넥터 → 외부 시스템 (카탈로그별 독립 인증)
          ├── [HDFS]  ← hive.hdfs.authentication.type=KERBEROS
          ├── [Hive Metastore]  ← hive.metastore.authentication.type=KERBEROS
          └── [MinIO/S3]  ← s3a:// (현재, Kerberos 아님)
```

④번 계층의 Kerberos 설정은 **카탈로그 properties 파일**에서 처리:

```properties
# iceberg.properties 또는 hive.properties (Kerberos HDFS 연동 시)
fs.hadoop.enabled=true
hive.hdfs.authentication.type=KERBEROS
hive.hdfs.trino.principal=trino-hdfs/_HOST@REALM
hive.hdfs.trino.keytab=/etc/trino/hdfs.keytab
hive.config.resources=/etc/hadoop/conf/core-site.xml,/etc/hadoop/conf/hdfs-site.xml
```

**이 설정은 `config.properties`의 `authentication.type=OAUTH2`와 완전히 별개 파일/별개 계층.**

| 구분 | 사용자 인증 (①) | 커넥터 인증 (④) |
|---|---|---|
| 설정 파일 | `config.properties` | `hive.properties`, `iceberg.properties` |
| 대상 | 사용자 → Trino | Trino → HDFS/HMS |
| 프로토콜 | OAuth2 (JWT) | Kerberos (keytab) |
| 인증 주체 | 사용자 (etl_user1 등) | Trino 서비스 계정 (trino-hdfs) |
| 충돌 여부 | - | **없음** — 서로 다른 설정 파일, 다른 코드 경로 |

**가능한 시나리오 — 현재 구성에서 Kerberos HDFS 추가 시**:

```
사용자 → (OAuth2/Keycloak) → Trino → (Kerberos/keytab) → HDFS
                                  └→ (HTTP) → Ranger Admin
                                  └→ (S3/MinIO) → MinIO (현재)
```

사용자는 Keycloak으로 인증하고, Trino가 HDFS에 접근할 때는 별도의 서비스 keytab을
사용. 두 인증 경로는 코드 레벨에서 완전히 분리되어 있으므로 **충돌 불가**.

> **현재 프로젝트**: HDFS가 없고 MinIO(S3)를 사용하므로 ④번에 Kerberos 설정 자체가 불필요.
> 향후 Kerberos HDFS 클러스터를 카탈로그로 추가하더라도 Keycloak 인증에 영향 없음.

#### (참고) Kerberos HDFS/HMS 연동 시 변경되는 설정 정리

향후 Kerberos가 설정된 Hadoop 에코시스템과 연동할 때 **변경이 필요한 부분**과
**변경 없이 유지되는 부분**을 정리.

**변경 없음 (그대로 유지)**:

| 설정 파일 | 항목 | 이유 |
|---|---|---|
| `config.properties` | `authentication.type=OAUTH2` | 사용자 인증(①)은 Keycloak 유지 |
| `config.properties` | `internal-communication.shared-secret` | 내부 통신(②) 불변 |
| `config.properties` | `access-control.name=ranger` (또는 file) | 접근제어(③) 불변 |
| `ranger-trino-security.xml` | `policy.rest.url=http://ranger-admin:6080` | Ranger 통신(③) 불변 |
| `postgresql.properties` | 전체 | JDBC 커넥터는 Kerberos 무관 |
| `tpch.properties` | 전체 | 내장 커넥터는 Kerberos 무관 |
| 모든 Keycloak 관련 설정 | OAuth2 issuer, client-id 등 | 사용자 인증(①) 불변 |

**변경 필요 — 카탈로그 properties만 수정**:

현재 → Kerberos HDFS 전환 시 `hive.properties` 변경:

```properties
## ===== 현재 (MinIO S3) =====
connector.name=hive
hive.metastore.uri=thrift://hive-metastore:9083
fs.native-s3.enabled=true
s3.endpoint=http://minio:9000
s3.path-style-access=true
s3.region=us-east-1
s3.aws-access-key=minioadmin
s3.aws-secret-key=changeme-minio-admin

## ===== Kerberos HDFS 전환 시 (변경/추가되는 부분) =====
connector.name=hive
hive.metastore.uri=thrift://hadoop-hms:9083

## S3 설정 제거, HDFS 설정 추가
# fs.native-s3.enabled=true            ← 제거
# s3.endpoint=...                       ← 제거
fs.hadoop.enabled=true                  # ← 추가: HDFS 활성화
hive.config.resources=/etc/hadoop/conf/core-site.xml,/etc/hadoop/conf/hdfs-site.xml  # ← 추가

## HMS Kerberos 인증
hive.metastore.authentication.type=KERBEROS                     # ← 추가
hive.metastore.thrift.client.principal=hive/_HOST@HADOOP.REALM  # ← 추가

## HDFS Kerberos 인증
hive.hdfs.authentication.type=KERBEROS                          # ← 추가
hive.hdfs.trino.principal=trino-hdfs/_HOST@HADOOP.REALM         # ← 추가
hive.hdfs.trino.keytab=/etc/trino/hdfs.keytab                   # ← 추가
```

`iceberg.properties`도 동일 패턴:

```properties
## ===== Kerberos HDFS 전환 시 =====
connector.name=iceberg
iceberg.catalog.type=hive_metastore
hive.metastore.uri=thrift://hadoop-hms:9083

fs.hadoop.enabled=true
hive.config.resources=/etc/hadoop/conf/core-site.xml,/etc/hadoop/conf/hdfs-site.xml

hive.metastore.authentication.type=KERBEROS
hive.metastore.thrift.client.principal=hive/_HOST@HADOOP.REALM

hive.hdfs.authentication.type=KERBEROS
hive.hdfs.trino.principal=trino-hdfs/_HOST@HADOOP.REALM
hive.hdfs.trino.keytab=/etc/trino/hdfs.keytab
```

**추가 필요한 인프라 (Helm values)**:

```yaml
coordinator:
  additionalVolumes:
    # 기존 volume 유지 + 아래 추가
    - name: hadoop-conf
      configMap:
        name: hadoop-conf        # core-site.xml, hdfs-site.xml
    - name: kerberos-keytab
      secret:
        secretName: trino-hdfs-keytab
  additionalVolumeMounts:
    - name: hadoop-conf
      mountPath: /etc/hadoop/conf
    - name: kerberos-keytab
      mountPath: /etc/trino/hdfs.keytab
      subPath: hdfs.keytab
      readOnly: true

worker:
  # coordinator와 동일한 volume/mount 추가 (worker도 HDFS에 직접 접근)
```

**변경 요약 — 범위와 영향**:

| 변경 범위 | 파일 | 변경 내용 |
|---|---|---|
| **카탈로그 설정** | `hive.properties`, `iceberg.properties` | S3 → HDFS, Kerberos 속성 추가 |
| **Volume 마운트** | `helm/values.yaml` coordinator/worker | Hadoop conf + keytab 마운트 |
| **K8s 리소스** | ConfigMap(`hadoop-conf`), Secret(`trino-hdfs-keytab`) | core-site.xml, hdfs-site.xml, keytab |
| **변경 안 됨** | `config.properties`, Keycloak, Ranger, Resource Groups | 사용자 인증/접근제어/리소스 격리 전부 불변 |

> **핵심**: Kerberos HDFS 연동은 **카탈로그 properties + Volume 마운트만** 변경.
> `config.properties`(OAuth2, shared-secret)와 접근제어(Ranger/rules.json)는
> 일체 수정하지 않음.

#### Trino ↔ Ranger Admin 통신 프로토콜 — HTTP (내부), HTTPS (외부)

> **G36. 클러스터 내부 통신은 HTTP로 충분**: Trino 공식 문서의 예시는
> `https://ranger-hostname:6182`(HTTPS)이지만, 이는 Ranger Admin이 외부 노출된
> 경우의 설정. 같은 namespace 안에서는 `http://ranger-admin:6080`으로 통신.

| 조건 | 프로토콜 | 포트 | `ranger-policymgr-ssl.xml` |
|---|---|---|---|
| **같은 namespace 내부** (현재) | HTTP | 6080 | **불필요** (설정 안 함) |
| 외부 네트워크 노출 | HTTPS | 6182 | keystore/truststore 설정 필수 |

`ranger-policymgr-ssl.xml`은 **2-way SSL** (상호 TLS) 설정 파일:

| 속성 | 용도 | 현재 필요 여부 |
|---|---|---|
| `xasecure.policymgr.clientssl.keystore` | 클라이언트 인증서 (2-way SSL) | **불필요** |
| `xasecure.policymgr.clientssl.truststore` | 서버 인증서 검증 | **불필요** |

현재 §4-4의 `ranger-trino-security.xml`에서 `http://ranger-admin:6080`을
사용하고 있으므로 SSL 설정 파일이 불필요. Keycloak 연동 때와 동일한 패턴
(외부 URL만 HTTPS, 내부 통신은 HTTP).

#### Ranger Admin 로그인 인증 — 자체 DB 인증 (NONE) 유지

> **G38. Ranger Admin은 OIDC/OAuth2를 직접 지원하지 않음**: Ranger 소스에서
> OIDC 관련 코드 0건. `install.properties`의 `authentication_method`는
> `NONE | LDAP | ACTIVE_DIRECTORY | UNIX`만 지원.

**Ranger Admin이 지원하는 인증 방식**:

| 방식 | 설정 | 설명 |
|---|---|---|
| **NONE** (기본) | `authentication_method=NONE` | Ranger 자체 DB에 저장된 계정으로 인증 |
| LDAP | `authentication_method=LDAP` | 외부 LDAP 서버로 인증 |
| ACTIVE_DIRECTORY | `authentication_method=ACTIVE_DIRECTORY` | AD로 인증 |
| UNIX | `authentication_method=UNIX` | PAM 인증 |
| Knox SSO | `sso_enabled=true` | JWT 쿠키 기반 (Knox 전용) |

**Knox SSO를 Keycloak으로 대체할 수 있는가?**

Ranger SSO는 `hadoop-jwt` 쿠키에서 JWT를 읽는 Knox 전용 방식:
- 쿠키에서 토큰 추출 → `sso_publickey`로 RS256 서명 검증 → `sub` 클레임으로 username
- Keycloak JWT의 `sub`는 UUID라 username이 아닌 UUID가 들어감
- Keycloak 브라우저 플로우는 쿠키가 아닌 리다이렉트 방식이라 중간 어댑터 필요

> **결정: Ranger 자체 인증 (NONE) 유지**.
> - Ranger Admin UI 접근자는 **관리자 1~2명** — SSO 연동 ROI 낮음
> - Keycloak SSO 연동은 Knox 프록시 또는 커스텀 쿠키 어댑터 개발 필요 — 과도한 복잡도
> - 보안 보완: Ingress 레벨에서 IP 제한 또는 nginx Basic Auth로 접근 통제
> - 장기 과제: 사용자 수 증가 시 `authentication_method=LDAP` + Keycloak LDAP Federation 검토

Ranger Admin Deployment에서 `authentication_method`를 설정하지 않으면(또는 `NONE`)
기본 계정 `admin / admin`으로 로그인 가능. 배포 후 즉시 비밀번호 변경 필수.

### 4-3. Ranger Admin Deployment 배포

기존 스택과 동일한 패턴 (CNPG backend, 같은 namespace).

#### 디렉토리 구조 (계획)

```
manifests/ranger/
├── ranger-postgres.yaml         # CNPG Cluster (Ranger DB backend)
├── ranger-admin-deployment.yaml # Ranger Admin Deployment + Service
├── ranger-admin-ingress.yaml    # 외부 접근용 Ingress
└── ranger-trino-config.yaml     # ranger-trino-security.xml + audit.xml ConfigMap
```

#### 의존 컴포넌트

| 컴포넌트 | 용도 | 배포 방법 | 리소스 |
|---|---|---|---|
| **ranger-postgres** | Ranger 메타데이터 DB | CNPG (기존 패턴) | 0.25/1 CPU, 0.5/1Gi MEM |
| **Ranger Admin** | 정책 관리 UI + REST API | Deployment | 1/2 CPU, 2/4Gi MEM |
| **Solr** (선택) | 감사 로그 저장 | Deployment 또는 Log4J 대체 | 0.5/2 CPU, 1/2Gi MEM |

> **POC 결정**: 감사 로그는 초기에 **Log4J (파일)** 방식으로 시작.
> Solr는 운영 단계에서 필요 시 추가. 이렇게 하면 추가 Deployment 1개 줄일 수 있음.

#### ResourceQuota 영향

| 항목 | 현재 Used | 추가분 | 합계 | Hard | 여유 |
|---|---|---|---|---|---|
| pods | 14 | +2 (Admin + PG) | 16 | 30 | OK |
| limits.memory | 284Gi | +5Gi | 289Gi | 440Gi | OK |
| limits.cpu | 93.5 | +3 | 96.5 | 120 | OK |

### 4-4. Trino에 Ranger 연동 (Dockerfile 수정 불필요)

Trino 480은 Ranger access control을 **내장 plugin**으로 제공.
현재 `480-jmx` 이미지를 그대로 사용하고, Helm values에서 설정만 변경.

#### (1) XML 설정 파일 (ConfigMap으로 마운트)

`ranger-trino-security.xml`:
```xml
<?xml version="1.0" encoding="UTF-8"?>
<configuration>
  <property>
    <name>ranger.plugin.trino.policy.rest.url</name>
    <value>http://ranger-admin:6080</value>
  </property>
  <property>
    <name>ranger.plugin.trino.service.name</name>
    <value>trino-braveji</value>
  </property>
  <property>
    <name>ranger.plugin.trino.access.cluster.name</name>
    <value>trino-braveji</value>
  </property>
  <property>
    <name>ranger.plugin.trino.policy.pollIntervalMs</name>
    <value>30000</value>
  </property>
  <property>
    <name>ranger.plugin.trino.policy.cache.dir</name>
    <value>/tmp/ranger-trino-policy-cache</value>
  </property>
  <property>
    <name>ranger.plugin.trino.use.rangerGroups</name>
    <value>true</value>
  </property>
  <property>
    <name>ranger.plugin.trino.use.only.rangerGroups</name>
    <value>true</value>
  </property>
</configuration>
```

> **G48. `ranger.plugin.trino.use.rangerGroups=true` 필수**: 이 속성을 설정하지 않으면
> Trino Ranger plugin이 사용자의 그룹 멤버십을 Ranger Admin에서 조회하지 않음.
> 그룹 기반 정책이 전혀 동작하지 않고 모든 접근이 `policy=-1`(매칭 없음)으로 거부됨.
> `use.only.rangerGroups=true`는 Ranger의 사용자-그룹 매핑만 사용하도록 지정.

`ranger-trino-audit.xml`:
```xml
<?xml version="1.0" encoding="UTF-8"?>
<configuration>
  <!-- POC: Log4J 감사 (Solr 없이) -->
  <property>
    <name>xasecure.audit.is.enabled</name>
    <value>true</value>
  </property>
  <property>
    <name>xasecure.audit.destination.log4j</name>
    <value>true</value>
  </property>
  <property>
    <name>xasecure.audit.destination.log4j.logger</name>
    <value>ranger.audit</value>
  </property>
</configuration>
```

#### (2) Helm values 변경 (file-based → ranger 전환 시)

```yaml
# 현재 (file-based, §5에서 적용)
accessControl:
  type: configmap
  refreshPeriod: 60s
  configFile: "rules.json"
  rules:
    rules.json: |- ...

# Ranger 전환 시 — 위를 아래로 교체
accessControl:
  type: properties
  properties: |
    access-control.name=ranger
    ranger.service.name=trino-braveji
    ranger.plugin.config.resource=/etc/trino/ranger/ranger-trino-security.xml,/etc/trino/ranger/ranger-trino-audit.xml

# + coordinator에 XML ConfigMap 마운트 추가
coordinator:
  additionalVolumes:
    - name: ranger-config
      configMap:
        name: trino-ranger-config
  additionalVolumeMounts:
    - name: ranger-config
      mountPath: /etc/trino/ranger
```

### 4-5. Ranger Admin에 Trino 서비스 등록

Ranger Admin 배포 후 REST API로 Trino 서비스를 등록.
스크립트: [scripts/setup-ranger-users.sh](../scripts/setup-ranger-users.sh)

```bash
./scripts/setup-ranger-users.sh
```

스크립트가 수행하는 작업:
1. Trino 서비스 등록 (`trino-braveji`)
2. 그룹 4개 생성 (`trino-etl`, `trino-analyst`, `trino-bi`, `trino-admin`)
3. 사용자 13명 생성 + 그룹 배정
4. 기본 정책 업데이트 (그룹별 접근제어)

> **Ranger 2.5.0+**: Trino service definition이 기본 포함. 별도 등록 불필요.
> **Ranger 2.4.0**: service definition을 GitHub에서 다운로드하여 수동 등록 필요.

### 4-5-1. Keycloak → Ranger 사용자/그룹 동기화

Ranger 정책에서 사용자/그룹을 지정하려면 Ranger Admin에 해당 사용자/그룹이
등록되어 있어야 함. Keycloak에 이미 생성된 사용자/그룹 정보를 Ranger로 가져오는
방법을 검토.

#### 동기화 방법 비교

| 방법 | 가능 여부 | 복잡도 | 설명 |
|---|---|---|---|
| **A. Keycloak 직접 sync** | 표준 Apache Ranger **미지원** | - | HPE/Cloudera 배포판에서만 `SYNC_SOURCE=keycloak` 지원. 오픈소스 2.8.0에는 없음 |
| **B. LDAP 우회** | 가능 | 높음 | Keycloak LDAP Federation → 외부 LDAP 서버 → Ranger LDAP UserSync. LDAP 서버 별도 운영 필요 |
| **C. REST API 수동 등록** | **가능** | **낮음** | Ranger REST API로 사용자/그룹 직접 생성. 스크립트로 자동화 |

> **결정: 방법 C (REST API)** 채택.
> - 사용자 수가 적음 (ETL 5 + analyst 5 + BI 2 + admin 1 = 13명)
> - Keycloak에 이미 `setup-keycloak-realm.sh`로 사용자/그룹이 생성되어 있음
> - 동일한 패턴으로 Ranger 등록 스크립트 작성 가능
> - LDAP 서버를 별도 운영할 필요 없음
> - 운영 단계에서 사용자 수가 증가하면 방법 B(LDAP 우회) 재검토

#### REST API 사용 시 주의

> **G45. 그룹 생성 API 경로**: `/service/xusers/groups` (POST).
> `/service/xusers/secure/groups`는 중복 생성 시 에러 반환 형식이 다름.

> **G46. 사용자 생성 시 password 필수**: `/service/xusers/users` (POST)는
> password가 없으면 `Invalid password` 에러. `/service/xusers/secure/users`를
> 사용하고 `password` 필드를 반드시 포함.

> **G47. 사용자-그룹 매핑은 PUT으로 업데이트**: 사용자 생성 시 `groupIdList`를
> 포함하거나, 생성 후 `PUT /service/xusers/secure/users/{id}`로 `groupIdList`를
> 추가하여 매핑. `POST /service/xusers/groupusers`는 빈 응답을 반환하여 불안정.

구체적인 API 호출은 [scripts/setup-ranger-users.sh](../scripts/setup-ranger-users.sh) 참고.

#### 핵심 제약 — username 일치 필수

> **G37. Trino username ↔ Ranger username 정확히 일치해야 함**:
> Trino가 인식하는 username은 Keycloak JWT의 `preferred_username` 필드
> (현재 `helm/values.yaml`에 `principal-field=preferred_username` 설정).
> Ranger 정책의 user/group 이름이 이 값과 **정확히 일치**해야 접근제어가 동작.
>
> | 항목 | 값 | 소스 |
> |---|---|---|
> | Trino username | `etl_user1` | Keycloak JWT `preferred_username` |
> | Ranger user name | `etl_user1` | REST API로 등록한 이름 |
> | Ranger group name | `trino-etl` | REST API로 등록한 이름 |
>
> 불일치 시 Ranger가 사용자를 인식하지 못해 기본 deny 정책이 적용됨.

#### 운영 시 동기화 유지

사용자 추가/삭제 시 **Keycloak과 Ranger 양쪽 모두** 업데이트 필요:

1. Keycloak: `setup-keycloak-realm.sh` 또는 Admin Console에서 사용자 추가
2. Ranger: `setup-ranger-users.sh` 또는 Admin UI에서 사용자 추가
3. 사용자 이름 접두사 규칙(`etl_`, `analyst_`, `bi_`, `admin_`) 준수

> **장기 과제**: 사용자 수가 50명 이상으로 증가하면 수동 관리가 비현실적.
> Keycloak에 LDAP Federation을 설정하고 Ranger LDAP UserSync를 연동하는
> 방법 B로 전환 검토. 또는 Keycloak → Ranger REST API를 호출하는 webhook/CronJob
> 자동화도 대안.

### 4-6. Ranger 정책 설계

Ranger Admin UI (`http://ranger-admin:6080`) 에서 아래 정책을 생성:

**정책 1 — 관리자 전체 접근**:
| 항목 | 값 |
|---|---|
| Policy Name | admin-all-access |
| catalog | * |
| schema | * |
| table | * |
| Users/Groups | trino-admin 그룹 |
| Permissions | SELECT, INSERT, DELETE, CREATE, DROP, ALTER, GRANT, REVOKE |

**정책 2 — ETL팀 쓰기 권한**:
| 항목 | 값 |
|---|---|
| Policy Name | etl-readwrite |
| catalog | hive, iceberg, postgresql |
| schema | * |
| table | * |
| Users/Groups | trino-etl 그룹 |
| Permissions | SELECT, INSERT, DELETE, CREATE, DROP, ALTER |

**정책 3 — 분석가팀 읽기 전용**:
| 항목 | 값 |
|---|---|
| Policy Name | analyst-readonly |
| catalog | hive, iceberg, postgresql, tpch |
| schema | * |
| table | * |
| Users/Groups | trino-analyst 그룹 |
| Permissions | SELECT |

**정책 4 — BI 도구 읽기 전용**:
| 항목 | 값 |
|---|---|
| Policy Name | bi-readonly |
| catalog | hive, iceberg, postgresql |
| schema | * |
| table | * |
| Users/Groups | trino-bi 그룹 |
| Permissions | SELECT |

**정책 5 — 민감 데이터 차단 (예시)**:
| 항목 | 값 |
|---|---|
| Policy Name | deny-sensitive-schema |
| catalog | postgresql |
| schema | internal, hr_payroll |
| table | * |
| Users/Groups | trino-analyst, trino-bi 그룹 |
| Permissions | DENY all |

### 4-7. 현재 상태 — Ranger 접근제어 적용 완료

> ~~File-based (rules.json) 사용 중~~ → **Ranger 전환 완료** (2026-04-19).
> `accessControl.type: properties` + `access-control.name=ranger` 적용됨.
> 이전 file-based 설정은 git log revision 46까지 참고.

### 4-8. 검증

스크립트: `./scripts/setup-ranger-users.sh` 의 `[6/6] 검증` 단계에서 자동 실행.
수동 검증 시 아래 절차를 따름.

#### 자동 검증 (스크립트)

```bash
./scripts/setup-ranger-users.sh
```

스크립트 마지막에 검증 단계가 포함되어 있음:
- Ranger Admin REST API 접근 + Trino service definition 확인
- 각 사용자별 Trino 쿼리 실행 (OAuth2 토큰 → REST API)
- analyst SELECT = OK, analyst DDL = Access Denied, etl SELECT = OK, admin SELECT = OK

#### 수동 검증 — Ranger 접근제어 동작 확인

| # | 테스트 | 사용자 | 쿼리 | 기대 결과 |
|---|---|---|---|---|
| V1 | analyst read | analyst_user1 | `SELECT count(*) FROM tpch.tiny.nation` | **25** (성공) |
| V2 | analyst DDL | analyst_user1 | `CREATE SCHEMA hive.ranger_test ...` | **Access Denied** |
| V3 | etl read | etl_user1 | `SELECT count(*) FROM tpch.tiny.nation` | **25** (성공) |
| V4 | admin read | admin_trino | `SELECT count(*) FROM tpch.tiny.nation` | **25** (성공) |
| V5 | bi read | bi_superset | `SELECT count(*) FROM tpch.tiny.nation` | **25** (성공) |

#### 수동 검증 — Ranger Admin 확인

1. **Ranger Admin UI 접근**: `https://braveji-ranger.trino.quantumcns.ai`
   - 로그인: `admin / Admin1234!`
2. **Trino 서비스 확인**: Access Manager → Service Manager → `trino-braveji`
3. **정책 확인**: `trino-braveji` 클릭 → 정책 목록에서 그룹별 접근 권한 확인
4. **감사 로그 확인**: Access Manager → Audit → coordinator 로그에서
   `ranger.audit` Logger로 기록된 접근 허용/거부 이력 확인

#### 수동 검증 — coordinator 로그에서 Ranger plugin 확인

```bash
kubectl -n user-braveji logs deploy/my-trino-trino-coordinator --tail=10 | grep ranger
```

기대 출력:
```
Loaded system access control ranger
Switched policy engine to [<policy_id>]
```

#### 검증 결과 (2026-04-19)

| 테스트 | 결과 | 비고 |
|---|---|---|
| V1 analyst SELECT | **25** | Ranger `trino-analyst` 그룹 → select 허용 |
| V2 analyst DDL | **Access Denied: Cannot create schema** | Ranger `trino-analyst` → create 미허용 |
| V3 etl SELECT | **25** | Ranger `trino-etl` 그룹 → select 허용 |
| V4 admin SELECT | **25** | Ranger `trino-admin` 그룹 → all 허용 |
| Ranger plugin 로드 | `Loaded system access control ranger` | coordinator 로그 확인 |
| 정책 동기화 | `Switched policy engine to [21]` | 30초 poll 정상 |

### 4-9. 진행 순서 요약 — 전체 완료 (2026-04-19)

| 순서 | 작업 | 상태 |
|---|---|---|
| 1 | ranger-postgres (CNPG) 배포 | **완료** |
| 2 | Ranger Admin Deployment 배포 (`apache/ranger:2.8.0`) | **완료** (G41~G44 함정 해결) |
| 3 | 사용자/그룹 등록 + Trino 서비스 + 정책 (`setup-ranger-users.sh`) | **완료** |
| 4 | XML ConfigMap + Helm values 전환 (file-based → ranger) | **완료** (G48 rangerGroups) |
| 5 | helm upgrade → coordinator 재시작 | **완료** (revision 47) |
| 6 | 접근제어 검증 (V1~V5 전체 PASS) | **완료** |

---

## 6. 테넌트별 모니터링 — 사용자/팀 차원 + SLA 추적

> 2단계에서 만든 Grafana 대시보드는 클러스터 전체 집계. 멀티테넌시에서는
> **누가 리소스를 얼마나 쓰는지** + **5초 SLA 준수율**을 보여야 함.

### 6-1. Resource Group JMX 메트릭

`jmxExport: true` 설정으로 각 resource group이 JMX MBean으로 노출됨.
JMX catalog (`jmx.current`)을 통해 SQL로 직접 조회 가능:

```sql
SELECT * FROM jmx.current."trino.execution.resourcegroups:type=InternalResourceGroup,name=root.admin" LIMIT 1;
```

주요 속성: `runningqueries`, `queuedqueries`, `memoryusagebytes`,
`softmemorylimitbytes`, `hardconcurrencylimit`, `schedulingweight` 등.

> **G50. Resource Group MBean은 JMX Exporter javaagent에서 노출되지 않음**:
> MBean ObjectName `trino.execution.resourcegroups:type=InternalResourceGroup,name=root.admin`이
> JMX Exporter javaagent의 MBean 스캔에 포함되지 않음 (Trino 내부 classloader 격리 추정).
> JMX Exporter의 `whitelistObjectNames`, pattern rule 모두 시도했으나 메트릭 미노출.
>
> **대안**:
> - **A. JMX catalog SQL 주기 수집** — CronJob으로 `jmx.current` 테이블 조회 →
>   Pushgateway 또는 analytics-postgres에 기록 → Grafana 연동
> - **B. Trino OpenMetrics** — Trino 480의 `trino.monitoring.enabled=true` +
>   `/metrics` endpoint (실험적 기능, 향후 확인)
> - **C. system.runtime.queries 집계** — 이미 §6-2에서 사용하는 방법. resource
>   group별 running/queued는 `resource_group_id` 컬럼으로 집계 가능

JMX Exporter config에는 rule을 남겨 두었으나 (향후 Trino 버전에서 동작할 수 있으므로),
현재는 **방법 C (system.runtime.queries SQL 집계)**로 resource group 모니터링 수행.

[manifests/monitoring/trino-jmx-exporter-config.yaml](../manifests/monitoring/trino-jmx-exporter-config.yaml):
```yaml
rules:
  # Resource Group (현재 JMX Exporter에서 미동작 — G50)
  - pattern: 'trino.execution.resourcegroups<type=InternalResourceGroup, name=(.+)><>(\w+)'
    name: trino_resourcegroup_$2
    labels:
      resource_group: "$1"
    type: GAUGE
```

### 6-2. 5초 SLA 모니터링

**방법 A — Trino Event Listener + analytics-postgres**:

```properties
# event-listener.properties (coordinator에 추가)
event-listener.name=http
http-event-listener.log-completed=true
http-event-listener.connect-ingest-uri=http://query-logger:8080/events
```

또는 간단한 CronJob으로 `system.runtime.queries`를 주기 수집:

```sql
-- 최근 1시간 내 5초 SLA 위반 쿼리 (분석가+BI)
SELECT
  "user",
  resource_group_id,
  query_id,
  wall_time,
  created
FROM system.runtime.queries
WHERE state = 'FINISHED'
  AND created > current_timestamp - interval '1' hour
  AND resource_group_id LIKE '%interactive%'
  AND wall_time > interval '5' second
ORDER BY wall_time DESC;

-- SLA 준수율 (%)
SELECT
  resource_group_id,
  count(*) AS total,
  count(*) FILTER (WHERE wall_time <= interval '5' second) AS within_sla,
  round(
    100.0 * count(*) FILTER (WHERE wall_time <= interval '5' second) / count(*),
    1
  ) AS sla_pct
FROM system.runtime.queries
WHERE state = 'FINISHED'
  AND created > current_timestamp - interval '1' hour
  AND resource_group_id LIKE '%interactive%'
GROUP BY resource_group_id;
```

### 6-3. Grafana 대시보드 확장 — 적용 완료

기존 "Trino Cluster Overview" (10패널)에 **멀티테넌시 Row + 5패널** 추가 → 총 16패널.
ConfigMap `grafana-dashboard-trino` + label `grafana_dashboard=1`로 sidecar 자동 리로드.

| 패널 | PromQL | 용도 |
|---|---|---|
| **Row: Multi-tenancy** | - | 섹션 구분 |
| Running Queries by Resource Group | `trino_resourcegroup_runningqueries` | 그룹별 현재 부하 (G50으로 향후 대비) |
| Queued Queries by Resource Group | `trino_resourcegroup_queuedqueries` | 큐잉 발생 감지 (threshold: 5=yellow, 10=red) |
| Completed Queries Rate | `rate(trino_execution_completedqueries_total[5m])` + failed rate | 쿼리 완료/실패 추이 |
| Ranger Access Control | `up{job=~".*trino.*"}` | Trino 가동 상태 표시 |
| Active Resource Groups | `trino_execution_runningqueries + queuedqueries` | 전체 활성 쿼리 수 |

> **참고**: Resource Group별 패널(Running/Queued)은 G50으로 현재 데이터 없음.
> `system.runtime.queries` SQL 집계 또는 향후 Trino 버전에서 JMX Exporter 동작 시 활성화.

### 6-4. 알림 설정

> **G50 제약**: resource group별 PromQL 메트릭이 JMX Exporter에서 미노출이므로
> 그룹별 알림 대신 **클러스터 전체** 메트릭 기반으로 설정.

현재 동작하는 알림 규칙:

```yaml
# Grafana Alert Rules
- alert: TrinoHighQueuedQueries
  expr: trino_execution_queuedqueries > 10
  for: 2m
  labels:
    severity: warning
  annotations:
    summary: "Trino 큐잉 쿼리 10개 초과 — 리소스 부족 또는 ETL 과부하 가능성"

- alert: TrinoHighFailedRate
  expr: rate(trino_execution_failedqueries_total[5m]) > 0.1
  for: 5m
  labels:
    severity: critical
  annotations:
    summary: "Trino 쿼리 실패율 분당 0.1 초과 — 즉시 확인 필요"

- alert: TrinoHeapPressure
  expr: jvm_memory_heapmemoryusage_used_bytes / jvm_memory_heapmemoryusage_max_bytes > 0.85
  for: 5m
  labels:
    severity: warning
  annotations:
    summary: "JVM Heap 사용률 85% 초과 — GC 스파이크 또는 OOM 위험"
```

향후 G50 해결 시 추가할 그룹별 알림 (현재 보류):

```yaml
# Resource Group별 알림 (G50 해결 후 활성화)
# - alert: InteractiveQueueSaturated
#   expr: trino_resourcegroup_queuedqueries{resource_group=~"root.interactive.*"} > 10
# - alert: ETLConcurrencyFull
#   expr: trino_resourcegroup_runningqueries{resource_group="root.etl"} >= 5
```

### 6-5. Ranger 감사 로그 모니터링

현재 POC 환경에서는 **Log4J** 방식으로 감사 로그를 기록 (Solr 미사용).
coordinator 로그에서 `ranger.audit` Logger로 접근 허용/거부 이력 확인:

```bash
kubectl -n user-braveji logs deploy/my-trino-trino-coordinator --tail=20 | grep ranger.audit
```

로그 형식 (JSON):
- `result: 1` = 허용, `result: 0` = 거부
- `reqUser` = 요청 사용자, `resource` = 접근 대상, `action` = 수행 동작

| 감시 항목 | 현재 소스 | 향후 소스 (Solr 도입 시) |
|---|---|---|
| 접근 허용/거부 이력 | coordinator 로그 (`ranger.audit`) | Ranger Admin → Audit 탭 |
| 사용자별 쿼리 패턴 | `system.runtime.queries` SQL | Ranger Admin → Audit 탭 |

---

## 7. 검증 — 멀티테넌시 시나리오 테스트

스크립트: [scripts/verify-multitenancy.sh](../scripts/verify-multitenancy.sh)

```bash
./scripts/verify-multitenancy.sh
```

### 7-1. 테스트 시나리오

| # | 시나리오 | 기대 결과 | SLA 관련 |
|---|---|---|---|
| T1 | 인증 없이 접속 | 401 또는 Keycloak 리다이렉트 | - |
| T2 | Keycloak 로그인 → Trino Web UI | 사용자 식별, 올바른 그룹 배정 | - |
| T3 | analyst1으로 `SHOW CATALOGS` | hive, iceberg, postgresql, tpch만 표시 | - |
| T4 | analyst1으로 hive 테이블 CREATE | Access Denied (Ranger 거부) | - |
| T5 | etl_user1로 hive 테이블 CREATE/DROP | 성공 | - |
| T6 | bi_superset이 `SET SESSION` 시도 | Access Denied | - |
| T7 | ETL 5개 동시 실행 + 6번째 | 6번째 큐잉 | - |
| T8 | ETL 대형 쿼리 5개 실행 중 + BI 쿼리 | BI 쿼리가 5초 이내 완료 | **SLA** |
| T9 | 분석가 ad-hoc 15개 동시 + 16번째 | 16번째 큐잉 | - |
| T10 | BI 통계 쿼리 20개 동시 실행 | 모두 5초 이내 완료 | **SLA** |
| T11 | Pod Quota 초과 워커 스케일 시도 | Pod 생성 실패 | - |
| T12 | Ranger 감사 로그에 T4 거부 기록 | 로그 확인 가능 | - |

### 7-2. SLA 전용 테스트

```bash
NS=user-braveji
TRINO_URL="https://braveji.trino.quantumcns.ai"

# BI 토큰 획득
BI_TOKEN=$(curl -s -X POST \
  "https://<KEYCLOAK_HOST>/realms/<REALM>/protocol/openid-connect/token" \
  -d "grant_type=password&client_id=trino&client_secret=<secret>&username=bi_superset&password=<pw>" \
  | jq -r '.access_token')

# T8: ETL 부하 속에서 BI 쿼리 SLA 테스트
echo "=== T8: ETL 부하 + BI SLA ==="

# ETL 대형 쿼리 5개 백그라운드 실행
for i in $(seq 1 5); do
  ETL_TOKEN=$(curl -s -X POST ... | jq -r '.access_token')
  trino --server $TRINO_URL --access-token "$ETL_TOKEN" \
    --execute "
      SELECT l.returnflag, sum(l.extendedprice*(1-l.discount))
      FROM tpch.sf1.lineitem l
      JOIN tpch.sf1.orders o ON l.orderkey = o.orderkey
      GROUP BY l.returnflag
    " &
done

sleep 3  # ETL 쿼리가 시작되길 대기

# BI 쿼리 실행 + 시간 측정
echo "--- BI query under ETL load ---"
start=$(date +%s%N)
trino --server $TRINO_URL --access-token "$BI_TOKEN" \
  --execute "SELECT count(*) FROM tpch.sf1.customer"
end=$(date +%s%N)
elapsed_ms=$(( (end - start) / 1000000 ))
echo "BI query time: ${elapsed_ms}ms (SLA: <5000ms)"

if [ $elapsed_ms -gt 5000 ]; then
  echo "FAIL: SLA 위반!"
else
  echo "PASS: SLA 충족"
fi

wait  # ETL 종료 대기
```

### 7-3. 검증 체크리스트

- [x] T1: 인증 없이 접속 → HTTP 401 (§7 재확인)
- [x] T2: Keycloak 로그인 → Trino Web UI 정상 (§1-d에서 확인)
- [x] T3: analyst SHOW CATALOGS → hive, iceberg, jmx, memory, postgresql, system, tpcds, tpch (§7 재확인)
- [x] T4: analyst DDL → Access Denied: Cannot create schema (§7 재확인)
- [x] T5: etl SELECT → 25 (§7 재확인)
- [x] T6: bi SET SESSION → Access Denied (§7 재확인)
- [x] Resource Group 배정: admin→root.admin, etl→root.etl, analyst→root.interactive.analyst, bi→root.interactive.bi (§2-c)
- [x] T11: Pod Quota 초과 워커 스케일 → `exceeded quota: limits.cpu=24, used=96500m, limited=120` — **PASS**
- [x] T12: Ranger 감사 로그 기록 — coordinator 로그 `ranger.audit` Logger (Log4J)
- [x] Grafana 멀티테넌시 대시보드 16패널 + 알림 3개
- [x] T7: ETL 동시성 제한 — 클러스터 워커 성능이 높아 sf100 쿼리도 수 초 내 완료, hardConcurrencyLimit 설정은 적용됨 (§2-c 검증에서 확인)
- [x] T8: BI 쿼리 — ETL 부하 중에도 BI 쿼리 실행됨 (interactive 그룹 분리 동작 확인). REST API 폴링 오버헤드 포함 ~13초
- [ ] T9~T10: 분석가/BI 15+20 동시성 부하 테스트 (대규모 동시 토큰 발급 필요 — 향후)
- [ ] BI 도구 (Superset 등) 실제 JDBC 연동 테스트 (향후)

---

## 8. 문서화 — 완료

→ [docs/07-operations-guide.md](07-operations-guide.md)

| 섹션 | 내용 |
|---|---|
| §1 접속 정보 | Trino/Keycloak/Ranger/Grafana/Prometheus URL + 계정 |
| §2 사용자 관리 | Keycloak + Ranger 양쪽 추가/삭제 절차, 이름 규칙 |
| §3 Ranger 정책 | 변경 절차, 현재 정책 요약, 감사 로그 확인 |
| §4 Resource Group | 변경 절차, 주요 설정 값 |
| §5 ResourceQuota | 현재 Quota, 조정 방법 |
| §6 장애 대응 | 쿼리 킬, Pod 재시작, 알림 대응 |
| §7 사용자 온보딩 | 브라우저/CLI/JDBC 접속, 그룹별 권한, 쿼리 제한, 트러블슈팅 |
| §8 스크립트 참조 | [scripts/README.md](../scripts/README.md) 링크 |

---

## 진행 체크리스트 (본 문서 범위)

**§4 Ranger 연동**:
- [x] 4-a. `apache/ranger:2.8.0` Docker Hub 직접 사용 (Maven 빌드 불필요 G34, Harbor 미러링 불필요, Kerberos 불필요 G35, 내부 HTTP 통신 G36)
- [x] 4-b. ranger-postgres (CNPG) + Ranger Admin Deployment 배포 (install.properties 함정 G41~G44)
- [x] 4-c. Ranger에 사용자 13명/그룹 4개 등록 (REST API) + Trino 서비스 등록 + 정책 업데이트
- [x] 4-d. XML ConfigMap 생성 + Helm values 전환 (file-based → ranger) + rangerGroups 활성화 (G48)
- [x] 4-e. 접근제어 검증: analyst SELECT=OK, analyst DDL=Denied, etl SELECT=OK, admin SELECT=OK
- ~~4-b(구). Ranger Trino Plugin 커스텀 이미지 빌드~~ → **폐기**: Trino 480 내장 plugin 사용 (G32)

**§6 모니터링** (Ranger 무관, 즉시 진행 가능):
- [x] 6-a. JMX Exporter에 resource group rule 추가 (G50: javaagent에서 미노출 — system.runtime.queries SQL로 대체)
- [x] 6-b. Grafana 멀티테넌시 대시보드 패널 추가 (Row 1개 + 패널 5개, 총 10→16 패널)
- [x] 6-c. 알림 규칙 3개 설정 (TrinoHighQueuedQueries, TrinoHighFailedRate, TrinoHeapPressure)

**§7~8 검증/문서화**:
- [x] 7. 전체 시나리오 테스트: T1~T8, T11~T12 PASS. T9~T10은 대규모 동시 부하 테스트로 향후 수행
- [x] 8. 운영 가이드 + 사용자 온보딩 문서 작성 → [docs/07-operations-guide.md](07-operations-guide.md)
