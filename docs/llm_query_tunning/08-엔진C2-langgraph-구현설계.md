# 튜닝 웹서비스 구현설계 — 엔진 C-2: LangGraph 오케스트레이션

> 작성일: 2026년 7월 31일
> 상위 문서: [07-엔진C-llm-api-직접](07-엔진C-llm-api-직접-오케스트레이션-구현설계.md)의 변형 —
> 파이프라인 골격(단계 분담·안전성·스킬 동기화 전략·플랜 파서)은 07을 그대로 따르고,
> **오케스트레이션과 LLM 호출 계층을 Anthropic SDK 직접 호출 → LangGraph + langchain-anthropic으로 대체**한 부분만 다룬다.
> 공통 아키텍처(API·DB·UI·안전장치)는 [04 문서](04-trino-튜닝-웹서비스-설계.md).

---

## 1. 무엇이 바뀌고 무엇이 그대로인가

| 계층 | 07 원안 (C-1) | 본 문서 (C-2) |
|---|---|---|
| 워크플로 6단계 분담 (LLM은 진단·재작성뿐) | 동일 | **동일** |
| 상태기계 | 직접 구현한 asyncio 상태기계 | **LangGraph `StateGraph`** |
| LLM 호출 | `anthropic` SDK (`tool_runner`, `messages.parse`) | **`langchain-anthropic` `ChatAnthropic`** (`bind_tools`, `with_structured_output`) |
| 재개·재시도 | 직접 구현 | **체크포인터 내장** (`PostgresSaver` → 기존 CNPG) |
| 진행 이벤트 | EventBus 직접 발행 | **`astream_events` → EventBus 어댑터** |
| 사람 개입(HITL) | 없음 | `interrupt()` — 승인 게이트 확장 여지 |
| 모델 | Claude 고정 | 프로바이더 스왑 가능 — **엔진 B의 모델 비교 역할 흡수** |
| Trino 접속·플랜 파서·등가성 게이트 | 코드 직접 | 동일 (그래프의 비-LLM 노드) |

**얻는 것**: 체크포인트 기반 재개, 표준화된 이벤트 스트림, HITL, 멀티모델.
**대가**: LangChain/LangGraph 의존성(버전 이동 빠름 — 고정 필수), Anthropic 최신
파라미터의 랩퍼 지연 가능성(§6).

## 2. 상태와 그래프 정의

### 2-1. 상태 (단일 진실 소스)

```python
from typing import Optional
from pydantic import BaseModel

class RewriteProposal(BaseModel):                 # 07 §3-3과 동일
    rewritten_sql: str
    applied_rules: list[str]
    transform_notes: list[str]
    expected_effect: str

class TuningState(BaseModel):
    session_id: str
    input_sql: str
    target: str                                   # trino-lab | prod
    # 단계 산출물 — 각 노드가 자기 필드만 채운다
    plan_before: Optional[str] = None
    stats: Optional[dict] = None
    discrepancies: list[dict] = []                # stage2 PlanParser 출력
    diagnosis: Optional[str] = None
    proposal: Optional[RewriteProposal] = None
    equivalent: Optional[bool] = None
    counter_example: Optional[dict] = None        # 등가성 실패 시 반례
    metrics_before: Optional[dict] = None
    metrics_after: Optional[dict] = None
```

상태가 체크포인터에 그대로 저장되므로 **04 문서의 `artifacts` 테이블 역할 일부를
체크포인트가 흡수**한다 (최종 리포트만 별도 영속화).

### 2-2. 그래프

```python
from langgraph.graph import StateGraph, START, END
from langgraph.checkpoint.postgres.aio import AsyncPostgresSaver

g = StateGraph(TuningState)
g.add_node("collect",   stage1_collect)     # trino-python-client — 07과 동일 코드
g.add_node("diff",      stage2_diff)        # PlanParser
g.add_node("diagnose",  stage3_diagnose)    # LLM + 툴 루프 (§3)
g.add_node("tools",     readonly_tool_node) # 진단용 읽기 전용 쿼리 실행
g.add_node("rewrite",   stage4_rewrite)     # LLM structured output (§4)
g.add_node("equiv",     stage5_equiv)       # EXCEPT 게이트
g.add_node("measure",   stage6_measure)     # 재측정 + 비교표

g.add_edge(START, "collect")
g.add_edge("collect", "diff")
g.add_edge("diff", "diagnose")
g.add_conditional_edges("diagnose",          # 표준 툴 루프: 툴 호출 있으면 tools로
    lambda s: "tools" if s.pending_tool_calls else "rewrite")
g.add_edge("tools", "diagnose")
g.add_edge("rewrite", "equiv")
g.add_conditional_edges("equiv",             # REJECTED 분기가 그래프 구조 자체
    lambda s: "measure" if s.equivalent else END)
g.add_edge("measure", END)

checkpointer = AsyncPostgresSaver.from_conn_string(TUNER_PG_DSN)   # 04 문서 tuner-postgres 재사용
graph = g.compile(checkpointer=checkpointer)
```

실행: `thread_id = session_id`로 세션과 체크포인트를 1:1 매핑.

```python
config = {"configurable": {"thread_id": session.id}, "recursion_limit": 25}
await graph.ainvoke(TuningState(session_id=session.id, input_sql=sql, target=t), config)
```

- **크래시 재개**: 같은 `thread_id`로 `graph.ainvoke(None, config)` — 마지막 완료
  노드 다음부터 재개. 07 원안에서 직접 구현하던 단계 단위 재시도가 공짜.
- 노드별 재시도: `g.add_node(..., retry_policy=RetryPolicy(max_attempts=2))` —
  Trino 일시 오류(수집·재측정 노드)에 적용.

## 3. 진단 노드 — ChatAnthropic + 툴 루프

07 §3-2의 툴 러너를 LangGraph의 표준 툴 루프(diagnose ↔ tools 순환)로 대체한다.

```python
from langchain_anthropic import ChatAnthropic
from langchain_core.tools import tool
from langchain_core.messages import SystemMessage

@tool
def run_readonly_query(sql: str) -> str:
    """진단에 필요한 추가 조회. EXPLAIN/SELECT/SHOW로 시작하는 단일 문장만 허용된다."""
    return trino_readonly.run(sql)               # 07과 동일한 코드 레벨 화이트리스트

llm = ChatAnthropic(model="claude-opus-5", max_tokens=16000)
diagnose_llm = llm.bind_tools([run_readonly_query])

def build_system_message() -> SystemMessage:
    rules = load_references(SKILL_DIR / "references")    # 03 문서 스킬 — 단일 소스 유지
    return SystemMessage(content=[
        {"type": "text", "text": DIAGNOSE_ROLE_PROMPT},
        {"type": "text", "text": rules,
         "cache_control": {"type": "ephemeral", "ttl": "1h"}},   # 캐싱은 랩퍼 통과 지원됨
    ])

async def stage3_diagnose(state: TuningState) -> dict:
    msgs = [build_system_message()] + state.diagnose_messages \
           or [build_system_message(), diagnosis_input(state)]
    resp = await diagnose_llm.ainvoke(msgs)
    if resp.tool_calls:
        return {"pending_tool_calls": resp.tool_calls,
                "diagnose_messages": msgs[1:] + [resp]}
    return {"diagnosis": resp.text(), "pending_tool_calls": []}
```

- 툴 루프 상한은 `recursion_limit`이 겸한다(폭주 방지 — 07의 "호출 횟수 고정" 성질을
  상한부로 유지).
- 툴 실행 노드는 LangGraph 제공 `ToolNode`를 쓰되, 실행 전후에 EventBus로
  `tool_call`/`tool_result`를 발행하는 래퍼를 한 겹 씌운다.

## 4. 재작성 노드 — structured output

```python
rewrite_llm = llm.with_structured_output(RewriteProposal)

async def stage4_rewrite(state: TuningState) -> dict:
    proposal: RewriteProposal = await rewrite_llm.ainvoke(
        [build_system_message(), rewrite_input(state)])
    return {"proposal": proposal}
```

`with_structured_output`은 tool-calling 기반 — 07 원안의 `messages.parse`
(API 네이티브 `output_config.format`)보다 보장 수준이 한 단계 약하다.
완화: 반환 객체의 `rewritten_sql`을 등가성 게이트 앞에서 sqlglot 등으로 **파싱 검증**하는
가드를 추가한다 (원안에는 불필요했던 단계).

## 5. 진행 이벤트 — astream_events 어댑터

StageMapper 없이, LangGraph 표준 이벤트를 04 문서 §4 프로토콜로 1:1 변환한다.
**노드 이름 → 스테이지 번호가 정적 테이블**이므로 판정이 아니라 매핑이다.

```python
NODE_STAGE = {"collect": 1, "diff": 2, "diagnose": 3, "tools": 3,
              "rewrite": 4, "equiv": 5, "measure": 6}

async def run_and_stream(state, config, bus):
    async for ev in graph.astream_events(state, config, version="v2"):
        match ev["event"]:
            case "on_chain_start" if ev["name"] in NODE_STAGE:
                bus.stage_started(sid, NODE_STAGE[ev["name"]])
            case "on_chain_end" if ev["name"] in NODE_STAGE:
                bus.stage_done(sid, NODE_STAGE[ev["name"]], summarize(ev["data"]))
            case "on_chat_model_stream":
                bus.narrative_delta(sid, ev["data"]["chunk"].text())   # 토큰 스트림 → SSE
            case "on_tool_start":
                bus.tool_call(sid, ev["name"], ev["data"].get("input"))
            case "on_tool_end":
                bus.tool_result(sid, ev["name"], ev["data"].get("output"))
```

`discrepancy_found`·`equivalence_result`·`measurement` 같은 도메인 이벤트는 07과
동일하게 해당 노드 코드가 직접 발행한다(표준 이벤트는 골격, 도메인 이벤트는 노드 책임).

## 6. 취소·타임아웃·예산·HITL

| 항목 | 구현 |
|---|---|
| 사용자 취소 | asyncio task cancel — 체크포인트가 남으므로 CANCELLED 세션의 **이어하기** 제공 가능 (07 원안에 없던 기능) |
| 벽시계 타임아웃 | 노드 함수 내부의 단계별 타임아웃 (07과 동일) + 전체 `asyncio.wait_for` |
| 예산 | `recursion_limit`(툴 루프 상한) + `UsageMetadataCallbackHandler`로 세션 누적 토큰 집계 → 초과 시 중단 |
| HITL (v1.1 확장) | `interrupt()`로 재작성 제안 후 일시정지 → 사용자 승인(`Command(resume=...)`) 후 등가성 게이트 진행 — 실 클러스터 적용 시 "적용 전 사람 확인" 요건에 대응 |

### Anthropic 파라미터 통과 주의 (이 변형의 대표 리스크)

- 프롬프트 캐싱(`cache_control`) — **지원 확인됨** (langchain-anthropic 캐싱 미들웨어/콘텐츠 블록).
- `thinking` / `output_config.effort` 등 최신 파라미터 — 랩퍼 버전에 따라 미노출일 수
  있음. 구현 시 설치 버전에서 통과 여부를 확인하고, 미지원이면 `model_kwargs` /
  `extra_body`류 우회 경로를 검증할 것. **우회도 안 되는 파라미터가 품질에 중요하면
  C-1(순수 SDK)로 회귀하는 것이 맞다** — 이 판단 기준을 MVP 체크리스트에 포함.

## 7. 멀티모델 — 엔진 B 역할 흡수 + 오픈소스 대체

```python
from langchain.chat_models import init_chat_model
llm = init_chat_model(session.model_ref)   # "anthropic:claude-opus-5" | "openai:..." 등
```

세션 파라미터로 모델을 받으면 03 문서 §5-4(플랫폼 간 비교)를 **같은 파이프라인 안에서**
수행할 수 있다 — 워크플로·규칙·측정이 완전 동일하므로 엔진 B 방식(하네스까지 다른 비교)보다
모델 순수 효과 측정에 오히려 낫다. 단, 06 문서의 존재 이유 중 "스킬 문구의 플랫폼 의존성
발견"은 대체하지 못한다(여긴 스킬을 쓰지 않으므로).

### 7-1. 오픈소스(자체 서빙) 모델 대체 — 가능, 구조 변경 없음

LLM을 쓰는 노드는 진단·재작성 2개뿐이므로, 오픈소스 모델 대체는 **모델 초기화 1곳의
변경**이다. 그래프·체크포인터·이벤트 어댑터·등가성 게이트는 모델과 무관하다.

| 서빙 | LangChain 연결 | 용도 |
|---|---|---|
| **vLLM** (OpenAI 호환 API, 클러스터 내 배포) | `ChatOpenAI(base_url="http://vllm:8000/v1", ...)` | **서비스 권장** |
| Ollama | `ChatOllama(...)` (`langchain-ollama`) | 로컬 PoC·모델 비교 |

**설계 요구 능력의 대응 관계:**

| 본 문서의 의존 기능 | 오픈소스 대응 | 판정 |
|---|---|---|
| `bind_tools` (진단 툴 루프) | vLLM `--enable-auto-tool-choice` + 모델별 tool parser | ✅ 가능 — 호출 품질은 모델 편차 큼 |
| `with_structured_output` | vLLM **guided decoding**(xgrammar/outlines) — 문법 수준 JSON 강제 | ✅ **오히려 강화** — sqlglot 가드 부담 감소 |
| 프롬프트 캐싱 (rules 프리픽스) | vLLM **automatic prefix caching** — 자동·무료 | ✅ 대체 (`cache_control` 불필요) |
| 긴 컨텍스트 (references/) | 32k+ 컨텍스트 모델 | ✅ 최신 오픈 모델 대부분 충족 |

- §6의 "Anthropic 파라미터 랩퍼 지연" 리스크는 **소멸**하고, 대신 **진단·재작성 품질
  리스크**로 치환된다.
- **안전망**: 이 아키텍처에서 약한 모델의 최악 결과는 "오답"이 아니라 "성공률 저하"다 —
  등가성 게이트(코드)가 틀린 재작성을, 재측정(코드)이 회귀를 걸러낸다. 모델 적합성은
  03 문서 §5-3 벤치(기하평균 speedup·등가성 통과율·규칙 적중률)로 모델별 실측해 판정한다.
- **선례**: [조사 보고서](../LLM-Trino-쿼리튜닝-조사.md) 2부의 QUITE가 오픈소스 모델
  (DeepSeek-R1)로 쿼리 재작성 SOTA를 달성 — 이 조합의 학술적 검증 사례.
- **동기와 대가**: 쿼리·스키마·통계가 클러스터 밖으로 나가지 않음(데이터 주권) + API 비용 0.
  대가는 GPU 노드(32B급 기준 A100/H100 1장 상당, 양자화 시 완화)와 vLLM 운영 부담.
  **클러스터 GPU 노드 보유 여부가 선결 확인 사항.**

**후보 모델 (2026-07 기준, 벤치 검증 전제):**

| 모델 | 라이선스 | 비고 |
|---|---|---|
| Qwen3 계열 (32B~) | Apache 2.0 | tool calling 안정, SQL 강함 — 1순위 평가 |
| DeepSeek-R1 / V3 | MIT | QUITE 선례, reasoning 강점 — 진단 노드 적합 |
| Qwen2.5-Coder | Apache 2.0 | 재작성 노드 특화 후보 |
| Llama 3.3+ | 커뮤니티 라이선스 | 상용 조건 확인 필요 |

**노드별 혼합**도 자연스럽다 — 진단(품질 민감)은 Claude, 재작성은 오픈소스처럼 노드마다
다른 `llm` 인스턴스를 바인딩하면 되고, 비용·주권·품질의 절충점을 벤치로 찾는다.

## 8. C-1 대비 요약과 선택

| 기준 | C-1 (순수 SDK) | C-2 (LangGraph) |
|---|---|---|
| 의존성 | `anthropic`뿐 | + langchain-core/anthropic, langgraph, checkpoint-postgres |
| 재개·재시도 | 직접 구현 | 체크포인터 내장 ✅ |
| 이벤트 스트림 | 직접 발행 | 표준 이벤트 + 어댑터 ✅ |
| structured output 보장 | API 네이티브 (강) | tool-calling 기반 (중) — sqlglot 가드 필요 |
| Anthropic 신기능 | 즉시 | 랩퍼 지연 가능 ⚠ |
| HITL | 없음 | `interrupt()` ✅ |
| 멀티모델 | 불가 | 스왑 1줄 ✅ |
| 취소 후 이어하기 | 불가 | 체크포인트로 가능 ✅ |

**권고**: 엔진 C를 채택하는 시점(07 문서 전환 기준 충족 시)에는 **C-2를 기본**으로 한다.
상태기계·재개·이벤트 스트림을 직접 구현할 이유가 없다. C-1로 남을 이유는 단 하나 —
Anthropic 신기능(예: effort 세분화, 신규 structured output 모드)이 품질에 중요한데
랩퍼가 따라오지 못하는 경우다.

## 9. MVP 체크리스트

07 체크리스트에 다음을 추가/대체:

- [ ] `ChatAnthropic` 설치 버전에서 `thinking`·`effort` 파라미터 통과 여부 확인 — 불가 시 `model_kwargs` 우회 검증, 그것도 불가하면 C-1 회귀 판단
- [ ] 프롬프트 캐시 적중 확인 (`usage_metadata`의 cache read > 0, 2회째 호출부터)
- [ ] 강제 크래시 후 같은 `thread_id` 재개 — collect/diff 재실행 없이 diagnose부터 이어지는지
- [ ] `with_structured_output` 결과에 sqlglot 파싱 가드 — 비정합 SQL 주입 테스트
- [ ] `astream_events` 어댑터의 6단계 타임라인이 UI에서 정확히 렌더되는지 (10세션)
- [ ] LangChain/LangGraph 버전 고정(lock) + 업그레이드 회귀 테스트 절차 문서화

오픈소스 모델 경로(§7-1) 검토 시 추가:

- [ ] 클러스터 GPU 노드 보유·가용량 확인 (32B급 서빙 기준) — 없으면 §7-1은 보류
- [ ] vLLM 배포 + tool calling(`--enable-auto-tool-choice`)·guided decoding 동작 확인
- [ ] 후보 모델(Qwen3, DeepSeek-R1 등)로 03 문서 벤치 세트 실측 — Claude 대비 등가성 통과율·speedup 비교 후 채택/혼합/보류 판정

---

## 참고

- 원안(C-1): [07-엔진C-llm-api-직접-오케스트레이션-구현설계.md](07-엔진C-llm-api-직접-오케스트레이션-구현설계.md) — 파이프라인 골격·안전성·스킬 동기화 전략은 그쪽이 원본
- langchain-anthropic 프롬프트 캐싱: `reference.langchain.com/python/langchain-anthropic/middleware/prompt_caching`
- LangGraph 체크포인터·HITL·astream_events: `docs.langchain.com` (langgraph)
- n8n 검토 결과(코어 엔진 부적합, v1.0 주변 자동화 계층 후보): 2026-07-31 세션 분석 —
  느린 쿼리 수집→후보 선별→튜닝 API 투입→Slack 통보 등 크론성 워크플로에 한정 권장
