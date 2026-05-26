# Trino 479 ~ 481 릴리즈 노트 통합 정리

> 대상 릴리즈: **479 (2025-12-14)**, **480 (2026-03-24)**, **481 (2026-05-11)**
> 출처: [trino.io/docs/current/release](https://trino.io/docs/current/release.html)

---

## 📌 한눈에 보기 (릴리즈별 핵심 테마)

| 릴리즈 | 날짜 | 핵심 테마 |
|---|---|---|
| **479** | 2025-12-14 | JDK 25 필수, 컬럼 default 값, `IS NOT DISTINCT FROM` 버그 수정 |
| **480** | 2026-03-24 | `number` 타입 도입, Iceberg v3 본격 지원, Vertica 커넥터 제거 |
| **481** | 2026-05-11 | `variant` 타입, 공간 라이브러리 JTS 전환, 레거시 오브젝트 스토리지 제거 |

---

## 1. 새로운 데이터 타입 (3개 릴리즈에 걸친 흐름)

세 릴리즈를 관통하는 가장 큰 흐름입니다.

- **480**: `number` 타입 신규 추가
- **481**:
  - `number` 타입 확장 → `boolean` / `json` 캐스팅, Python UDF 지원
  - **`variant` 타입** 신규 추가 (Iceberg v3 실험적 지원, JDBC/CLI 지원)
  - Iceberg v3에서 `timestamp(9)` 및 `timestamp(9) with time zone` 읽기/쓰기

---

## 2. SQL 언어 / 함수 기능 추가

### 479
- `ALTER TABLE ... ALTER COLUMN`으로 컬럼 default 값 설정/삭제
- `array_first()`, `array_last()` 함수
- row 리터럴에서 필드명 선언: `row(1 as a, 2 as b)`
- `SHOW CREATE MATERIALIZED VIEW`에 `GRACE PERIOD` 추가

### 480
- 술어 기반 `array_first()` 변형
- **DataSketches 함수** 패키지
- 테이블 `[VERSION | TIMESTAMP] AS OF` 절에서 쿼리 파라미터 사용 가능

### 481
- `DESCRIBE OUTPUT`에서 인라인 쿼리 지원 (`PREPARE` 불필요)
- 조인의 **`NEAREST` 절** (근사 매칭)
- `WITH SESSION`, `SET SESSION`, `CALL` 문에서 파라미터 바인딩

---

## 3. ⚠️ Breaking Changes (가장 중요 — 업그레이드 시 필독)

### 환경 / 런타임
- **479**: **JDK 25 요구** (빌드/실행), Docker JDK 25.0.1로 업데이트
- **480**: 동적 필터링 관련 설정 다수 제거 (`enable-large-dynamic-filters`, `dynamic-filtering.small*` 등)

### 커넥터 제거
- **480**: **Vertica 커넥터 완전 제거**

### 오브젝트 스토리지 (가장 큰 운영 영향)
- **479**: GCS `SERVICE_ACCOUNT` 인증에서 미인증 액세스 제거 (Delta/Hive/Hudi/Iceberg)
- **480**: 다수의 레거시 Parquet writer 설정 제거 → `parquet.writer.*` 신규 속성 사용
- **481**: **Azure Storage, GCS, IBM COS, S3 및 S3 호환 시스템의 레거시 오브젝트 스토리지 지원 완전 제거** → native 파일시스템으로 마이그레이션 필수 (`fs.hadoop.enabled`는 이제 HDFS 전용)

### JDBC 커넥터 공통
- **479**: 모든 JDBC 커넥터(ClickHouse, MySQL, PostgreSQL, Oracle 등 14개)에서 `join-pushdown.with-expressions` → `deprecated.join-pushdown.with-expressions`로 이름 변경

### 공간(Geospatial) 라이브러리 — 481의 큰 변화
- 라이브러리를 **Esri → JTS로 교체**
- OGC 표준에 맞지 않는 WKT 입력 거부
- `ST_Union()`이 빈 입력에 대해 `NULL` 대신 빈 geometry collection 반환

### 기타
- **480**: `iceberg.extended-statistics.enabled` 제거, MySQL/SingleStore `BIT(n)` (n > 1) 잘못된 지원 제거
- **481**: SPI에서 `Type` 인터페이스의 `getObject`, `appendTo` 메서드 제거

---

## 4. 보안 / 인증

- **479**: 노드 디스커버리가 `ANNOUNCE`일 때 내부 클러스터 TLS 인증서 자동 생성
- **481**:
  - 외부 인증 토큰 디스크 영속화 (`~/.trino/`) — JDBC 클라이언트 프로세스 간 재사용
  - JDBC OAuth2 액세스 토큰 만료 시 **투명한 자동 갱신** (서버 `refresh-tokens=true` 필요)

---

## 5. 성능 개선

### 쿼리 실행 / 옵티마이저
- **479**: 신형 CPU(Graviton 3, Skylake, Icelake, Zen 4+) 데이터 교환 실험적 가속화, `array_sort()` / `repeat()` / 가변폭 데이터 교환 성능 개선
- **480**: Graviton 4 등 더 신형 CPU 데이터 교환 가속화, 윈도우 함수 + 스필링 시 OOM 감소, exchange manager 사용 시 비-task-retry 쿼리 성능 개선
- **481**: 선택성 높은 단순 `AND` / `OR` 술어 쿼리 성능, 통계 미상 컬럼의 조인 순서 메모리 절감, `json_value` / `json_table` 지연 평가 성능 개선

### 커넥터별
- **480 / 481**: Parquet Bloom filter 효율 개선 (고카디널리티 컬럼), S3 쓰기 메모리 사용량 감소 (Delta/Hive/Iceberg/Lakehouse)
- **Iceberg**: 플래닝 시간 단축 (대형 테이블, delete 파일 포함 테이블), fresh MV 쿼리 성능, `optimize_manifests`의 파티션 클러스터링 (480)
- **481**: Delta checksum 파일에서 메타데이터 직접 로드로 플래닝 시간 단축, PostgreSQL의 `COALESCE` 푸시다운, Hive Glue 카탈로그 날짜 파티션 쿼리 성능

---

## 6. Iceberg 커넥터 (3개 릴리즈 누적, 가장 활발한 영역)

### 479
- REST catalog `token-exchange-enabled` 설정
- `expire_snapshots`에 `retain_last` / `clean_expired_metadata` 옵션
- MV grace period 내 base 테이블 누락/손상 무시

### 480
- **Iceberg v3 본격 지원** (생성/쓰기/삭제, optimize/expire/remove orphan, **row lineage**, 컬럼 default 값)
- **BigLake metastore** (REST catalog) 지원
- `delete_after_commit_enabled`, `max_previous_versions` 테이블 속성
- `map` / `array` 중첩 타입의 `ALTER ... SET DATA TYPE`
- `$manifests` / `$all_manifests`에 `content` 컬럼
- 임시 GCS 자격증명 (REST catalog)

### 481
- **`variant` 타입 실험적 지원** (Iceberg v3)
- `timestamp(9)` 및 `timestamp(9) with time zone` 지원
- REST catalog 강화: Azure vended credentials, **refreshable vended credentials** (S3/GCS/Azure), HTTP 헤더 지정
- `add_files` / `add_files_from_table` / `optimize` 프로시저 실행 메트릭
- `$files` 시스템 테이블 컬럼 확장 (`added_snapshot_id` 등)

---

## 7. Delta Lake 커넥터

### 479
- GCS `APPLICATION_DEFAULT` 인증 타입
- Databricks 17.3 테이블 쓰기 실패 수정
- 클론 테이블 읽기 실패 수정
- `s3.exclusive-create` → `delta.s3.transaction-log-conditional-writes.enabled`

### 480
- live files 메타데이터 캐시 제거 (관련 설정 모두 defunct)
- Delta v3 관련 정비

### 481
- 🚨 **중요 버그 수정**: Spark가 쓴 Parquet column index 파일에서 `DELETE`가 잘못된 행을 삭제하던 버그 수정
- Delta checksum 파일에서 메타데이터 직접 로드 (플래닝 단축)

---

## 8. Hive 커넥터

- **479**: GCS `APPLICATION_DEFAULT` 인증, INSERT OVERWRITE 통계 정확도 개선
- **480**: Parquet 나노초 정밀도 타임스탬프 읽기, Hive metastore v4의 INSERT/ANALYZE 수정
- **481**:
  - **Esri GeoJSON 형식 지원**
  - Glue 카탈로그 날짜 파티션 쿼리 성능
  - Hive metastore 3.1 테이블 생성 실패 수정

---

## 9. 기타 커넥터 변화

| 커넥터 | 479 | 480 | 481 |
|---|---|---|---|
| **PostgreSQL** | `IS NOT DISTINCT FROM` 버그 수정 | 모든 `NUMERIC` / `DECIMAL` 읽기 지원 | `COALESCE` 푸시다운 |
| **MySQL** | `IS NOT DISTINCT FROM` 버그 수정 | `DECIMAL(p>38)` 지원, `BIT(n>1)` 잘못된 지원 제거 ⚠️ | JSON 큰 숫자 버그 수정 |
| **Oracle** | — | `NUMBER` 컬럼 전체 지원, 커넥션 풀 wait timeout 설정 | — |
| **ClickHouse** | — | CTAS 실패 후 재생성 버그 수정 | 모든 `DECIMAL` 읽기 지원 |
| **MariaDB** | — | `DECIMAL(p>38)` 지원 | — |
| **SQL Server** | 테이블 목록 조회 실패 수정 | CTAS 실패 후 재생성 버그 수정 | **`json` 타입 지원**, permission denied 수정 |
| **Redshift** | `character varying` 읽기 수정 | — | — |
| **BigQuery** | `query()` TF 재사용 실패 수정 | — | — |
| **Loki** | 초기화 실패 수정 | — | — |
| **MongoDB / Pinot / SingleStore** | — | — | JSON 큰 숫자 (>16자리) 버그 수정 |

---

## 10. 주요 버그 수정 (전역적 영향)

### 479
- `IS NOT DISTINCT FROM` 잘못된 결과 수정 (Delta/Iceberg/MySQL/PostgreSQL)
- Parquet huge value 컬럼 워커 크래시 방지 (Delta/Hive/Hudi/Iceberg)
- S3 쓰기 중 네트워크 실패의 `FileAlreadyExistsException` 수정

### 480
- `localtimestamp()` 정밀도 3/7/8 결과 오류
- `date_add()` Integer.MAX_VALUE 초과 처리
- `json` / `time` / `boolean` / `interval` → `varchar(n)` 캐스팅 시 결과 검증
- Azure exchange manager 실패/지연
- GCS 파일 경로에 `#` 포함 시 실패

### 481
- **소수부 16자리 초과 숫자의 잘못된 결과** 수정 (`json_parse`, MongoDB/MySQL/Pinot/PostgreSQL/SingleStore JSON 컬럼)
- 동적 카탈로그 drop과 system 쿼리의 race condition
- 대문자 컬럼명 테이블 프로시저 실행 실패
- 비결정적 함수 포함 MV의 freshness 체크

---

## 11. Web UI / JDBC / CLI / SPI

### 479
- Web UI 프리뷰의 긴 쿼리 및 카탈로그 속성 렌더링
- JDBC `extraHeaders`, CLI `--extra-header` 옵션

### 480
- Web UI 프리뷰 헤더에 클러스터 상태 정보
- 쿼리 상세 페이지 스테이지를 숫자 순으로 정렬
- JDBC `ResultSetMetaData.getColumnClassName` 정정 (map / row / time tz / timestamp tz / varbinary / null)

### 481
- JDBC / CLI에 **`variant` 타입** 지원
- JDBC OAuth2 자동 갱신
- SPI에 `variant` 타입, `tableBranch` 파라미터, `COALESCE` 푸시다운 지원

---

## 🎯 통합 업그레이드 체크리스트

위 세 릴리즈를 한꺼번에 적용한다면 다음 항목을 확인하세요.

- [ ] **JDK 25 환경** 준비 (479)
- [ ] **Vertica 커넥터 사용 여부** 확인 (480에서 제거)
- [ ] **오브젝트 스토리지 설정** native 파일시스템으로 마이그레이션 (481, 레거시 완전 제거)
- [ ] **모든 JDBC 커넥터 설정 파일**의 `join-pushdown.with-expressions` 이름 변경 (479)
- [ ] **GCS `SERVICE_ACCOUNT`** 사용 시 미인증 액세스 의존 여부 확인 (479)
- [ ] **Parquet writer 설정** 신규 속성으로 변경 (480)
- [ ] **공간 함수 사용 코드**의 WKT 입력 OGC 표준 준수 및 `ST_Union()` NULL 처리 동작 검증 (481)
- [ ] **Delta Lake on Spark + `DELETE`** 사용 환경이면 481 버그 수정 반드시 반영 권장
- [ ] **MySQL / SingleStore `BIT(n)` (n>1)** 사용 코드 점검 (480)
- [ ] **동적 필터링 관련 deprecated 설정** 제거 (480)

기능 측면에서는 **`number` / `variant` 타입 도입**, **Iceberg v3 본격 지원**, **공간 라이브러리 JTS 전환**이 세 릴리즈의 가장 큰 흐름입니다.

---

## 📚 원문 링크

- [Release 479 (14 Dec 2025)](https://trino.io/docs/current/release/release-479.html)
- [Release 480 (24 Mar 2026)](https://trino.io/docs/current/release/release-480.html)
- [Release 481 (11 May 2026)](https://trino.io/docs/current/release/release-481.html)
