# 4단계 튜닝 — JVM 파라미터 최적화

[docs/03-resource-tuning-plan.md](03-resource-tuning-plan.md)의 **4. JVM 튜닝** 단계에
해당하는 실제 적용 가이드. 2단계(노드 용량)에서 워커 heap을 64G로 확장한 상태에서,
JVM 플래그만 조정하여 GC 효율/안정성을 개선한다.

---

## 1. 현재 상태 (tune-2 Step 2 완료 후)

### Worker JVM 설정

```yaml
# helm/values.yaml — worker 섹션
jvm:
  maxHeapSize: "64G"
  gcMethod:
    type: "UseG1GC"
    g1:
      heapRegionSize: "32M"
additionalJVMConfig:
  - "-javaagent:/opt/jmx-exporter/jmx_prometheus_javaagent.jar=5556:/etc/jmx-exporter/config.yaml"
```

### Coordinator JVM 설정

```yaml
jvm:
  maxHeapSize: "8G"
  gcMethod:
    type: "UseG1GC"
    g1:
      heapRegionSize: "32M"
additionalJVMConfig:
  - "-javaagent:/opt/jmx-exporter/jmx_prometheus_javaagent.jar=5556:/etc/jmx-exporter/config.yaml"
```

### 문제점

현재 `additionalJVMConfig`에는 JMX Exporter javaagent만 들어가 있고, Trino 공식 권장
JVM 플래그가 **하나도 설정되어 있지 않다**. Trino Helm chart의 기본값에 일부가 포함되어
있을 수 있지만, 명시적으로 제어하지 않으면:

- 컨테이너 메모리 limit을 JVM이 인식 못 할 수 있음 (`UseContainerSupport` 미보장)
- OOM 시 heap dump 없이 죽어 원인 분석 불가
- OOM 시 JVM이 반쯤 살아서 zombie 상태로 남을 수 있음 (`ExitOnOutOfMemoryError` 없음)
- Code cache가 기본값(240MB)에서 부족해 JIT deopt 발생 가능
- GC 로그가 없어 pause 원인 분석 불가

---

## 2. Trino 공식 권장 기반 JVM 플래그

Trino 480의 `etc/jvm.config` 기본값 + 운영 환경 권장사항을 조합.
**coordinator와 worker에 동일하게 적용.**

### 2-1. 필수 플래그 (이번 단계에서 적용)

| 플래그 | 목적 | 비고 |
|---|---|---|
| `-XX:+UseContainerSupport` | JVM이 cgroup memory limit을 인식 | Java 10+ 기본 true이나 명시 권장 |
| `-XX:+ExplicitGCInvokesConcurrent` | `System.gc()` 호출 시 STW 대신 concurrent GC | Trino 내부에서 간헐적 호출 있음 |
| `-XX:+ExitOnOutOfMemoryError` | OOM 시 JVM 즉시 종료 → k8s가 재시작 | zombie 방지, 필수 |
| `-XX:+HeapDumpOnOutOfMemoryError` | OOM 직전 heap dump 생성 | 원인 분석용 |
| `-XX:HeapDumpPath=/tmp/heapdump` | dump 경로 | emptyDir이므로 pod 재시작 시 소실 — 필요하면 PV로 변경 |
| `-XX:ErrorFile=/tmp/hs_err_%p.log` | JVM crash 시 에러 파일 | 디버깅용 |
| `-XX:ReservedCodeCacheSize=512M` | JIT 컴파일 코드 캐시 | 기본 240MB는 대형 쿼리에서 부족할 수 있음 |
| `-Djdk.attach.allowAttachSelf=true` | jcmd/jmap 등 진단 도구 사용 허용 | 튜닝 중 필수 |
| `-Dfile.encoding=UTF-8` | 문자 인코딩 통일 | 카탈로그 메타데이터 깨짐 방지 |
| `-XX:G1HeapRegionSize=32M` | G1 region 크기 | 64G ÷ 32M = 2048 regions (권장 범위 내) |

### 2-2. GC 로깅 (튜닝 기간 중 임시 활성화)

| 플래그 | 목적 |
|---|---|
| `-Xlog:gc*:file=/tmp/gc.log:time,uptime,level,tags:filecount=5,filesize=100M` | GC 이벤트 상세 로깅 |

GC 로그에서 확인할 것:
- **Full GC 발생 여부** — 발생하면 heap 부족 or region 파편화
- **G1 mixed GC pause > 200ms** — `G1MaxNewSizePercent` 조정 고려
- **To-space exhausted** — region 부족, `G1HeapRegionSize` 증가 필요
- **Humongous allocation** — 32M 이상 단일 객체 할당 빈도

튜닝 안정화 후 GC 로깅은 제거하거나 `gc:file=...` (상세도 낮춤)으로 변경.

### 2-3. 선택적 고급 플래그 (Step 2에서 검토)

벤치마크 결과에 따라 추가를 검토. 이번 단계에서는 **적용하지 않는다**.

| 플래그 | 목적 | 적용 조건 |
|---|---|---|
| `-XX:G1HeapRegionSize=64M` | region 수 절반(1024)으로 줄여 관리 오버헤드 감소 | Humongous allocation이 빈번할 때 |
| `-XX:InitiatingHeapOccupancyPercent=30` | concurrent GC를 더 일찍 시작 | heap 사용률 피크가 70%+ |
| `-XX:G1ReservePercent=15` | To-space reserve 확대 | To-space exhausted 발생 시 |
| `-XX:MaxGCPauseMillis=100` | GC pause 목표 단축 | p99 latency가 중요한 워크로드 |
| `-XX:+UseNUMA` | NUMA 아키텍처 최적화 | qcs05/06이 multi-socket이면 |
| `-XX:+AlwaysPreTouch` | JVM 시작 시 전체 heap을 미리 할당 | 첫 쿼리 cold-start 개선, 시작 시간 증가 |

---

## 3. [helm/values.yaml](../helm/values.yaml) 변경 diff

coordinator와 worker의 `additionalJVMConfig`에 플래그를 추가. 기존 JMX Exporter
javaagent는 유지.

### Step 1 — 필수 플래그 + GC 로깅

```yaml
coordinator:
  additionalJVMConfig:
    - "-javaagent:/opt/jmx-exporter/jmx_prometheus_javaagent.jar=5556:/etc/jmx-exporter/config.yaml"
    # tune-4 Step 1: JVM 안정성 + 진단 플래그
    - "-XX:+UseContainerSupport"
    - "-XX:+ExplicitGCInvokesConcurrent"
    - "-XX:+ExitOnOutOfMemoryError"
    - "-XX:+HeapDumpOnOutOfMemoryError"
    - "-XX:HeapDumpPath=/tmp/heapdump"
    - "-XX:ErrorFile=/tmp/hs_err_%p.log"
    - "-XX:ReservedCodeCacheSize=512M"
    - "-Djdk.attach.allowAttachSelf=true"
    - "-Dfile.encoding=UTF-8"
    # GC 로깅 (튜닝 중 임시)
    - "-Xlog:gc*:file=/tmp/gc.log:time,uptime,level,tags:filecount=5,filesize=100M"

worker:
  additionalJVMConfig:
    - "-javaagent:/opt/jmx-exporter/jmx_prometheus_javaagent.jar=5556:/etc/jmx-exporter/config.yaml"
    # tune-4 Step 1: JVM 안정성 + 진단 플래그
    - "-XX:+UseContainerSupport"
    - "-XX:+ExplicitGCInvokesConcurrent"
    - "-XX:+ExitOnOutOfMemoryError"
    - "-XX:+HeapDumpOnOutOfMemoryError"
    - "-XX:HeapDumpPath=/tmp/heapdump"
    - "-XX:ErrorFile=/tmp/hs_err_%p.log"
    - "-XX:ReservedCodeCacheSize=512M"
    - "-Djdk.attach.allowAttachSelf=true"
    - "-Dfile.encoding=UTF-8"
    # GC 로깅 (튜닝 중 임시)
    - "-Xlog:gc*:file=/tmp/gc.log:time,uptime,level,tags:filecount=5,filesize=100M"
```

### Step 2 — 고급 플래그 (Step 1 결과에 따라 선택 적용)

Step 1 벤치마크에서 GC 관련 문제가 관찰되면, 해당 문제에 맞는 플래그만 추가:

```yaml
    # 아래는 GC 로그 분석 결과에 따라 선택 적용
    - "-XX:InitiatingHeapOccupancyPercent=30"   # heap 사용률 피크 > 70%일 때
    - "-XX:G1ReservePercent=15"                 # To-space exhausted 발생 시
    - "-XX:+AlwaysPreTouch"                     # cold-start latency 개선
```

---

## 4. 적용 & 검증 순서

```bash
NS=user-braveji

# 1) helm upgrade
helm upgrade --install my-trino my-trino/trino -n $NS -f helm/values.yaml --wait --timeout 10m

# 2) JVM 플래그가 실제로 반영됐는지 확인
POD=$(kubectl -n $NS get pod -l app.kubernetes.io/component=worker -o name | head -1)
kubectl -n $NS exec "$POD" -c trino-worker -- \
  sh -c 'jcmd 1 VM.flags | tr " " "\n" | grep -E "ContainerSupport|ExitOnOutOfMemory|CodeCache|HeapDump"'

# coordinator도 확인
kubectl -n $NS exec deploy/my-trino-trino-coordinator -c trino-coordinator -- \
  sh -c 'jcmd 1 VM.flags | tr " " "\n" | grep -E "ContainerSupport|ExitOnOutOfMemory|CodeCache|HeapDump"'

# 3) GC 로그가 쌓이고 있는지 확인
kubectl -n $NS exec "$POD" -c trino-worker -- ls -lh /tmp/gc.log

# 4) 벤치마크 3회 실행 (tune-2와 동일 쿼리)
tq() { kubectl -n "$NS" exec deploy/my-trino-trino-coordinator -- trino --execute "$1"; }
tq "SELECT count(*) FROM tpch.sf1.lineitem" >/dev/null  # 워밍업

START_TS=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
for i in 1 2 3; do
  echo "=== Q3 run $i ==="
  start=$(date +%s)
  tq "
    SELECT l.returnflag, sum(l.extendedprice*(1-l.discount))
    FROM tpch.sf1.lineitem l
    JOIN tpch.sf1.orders   o ON l.orderkey = o.orderkey
    WHERE o.orderdate < DATE '1995-01-01'
    GROUP BY l.returnflag
  "
  end=$(date +%s)
  echo "running(초): $((end - start))"
  sleep 5
done
END_TS=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
echo "tune-4 step1: start=$START_TS end=$END_TS"
```

### GC 로그 분석

벤치마크 완료 후 GC 로그를 로컬로 가져와서 분석.
아래 스크립트는 **macOS (BSD grep)** 호환. Linux에서도 동작.

#### 1) 로그 추출

```bash
NS=user-braveji
for POD in $(kubectl -n $NS get pod -l app.kubernetes.io/component=worker -o name); do
  NAME=$(echo "$POD" | cut -d/ -f2)
  kubectl -n $NS exec "$POD" -c trino-worker -- cat /tmp/gc.log > "gc-${NAME}.log"
  echo "saved: gc-${NAME}.log"
done
```

#### 2) 전체 요약 분석

```bash
for f in gc-my-trino-trino-worker-*.log; do
  NAME=$(basename "$f" .log)
  echo "============================================"
  echo "=== $NAME ==="
  echo "============================================"

  # 위험 이벤트 카운트
  FULL_GC=$(grep -c 'Full GC\|Pause Full' "$f" 2>/dev/null || echo 0)
  TO_SPACE=$(grep -c 'to-space exhausted\|To-space Exhausted' "$f" 2>/dev/null || echo 0)
  HUMONGOUS=$(grep -c -i 'humongous' "$f" 2>/dev/null || echo 0)
  CMA=$(grep -c 'Concurrent Mark Abort\|concurrent-mark-abort' "$f" 2>/dev/null || echo 0)
  echo "Full GC: $FULL_GC"
  echo "To-space exhausted: $TO_SPACE"
  echo "Humongous events: $HUMONGOUS"
  echo "Concurrent Mark Abort: $CMA"

  # Pause time 통계
  echo ""
  echo "--- Pause time 통계 ---"
  grep -E '^\[.*\]\[info\]\[gc ' "$f" | grep 'Pause' \
    | sed -E 's/.*\) ([0-9]+\.[0-9]+)ms$/\1/' | awk '
    BEGIN { cnt=0; sum=0; max=0; over100=0; over200=0; over500=0 }
    /^[0-9]/ {
      cnt++; sum+=$1;
      if($1>max) max=$1;
      if($1>100) over100++;
      if($1>200) over200++;
      if($1>500) over500++;
    }
    END {
      if(cnt>0) {
        printf "  Total pauses: %d\n", cnt
        printf "  Avg: %.1f ms\n", sum/cnt
        printf "  Max: %.1f ms\n", max
        printf "  > 100ms: %d\n", over100
        printf "  > 200ms: %d\n", over200
        printf "  > 500ms: %d\n", over500
      } else {
        print "  No pause data found"
      }
    }'

  # Humongous regions 추이 (마지막 10개 GC)
  echo ""
  echo "--- Humongous regions (마지막 10개 GC) ---"
  grep 'Humongous regions:' "$f" | tail -10 | sed -E 's/.*Humongous regions: /  /'

  # Heap 사용량 추이 (마지막 10개 GC)
  echo ""
  echo "--- Heap 사용량 (마지막 10개 GC) ---"
  grep -E '^\[.*\]\[info\]\[gc ' "$f" | grep 'Pause' | tail -10 \
    | sed -E 's/.*\) ([0-9]+M->[0-9]+M\([0-9]+M\) [0-9.]+ms)/  \1/'

  echo ""
done
```

#### 3) 상세 분석 (필요 시)

```bash
for f in gc-my-trino-trino-worker-*.log; do
  NAME=$(basename "$f" .log)
  echo "--- $NAME ---"

  # Humongous regions 최대값
  grep 'Humongous regions:' "$f" \
    | sed -E 's/.*Humongous regions: ([0-9]+)->([0-9]+)/\2/' \
    | sort -n | tail -1 | xargs -I{} echo "  Max humongous regions (after GC): {}"

  # Humongous > 0인 GC 비율
  TOTAL=$(grep -c 'Humongous regions:' "$f")
  NONZERO=$(grep 'Humongous regions:' "$f" \
    | sed -E 's/.*->([0-9]+)/\1/' | awk '$1>0{c++}END{print c+0}')
  echo "  GCs with humongous > 0: $NONZERO / $TOTAL"

  # Concurrent Marking 횟수
  CM=$(grep -c 'Concurrent Mark' "$f" 2>/dev/null || echo 0)
  echo "  Concurrent mark events: $CM"

  # Peak heap (before GC) vs max capacity
  MAX_BEFORE=$(grep -E '^\[.*\]\[info\]\[gc ' "$f" | grep 'Pause' \
    | sed -E 's/.*\) ([0-9]+)M->.*/\1/' | sort -n | tail -1)
  MAX_CAPACITY=$(grep 'Heap Max Capacity' "$f" | sed -E 's/.*: (.+)/\1/')
  echo "  Peak before-GC: ${MAX_BEFORE}M, Max capacity: $MAX_CAPACITY"

  echo ""
done
```

#### 4) 분석 결과 판독 기준

| 지표 | 정상 | 주의 | 위험 |
|---|---|---|---|
| Full GC | 0 | 1~2 (warm-up 중) | 3+ (heap 부족) |
| To-space exhausted | 0 | — | 1+ (G1ReservePercent 조정) |
| Concurrent Mark Abort | 0 | — | 1+ (IHOP 조정) |
| Avg pause | < 10ms | 10~50ms | > 50ms |
| Max pause | < 100ms | 100~500ms | > 500ms |
| Peak heap / capacity | < 50% | 50~80% | > 80% (확장 필요) |
| Humongous regions | 고정 (변동 없음) | 증가 추세 | GC마다 급증 (regionSize 조정) |

### GC 로그에서 보이는 패턴별 대응

| 패턴 | 의미 | 대응 |
|---|---|---|
| `Full GC (Allocation Failure)` | Old gen이 가득 참 | heap 부족 → 2단계로 돌아가 메모리 확장 검토 |
| `To-space exhausted` | Survivor/Eden에서 Old로 승격 시 공간 부족 | `-XX:G1ReservePercent=15` 추가 |
| `Humongous allocation` 빈번 | 32M 이상 객체가 자주 생성 | `-XX:G1HeapRegionSize=64M` 검토 |
| `GC pause > 500ms` | STW가 길어 쿼리 latency 저하 | `-XX:MaxGCPauseMillis=200`, IHOP 조정 |
| `Concurrent Mark Abort` | Marking이 할당 속도를 못 따라감 | `-XX:InitiatingHeapOccupancyPercent=30` |
| 이상 없음 (pause < 200ms, Full GC 0) | G1이 잘 동작 중 | 고급 플래그 불필요, Step 2 스킵 |

---

## 5. 기대 변화

tune-2 (Step 2, 64G) 대비 tune-4 에서 기대하는 변화:

- **wall-clock latency**: JVM 플래그 자체로 큰 차이는 없을 수 있음. 주 목적은 안정성.
- **GC pause 안정화**: `ExplicitGCInvokesConcurrent`로 간헐적 STW full GC 제거.
- **OOM 시 빠른 복구**: `ExitOnOutOfMemoryError`로 zombie 방지 → k8s가 즉시 재시작.
- **Code cache 안정**: `ReservedCodeCacheSize=512M`으로 JIT deopt 방지 → 장시간 운영 시
  latency drift 제거.
- **진단 가능성 확보**: heap dump + GC 로그 + jcmd 접근 → 이후 단계에서 문제 발생 시
  원인 분석 시간 대폭 단축.

수치 기록은 [docs/04-tuning-results.md](04-tuning-results.md)의 `tune-4 (JVM)` 컬럼에 누적.

---

## 6. 롤백 규칙

- JVM 플래그 추가 후 pod가 `CrashLoopBackOff`로 빠지면 **플래그 오타** 가능성이 높음.
  `kubectl logs` 로 JVM 에러 메시지 확인 후 해당 플래그만 제거.
- 벤치마크에서 tune-2보다 **latency가 나빠지면**: GC 로그를 먼저 분석. `AlwaysPreTouch`
  등 메모리 사전할당 플래그가 원인일 수 있음 → 해당 플래그만 제거.
- 문제 없으면 GC 로깅은 안정화 확인 후 제거하거나 축소:
  ```yaml
  # 상세 로깅 → 경량 로깅으로 전환
  - "-Xlog:gc:file=/tmp/gc.log:time:filecount=3,filesize=50M"
  ```

---

## 7. 다음 단계

tune-4 결과에 따라:

| 결과 | 다음 행동 |
|---|---|
| GC 이상 없음, latency 안정 | GC 로깅 경량화 후 **5. 디스크(spill & exchange)** 로 진행 |
| Full GC / To-space exhausted 발견 | Step 2 고급 플래그 적용 후 재측정 |
| GC는 정상이나 latency 개선 미미 | JVM은 안정화 완료, **7. 커넥터 레벨 튜닝**으로 진행 |
| heap dump가 필요한 OOM 발생 | `/tmp/heapdump`에서 dump 추출 후 원인 분석 → 2단계(메모리) 재검토 |
