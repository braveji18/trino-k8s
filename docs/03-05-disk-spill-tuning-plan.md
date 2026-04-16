# 5단계 튜닝 — 디스크 (Spill & Exchange)

[docs/03-resource-tuning-plan.md](03-resource-tuning-plan.md)의 **5. 디스크/셔플** 단계에
해당하는 실제 적용 가이드. 4단계(JVM 튜닝)까지 완료 후 SF10+ 스케일 테스트를 앞두고,
대용량 쿼리가 메모리를 넘어서더라도 **spill로 완주**할 수 있는 환경을 구성한다.

---

## 1. 현재 상태

### 디스크 구성

| 항목 | 현재 값 | 문제점 |
|---|---|---|
| `/data/trino` 마운트 | **없음 (container overlay)** | 노드 root FS(891G 중 734G 사용, 83%)에 직접 쓰기 |
| spill 설정 | **꺼져 있음** | `maxMemoryPerNode=42GB` 초과 시 쿼리 실패 |
| exchange 경로 | `/data/trino/exchange` (overlay) | spill과 같은 문제 |
| StorageClass | `qks-ceph-block` (default), `qks-ceph-cephfs`, `qks-nfs-csi` | 네트워크 스토리지 — spill에는 느림 |

### 핵심 문제

1. **spill이 꺼져 있어** `maxMemoryPerNode`를 초과하는 쿼리는 무조건 실패.
   SF10 Q3(lineitem 60M rows join)에서 peak memory가 42GB를 넘기면 `EXCEEDED_LOCAL_MEMORY_LIMIT`.
2. `/data/trino`가 container writable layer에 있어 **노드 root FS를 잠식**. overlay 위에
   대량 I/O가 발생하면 overlay 성능 저하 + 노드 전체가 느려질 수 있음.
3. 가용 StorageClass가 모두 **네트워크 스토리지**(Ceph RBD, CephFS, NFS). spill은 random
   I/O가 많아 네트워크 latency에 민감 — local disk 대비 수배 느림.

---

## 2. 전략 선택

### 2-1. spill 경로 옵션 비교

| 옵션 | 장점 | 단점 | 적합 시나리오 |
|---|---|---|---|
| **A. emptyDir** | 구성 간단, PV 불필요 | 노드 root FS 사용, sizeLimit 초과 시 eviction | POC/테스트 (이번 단계 권장) |
| **B. emptyDir + medium: Memory** | RAM 기반, 극히 빠름 | container limit에 합산됨, 용량 제한적 | heap 여유가 클 때 소량 spill |
| **C. hostPath** | local disk 직접 사용, 빠름 | 노드별 디렉토리 선생성 필요, 보안 정책 이슈 | 노드에 NVMe/SSD 별도 파티션이 있을 때 |
| **D. PVC (Ceph RBD)** | k8s native, 자동 프로비저닝 | 네트워크 스토리지 latency | 운영 단계 안정성 우선 |

### 2-2. 이번 단계 결정: **A. emptyDir** (sizeLimit 설정)

이유:
- qcs05/06 노드 root FS에 ~157GB 여유가 있음 (overlay 891G 중 734G 사용)
- spill은 쿼리 실행 중에만 발생하고 끝나면 삭제 → 영구 스토리지 불필요
- emptyDir의 sizeLimit을 설정하면 노드 root FS를 보호할 수 있음
- PV 프로비저닝 없이 helm values만으로 완결 → 복잡도 최소
- 성능이 부족하면 이후 hostPath 또는 local PV로 교체 (Step 2)

---

## 3. [helm/values.yaml](../helm/values.yaml) 변경

### Step 1 — spill 활성화 + emptyDir

```yaml
# additionalConfigProperties에 spill 설정 추가
additionalConfigProperties:
  - http-server.process-forwarded=true
  # tune-5: spill 활성화
  - spill-enabled=true
  - spiller-spill-path=/data/trino/spill
  - spiller-max-used-space-threshold=0.8
  - max-spill-per-node=100GB
  - query-max-spill-per-node=50GB

worker:
  # /data/trino 용 emptyDir 추가
  additionalVolumes:
    - name: jmx-exporter-config         # 기존 유지
      configMap:
        name: trino-jmx-exporter-config
    - name: data-trino                   # 신규
      emptyDir:
        sizeLimit: 100Gi
  additionalVolumeMounts:
    - name: jmx-exporter-config          # 기존 유지
      mountPath: /etc/jmx-exporter
    - name: data-trino                   # 신규
      mountPath: /data/trino

coordinator:
  # coordinator도 exchange 경로 확보 (spill은 worker만)
  additionalVolumes:
    - name: jmx-exporter-config
      configMap:
        name: trino-jmx-exporter-config
    - name: data-trino
      emptyDir:
        sizeLimit: 20Gi
  additionalVolumeMounts:
    - name: jmx-exporter-config
      mountPath: /etc/jmx-exporter
    - name: data-trino
      mountPath: /data/trino
```

**중요**: 현재 values.yaml에서 `additionalVolumes`/`additionalVolumeMounts`는 YAML anchor
(`*jmxExporterVolumes`)로 참조 중. anchor는 단일 값만 반환하므로, spill용 volume을 추가하려면
**anchor를 풀고 직접 나열**해야 한다. 아래 4절의 실제 diff 참고.

### Spill 설정 파라미터 설명

| 파라미터 | 값 | 설명 |
|---|---|---|
| `spill-enabled` | `true` | spill 기능 활성화 |
| `spiller-spill-path` | `/data/trino/spill` | spill 데이터 저장 경로 |
| `spiller-max-used-space-threshold` | `0.8` | 경로 디스크 사용률 80% 초과 시 spill 중단 |
| `max-spill-per-node` | `100GB` | 노드당 최대 spill 총량 (emptyDir sizeLimit과 맞춤) |
| `query-max-spill-per-node` | `50GB` | 쿼리 하나가 노드에서 쓸 수 있는 최대 spill |

### Exchange manager는 현재 유지

```yaml
server:
  exchangeManager:
    name: "filesystem"
    baseDir: "/data/trino/exchange"
```

emptyDir에 `/data/trino`를 마운트하면 exchange 경로도 자동으로 emptyDir 위에 올라가므로
별도 설정 불필요. Fault-tolerant execution은 아직 사용하지 않으므로 exchange manager
자체는 POC 단계에서 보류.

---

## 4. 실제 values.yaml diff

YAML anchor(`*jmxExporterVolumes`)를 풀고 직접 나열하는 변경이 필요하므로,
정확한 변경 범위를 명시한다.

**변경 1**: `additionalConfigProperties`에 spill 설정 추가

```yaml
# before
additionalConfigProperties:
  - http-server.process-forwarded=true

# after
additionalConfigProperties:
  - http-server.process-forwarded=true
  # tune-5: spill 활성화
  - spill-enabled=true
  - spiller-spill-path=/data/trino/spill
  - spiller-max-used-space-threshold=0.8
  - max-spill-per-node=100GB
  - query-max-spill-per-node=50GB
```

**변경 2**: coordinator의 volumes/mounts를 anchor에서 직접 나열로 교체 + data-trino 추가

```yaml
# before
  additionalVolumes: *jmxExporterVolumes
  additionalVolumeMounts: *jmxExporterVolumeMounts

# after
  additionalVolumes:
    - name: jmx-exporter-config
      configMap:
        name: trino-jmx-exporter-config
    - name: data-trino
      emptyDir:
        sizeLimit: 20Gi
  additionalVolumeMounts:
    - name: jmx-exporter-config
      mountPath: /etc/jmx-exporter
    - name: data-trino
      mountPath: /data/trino
```

**변경 3**: worker의 volumes/mounts도 동일하게 교체 + data-trino 추가

```yaml
# before
  additionalVolumes: *jmxExporterVolumes
  additionalVolumeMounts: *jmxExporterVolumeMounts

# after
  additionalVolumes:
    - name: jmx-exporter-config
      configMap:
        name: trino-jmx-exporter-config
    - name: data-trino
      emptyDir:
        sizeLimit: 100Gi
  additionalVolumeMounts:
    - name: jmx-exporter-config
      mountPath: /etc/jmx-exporter
    - name: data-trino
      mountPath: /data/trino
```

YAML anchor 정의(`_jmxExporterVolumes`, `_jmxExporterVolumeMounts`)는 더 이상
참조되지 않으므로 제거해도 되지만, 다른 곳에서 참조하지 않는지 확인 후 정리.

---

## 5. 적용 & 검증 순서

```bash
NS=user-braveji

# 1) helm upgrade
helm upgrade --install my-trino my-trino/trino -n $NS -f helm/values.yaml --wait --timeout 10m

# 2) /data/trino가 emptyDir로 마운트됐는지 확인
POD=$(kubectl -n $NS get pod -l app.kubernetes.io/component=worker -o name | head -1)
kubectl -n $NS exec "$POD" -c trino-worker -- df -h /data/trino
# → overlay가 아닌 tmpfs 또는 별도 mount로 보여야 함

# 3) spill 경로 존재 확인
kubectl -n $NS exec "$POD" -c trino-worker -- ls -la /data/trino/
# → spill/ 디렉토리가 쿼리 실행 전에는 없을 수 있음 (쿼리 시 자동 생성)

# 4) spill 설정이 config.properties에 반영됐는지 확인
kubectl -n $NS exec "$POD" -c trino-worker -- cat /etc/trino/config.properties | grep spill

# 5) coordinator에서도 확인
kubectl -n $NS exec deploy/my-trino-trino-coordinator -c trino-coordinator -- \
  cat /etc/trino/config.properties | grep spill
```

---

## 6. spill 동작 검증 — SF10 벤치마크

spill이 실제로 작동하는지 확인하려면 `maxMemoryPerNode`(42GB)를 넘는 쿼리를 돌려야 함.
SF10의 lineitem(60M rows) + orders(15M rows) join이 후보.

### 6-1. 벤치마크 실행

```bash
tq() { kubectl -n "$NS" exec deploy/my-trino-trino-coordinator -- trino --execute "$1"; }

# 워밍업
tq "SELECT count(*) FROM tpch.sf10.lineitem" >/dev/null

# SF10 Q3 (spill 유도)
START_TS=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
for i in 1 2 3; do
  echo "=== SF10 Q3 run $i ==="
  start=$(date +%s)
  tq "
    SELECT l.returnflag, sum(l.extendedprice*(1-l.discount))
    FROM tpch.sf10.lineitem l
    JOIN tpch.sf10.orders   o ON l.orderkey = o.orderkey
    WHERE o.orderdate < DATE '1995-01-01'
    GROUP BY l.returnflag
  "
  end=$(date +%s)
  echo "running(초): $((end - start))"
  sleep 10
done
END_TS=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
echo "tune-5 sf10: start=$START_TS end=$END_TS"
```

### 6-2. spill 발생 확인

```bash
# Prometheus에서 spill bytes 확인
# Grafana "Spill Bytes" 패널 또는:
# rate(trino_spiller_totalspilledbytes[5m]) > 0 이면 spill 발생

# 워커 pod에서 spill 파일 확인 (쿼리 실행 중에만 존재)
kubectl -n $NS exec "$POD" -c trino-worker -- ls -la /data/trino/spill/ 2>/dev/null
kubectl -n $NS exec "$POD" -c trino-worker -- du -sh /data/trino/spill/ 2>/dev/null

# emptyDir 사용량
kubectl -n $NS exec "$POD" -c trino-worker -- df -h /data/trino
```

### 6-3. 결과 해석

| 결과 | 의미 | 다음 행동 |
|---|---|---|
| spill 0, 쿼리 완주 | SF10이 42GB 안에 들어감 | SF100으로 스케일 업 |
| spill 발생, 쿼리 완주 | spill이 정상 동작 | spill 경로 I/O 성능 확인 (느리면 Step 2) |
| spill 발생, 쿼리 매우 느림 | emptyDir(overlay) I/O가 병목 | Step 2 — hostPath/PVC 검토 |
| `EXCEEDED_LOCAL_MEMORY_LIMIT` | spill 설정이 안 먹힘 | config.properties 확인, helm template 검증 |
| `EXCEEDED_SPILL_LIMIT` | 50GB/쿼리 상한 초과 | `query-max-spill-per-node` 올림 |

---

## 7. 기대 변화

tune-4 대비 tune-5 에서:

- **SF1 벤치마크**: 변화 없음 (spill이 발생하지 않는 크기)
- **SF10 벤치마크**: spill 없이 통과하면 → 메모리 여유 확인. spill 발생하면 → wall-clock
  증가하지만 **쿼리가 실패하지 않고 완주**하는 것이 핵심 성과.
- **Grafana 관찰**: `rate(trino_spiller_totalspilledbytes[5m])` 패널에서 spill 발생 시점과
  양을 시각적으로 확인 가능.

수치 기록은 [docs/04-tuning-results.md](04-tuning-results.md)의 `tune-5 (spill)` 컬럼에 누적.

---

## 8. Step 2 — hostPath / PVC 전환 (선택, 성능 부족 시)

emptyDir의 I/O가 spill 병목으로 확인되면 다음 옵션을 검토.

### 8-1. hostPath (노드에 별도 파티션이 있을 때)

```yaml
worker:
  additionalVolumes:
    - name: jmx-exporter-config
      configMap:
        name: trino-jmx-exporter-config
    - name: data-trino
      hostPath:
        path: /var/lib/trino-data
        type: DirectoryOrCreate
```

주의:
- qcs05/06에 `/var/lib/trino-data` 디렉토리가 자동 생성됨 (`DirectoryOrCreate`)
- 노드 root FS가 아닌 별도 NVMe/SSD 파티션에 마운트하는 것이 이상적
- 보안 정책(PodSecurityPolicy/Standards)에서 hostPath를 허용하는지 확인 필요
- **권한 문제**: `DirectoryOrCreate`는 root 소유로 디렉토리를 생성하지만, Trino 컨테이너는
  `trino` 유저(non-root)로 실행됨 → `mkdir /data/trino/var: permission denied`로 실패.
  해결하려면 initContainers로 `chown trino:trino /var/lib/trino-data`를 실행해야 하지만,
  Trino Helm chart에서 initContainers 주입이 어려워 **현실적으로 사용 불가**.
  emptyDir(옵션 A)이 권한 문제 없이 동작하므로 이쪽을 권장.

### 8-2. PVC with Ceph RBD

```yaml
worker:
  additionalVolumes:
    - name: data-trino
      persistentVolumeClaim:
        claimName: trino-worker-data  # 사전 생성 필요
```

PVC를 워커 수만큼 만들어야 하므로 StatefulSet 패턴이 더 자연스럽지만, Trino Helm chart의
worker는 Deployment라 PVC 이름 충돌이 생김. 동적 프로비저닝이 필요하면 별도 PVC 생성
스크립트 또는 chart fork가 필요.

**권한 문제 (hostPath와 동일)**: CephFS PVC도 root 소유로 마운트되어 Trino 컨테이너
(`trino` 유저, non-root)가 `/data/trino/var/` 디렉토리를 생성할 수 없음
(`mkdir: permission denied`). Trino Helm chart가 initContainers 주입을 지원하지 않아
`chown`으로 소유자를 바꿀 수 없으므로, **hostPath/PVC 모두 현재 chart에서는 사용 불가**.
emptyDir(옵션 A)만 동작함.

---

## 9. 롤백 규칙

- `spill-enabled=true` 추가 후 pod가 시작되지 않으면: config.properties 파라미터 이름 오타
  가능성. `kubectl logs`로 Trino 시작 에러 확인.
- emptyDir sizeLimit(100Gi) 초과 시 kubelet이 pod를 **evict** (OOMKilled가 아니라 Evicted
  상태). `kubectl describe pod`에서 `Evicted` 이유 확인 → sizeLimit 조정 또는 spill limit 축소.
- spill 성능이 너무 느려서 쿼리 타임아웃 → `query-max-spill-per-node`을 낮춰서 spill 양을
  제한하고, 쿼리 실패를 허용하는 편이 나을 수 있음.
- 롤백: `additionalConfigProperties`에서 spill 관련 5줄 제거 + data-trino volume 제거.

---

## 10. 다음 단계

| 결과 | 다음 행동 |
|---|---|
| SF10 spill 없이 통과 | SF100으로 스케일 업 테스트 |
| SF10 spill 발생 + 합리적 latency | **7. 커넥터 레벨 튜닝**으로 진행 |
| SF10 spill 발생 + I/O 병목 | Step 2 (hostPath/PVC) 적용 후 재측정 |
| SF100 도전 → spill + 완주 | 벤치마크 결과 기록 후 **6. 워커 수** 또는 **7. 커넥터** |
| SF100 도전 → OOM/eviction | `max-spill-per-node` 조정, 또는 노드 메모리 확장 재검토 |
