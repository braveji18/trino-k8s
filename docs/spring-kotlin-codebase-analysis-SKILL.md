---
name: spring-kotlin-codebase-analysis
description: Spring Boot 3.4 / Kotlin 1.9 / Gradle / JDK 21 프로젝트의 구조, 빈 구성, API 엔드포인트, 영속 계층, 트랜잭션 경계, 횡단 관심사를 단계적으로 파악해 ARCHITECTURE.md로 정리한다. 사용자가 "이 프로젝트 구조 분석", "코드 파악", "온보딩", "어디서부터 봐야 하나", "이 API 흐름 추적", "레거시 서비스 이해" 같은 요청을 하거나, 낯선 Spring/Kotlin 저장소에서 작업을 시작할 때 반드시 이 스킬을 사용할 것. 사용자가 '분석'이라는 단어를 쓰지 않아도, 처음 보는 Spring 저장소에서 무언가를 고치거나 추가하려는 상황이면 먼저 이 스킬로 지형을 파악한다.
allowed-tools: Read, Grep, Glob, Bash(./gradlew:*), Bash(git log:*), Bash(git ls-files:*), Bash(find:*), Bash(wc:*)
---

# Spring Boot + Kotlin 코드베이스 분석

## 전제 스택

Spring Boot 3.4.6 / Kotlin 1.9.25 / Gradle (Kotlin DSL 가정) / JDK 21.
실제 버전이 다르면 Phase 0에서 확인한 값을 따르고, 차이가 크면 사용자에게 알린다.

## 진행 원칙

- **읽기 전에 좁힌다.** 파일을 통째로 읽는 대신 Grep으로 심볼 정의 위치를 먼저 찾는다. 대형 저장소에서 무작정 Read를 반복하면 컨텍스트가 금방 소진되고 정작 중요한 파일을 못 본다.
- **각 Phase가 끝날 때마다 3~5줄로 요약**하고 다음으로 넘어간다. 사용자가 중간에 방향을 틀 수 있어야 한다.
- **추측 금지.** 확인하지 못한 부분은 결과물에 `(미확인)`으로 남긴다. 그럴듯한 추측은 잘못된 문서보다 나쁘다.
- 사용자가 특정 기능(예: "결제 흐름")을 지목했다면 Phase 1~2만 빠르게 훑고 Phase 4의 흐름 추적으로 바로 이동한다.

---

## Phase 0 — 스택 확정

```bash
cat gradle/libs.versions.toml 2>/dev/null || echo "version catalog 없음"
cat settings.gradle.kts
./gradlew -q javaToolchains
```

`build.gradle.kts`에서 다음을 확인한다.

- Spring Boot 플러그인 버전, `dependencyManagement` 사용 여부
- Kotlin 플러그인 구성: `kotlin("plugin.spring")` (allopen), `kotlin("plugin.jpa")` (noarg), `kotlin("kapt")` 또는 `ksp`
- `kotlinOptions`의 `jvmTarget`, `freeCompilerArgs` (`-Xjsr305=strict` 여부 → 플랫폼 타입 널 처리 정책)
- 주요 스타터: web / webflux / data-jpa / security / batch / cloud 중 무엇인가

**여기서 갈림길이 생긴다.** `spring-boot-starter-web`이면 서블릿 + 블로킹, `webflux`면 리액티브 + 코루틴 가능성이 높다. 이후 Phase의 탐색 대상이 달라지므로 반드시 먼저 확정한다.

## Phase 1 — 모듈과 빌드 구조

```bash
./gradlew -q projects
git ls-files | head -200
```

멀티모듈이면 각 모듈의 책임과 의존 방향을 표로 정리한다.

| 모듈 | 책임 | 의존 대상 |
|---|---|---|

의존 방향에 순환이 있거나 도메인 모듈이 인프라 모듈을 참조하면 그 자체가 중요한 발견이므로 기록한다.

## Phase 2 — 진입점과 설정

```bash
grep -rn "@SpringBootApplication" --include=*.kt
find . -name "application*.yml" -o -name "application*.yaml" -o -name "application*.properties" | grep -v build/
```

확인 항목:

- `@SpringBootApplication`의 패키지 위치 → 컴포넌트 스캔 루트. `scanBasePackages`가 명시돼 있으면 스캔 범위가 예상과 다를 수 있다.
- 프로필별 설정 파일과 프로필 간 차이 (특히 `local` vs `prod`의 DB, 로깅 레벨)
- `spring.threads.virtual.enabled` → JDK 21 가상 스레드 사용 여부. 켜져 있으면 `synchronized` 블록과 ThreadLocal 사용처를 별도로 점검할 가치가 있다.
- `@ConfigurationProperties` 클래스: `grep -rn "@ConfigurationProperties" --include=*.kt`

## Phase 3 — 빈 지도 그리기

레이어별로 존재하는 빈을 수집한다.

```bash
grep -rn "@RestController\|@Controller" --include=*.kt | wc -l
grep -rln "@Service" --include=*.kt
grep -rln "@Repository" --include=*.kt
grep -rn "@Configuration" --include=*.kt
grep -rn "@Bean" --include=*.kt | wc -l
```

애플리케이션을 실행할 수 있고 actuator가 켜져 있다면, 정적 분석보다 정확한 실물 정보를 얻을 수 있다.

```bash
curl -s localhost:8080/actuator/beans | head
curl -s localhost:8080/actuator/mappings
curl -s localhost:8080/actuator/configprops
```

실행이 불가능한 환경이면 이 단계는 건너뛰고 정적 분석 결과만 사용한다. 실행 여부를 임의로 시도하기 전에 사용자에게 물어본다.

## Phase 4 — 엔드포인트 인벤토리와 흐름 추적

먼저 전체 엔드포인트 목록을 만든다.

```bash
grep -rn "@GetMapping\|@PostMapping\|@PutMapping\|@DeleteMapping\|@PatchMapping\|@RequestMapping" --include=*.kt
```

| Method | Path | Controller.function | 호출하는 Service |
|---|---|---|---|

그다음 **가장 중요한 유스케이스 1~2개를 골라 끝까지 추적한다.** 목록만으로는 설계 의도가 보이지 않는다. 추적은 다음 형태로 기술한다.

```
POST /api/orders
 → OrderController.create(OrderCreateRequest)
 → OrderService.place(command)          [@Transactional]
 → InventoryClient.reserve(...)         [외부 HTTP — 트랜잭션 안에서 호출됨 ⚠]
 → OrderRepository.save(entity)
 → OrderCreatedEvent 발행               [@TransactionalEventListener AFTER_COMMIT]
```

요청/응답 DTO가 data class인지, 엔티티를 그대로 노출하는지도 함께 본다. 엔티티 직접 노출은 이후 변경 작업의 지뢰가 된다.

## Phase 5 — 영속 계층과 트랜잭션

```bash
grep -rn "@Entity" --include=*.kt
grep -rn "@Transactional" --include=*.kt
find . -path "*/db/migration/*" -o -name "*.xml" -path "*changelog*" | grep -v build/
```

확인 항목:

- ORM/쿼리 도구: Spring Data JPA, QueryDSL, JOOQ, MyBatis, Exposed, R2DBC 중 무엇인가
- 마이그레이션: Flyway(`db/migration`) 또는 Liquibase. 스키마의 최신 형태는 엔티티가 아니라 마이그레이션 스크립트가 진실에 가깝다.
- 연관관계의 fetch 전략과 N+1 위험 지점 (`@OneToMany` 기본 LAZY, `@ManyToOne` 기본 EAGER)
- `@Transactional`이 붙은 위치가 Service인지 Controller인지 Repository인지 — 트랜잭션 경계가 일관적인가

### Kotlin + JPA 특유의 확인 사항

- 엔티티가 `data class`로 선언돼 있는가 → `equals`/`hashCode`가 모든 프로퍼티 기반이라 지연 로딩 프록시와 컬렉션에서 오작동할 수 있다. 발견하면 기록한다.
- `kotlin("plugin.jpa")` (noarg)가 없는데 `@Entity`가 있으면 기본 생성자 문제가 있다.
- `val` 프로퍼티만으로 구성된 엔티티는 더티 체킹이 동작하지 않는다.

## Phase 6 — 횡단 관심사

각 항목을 한 번씩 훑고, 존재하지 않으면 "없음"으로 명시한다.

```bash
grep -rn "SecurityFilterChain\|@EnableWebSecurity\|@PreAuthorize" --include=*.kt
grep -rn "@RestControllerAdvice\|@ExceptionHandler" --include=*.kt
grep -rn "OncePerRequestFilter\|HandlerInterceptor\|@Aspect" --include=*.kt
grep -rn "@Async\|@Scheduled\|@EventListener\|@TransactionalEventListener" --include=*.kt
```

- **보안**: 인증 방식(JWT/세션/OAuth2), 필터 체인 순서, 공개 경로
- **예외 처리**: 전역 핸들러의 응답 포맷, 에러 코드 체계
- **관측**: Actuator 노출 엔드포인트, Micrometer 메트릭, 분산 추적, 구조화 로깅 여부
- **외부 연동**: RestClient / WebClient / Feign 중 무엇을 쓰는지, 타임아웃과 재시도 설정이 있는지

## Phase 7 — Kotlin·JDK 21 특이점 점검

이 항목들은 코드를 읽는 것만으로는 눈에 잘 띄지 않지만 이후 작업에서 자주 문제를 일으킨다.

- **프록시 self-invocation**: 같은 클래스 안에서 `@Transactional`/`@Async` 메서드를 직접 호출하면 프록시를 거치지 않아 무효가 된다. `grep`으로 의심 지점을 찾아 표시한다.
- **open 여부**: `kotlin("plugin.spring")`이 `@Component` 계열 클래스를 자동으로 open 처리한다. 이 플러그인이 없는데 CGLIB 프록시가 필요한 구성이면 문제가 된다.
- **코루틴**: `suspend` 함수가 있는지, 있다면 트랜잭션 및 MDC 컨텍스트 전파를 어떻게 처리하는지.
- **가상 스레드**: 활성화돼 있다면 `synchronized`로 감싼 긴 블로킹 구간과 커넥션 풀 크기 설정을 함께 본다.
- **널 안정성 경계**: Java 라이브러리와 맞닿는 지점의 플랫폼 타입 처리.

## Phase 8 — 테스트 구조

```bash
find . -path "*/src/test/*" -name "*.kt" | head -50
grep -rn "@SpringBootTest\|@WebMvcTest\|@DataJpaTest\|Testcontainers" --include=*.kt src/test 2>/dev/null
```

테스트는 그 팀이 무엇을 중요하게 여기는지 가장 정직하게 보여준다. 사용 프레임워크(JUnit5 / Kotest), 모킹 도구(MockK / Mockito), 통합 테스트 전략(Testcontainers / 임베디드 DB), 그리고 **테스트가 아예 없는 영역**을 기록한다.

## Phase 9 — 산출물

`docs/ARCHITECTURE.md`에 아래 구조로 저장한다. 기존 파일이 있으면 덮어쓰기 전에 사용자에게 확인한다.

```markdown
# 아키텍처 개요

## 1. 한 문단 요약
## 2. 기술 스택
## 3. 모듈 구조
## 4. 레이어와 데이터 흐름
     (mermaid flowchart 1개)
## 5. 주요 엔드포인트
## 6. 도메인 모델과 영속 계층
## 7. 횡단 관심사
## 8. 빌드·실행·테스트 방법
## 9. 관찰된 리스크와 개선 후보
## 10. 미확인 영역
```

9번과 10번을 비워두지 않는다. 분석의 실질적 가치는 대부분 이 두 섹션에 있다.

---

## 마무리 보고

문서를 저장한 뒤 사용자에게 다음을 짧게 전달한다.

1. 이 코드베이스를 이해하려면 어떤 파일 3개를 먼저 읽어야 하는가
2. 가장 눈에 띈 리스크 하나
3. 다음으로 파고들면 좋을 영역 하나
