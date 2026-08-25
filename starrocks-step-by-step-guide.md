# StarRocks Operator — 소스 획득부터 ArgoCD 배포까지 (Kustomize 확장 구조)

원본: <https://github.com/StarRocks/starrocks-kubernetes-operator>
방식: 소스는 **사내 Git**, 배포는 **ArgoCD**, 환경 확장은 **Kustomize base/overlay**
검증: 아래 예제는 kustomize v5.4.3으로 `base/operator`, `overlays/{prod,staging,dev}` 빌드 성공 확인 완료.

---

## 0. 최종 목표 구조

```
starrocks-deploy/                     # 사내 git repo
├── fetch-source.sh                   # 원본에서 CRD·operator.yaml 갱신
├── README.md
├── base/
│   ├── operator/                     # CRD + Operator (공통)
│   │   ├── kustomization.yaml
│   │   ├── crd.yaml                  # 원본 deploy/…clusters.yaml (약 330KB)
│   │   └── operator.yaml             # 원본 deploy/operator.yaml
│   └── cluster/                      # StarRocksCluster CR 기본형
│       ├── kustomization.yaml
│       └── starrockscluster.yaml
├── overlays/
│   ├── prod/     (kustomization.yaml + patch-cluster.yaml)
│   ├── staging/  (kustomization.yaml + patch-cluster.yaml)
│   └── dev/      (kustomization.yaml + patch-cluster.yaml)
└── argocd/
    ├── app-operator.yaml
    ├── app-cluster-{prod,staging,dev}.yaml
    └── applicationset.yaml           # 환경 자동 확장(선택)
```

---

## STEP 1. 원본에서 필요한 파일만 가져오기

원본 저장소 전체가 아니라 **plain manifest 3개**만 필요합니다.
Go 소스·vendor 등은 operator 이미지를 직접 빌드할 게 아니면 불필요합니다.

가져올 파일:

| 원본 경로 | 사내 배치 위치 | 용도 |
| --- | --- | --- |
| `deploy/starrocks.com_starrocksclusters.yaml` | `base/operator/crd.yaml` | CRD (약 330KB) |
| `deploy/operator.yaml` | `base/operator/operator.yaml` | Operator + RBAC |
| `examples/starrocks/starrocks-fe-and-be.yaml` | `base/cluster/starrockscluster.yaml` | CR 기본형(참고) |

### 방법 A — 스크립트 사용 (권장)

```bash
./fetch-source.sh v1.11.7
```

`fetch-source.sh`는 지정한 태그로 `--depth 1` 클론 후 CRD와 operator.yaml만 복사하고 임시 디렉터리를 정리합니다.

### 방법 B — 수동

```bash
git clone --depth 1 --branch v1.11.7 \
  https://github.com/StarRocks/starrocks-kubernetes-operator.git /tmp/sr
cp /tmp/sr/deploy/starrocks.com_starrocksclusters.yaml base/operator/crd.yaml
cp /tmp/sr/deploy/operator.yaml                          base/operator/operator.yaml
```

> ⚠️ **CRD 심볼릭 링크 주의** — 원본 helm 차트 안의 CRD는 `deploy/`를 가리키는 심볼릭 링크입니다.
> 반드시 `deploy/` 아래의 **실체 파일**을 복사하세요. (위 경로가 실체 파일)

---

## STEP 2. base/operator 구성

`base/operator/kustomization.yaml`

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
  - crd.yaml
  - operator.yaml

# Operator Deployment 이미지는 표준 컨테이너 필드라 여기서 치환 가능.
images:
  - name: starrocks/operator
    newName: registry.내부.com/starrocks/operator
    newTag: v1.11.7
```

검증:

```bash
kustomize build base/operator
# → CustomResourceDefinition, Deployment, ClusterRole/Binding, Role/Binding,
#   ServiceAccount, Namespace 렌더링. Deployment 이미지가 사내 레지스트리로 치환됨.
```

---

## STEP 3. base/cluster 구성

`base/cluster/starrockscluster.yaml` (핵심 필드만)

```yaml
apiVersion: starrocks.com/v1
kind: StarRocksCluster
metadata:
  name: starrockscluster
  namespace: starrocks
spec:
  starRocksFeSpec:
    image: starrocks/fe-ubuntu:3.3.5
    replicas: 3
    requests: { cpu: 1, memory: 2Gi }
    limits:   { cpu: 4, memory: 8Gi }
    storageVolumes:
      - { name: fe-meta, storageSize: 10Gi, mountPath: /opt/starrocks/fe/meta }
      - { name: fe-log,  storageSize: 5Gi,  mountPath: /opt/starrocks/fe/log }
  starRocksBeSpec:
    image: starrocks/be-ubuntu:3.3.5
    replicas: 3
    requests: { cpu: 1, memory: 2Gi }
    limits:   { cpu: 4, memory: 8Gi }
    storageVolumes:
      - { name: be-data, storageSize: 100Gi, mountPath: /opt/starrocks/be/storage }
      - { name: be-log,  storageSize: 1Gi,   mountPath: /opt/starrocks/be/log }
```

`base/cluster/kustomization.yaml`

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - starrockscluster.yaml
```

---

## STEP 4. overlay로 환경 확장

`overlays/prod/kustomization.yaml`

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
  - ../../base/cluster

namePrefix: prod-
namespace: starrocks

patches:
  - path: patch-cluster.yaml
    target: { group: starrocks.com, version: v1, kind: StarRocksCluster }
```

`overlays/prod/patch-cluster.yaml` (이미지·리소스·스토리지 환경값)

```yaml
apiVersion: starrocks.com/v1
kind: StarRocksCluster
metadata:
  name: starrockscluster
spec:
  starRocksFeSpec:
    image: registry.내부.com/starrocks/fe-ubuntu:3.3.5
    replicas: 3
    requests: { cpu: 4, memory: 16Gi }
    limits:   { cpu: 8, memory: 32Gi }
    storageVolumes:
      - { name: fe-meta, storageClassName: 내부-ssd-sc, storageSize: 50Gi, mountPath: /opt/starrocks/fe/meta }
      - { name: fe-log,  storageClassName: 내부-ssd-sc, storageSize: 10Gi, mountPath: /opt/starrocks/fe/log }
  starRocksBeSpec:
    image: registry.내부.com/starrocks/be-ubuntu:3.3.5
    replicas: 3
    requests: { cpu: 4, memory: 16Gi }
    limits:   { cpu: 8, memory: 64Gi }
    storageVolumes:
      - { name: be-data, storageClassName: 내부-ssd-sc, storageSize: 2Ti, mountPath: /opt/starrocks/be/storage }
      - { name: be-log,  storageClassName: 내부-ssd-sc, storageSize: 5Gi, mountPath: /opt/starrocks/be/log }
```

> **왜 이미지를 patch로 바꾸나?**
> kustomize `images:` 트랜스포머는 표준 컨테이너 이미지 필드만 치환합니다.
> StarRocksCluster CR의 `spec.starRocksFeSpec.image`는 **커스텀 필드**라 `images:`로는 안 바뀝니다.
>
> **왜 storageVolumes를 통째로 다시 쓰나?**
> kustomize는 CRD 리스트의 병합키를 몰라 **리스트 전체를 교체**합니다. 항목을 모두 기술해야 합니다.

staging / dev는 같은 형태에서 `namePrefix`, `namespace`, `replicas`, 리소스만 조정합니다.
(dev는 `replicas: 1`로 non-HA 허용)

검증:

```bash
kustomize build overlays/prod     # prod-starrockscluster / ns starrocks / replicas 3
kustomize build overlays/dev      # dev-starrockscluster  / ns starrocks-dev / replicas 1
```

---

## STEP 5. 사내 레지스트리로 이미지 미러링

폐쇄망이라면 아래 이미지를 사내 레지스트리로 미러링하고, 위 kustomization/patch의 경로를 맞춥니다.

```
starrocks/operator:v1.11.7   → registry.내부.com/starrocks/operator:v1.11.7   (base/operator images:)
starrocks/fe-ubuntu:<버전>    → registry.내부.com/starrocks/fe-ubuntu:<버전>    (overlay patch)
starrocks/be-ubuntu:<버전>    → registry.내부.com/starrocks/be-ubuntu:<버전>    (overlay patch)
starrocks/cn-ubuntu:<버전>    → registry.내부.com/starrocks/cn-ubuntu:<버전>    (CN 사용 시)
```

프라이빗 레지스트리 인증이 필요하면 각 CR에 `imagePullSecrets`를, operator에는 배포 네임스페이스에 pull secret을 추가합니다.

---

## STEP 6. 사내 Git에 커밋 & 푸시

```bash
git init
git add .
git commit -m "StarRocks operator: kustomize base/overlay + argocd"
git remote add origin https://git.내부.com/data/starrocks-deploy.git
git push -u origin main
```

---

## STEP 7. ArgoCD 등록 — Operator 먼저

`argocd/app-operator.yaml` (sync-wave 0, **ServerSideApply 필수**)

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: starrocks-operator
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "0"
spec:
  project: default
  source:
    repoURL: https://git.내부.com/data/starrocks-deploy.git
    targetRevision: main
    path: base/operator
  destination:
    server: https://kubernetes.default.svc
    namespace: starrocks
  syncPolicy:
    automated: { prune: true, selfHeal: true }
    syncOptions:
      - CreateNamespace=true
      - ServerSideApply=true          # ★ 330KB CRD → 반드시 필요
```

```bash
kubectl apply -f argocd/app-operator.yaml
```

> **ServerSideApply가 필수인 이유** — CRD가 약 330KB로, client-side apply가 쓰는
> `last-applied-configuration` 어노테이션 한도(262144 bytes)를 초과합니다.
> 이 옵션이 없으면 `metadata.annotations: Too long` 오류가 납니다.

Operator Application이 `Healthy / Synced` 되고 CRD가 등록됐는지 확인:

```bash
kubectl get crd starrocksclusters.starrocks.com
kubectl -n starrocks get deploy kube-starrocks-operator
```

---

## STEP 8. ArgoCD 등록 — Cluster 배포

`argocd/app-cluster-prod.yaml` (sync-wave 10, operator 이후)

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: starrocks-cluster-prod
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "10"
spec:
  project: default
  source:
    repoURL: https://git.내부.com/data/starrocks-deploy.git
    targetRevision: main
    path: overlays/prod
  destination:
    server: https://kubernetes.default.svc
    namespace: starrocks
  syncPolicy:
    automated: { prune: true, selfHeal: true }
    syncOptions:
      - ServerSideApply=true
```

```bash
kubectl apply -f argocd/app-cluster-prod.yaml
```

### (선택) 환경 자동 확장 — ApplicationSet

`overlays/*` 디렉터리를 자동 감지해 환경별 Application을 만들어 줍니다.
새 환경은 `overlays/<env>` 디렉터리만 추가하면 됩니다.

```bash
kubectl apply -f argocd/applicationset.yaml
```

---

## STEP 9. 배포 확인 & 접속

```bash
kubectl -n starrocks get starrockscluster
kubectl -n starrocks get pods
kubectl -n starrocks get svc

# FE 서비스 9030 포트로 MySQL 프로토콜 접속
kubectl -n starrocks port-forward svc/prod-starrockscluster-fe-service 9030:9030
mysql -h 127.0.0.1 -P 9030 -uroot
```

---

## 운영 시 자주 겪는 이슈 요약

| 증상 | 원인 | 해결 |
| --- | --- | --- |
| `metadata.annotations: Too long` | 330KB CRD + client-side apply | Application에 `ServerSideApply=true` |
| overlay에서 이미지가 안 바뀜 | CR의 `image`는 커스텀 필드 | `images:`가 아니라 patch로 교체 |
| patch 후 storageVolumes 일부만 반영 | 리스트 전체 교체 방식 | patch에 항목 전체 기술 |
| CR이 CRD보다 먼저 적용돼 실패 | 동기화 순서 | sync-wave(operator 0 / cluster 10) |
| FE 축소 후 클러스터 불안정 | 쿼럼 손상 | 프로덕션 FE 3대 미만 금지 |
| CRD 링크 깨짐 | helm 차트 내 CRD가 심볼릭 링크 | `deploy/` 실체 파일 복사 |

---

## 버전 업그레이드 흐름

1. `./fetch-source.sh <새태그>` 로 CRD·operator.yaml 갱신
2. `base/operator/kustomization.yaml` 의 operator `newTag` 수정
3. overlay patch의 fe/be 이미지 태그 수정
4. `kustomize build`로 로컬 검증 후 커밋·푸시 → ArgoCD 자동 동기화
