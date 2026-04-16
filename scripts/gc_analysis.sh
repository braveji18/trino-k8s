
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

