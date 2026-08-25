# helm-charts/ 를 Kustomize로 확장하는 방법 (Helm Inflation)

**결론: 가능합니다.** kustomize의 **Helm chart inflation**(`helmCharts:` 필드)으로
원본 `helm-charts/charts/kube-starrocks` 차트를 그대로 base로 삼고, 그 위에 kustomize patch를 얹어
환경을 확장할 수 있습니다. 아래 내용은 kustomize v5.4.3 + helm으로 **실제 빌드 성공을 확인**했습니다.

> 앞서 만든 "plain manifest 방식"과의 차이:
> - **plain manifest 방식** — helm을 안 쓰고 `deploy/*.yaml`을 base로. 단순·투명하지만 helm 값 관리 이점이 없음.
> - **이 Helm inflation 방식** — helm 차트의 `values.yaml` 관리 편의 + kustomize patch 확장을 **둘 다** 얻음. 대신 빌드에 helm 의존.

---

## 1. 두 방식 중 어떤 걸 선택하나

| 항목 | plain manifest + kustomize | **helm 차트 + kustomize inflation** |
| --- | --- | --- |
| helm `values.yaml` 활용 | ❌ | ✅ |
| 차트 업그레이드 추적 | 파일 3개 교체 | 차트 디렉터리 교체 |
| 빌드 의존성 | kustomize만 | kustomize + **helm 바이너리** |
| ArgoCD 추가설정 | 없음 | `--enable-helm` 필요 |
| 렌더링 투명성 | 높음 | 중간(helm 템플릿 거침) |

사내 표준이 "순수 kustomize"라면 plain 방식이, "helm 값 체계를 유지하고 싶다"면 이 방식이 적합합니다.

---

## 2. 저장소 구조

```
starrocks-helm-kustomize/
├── charts/
│   └── kube-starrocks/                 # 원본 helm 차트 통째로 벤더링
│       ├── Chart.yaml
│       ├── values.yaml
│       └── charts/{operator,starrocks} # 서브차트 포함
│           └── operator/crds/…clusters.yaml   # ★ 심볼릭 링크 → 실체 파일로 교체
├── base/
│   ├── kustomization.yaml              # helmCharts inflation
│   └── values.yaml                     # 차트에 넘길 값
├── overlays/
│   ├── prod/ (kustomization.yaml + patch-cluster.yaml)
│   └── dev/  (kustomization.yaml + patch-cluster.yaml)
└── argocd/
    ├── app-operator.yaml
    ├── app-cluster-prod.yaml
    └── argocd-cm-enable-helm.yaml      # repo-server helm 활성화
```

차트 벤더링과 CRD 링크 교체:

```bash
cp -r 원본/helm-charts/charts/kube-starrocks charts/
# CRD 심볼릭 링크를 deploy/ 실체 파일로 교체
CRD=charts/kube-starrocks/charts/operator/crds/starrocks.com_starrocksclusters.yaml
rm -f "$CRD"
cp 원본/deploy/starrocks.com_starrocksclusters.yaml "$CRD"
```

---

## 3. base — helmCharts inflation

`base/kustomization.yaml`

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

helmCharts:
  - name: kube-starrocks
    version: 1.11.7
    releaseName: starrocks
    namespace: starrocks
    valuesFile: values.yaml
    includeCRDs: true          # ★ 없으면 crds/ 가 렌더링에서 빠짐

helmGlobals:
  chartHome: ../charts         # ★ 로컬 벤더 차트 위치 (기본은 kustomization 옆 charts/)
```

`base/values.yaml`

```yaml
operator:
  starrocksOperator:
    enabled: true
    image:
      repository: registry.내부.com/starrocks/operator
      tag: v1.11.7
starrocks:
  starrocksCluster:
    enabled: true
    name: starrockscluster
  starrocksFESpec:
    image: { repository: registry.내부.com/starrocks/fe-ubuntu, tag: "3.3.5" }
    replicas: 3
  starrocksBeSpec:
    image: { repository: registry.내부.com/starrocks/be-ubuntu, tag: "3.3.5" }
    replicas: 3
```

빌드 검증 (**`--enable-helm` 필수**):

```bash
kustomize build --enable-helm base
```

확인된 렌더링 결과: `CustomResourceDefinition`, `Deployment`(operator), `StarRocksCluster`,
`ConfigMap` x2, `ClusterRole/Binding`, `Role/Binding`, `ServiceAccount` — values의 replicas가 반영됨.

---

## 4. overlay — helm 렌더 결과에 patch

`overlays/prod/kustomization.yaml`

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
  - ../../base                 # helm inflation 결과를 입력으로

patches:
  - path: patch-cluster.yaml
    target: { group: starrocks.com, version: v1, kind: StarRocksCluster }
```

`overlays/prod/patch-cluster.yaml`

```yaml
apiVersion: starrocks.com/v1
kind: StarRocksCluster
metadata:
  name: starrockscluster
spec:
  starRocksFeSpec:
    requests: { cpu: 4, memory: 16Gi }
    limits:   { cpu: 8, memory: 32Gi }
  starRocksBeSpec:
    requests: { cpu: 4, memory: 16Gi }
    limits:   { cpu: 8, memory: 64Gi }
```

```bash
kustomize build --enable-helm overlays/prod
# → helm이 렌더한 CR 위에 patch가 적용되어 prod 리소스값(cpu 8/4, memory 64Gi/16Gi) 반영 확인됨
```

> **환경별 values를 아예 다르게 주고 싶다면?**
> overlay가 base를 참조하는 대신, overlay의 kustomization.yaml에 **자체 `helmCharts:` 블록**을 두고
> `valuesFile: values-prod.yaml` 처럼 환경 전용 values로 다시 inflation하는 방법도 있습니다.
> (values 레벨에서 크게 갈리면 이 방식, 소소한 차이면 위의 patch 방식)

---

## 5. ArgoCD 설정 — helm 활성화가 관건

kustomize가 helm을 호출하는 방식이라, **ArgoCD repo-server가 kustomize 빌드 중 helm 실행을 허용**해야 합니다.
이 설정이 없으면 `must specify --enable-helm` 오류로 동기화가 실패합니다.

`argocd/argocd-cm-enable-helm.yaml`

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: argocd-cm
  namespace: argocd
data:
  kustomize.buildOptions: --enable-helm
```

```bash
kubectl -n argocd patch cm argocd-cm --type merge \
  -p '{"data":{"kustomize.buildOptions":"--enable-helm"}}'
# 적용 후 repo-server 재시작
kubectl -n argocd rollout restart deploy argocd-repo-server
```

Application 자체는 앞서와 동일하되, `path`가 이 저장소의 base/overlay를 가리키고
**대형 CRD 때문에 `ServerSideApply=true`가 필요**합니다.

```yaml
# argocd/app-cluster-prod.yaml (발췌)
spec:
  source:
    repoURL: https://git.내부.com/data/starrocks-deploy.git
    targetRevision: main
    path: overlays/prod
  syncPolicy:
    syncOptions:
      - ServerSideApply=true
```

---

## 6. 이 방식의 함정 정리

| 함정 | 설명 | 대응 |
| --- | --- | --- |
| `--enable-helm` 누락 | kustomize/ArgoCD가 helm 호출 차단 | 로컬은 플래그, ArgoCD는 argocd-cm |
| CRD 누락 | helm template은 기본적으로 crds/ 제외 | `includeCRDs: true` |
| chartHome 미지정 | 로컬 차트를 kustomization 옆 charts/에서만 탐색 | `helmGlobals.chartHome` |
| CRD 심볼릭 링크 | 원본 차트 내 CRD가 링크 | deploy/ 실체 파일로 교체 |
| kubeVersion 오류 | 오래된 helm 기본 kube-version이 낮음 | 최신 helm 사용(운영 repo-server는 무관) |
| 330KB CRD 어노테이션 초과 | client-side apply 한도 초과 | `ServerSideApply=true` |
| 폐쇄망 helm repo | 서브차트가 원격이면 pull 필요 | 서브차트까지 통째로 벤더링(이미 반영됨) |

---

## 7. 요약

원본 `helm-charts/`를 kustomize로 확장하는 것은 **`helmCharts:` inflation으로 충분히 가능**하며,
`includeCRDs: true` + `helmGlobals.chartHome` + ArgoCD의 `--enable-helm` + `ServerSideApply=true`
네 가지만 맞추면 됩니다. helm 값 관리와 kustomize patch 확장을 모두 원할 때 권장되는 구성입니다.
