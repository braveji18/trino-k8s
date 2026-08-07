# 튜닝 웹서비스 구현설계 — 엔진 C: LLM API 직접 오케스트레이션

> 작성일: 2026년 7월 31일
> 상위 문서: [04-trino-튜닝-웹서비스-설계.md](04-trino-튜닝-웹서비스-설계.md) — 공통 아키텍처는 04를 따르고,
> 본 문서는 **AgentRunner + StageMapper 계층**을 결정적 파이프라인으로 대체하는 구현을 다룬다.
> 형제 문서: [05-엔진A-claude-agent-sdk](05-엔진A-claude-agent-sdk-구현설계.md) · [06-엔진B-codex-exec](06-엔진B-codex-exec-구현설계.md)
> 변형: [08-엔진C2-langgraph](08-엔진C2-langgraph-구현설계.md) — 본 문서의 오케스트레이션·LLM 호출 계층을 LangGraph + langchain-anthropic으로 대체한 설계 (체크포인트 재개·HITL·멀티모델). 엔진 C 채택 시 C-2가 기본 권장.

---

## 1. 개요와 적합성

에이전트 하네스 없이, 워크플로 6단계를 **백엔드 코드의 상태기계**로 구현하고 LLM은
판단이 필요한 단계에서만 Anthropic SDK(`anthropic`, 모델 `claude-opus-5`)로 호출한다.

핵심 관찰: **6단계 중 4단계는 LLM이 필요 없다.**

| 단계 | 실행 주체 | 방식 |
|---|---|---|
| 1 수집 | 코드 | trino 드라이버로 EXPLAIN/EXPLAIN ANALYZE/SHOW STATS 직접 실행 |
| 2 괴리 확인 | 코드 | 플랜 파서가 추정/실측 행수를 구조적으로 대조 |
| **3 진단** | **LLM** | 괴리 데이터 + 해당 규칙 파일 → 원인 판정 |
| **4 재작성** | **LLM** | 재작성 SQL 생성 (structured output) |
| 5 등가성 게이트 | 코드 | EXCEPT 양방향 차집합 쿼리 실행·판정 |
| 6 재측정·기록 | 코드 | EXPLAIN ANALYZE 재실행 + 비교표 생성 |

| 항목 | 내용 |
|---|---|
| 스킬 재사용 | ⚠ 부분 — references/·examples/는 프롬프트 자산으로 재사용, **워크플로는 코드로 재구현** |
| MCP | 불필요 — 백엔드가 Trino에 직접 접속 (mcp-trino 제거) |
| 진행 이벤트 | **StageMapper 자체가 불필요** — 단계가 코드이므로 이벤트를 코드가 직접 발행 (100% 결정적) |
| 워크플로 준수 | 구조적으로 100% (준수율 지표 무의미해짐) |
| 비용 제어 | 호출 횟수가 고정(세션당 LLM 2~4회) + 프롬프트 캐싱 |

**mcp-trino 제거의 안전성 함의**: read-only 필터 대신, 코드가 실행하는 SQL 자체가
EXPLAIN/SELECT/SHOW로 한정된 템플릿이므로 **구조적으로 읽기 전용**이다. 02 문서에서
지적한 허용목록 미적용·문자열 필터 우회 문제가 원천 소멸한다. Trino 측 OPA·resource
group은 그대로 유지(심층 방어).

## 2. 파이프라인 구조

```
tuner-api (FastAPI)
 └ TuningPipeline (세션당 asyncio task — 상태기계)
    ├ stage1_collect()    trino-python-client ── Trino
    ├ stage2_diff()       PlanParser (EXPLAIN ANALYZE 텍스트 → 프래그먼트별 추정/실측)
    ├ stage3_diagnose()   Anthropic SDK  ← references/rules-*.md (캐시된 시스템 프롬프트)
    ├ stage4_rewrite()    Anthropic SDK  → RewriteProposal (structured output)
    ├ stage5_equiv()      trino-python-client (EXCEPT 게이트)
    └ stage6_measure()    trino-python-client + 비교표
    각 단계 진입/완료 시 EventBus로 04 문서 §4 이벤트 직접 발행
```

## 3. LLM 호출 설계

### 3-1. 지식 베이스 = 캐시되는 시스템 프롬프트

스킬 references/를 런타임에 읽어 시스템 프롬프트로 구성하고 **프롬프트 캐싱**을 건다.
세션당 LLM 호출이 2~4회, 세션 간에도 동일 프리픽스이므로 캐시 효율이 높다.
규칙 파일은 안정 콘텐츠이므로 앞에, 세션별 컨텍스트는 messages로 — 프리픽스 불변 원칙.

```python
import anthropic
client = anthropic.AsyncAnthropic()

def build_system() -> list[dict]:
    rules = load_references(SKILL_DIR / "references")   # 03 문서 스킬 디렉터리를 그대로 읽음
    return [
        {"type": "text", "text": DIAGNOSE_ROLE_PROMPT},
        {"type": "text", "text": rules,
         "cache_control": {"type": "ephemeral", "ttl": "1h"}},   # 규칙 승격 시에만 무효화
    ]
```

### 3-2. 진단 (stage 3)

추가 조회가 필요할 수 있으므로 **툴 러너**에 읽기 전용 쿼리 툴 하나를 준다:

```python
from anthropic import beta_tool

@beta_tool
def run_readonly_query(sql: str) -> str:
    """진단에 필요한 추가 조회. EXPLAIN/SELECT/SHOW로 시작하는 단일 문장만 허용된다."""
    return trino_readonly.run(sql)          # 코드 레벨 화이트리스트 — 위반 시 에러 반환

runner = client.beta.messages.tool_runner(
    model="claude-opus-5",
    max_tokens=16000,
    thinking={"type": "adaptive"},
    system=build_system(),
    tools=[run_readonly_query],
    messages=[{"role": "user", "content": diagnosis_input(plan, stats, discrepancies)}],
)
```

툴 호출·결과는 러너 반복 중에 `tool_call`/`tool_result` 이벤트로 발행 — UI 피드는
A안과 동일한 형태를 유지한다.

### 3-3. 재작성 (stage 4) — structured output

```python
from pydantic import BaseModel

class RewriteProposal(BaseModel):
    rewritten_sql: str
    applied_rules: list[str]        # 규칙 ID — UI 배지·규칙 적중률 집계에 직결
    transform_notes: list[str]
    expected_effect: str

resp = await client.messages.parse(
    model="claude-opus-5",
    max_tokens=16000,
    system=build_system(),
    messages=[...],
    output_format=RewriteProposal,
)
proposal = resp.parsed_output       # 검증된 객체 — 파싱 실패가 구조적으로 차단됨
```

재작성 결과가 정형 객체이므로 **등가성 게이트(stage 5)에 넘기는 SQL이 항상 깨끗하다** —
에이전트 방식에서 필요했던 "텍스트에서 SQL 추출" 단계가 없다.

### 3-4. 공통 파라미터

- `thinking={"type": "adaptive"}` + `output_config={"effort": "high"}` — 진단·재작성은 지능 민감
- 스트리밍: 진단 단계의 narrative는 `client.messages.stream()`으로 SSE 패스스루
- 에러 처리: `RateLimitError`/`APIStatusError` 체인 — 재시도는 SDK 기본(2회)에 위임

## 4. 스킬과의 동기화 — 이 방식의 최대 리스크

워크플로가 코드로 복제되므로 03 문서의 스킬과 **이중 관리**가 된다. 완화 전략:

1. **규칙·예제는 단일 소스**: 코드가 스킬 디렉터리(references/·examples/)를 런타임에
   읽는다 — 규칙 승격(03 문서 §5-2)은 코드 변경 없이 반영. 중복되는 것은 워크플로
   순서와 금지사항뿐이다.
2. **SKILL.md를 명세로 취급**: 파이프라인 각 단계 함수에 SKILL.md의 해당 절을 주석으로
   링크하고, SKILL.md 변경 PR에 파이프라인 코드 검토를 요구(CODEOWNERS).
3. **동일 벤치 검증**: 03 문서 §5-3 하네스를 엔진 C에도 돌려 스킬 세션과 결과가
   갈라지는지 감시 — 갈라짐 = 동기화 깨짐 신호.

## 5. 취소·타임아웃·예산

| 항목 | 구현 |
|---|---|
| 사용자 취소 | asyncio task cancel — 단계 경계에서 즉시 중단, 실행 중 Trino 쿼리는 드라이버 취소 |
| 벽시계 타임아웃 | 단계별 개별 타임아웃 (수집 120s, 진단 180s, ...) — 어느 단계가 느린지 정확히 계측됨 |
| 예산 | 호출 횟수 고정 + `max_tokens` — 예산 초과라는 개념 자체가 거의 소멸 |
| 재시도 | 단계 단위 재시도 가능 (에이전트 방식은 세션 전체 재실행뿐) |

## 6. 장단점과 리스크

**장점**
- **결정적 진행**: 타임라인이 항상 정확, REJECTED/회귀 판정이 코드 — UI 신뢰도 최고.
- **최저 비용·지연**: LLM 호출 2~4회 고정 + 프롬프트 캐싱(규칙 프리픽스 1h TTL).
- 안전성 구조화: 쓰기 차단이 필터가 아닌 코드 경로 자체.
- 단계 단위 재시도·부분 실패 처리 가능.

**단점·리스크**
- 워크플로 이중 관리 (§4) — **스킬 고도화 루프와 서비스가 갈라질 위험**이 상존.
- 구현량 최대: 플랜 파서(EXPLAIN ANALYZE 텍스트 구조 파싱)가 실질적 난제.
  Trino 버전 업그레이드 시 플랜 포맷 변동에 취약 — 파서에 버전별 픽스처 테스트 필수.
- 진단의 유연성 손실: 에이전트가 자율적으로 하던 탐색(예: 연관 테이블 추가 확인)이
  `run_readonly_query` 툴 한도 내로 제한됨.

## 7. MVP 체크리스트

- [ ] PlanParser: trino-lab의 EXPLAIN ANALYZE 출력으로 픽스처 테스트 (TPC-H 22개 쿼리)
- [ ] stage3 툴 러너 + stage4 structured output 왕복 1회 완주 (Q9)
- [ ] 프롬프트 캐시 적중 확인 (`usage.cache_read_input_tokens` > 0, 2회째 호출부터)
- [ ] 등가성 게이트 REJECTED 경로 — 고의로 틀린 재작성 주입 테스트
- [ ] 03 문서 벤치 세트로 엔진 A와 speedup·규칙 적중률 비교

---

## 세 엔진 종합 비교와 선택 가이드

| 기준 | A: Agent SDK | B: Codex exec | C: API 직접 |
|---|---|---|---|
| 스킬 재사용 | 완전 | 완전 | 부분 (규칙만) |
| 구현량 | 최소 | 소 | **최대** |
| 진행 표시 신뢰도 | 높음 (훅) | 중 (마커 의존) | **최고 (결정적)** |
| 워크플로 준수 | 관찰 필요 | 관찰 필요 | 구조적 100% |
| 토큰 비용/세션 | 높음 | 높음 | **최저** |
| 예산 강제 | SDK 내장 | 사후 관찰뿐 | 구조적 |
| 스킬 고도화 연동 | **즉시 반영** | 즉시 반영 | 규칙만 즉시, 워크플로는 코드 변경 |
| 쓰기 차단 | mcp 필터+OPA | mcp 필터+OPA | **코드 경로 자체** |
| 이미지 의존성 | Node+CLI | Rust CLI | Python뿐 |

**권장 경로** (04 문서 결정 1의 구체화):

```
MVP~v0.3   엔진 A (스킬이 곧 서비스 — 고도화 루프와 함께 진화)
     +     엔진 B는 벤치 평가 전용으로 병행 (03 문서 §5-4)
v1.0 판단  스킬이 안정화되어 워크플로 변경 빈도가 낮아지면
           엔진 C로 전환 검토 — 비용·결정성·안전성 이득이 이중 관리 비용을 넘는 시점
           (전환 시 구현은 C-2/LangGraph가 기본 — 08 문서 §8 참고)
```

전환 판단 기준: 03 문서 §5-3 지표에서 **워크플로 준수율이 2개 버전 연속 95% 이상**이고
규칙 변경이 워크플로 변경 없이 이뤄지는 상태가 되면, 워크플로를 코드로 고정해도 잃는 것이
없다는 신호다.
