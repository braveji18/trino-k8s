# 튜닝 웹서비스 구현설계 — 엔진 B: Codex exec 헤드리스

> 작성일: 2026년 7월 31일
> 상위 문서: [04-trino-튜닝-웹서비스-설계.md](04-trino-튜닝-웹서비스-설계.md) — 공통 아키텍처는 04를 따르고,
> 본 문서는 **AgentRunner + StageMapper 계층**의 Codex exec 구현만 다룬다.
> 형제 문서: [05-엔진A-claude-agent-sdk](05-엔진A-claude-agent-sdk-구현설계.md) · [07-엔진C-llm-api-직접](07-엔진C-llm-api-직접-오케스트레이션-구현설계.md)

---

## 1. 개요와 적합성

`codex exec`는 Codex CLI의 비대화형 모드다. 프롬프트를 인자로 받아 완주하고,
`--json` 플래그로 **JSONL 이벤트 스트림**을 stdout에 흘린다. 03 문서에서 스킬을
`.agents/skills/`에 배치했으므로 스킬·MCP(.codex/config.toml) 재사용이 가능하다.

| 항목 | 내용 |
|---|---|
| 스킬 재사용 | ✅ `.agents/skills/` 자동 탐색 (03 문서 배치 그대로) |
| MCP 재사용 | ✅ `.codex/config.toml`의 `[mcp_servers.trino]` |
| 진행 이벤트 | stdout JSONL 파싱 — **in-process 훅 없음 → 스테이지 마커가 주 채널** |
| 워크플로 준수 | 스킬 지시 기반 (비결정적) |
| 비용 제어 | SDK 수준 예산 옵션 없음 — 프로세스 타임아웃 + turn 관찰로 대체 |

**이 엔진의 존재 이유**: 03 문서 §5-4(플랫폼 간 비교)의 연장이다. 같은 스킬을 다른
모델·하네스로 돌려 스킬 문구의 플랫폼 의존성과 성능 차이를 측정하는 **평가용 세컨드 엔진**
포지션이며, 단독 프로덕션 엔진으로는 권장하지 않는다(§6 리스크 참고).

## 2. 세션 실행 구조

세션당 서브프로세스 1개. 백엔드는 프로세스를 spawn하고 stdout JSONL을 줄 단위로 파싱한다.

```
tuner-api (FastAPI)
 └ SessionTask (asyncio)
    └ subprocess: codex exec --json [flags] "<프롬프트>"
         cwd = 저장소 루트 (.agents/skills/ + .codex/config.toml)
         stdout(JSONL) ──→ JsonlStageMapper ──→ EventBus ──→ SSE
```

### AgentRunner 골격

```python
import asyncio, json

def build_cmd(session: Session) -> list[str]:
    return [
        "codex", "exec",
        "--json",
        "--sandbox", "read-only",          # 파일 변경 불필요 — 최소 권한
        "--ask-for-approval", "never",     # 헤드리스: 승인 대기 금지
        "--skip-git-repo-check",
        "--output-schema", str(REPORT_SCHEMA_PATH),   # 최종 리포트를 정형 JSON으로
        build_prompt(session),             # "$trino-query-tuning 스킬로 다음 쿼리를 튜닝하라..." + 마커 지시
    ]

async def run_session(session: Session, bus: EventBus):
    proc = await asyncio.create_subprocess_exec(
        *build_cmd(session),
        cwd=REPO_ROOT,
        env={**os.environ, **codex_env(session)},   # OPENAI_API_KEY 등
        stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE,
    )
    session.attach_process(proc)                    # 취소용
    mapper = JsonlStageMapper(session.id, bus)
    async for line in proc.stdout:
        try:
            mapper.handle(json.loads(line))
        except json.JSONDecodeError:
            continue                                # 비-JSON 라인은 무시
    rc = await proc.wait()
    bus.session_done(session.id, exit_code=rc, report=mapper.final_report)
```

프롬프트에는 05 문서와 동일한 서비스 모드 지시(스테이지 마커 출력, SQL 내 지시문 무시)를
포함하되, **마커 의존도가 A안보다 훨씬 높다는 점**을 반영해 마커 지시를 SKILL.md의
"서비스 모드" 절에도 중복 기재한다.

## 3. StageMapper — JSONL 파싱 (마커가 주 채널)

`--json` 이벤트 시퀀스: `thread.started` → `turn.started` → `item.started/updated/completed`*
→ `turn.completed`(토큰 사용량 포함). item 타입: `agent_message`(버전에 따라
`assistant_message`), `reasoning`, `command_execution`, `mcp_tool_call`, `file_change`,
`web_search` — **구현 시 설치 버전의 실제 출력으로 타입명을 확정할 것.**

```python
class JsonlStageMapper:
    def handle(self, ev: dict):
        et = ev.get("type", "")
        if et == "item.completed":
            item = ev["item"]
            match item.get("type") or item.get("item_type"):
                case "mcp_tool_call":
                    self.map_tool(item)                 # SQL 패턴 판정 (04 문서 §4 규칙 재사용)
                    self.bus.tool_call(self.sid, item.get("tool"), item)
                case "agent_message" | "assistant_message":
                    self.scan_markers(item.get("text", ""))   # <<stage:N>> — 주 채널
                    self.bus.narrative(self.sid, item.get("text", ""))
                case "reasoning":
                    pass                                # 표시하지 않음
        elif et == "turn.completed":
            self.accumulate_usage(ev.get("usage", {}))
```

- A안과 판정 로직(`EXPLAIN ANALYZE`→1/6, `EXCEPT`→5 등)은 공유 모듈로 재사용한다 —
  차이는 입력이 훅 컨텍스트냐 JSONL item이냐뿐.
- `agent_message`는 완료 단위로만 도착하므로 **narrative가 A안처럼 토큰 단위로 흐르지
  않는다** — UI 피드가 문단 단위로 갱신됨 (수용 가능한 UX 차이로 명시).

## 4. 취소·타임아웃·예산

| 항목 | 구현 |
|---|---|
| 사용자 취소 | `proc.send_signal(SIGINT)` → 유예 후 `proc.kill()` |
| 벽시계 타임아웃 | `asyncio.wait_for` + kill |
| 예산 | **내장 예산 옵션 없음** — `turn.completed`의 usage 누적을 관찰해 상한 초과 시 SIGINT (사후 차단임을 한계로 명시) |
| 이어가기 | `codex exec resume <thread>` — 끊긴 세션 재개에 활용 가능 (v0.3 검토) |
| Trino 측 취소 | mcp-trino 타임아웃 경로 동일 |

## 5. 배포 특이사항

- 이미지에 **Codex CLI(Rust 바이너리) + mcp-trino + 스킬 디렉터리** 필요. Node 불필요 —
  A안보다 이미지가 가벼움.
- 인증: `OPENAI_API_KEY` Secret (또는 ChatGPT 플랜 인증 — 서버 환경에서는 API 키 방식 권장).
- `.codex/config.toml`은 신뢰된 프로젝트에서만 로드됨 — 컨테이너 내 trust 설정 필요.
- `TRINO_SOURCE=trino-tuner-codex`로 Trino 측에서 엔진 구분 (03 문서 §5-4 계측과 정합).

## 6. 장단점과 리스크

**장점**
- 교차 검증: 같은 스킬·같은 벤치를 다른 모델로 — 스킬 품질 신호와 성능 비교 데이터 확보.
- 프로세스 경계가 명확해 격리·리소스 제한(cgroup)이 쉬움. 이미지 경량.
- `--output-schema`로 최종 리포트를 정형 JSON으로 강제 가능.

**단점·리스크**
- **in-process 훅 없음** → 스테이지 판정이 마커+JSONL 패턴 매칭에 전적으로 의존.
  마커 누락 시 타임라인 품질 저하 — 04 문서 결정 2의 이중화가 여기서는 단일화됨.
- 예산 강제 수단 부재 (사후 관찰뿐).
- 툴 제한 수단이 A안의 `allowed_tools`만큼 세밀하지 않음 — sandbox 플래그 수준.
- `--json` 이벤트 스키마가 실험적 표기 — 버전 업그레이드 시 파서 회귀 테스트 필수.

## 7. MVP 체크리스트

- [ ] `codex exec --json` 1회 실행 → 설치 버전의 실제 item 타입명 확정, 파서 픽스처 저장
- [ ] 마커 출력 준수율 측정 (10세션) — 90% 미만이면 SKILL.md 마커 지시 문구 보강
- [ ] SIGINT → mcp-trino → Trino 쿼리 취소 전파 확인
- [ ] usage 누적 기반 예산 차단 동작 확인
- [ ] 동일 벤치 세트로 A안과 speedup·등가성 통과율 비교 (03 문서 §5-3 하네스)

---

참고: [Codex exec JSONL 이벤트](https://takopi.dev/reference/runners/codex/exec-json-cheatsheet/) · [비대화형 모드 문서](https://docs.onlinetool.cc/codex/docs/exec.html) · [exec 플래그 실험 기록](https://gist.github.com/alexfazio/359c17d84cb6a5af12bac88fa1db9770)
