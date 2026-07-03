# Trino Oracle 커넥터 UCP-45280 오류 분석

> 작성일: 2026-07-03
> 환경: Trino on Kubernetes, Oracle 카탈로그 properties를 ConfigMap으로 pod에 마운트

## 1. 발생한 오류

```
suppressed: java.sql.SQLException: UCP-0: Unable to start the Universal Connection Pool
Caused by: oracle.ucp.UniversalConnectionPoolException: UCP-45280: The connection Request Info is null
```

## 2. 발생 상황

- Trino를 K8s에서 운영, Oracle 카탈로그 properties는 ConfigMap으로 pod에 마운트
- 일부 워커 shutdown, `no nodes available` 오류가 동시 발생
- 신규 워커 10대 재기동 후 위 UCP 오류 발생

## 3. 오류 발생 코드

### 예외 발생 지점

`plugin/trino-oracle/src/main/java/io/trino/plugin/oracle/OraclePoolConnectionFactory.java:87`

```java
@Override
public Connection openConnection(ConnectorSession session)
        throws SQLException
{
    Connection connection = dataSource.getConnection();  // ← 여기서 UCP 풀 지연 기동 시 실패
    ...
}
```

`dataSource.getConnection()` 호출 시 UCP가 풀을 처음 기동(lazy start)하는데, 이때
`UCP-0: Unable to start the Universal Connection Pool` → `UCP-45280: The connection Request Info is null`이 발생.

### 근본 원인 코드

`OraclePoolConnectionFactory.java:62-79`

```java
credentialProvider.getConnectionUser(Optional.empty())
        .ifPresent(user -> { ... dataSource.setUser(user); ... });
credentialProvider.getConnectionPassword(Optional.empty())
        .ifPresent(password -> { ... dataSource.setPassword(password); ... });
```

- user/password가 `ifPresent`로만 설정됨 — `CredentialProvider`가 빈 값을 반환하면
  `setUser()`/`setPassword()`가 **아예 호출되지 않은 채** 풀 DataSource가 생성됨 (예외 없이 조용히 진행)
- 이후 첫 `getConnection()`에서 UCP가 초기 커넥션을 만들 때 인증 정보(connection request info)가
  null이라 `UCP-45280` 발생

### 관련 설정 코드

- `OracleClientModule.java:63-82` — `@Provides @Singleton`이라 **pod 기동 시 카탈로그 로드 시점에
  딱 한 번** 팩토리가 생성됨. 자격증명은 이 시점에 스냅샷됨
- `OracleConfig.java:37` — `connectionPoolEnabled = true`가 **기본값**이므로 별도 설정이 없으면
  자동으로 풀 팩토리가 선택됨
- `Optional.empty()`(세션 없음)로 자격증명을 조회하므로 **세션별 자격증명(pass-through)은 풀에
  절대 전달되지 않음** (`ExtraCredentialProvider.java:45-66` 참고)
- `suppressed:`로 보이는 것은 base-jdbc의 `RetryingConnectionFactory`가 재시도하면서 실패한
  시도의 예외를 suppressed로 붙이기 때문 (`OracleClientModule.java`의 `OracleRetryStrategy` 참고)

## 4. 원인 분석 — 왜 신규 워커에서만 발생했나

핵심 메커니즘: **자격증명은 워커 기동 시점에 1회 스냅샷되고, UCP 풀은 첫 쿼리 때 지연 기동됨.**

- 기존 워커: 예전에 정상 자격증명으로 팩토리 생성, 풀이 이미 기동됨 → 이후 ConfigMap이
  어떻게 바뀌든 영향 없음
- 신규 워커: **기동 시점에 읽은 카탈로그 설정에 user/password가 없었음** → 조용히 null 풀 생성
  → 첫 쿼리에서 UCP-45280

### 신규 워커에서 자격증명이 비어 있었을 유력 시나리오

| 시나리오 | 설명 |
|---|---|
| ① ConfigMap이 변경된 상태였음 | 장애 대응 중 ConfigMap 수정(오타, 키 이름 변경, `connection-user`/`connection-password` 제거) → 기존 pod는 멀쩡, **신규 pod만** 깨진 설정을 읽음 |
| ② credential pass-through 구성 | `user-credential-name`/`password-credential-name`(extra credentials)만 쓰고 정적 `connection-user`가 없으면 풀 팩토리는 세션 없이 조회하므로 **항상 null** → 풀 활성화와 근본적으로 호환 불가 |
| ③ FILE/KEYSTORE credential 파일 마운트 지연/누락 | `credential-provider.type=FILE` 등으로 Secret을 별도 마운트하는 경우, 신규 pod 기동 시 해당 파일이 없거나 비어 있었을 가능성 |
| ④ subPath 마운트 | ConfigMap을 `subPath`로 마운트하면 갱신이 전파되지 않고, 기동 타이밍에 따라 불완전한 내용을 읽을 수 있음 |

> 참고: 워커 10대가 동시에 붙어 Oracle 리스너가 과부하였다면 ORA-12516/12520 같은 **ORA-** 오류가
> 발생함. `UCP-45280`은 부하 문제가 아니라 **자격증명(request info)이 null**이라는 뜻이므로 설정 쪽이 확실.

## 5. K8s에서 ConfigMap이 pod에 마운트되지 않는 상황

크게 두 부류:

- **A. 마운트 실패 → pod가 아예 못 뜨는 경우** (`ContainerCreating`에서 멈춤)
- **B. pod는 정상 기동했지만 내용이 없거나/비었거나/오래된 경우** ← 이번 장애와 부합

### A. 마운트 자체가 실패하는 경우 (pod 기동 불가)

`kubectl describe pod`에 `FailedMount` 이벤트가 남음.

| 원인 | 증상 |
|---|---|
| ConfigMap 미존재 (이름 오타, 네임스페이스 불일치, 삭제됨) | `MountVolume.SetUp failed ... configmap "xxx" not found` |
| Helm/GitOps 배포 순서 문제 — pod가 CM보다 먼저 생성 | 위와 동일, CM 생성 후 자동 복구 |
| hash suffix 패턴에서 옛 CM 정리 후 옛 ReplicaSet pod가 재스케줄 | 재기동된 pod만 not found |
| kubelet 장애/API 서버 통신 불가 | 마운트 타임아웃, 노드 단위 발생 |

**중요**: 기본 설정(`optional: false`)에서 CM이 없으면 컨테이너가 시작되지 않음.
"Trino는 떴는데 설정만 없는" 상황은 이 부류가 아님.

### B. pod는 떴는데 내용이 없거나 잘못된 경우

#### ① `optional: true` 마운트

```yaml
volumes:
  - name: catalog
    configMap:
      name: oracle-catalog
      optional: true    # ← CM이 없어도 pod가 그냥 뜸 (빈 디렉토리!)
```

CM이 없거나 생성 전이면 **빈 디렉토리인 채로 컨테이너가 정상 기동**.
워커 대량 재기동 + GitOps 재동기화가 겹치면 일부 pod만 빈 설정으로 뜨는 전형적 패턴.

#### ② `items`로 특정 key만 선택한 경우

```yaml
configMap:
  name: catalogs
  items:
    - key: hive.properties
      path: hive.properties
    # oracle.properties를 CM에 추가해도 여기 없으면 파일이 안 생김
```

CM에 key가 있어도 volume spec의 `items`에 없으면 파일이 생성되지 않음.

#### ③ `subPath` 마운트 — 갱신 미전파

```yaml
volumeMounts:
  - name: catalog
    mountPath: /etc/trino/catalog/oracle.properties
    subPath: oracle.properties
```

`subPath`로 마운트된 파일은 **ConfigMap을 수정해도 절대 갱신되지 않음**.
기존 pod는 옛 내용, 신규 pod는 새 내용 → pod 세대 간 불일치 발생.

#### ④ CM 수정과 pod 기동의 race + kubelet 캐시

- 일반 볼륨 마운트는 kubelet이 주기적으로 동기화(전파 지연 수초~약 1분),
  갱신은 `..data` 심볼릭 링크의 원자적 교체 방식이라 "반쪽 파일"은 드묾
- 하지만 **pod 기동 시점에 CM이 수정 중이었다면** 신규 pod들은 수정된(깨진) 버전을 스냅샷으로 받음
- kubelet의 ConfigMap 캐시(TTL 기반 전략) 때문에 노드별로 다른 버전을 볼 수도 있음

#### ⑤ `immutable: true` ConfigMap

immutable CM은 수정 불가 → 이름을 바꿔 재배포하는데 Deployment의 volume 참조 갱신이 누락되면
신규 pod가 옛(또는 존재하지 않는) CM을 참조.

#### ⑥ 환경변수 주입(`envFrom`/`valueFrom`)

pod 생성 시점에 1회만 평가. CM이 없으면 `CreateContainerConfigError`로 명확히 실패하지만,
key가 없는 경우(`optional`)엔 빈 값으로 뜰 수 있음.

## 6. 확인(진단) 방법

```bash
# 1. volume spec 확인 — optional: true, subPath, items 사용 여부
kubectl get pod <worker> -o yaml | grep -B3 -A8 "configMap\|subPath"

# 2. 문제 pod에 실제 마운트된 내용 확인 (pod가 아직 살아있다면)
kubectl exec <worker> -- ls -la /etc/trino/catalog/
kubectl exec <worker> -- cat /etc/trino/catalog/oracle.properties
# → connection-user / connection-password 가 실제로 있는지

# 3. CM 변경 시각과 워커 기동 시각 비교
kubectl get cm <catalog-cm> -o jsonpath='{.metadata.resourceVersion}{"\n"}{.metadata.managedFields[*].time}'
kubectl get pod <worker> -o jsonpath='{.status.startTime}'
# audit log나 GitOps 커밋 이력으로 해당 시각 부근 수정 여부 확인

# 4. 당시 이벤트 로그 (시간이 지나면 소실될 수 있음)
kubectl get events --field-selector reason=FailedMount -A
```

## 7. 조치 및 재발 방지

### 즉시 조치

1. 카탈로그 properties에 정적 `connection-user`/`connection-password`가 온전히 있는지 확인 후
   **해당 워커 pod 재시작** — 팩토리가 기동 시점 스냅샷이므로 ConfigMap만 고쳐서는 복구되지 않음
2. **pass-through 구성이라면**: `oracle.connection-pool.enabled=false` 필수
   (풀과 세션별 자격증명은 함께 사용 불가)

```properties
# 방법 1: 세션별 자격증명(pass-through 등)을 쓴다면 풀 비활성화
oracle.connection-pool.enabled=false

# 방법 2: 풀을 유지하려면 정적 자격증명 설정
connection-user=<user>
connection-password=<password>
```

### 재발 방지

- **fail-fast**: `optional: true` 제거 — 설정이 없으면 pod가 뜨지 않는 것이
  조용히 빈 설정으로 뜨는 것보다 안전
- **initContainer로 검증**: Trino 기동 전 `oracle.properties`에 `connection-user` 존재 여부를
  grep으로 확인, 없으면 실패시키기
- **CM 불변화 + hash suffix**: CM을 immutable로 만들고 내용 해시를 이름에 붙여 Deployment와
  함께 롤아웃(Helm checksum annotation 패턴) — pod 세대와 설정 버전이 항상 1:1
- **subPath 지양**: 디렉토리 단위 마운트로 전환
- **자격증명은 Secret으로 분리**: 접근 통제 + 누락 시 실패 지점이 명확해짐

> 유의: Trino의 `OraclePoolConnectionFactory`는 자격증명이 없어도 **조용히** 풀을 생성하므로,
> 빈/불완전한 설정으로 pod가 뜨면 첫 쿼리 때까지 문제가 드러나지 않음.
> 따라서 K8s 쪽 fail-fast 장치(initContainer 검증 등)가 특히 효과적.
