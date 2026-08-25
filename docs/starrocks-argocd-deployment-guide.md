# StarRocks Kubernetes Operator — 사내 Git + ArgoCD 배포 가이드

> 원본 저장소: <https://github.com/StarRocks/starrocks-kubernetes-operator>
> 기준 버전: Helm Chart `v1.11.7` / operator 이미지 `v1.11.7` / appVersion `4.1`
> 목표: 소스는 **사내 Git**에 저장하고, 배포는 **ArgoCD**로 수행

---

## 1. 전체 방향 결정

사내 Git에 소스를 두고 ArgoCD로 배포하려면, 원본 저장소 전체가 아니라
**`helm-charts/charts/` 아래의 Helm 차트만 벤더링(복사)** 하는 방식이 가장 깔끔합니다.
Go 소스코드(`pkg`, `cmd`, `vendor` 등)는 operator 이미지를 직접 빌드할 게 아니라면 필요 없습니다.

배포는 관심사를 나눠 **두 개의 ArgoCD Application** 으로 구성하는 것을 권장합니다.

| Application | 역할 | 배포 빈도 |
| --- | --- | --- |
| operator Application | CRD + Operator 컨트롤러 | 클러스터 1개당 1번만 |
| cluster Application | StarRocksCluster CR (실제 FE/BE 클러스터) | 환경별로 복제 |

Operator가 CRD를 먼저 설치해야 StarRocksCluster CR을 적용할 수 있기 때문에 **순서 제어**가 중요합니다.

---

## 2. 사내 Git 저장소 구조

원본에서 필요한 부분만 가져와 아래 구조로 커밋합니다.

```
starrocks-deploy/                      # 사내 git repo
├── charts/
│   └── kube-starrocks/                # 원본 helm-charts/charts/kube-starrocks 통째로 복사
│       ├── Chart.yaml
│       ├── values.yaml
│       └── charts/
│           ├── operator/
│           │   └── crds/
│           │       └── starrocks.com_starrocksclusters.yaml   # ★ 심볼릭 링크 주의 (3번 참고)
│           └── starrocks/
├── operator/
│   └── values-operator.yaml           # operator 전용 오버라이드
├── clusters/
│   └── prod/
│       └── values-cluster.yaml        # 환경별 클러스터 정의
└── argocd/
    ├── app-operator.yaml
    └── app-cluster-prod.yaml
```

---

## 3. ⚠️ 반드시 짚어야 할 함정 3가지

### (1) CRD 심볼릭 링크

원본의 `charts/operator/crds/starrocks.com_starrocksclusters.yaml`은 실제 파일이 아니라
`deploy/` 아래를 가리키는 **심볼릭 링크**입니다. 단순 복사하면 링크가 깨지므로,
반드시 원본 실체 파일로 교체하세요.

```bash
cd charts/kube-starrocks/charts/operator/crds/
rm starrocks.com_starrocksclusters.yaml
cp /원본/deploy/starrocks.com_starrocksclusters.yaml .
```

### (2) CRD 크기와 Server-Side Apply

StarRocksCluster CRD는 **약 330KB**로, kubectl의 기본 client-side apply가 사용하는
`last-applied-configuration` 어노테이션 크기 한도(262144 bytes)를 초과합니다.
ArgoCD에서 기본 동기화로 하면 `metadata.annotations: Too long` 오류가 납니다.

> **operator Application에는 반드시 `ServerSideApply=true`를 설정**해야 합니다.

### (3) 동기화 순서

CRD → Operator → StarRocksCluster CR 순으로 적용돼야 합니다.
Application을 분리하고 **sync wave**로 제어합니다.

---

## 4. 이미지 미러링 (사내 환경)

사내(폐쇄망 가능성)에서는 외부 이미지를 사내 레지스트리로 미러링해야 합니다.
필요한 이미지는 다음과 같습니다.

```
starrocks/operator:v1.11.7      → registry.내부.com/starrocks/operator:v1.11.7
starrocks/fe-ubuntu:<버전>       → registry.내부.com/starrocks/fe-ubuntu:<버전>
starrocks/be-ubuntu:<버전>       → registry.내부.com/starrocks/be-ubuntu:<버전>
```

values에서 `repository`를 사내 레지스트리로 바꾸고, 필요 시 `imagePullSecrets`를 추가합니다.

---

## 5. Operator Application

`argocd/app-operator.yaml` — Operator 하위 차트만 활성화하고 클러스터 CR은 끕니다.

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: starrocks-operator
  namespace: argocd
spec:
  project: default
  source:
    repoURL: https://git.내부.com/data/starrocks-deploy.git
    targetRevision: main
    path: charts/kube-starrocks
    helm:
      valueFiles:
        - ../../operator/values-operator.yaml
  destination:
    server: https://kubernetes.default.svc
    namespace: starrocks
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - CreateNamespace=true
      - ServerSideApply=true      # ★ 대형 CRD 필수
```

`operator/values-operator.yaml` — operator만 켜고 starrocks 클러스터는 끕니다.

```yaml
operator:
  starrocksOperator:
    enabled: true
    image:
      repository: registry.내부.com/starrocks/operator
      tag: v1.11.7
# 이 Application에서는 클러스터를 만들지 않음
starrocks:
  starrocksCluster:
    enabled: false
  starrocksFESpec: {}
  starrocksBeSpec: {}
```

---

## 6. Cluster Application

`argocd/app-cluster-prod.yaml` — 동일 차트를 재사용하되, sync wave를 뒤로 둬서
operator 준비 후 적용되게 합니다.

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: starrocks-cluster-prod
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "10"    # operator보다 나중
spec:
  project: default
  source:
    repoURL: https://git.내부.com/data/starrocks-deploy.git
    targetRevision: main
    path: charts/kube-starrocks
    helm:
      valueFiles:
        - ../../clusters/prod/values-cluster.yaml
  destination:
    server: https://kubernetes.default.svc
    namespace: starrocks
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
      - ServerSideApply=true
```

`clusters/prod/values-cluster.yaml` — 이번엔 operator를 끄고 클러스터만 정의합니다.

```yaml
operator:
  starrocksOperator:
    enabled: false
starrocks:
  starrocksCluster:
    enabled: true
    name: starrocks-prod
  # 초기 root 비밀번호는 Secret 참조 권장
  initPassword:
    enabled: true
    passwordSecret: starrocks-root-secret
  starrocksFESpec:
    image:
      repository: registry.내부.com/starrocks/fe-ubuntu
      tag: "3.3.5"          # 사용할 StarRocks 버전으로 고정
    replicas: 3             # HA. 3 미만으로 줄이지 말 것
    storageSpec:
      name: fe-meta
      storageClassName: "내부-ssd-sc"
      storageSize: 50Gi
  starrocksBeSpec:
    image:
      repository: registry.내부.com/starrocks/be-ubuntu
      tag: "3.3.5"
    replicas: 3
    storageSpec:
      name: be-data
      storageClassName: "내부-ssd-sc"
      storageSize: 500Gi
```

---

## 7. 배포 순서 정리

1. `starrocks-operator` Application을 등록·동기화한다.
2. CRD와 컨트롤러가 `Healthy` 상태가 되는 것을 확인한다.
3. `starrocks-cluster-prod` Application을 동기화한다.

> App-of-Apps 패턴으로 묶으면 sync wave 하나로 순서 제어가 가능합니다.

---

## 8. 추가 참고 사항

- **`valueFiles` 상대경로**: `../../` 상대경로가 ArgoCD 버전에 따라 제한될 수 있습니다.
  그럴 경우 values 파일을 차트 디렉터리 안으로 옮기거나 ArgoCD의 **multi-source** 기능을 사용하세요.
- **이미지 직접 빌드**: 사내 정책상 operator 이미지 빌드까지 직접 관리해야 한다면
  Go 소스와 `Dockerfile`, `Makefile`도 함께 가져와 CI에서 이미지를 빌드하는 파이프라인이 추가로 필요합니다.
- **HA 주의**: FE는 3대로 시작하면 HA 모드가 되며, **3대 미만으로 줄이면 쿼럼이 깨집니다.** CN 노드에는 이 제약이 없습니다.
- **초기 비밀번호**: `initPassword`는 평문 대신 Kubernetes Secret 참조(`passwordSecret`) 방식을 권장합니다.

---

## 부록: 필요한 컨테이너 이미지 목록

| 컴포넌트 | 원본 이미지 | 비고 |
| --- | --- | --- |
| Operator | `starrocks/operator:v1.11.7` | 컨트롤러 |
| FE (Frontend) | `starrocks/fe-ubuntu:<버전>` | 필수 컴포넌트 |
| BE (Backend) | `starrocks/be-ubuntu:<버전>` | 선택 (스토리지형) |
| CN (Compute Node) | `starrocks/cn-ubuntu:<버전>` | 선택 (컴퓨트 분리형) |
