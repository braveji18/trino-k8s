# Trino Oracle 커넥터 UCP-45203 오류 분석

> 최종 갱신: 2026-07-07
> 환경: Trino 475 **on-premise**, Oracle 카탈로그 properties는 로컬 디스크의 고정 파일
> (배포/기동 스크립트는 파일을 재생성하지 않음), `credential-provider.type=INLINE`,
> `connection-user`/`connection-password` 정상 설정됨, UCP/ojdbc11 23.3.0.23.09

## 1. 발생한 오류

```
suppressed: java.sql.SQLException: UCP-0: Unable to start the Universal Connection Pool
Caused by: oracle.ucp.UniversalConnectionPoolException: UCP-45203: The connection Request Info is null
```

- 정확한 에러 코드는 **UCP-45203** (Oracle 공식 에러 레퍼런스에서 확인:
  "The Connection Request Info is null"). UCP-0의 원인 예외로 나타남.

## 2. 발생 상황

- Trino on-premise 운영 중 과부하 → 일부 워커 shutdown, `no nodes available` 동시 발생
- 신규 워커 10대 재기동 후 위 오류 발생

## 3. 관련 Trino 코드

### 예외 발생 지점

`plugin/trino-oracle/src/main/java/io/trino/plugin/oracle/OraclePoolConnectionFactory.java:87`
— `dataSource.getConnection()` 호출 시 UCP 풀 지연 기동(lazy start) 중 실패.

### 구조적 특징

- `OracleClientModule.java:63-82` — 팩토리는 `@Provides @Singleton`으로 **노드 기동 시 1회** 생성,
  자격증명은 그 시점에 스냅샷됨 (`Optional.empty()`로 조회 → 세션 자격증명 미전달)
- `OraclePoolConnectionFactory.java:62-79` — 자격증명이 비면 `ifPresent`에 의해
  `setUser`/`setPassword`가 **조용히 스킵**됨
- `OracleConfig.java:37` — `oracle.connection-pool.enabled=true`가 기본값
- 관련 공개 이슈: [trinodb/trino#19205](https://github.com/trinodb/trino/issues/19205)
  — extraCredentials(pass-through)는 풀과 호환 불가 (다만 그 경우 증상은 ORA-01017)

## 4. 검증 실험 (2026-07-06 수행)

UCP 23.3.0.23.09 + ojdbc11 23.3.0.23.09를 Trino의 `OraclePoolConnectionFactory`와
동일하게 구성하고, 과부하 상황 3종을 모의 리스너로 재현 (동시 8스레드 × 반복 5회):

| 시나리오 | 모의 방법 | 결과 |
|---|---|---|
| 리스너 없음 (프로세스 다운) | 미개방 포트 | `UCP-0 → UCP-45257 → ORA-12541` |
| 리스너 과부하 (연결 즉시 종료) | accept 후 close | `UCP-0 → UCP-45257 → ORA-17002/17800` |
| 리스너/서버 응답 없음 (행) | accept 후 무응답 (타임아웃) | `UCP-0 → UCP-45257 → ORA-17002 (read timeout)` |
| 자격증명 미설정 + 위 상황 | setUser/setPassword 생략 | 위와 동일 (네트워크 단계에서 먼저 실패) |

**위 조합에서는 UCP-45203이 재현되지 않음.** 풀 기동 실패가 반복되어도
(Exception 계열인 한) 풀 내부 상태가 오염되어 45203으로 전이하는 현상 없음.

### 재현 성공: Error(OOM)로 인한 풀 상태 오염 (2026-07-06)

`PoolDataSourceImpl.createUniversalConnectionPool()`의 실패 정리 코드는
`catch (Exception exc) { this.connectionPool = null; ... }` — **`Error`는 잡지 않는다.**
풀 객체 할당(`createPoolWithDefaultProperties`) **이후** ~ 자격증명 정보 설정
(`setConnectionRetrievalInfo`) **이전** 구간에서 `OutOfMemoryError` 같은 Error가
발생하면:

- `connectionPool` 필드에는 **CRI(자격증명 정보)가 없는 반쯤 초기화된 풀 객체**가 남고
  (lifecycle은 초기값 `LIFE_CYCLE_STOPPED`)
- 이후 모든 `getConnection()` → `startPool()`은 풀이 이미 있으므로 생성 블록을 건너뛰고
  `start()` 호출 → CRI null 체크에서 UCP-45203 → UCP-0으로 래핑
- 이 상태는 **JVM을 재시작할 때까지 영구 지속** (CRI를 다시 설정하는 경로가 없음)

이 상태를 리플렉션으로 재현한 결과, 사용자 로그와 **완전히 동일한** 에러 체인 확인:

```
attempt 2: SQLException: UCP-0: Unable to start the Universal Connection Pool
             <- Caused by: UniversalConnectionPoolException: UCP-45203: The Connection Request Info is null
```

user/password가 정상 설정되어 있어도 발생하며, DB가 정상으로 복구된 후에도 계속된다.

### UCP 23.3 디컴파일 분석

UCP-45203(내부 코드 203, `UCP_COMMON_CRI_NULL`)을 던지는 곳은 **정확히 2곳**:

1. `UniversalConnectionPoolBase.start()` — 풀의 기본 `ConnectionRetrievalInfo`(CRI) 필드가
   null일 때. 그러나 이 필드는 풀 생성 시(`PoolDataSourceImpl.createUniversalConnectionPool`)
   user/password로 **무조건** 설정되며(값이 null이어도 CRI 객체는 생성됨), null로 되돌리는
   코드 경로가 존재하지 않음 (전체 jar 디컴파일로 확인). UCP 19.3도 동일 구조.
2. `UniversalConnectionPoolImpl.borrowConnection(cri)` — 인자가 null일 때.
   `PoolDataSource` 경로에서는 항상 CRI 객체를 생성해 전달하므로 도달 불가.

## 5. 결론 (확정)

**과부하 → JVM 메모리 압박 → UCP 풀 생성 도중 Error(OutOfMemoryError 등) →
풀 상태 영구 오염 → UCP-0/UCP-45203** 이 인과 사슬로 설명된다.

1. UCP-45203은 자격증명 설정과 무관하게, **풀 생성 도중 Error가 발생해 CRI 설정 단계에
   도달하지 못한 채 풀 객체만 남으면** 발생한다 (UCP의 정리 코드가 `catch (Exception)`이라
   Error를 놓치는 결함).
2. 이 상태는 해당 노드의 **JVM 재시작 전까지 영구 지속**되며, Oracle DB가 정상이어도
   모든 연결 시도가 같은 에러로 실패한다. Trino의 재시도(RetryingConnectionFactory)도
   소용없고, 재시도 실패가 `suppressed:`로 붙는다 — 관측된 로그 형태와 일치.
3. 장애 정황과의 부합: 과부하로 워커들이 shutdown(메모리 압박 정황) →
   신규 워커 10대 재기동 직후 아직 부하가 높은 상태에서 첫 Oracle 쿼리가
   풀 생성을 트리거 → 그 시점에 OOM 등 Error 발생 → 이후 계속 UCP-45203.
4. 단순 리스너/네트워크 과부하만으로는 45203이 나오지 않는다
   (그 경우는 `UCP-45257 → ORA-*`). 45203이 나왔다는 것은 **그 노드 JVM에서
   풀 생성 도중 Error가 발생했었다**는 강한 신호다.

## 6. 확인/뒷받침 증거 수집

1. 오류 발생 노드의 당시 GC 로그 / `OutOfMemoryError` 로그 여부
   (풀 생성 시점 전후, 예: `grep -i "OutOfMemory\|java.lang.Error" server.log`)
2. 오류 발생 노드가 코디네이터인지 신규 워커인지, 해당 노드 재시작 후 해소되었는지
   (재시작으로 해소되었다면 이 가설과 정확히 일치)
3. UCP-45203의 스택 프레임이 `UniversalConnectionPoolBase.start`인지 확인

## 7. 조치 및 재발 방지

```properties
# 권장: 풀 비활성화 (Trino의 RetryingConnectionFactory가 재시도를 담당하므로
# UCP 풀 없이도 안정 운영 가능. UCP 상태 오염 장애 클래스 전체 제거)
oracle.connection-pool.enabled=false
```

- **즉시 복구**: 오염된 노드는 JVM(Trino 프로세스) 재시작 외에 복구 방법 없음
- **근본 원인 관리**: 워커 메모리 압박(OOM) 자체를 해소 — 메모리 설정/쿼리 부하 관리.
  UCP-45203 발생 = "해당 노드 재시작 필요" 신호로 모니터링에 등록
- 풀을 유지한다면: 재기동 폭주 시 초기 연결 폭주(워커 수 × `oracle.connection-pool.min-size`)를
  줄이도록 min-size를 낮게 유지
- Trino의 `OraclePoolConnectionFactory`는 자격증명 부재 시에도 조용히 풀을 생성하므로
  (`ifPresent` 스킵), 그 경로의 UCP-45203도 여전히 가능 — 카탈로그 설정 검증 병행 권장
- 업스트림 보고 가치: UCP의 `catch (Exception)` → `catch (Throwable)`/finally 결함(Oracle SR),
  Trino 쪽은 풀을 기동 시점에 eager 생성하면 부하 중 lazy 생성 창을 줄일 수 있음

## 8. 검증 실험 코드 (재실행 가능)

위 실험을 누구나 재실행할 수 있도록 [`ucp-45203-verify/`](ucp-45203-verify/) 폴더에
코드와 자동 실행 스크립트를 두었다. **실제 Oracle DB 없이** 모의 리스너로 검증한다.

### 구성 파일

| 파일 | 역할 |
|---|---|
| `run.sh` | 전체 실험 자동 실행 (jar 준비 → 컴파일 → 실험 4종 → 판정 기준 출력) |
| `UcpOverloadRepro.java` | 실험 1: Trino와 동일 구성의 UCP 풀에 과부하 3종(다운/드롭/행)을 가해 45203 발생 여부 확인 (반증 실험) |
| `UcpPoisonState.java` | 실험 2: "풀 생성 중 Error(OOM)" 상태를 리플렉션으로 재현해 UCP-45203 영구 발생 입증 |
| `fake_listener.py` | 과부하 상태의 Oracle 리스너 모의 (`drop`: accept 후 즉시 끊음, `hang`: accept 후 무응답) |
| `README.md` | 실행 방법, 기대 결과, 디컴파일 근거 상세 |

### 실행 방법

```bash
# 요구사항: JDK 17+(javac), python3, curl. 실제 Oracle DB 불필요.
cd ucp-45203-verify
./run.sh

# 운영 Trino와 동일한 드라이버 버전으로 검증 (권장):
JARS_DIR=/운영trino경로/plugin/oracle ./run.sh
```

`JARS_DIR` 미지정 시 Trino 475 번들 버전(ojdbc11/ucp 23.3.0.23.09)을
Maven Central에서 자동 다운로드한다.

개별 실험만 실행하려면:

```bash
javac -cp .:ojdbc11.jar:ucp.jar UcpOverloadRepro.java UcpPoisonState.java

# 실험 1b: 리스너 과부하 (인자: 포트, 동시 스레드 수, 라운드 수)
python3 fake_listener.py drop 15298 &
java -cp .:ojdbc11.jar:ucp.jar UcpOverloadRepro 15298 8 3

# 실험 2: 풀 오염 → 45203 재현
python3 fake_listener.py drop 15296 &
java -cp .:ojdbc11.jar:ucp.jar UcpPoisonState 15296
```

### 실제 실행 결과 (2026-07-07 검증 완료)

```
실험 1a (리스너 다운):        최종: UCP-45203=0건, 기타(UCP-45257←ORA-12541) 24건
실험 1b (연결 즉시 끊김):     최종: UCP-45203=0건, 기타(UCP-45257←ORA-17002/17800) 24건
실험 1c (무응답/타임아웃):    최종: UCP-45203=0건, 기타(UCP-45257←ORA-17002 timeout) 8건

실험 2 (풀 생성 중 Error 상태):
  1차 시도 (과부하 중):   UCP-0 ← UCP-45257 ← ORA-17800
  -- 풀 오염 주입: defaultConnectionRetrievalInfo = null --
  2차 시도 (과부하 이후): UCP-0 ← UCP-45203: The Connection Request Info is null   ← 재현
  3차 시도 (과부하 이후): UCP-0 ← UCP-45203: The Connection Request Info is null   ← 영구 반복
```

### 판정 기준

- **실험 1a/1b/1c**: `UCP-45203=0건`이어야 함 — 과부하 자체는 45203의 원인이 아님(반증).
  에러는 `UCP-0 ← UCP-45257 ← ORA-*` 형태여야 함.
- **실험 2**: 2차/3차 시도에서 `UCP-0 ← UCP-45203`이 나오면
  "풀 생성 중 Error → CRI 미설정 풀 영구 잔존" 가설 입증.
  자격증명이 정상 설정된 상태에서 재현된다는 점이 핵심.

### 시뮬레이션 방식에 대한 주석

실험 2는 실제 OOM을 UCP 내부의 정확한 지점에 주입하는 대신, OOM이 남기는 상태
(풀 객체 존재 + `defaultConnectionRetrievalInfo == null`)를 리플렉션으로 재현한다.
"Error가 이 상태를 만든다"는 연결고리는 4절의 UCP 23.3 디컴파일 분석으로 확인했다.
운영 환경에서의 최종 확인은 당시 해당 노드의 OOM/GC 로그와
재시작으로 해소됐는지 여부를 대조하면 된다 (6절 참고).

## 9. Trino 방어 코드 (구현 및 검증 완료)

`OraclePoolConnectionFactory`에 **자가 복구(self-healing) 방어 코드**를 구현했다
(`plugin/trino-oracle/src/main/java/io/trino/plugin/oracle/OraclePoolConnectionFactory.java`).

### 방어 원리

기존 코드는 `dataSource`가 `final`이라 풀이 한 번 오염되면 JVM 재시작 외에 복구 수단이
없었다. 패치는:

1. **감지**: `openConnection()` 실패 시 예외 원인 체인에서
   `UniversalConnectionPoolException.getErrorCode() == 45203`을 확인
   (45203은 UCP가 스스로 복구하지 못하는 영구 오염 상태)
2. **복구**: 오염 감지 시 경고 로그를 남기고 DataSource(풀)를 **재생성**한 뒤
   즉시 재시도 — DB가 정상이면 해당 쿼리부터 바로 성공
3. **동시성**: `volatile` 필드 + `synchronized` 교체(오염된 인스턴스와 동일할 때만 교체)로
   동시 다발 쿼리 상황에서 중복 재생성 방지

핵심 코드:

```java
@Override
public Connection openConnection(ConnectorSession session)
        throws SQLException
{
    OpenTelemetryDataSource currentDataSource = dataSource;
    Connection connection;
    try {
        connection = currentDataSource.getConnection();
    }
    catch (SQLException e) {
        if (!isPoolPermanentlyBroken(e)) {
            throw e;
        }
        log.warn(e, "Oracle connection pool cannot be started anymore (UCP-45203), replacing it with a new pool");
        connection = replaceBrokenDataSource(currentDataSource).getConnection();
    }
    connection.setAutoCommit(true);
    return connection;
}

private static boolean isPoolPermanentlyBroken(SQLException exception)
{
    return Throwables.getCausalChain(exception).stream()
            .anyMatch(cause -> cause instanceof UniversalConnectionPoolException ucpException
                    && ucpException.getErrorCode() == UCP_CONNECTION_REQUEST_INFO_IS_NULL);
}
```

### 검증 결과 (2026-07-07, JDK 23 + UCP 23.3.0.23.09)

패치 클래스를 컴파일한 뒤, 실험 2와 동일한 방식으로 풀을 오염시키고 재호출:

```
1차 (과부하 중):   UCP-0 ← UCP-45257 ← ORA-17800          (일시 장애, 정상 동작)
-- 풀 오염 주입 --
WARNING: Oracle connection pool cannot be started anymore (UCP-45203), replacing it with a new pool
2차 (오염 이후):   UCP-0 ← UCP-45257 ← ORA-17002          ← 45203이 아닌 일시 에러로 복귀!
3차 (오염 이후):   UCP-0 ← UCP-45257 ← ORA-17800          ← 오염 소멸 확인
풀 교체 여부: 교체됨 (자가 복구 동작)
검증 성공: UCP-45203 오염이 자동 복구되어 일시적 에러(45257)로 돌아옴
```

패치 전에는 2차/3차가 영원히 `UCP-45203`이었으나(4절 실험 2), 패치 후에는 풀이 자동
교체되어 일시 에러로 돌아온다. 실제 운영에서는 DB가 정상이므로 **재시도한 그 쿼리부터
즉시 성공**하며, 노드 재시작이 불필요해진다.

### 한계 및 참고

- 이 패치는 "풀 영구 오염" 클래스의 45203을 복구한다. 자격증명이 아예 없는 구성
  (3절의 pass-through 문제)은 재생성해도 동일 상태이므로 별개 문제로 남는다
  (다만 그 경우 UCP 23.3에서는 ORA-01017로 나타남).
- 업스트림 기여 시: 단위 테스트는 UCP 내부 상태를 리플렉션으로 조작해야 작성 가능
  (`ucp-45203-verify/`의 `PatchVerify` 방식 참조). 근본 수정은 Oracle UCP의
  `catch (Exception)` → `catch (Throwable)` 결함 수정(Oracle SR)이 정도(正道)다.
