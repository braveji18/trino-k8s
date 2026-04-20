# scripts/ — 배포 및 설정 스크립트

모든 스크립트는 **저장소 루트에서 실행**한다는 가정 (`ROOT="$(pwd)"`).
`scripts/config.env`를 source하여 `NAMESPACE`, `RELEASE_NAME` 등 공통 설정을 사용.

## 실행 순서

```
[1단계] 클러스터 구축
  └→ ./scripts/install.sh

[2단계] 리소스 튜닝 + 모니터링
  └→ ./scripts/install-monitor.sh

[3단계] 멀티테넌시 (Keycloak + OPA — 현재 운영 중)
  ├→ ./scripts/install-keycloak-ranger.sh     # Keycloak 인프라 (Ranger 부분은 무시)
  ├→ ./scripts/setup-keycloak-realm.sh        # Keycloak Realm/사용자
  ├→ ./scripts/setup-opa.sh                   # OPA Deployment + Rego 정책 + Trino helm upgrade
  ├→ ./scripts/verify-opa.sh                  # OPA V1~V8 시나리오 검증
  └→ ./scripts/verify-multitenancy.sh         # (legacy) Ranger 시절 T1~T12 검증

[3단계 — legacy] Ranger 방식 (deprecated, 참고용)
  └→ ./scripts/setup-ranger-users.sh          # Ranger 사용자/정책
```

## 스크립트 목록

| 스크립트 | 단계 | 용도 | 멱등성 |
|---|---|---|---|
| `config.env` | 공통 | `NAMESPACE=user-braveji`, `RELEASE_NAME=my-trino` 기본값 정의 | - |
| `install.sh` | 1단계 | cert issuer → MinIO → CNPG PostgreSQL(HMS/analytics) → HMS → Trino helm upgrade | 멱등 |
| `install-monitor.sh` | 2단계 | JMX ConfigMap → Prometheus/Grafana helm → Trino 커스텀 이미지 빌드 + upgrade | 멱등 (SKIP 플래그) |
| `install-keycloak-ranger.sh` | 3단계 | Keycloak PG + Deployment + Ingress → Ranger PG + Deployment + Ingress | 멱등 |
| `setup-keycloak-realm.sh` | 3단계 | Keycloak Realm/Client/Group/User 생성 (13명). Client Secret 출력 | 멱등 |
| `setup-opa.sh` | 3단계 | OPA Policy ConfigMap + Deployment 배포 + Trino helm upgrade + 스모크 테스트 | 멱등 (SKIP 플래그) |
| `verify-opa.sh` | 3단계 | OPA V1~V8 시나리오 (admin/etl/analyst/bi 권한, deny 케이스, 401) | 멱등 (읽기 전용) |
| `setup-ranger-users.sh` | 3단계 (deprecated) | Ranger PG + Admin 배포 + Trino 서비스/그룹/사용자/정책 + 검증 | 멱등 (SKIP 플래그) |
| `verify-multitenancy.sh` | 3단계 (legacy) | T1~T12 Ranger 시나리오 (resource group, quota 검증은 OPA에서도 유효) | 멱등 (읽기 전용) |
| `gc_analysis.sh` | 2단계 | GC 로그 분석 (튜닝 보조) | - |

## 환경변수 override

모든 스크립트는 환경변수로 기본값을 override 가능:

```bash
NAMESPACE=other-ns ./scripts/install.sh
SKIP_HELM_UPGRADE=1 ./scripts/setup-opa.sh         # OPA 정책만 갱신 (Trino 재배포 생략)
SKIP_SMOKE=1 ./scripts/setup-opa.sh                # 스모크 테스트 생략
OPA_RESTART=1 ./scripts/setup-opa.sh               # ConfigMap만 바꿨을 때 OPA pod 재시작
SKIP_INSTALL=1 ./scripts/setup-ranger-users.sh     # Ranger 인프라 설치 건너뛰기
SKIP_VERIFY=1 ./scripts/setup-ranger-users.sh      # 검증 건너뛰기
SKIP_TRINO_BUILD=1 ./scripts/install-monitor.sh    # Trino 이미지 빌드 건너뛰기
SKIP_TRINO_UPGRADE=1 ./scripts/install-monitor.sh  # Trino helm upgrade 건너뛰기
```

## 스크립트 간 의존 관계

```
config.env ──────────────────────────────────────────────────┐
  │                                                          │
install.sh ─── Trino 스택 (1단계)                             │
  │                                                          │
install-monitor.sh ─── Prometheus/Grafana (2단계)             │
  │                                                          │
install-keycloak-ranger.sh ─── Keycloak + (legacy) Ranger 인프라 (3단계)│
  │                                                          │
  ├── setup-keycloak-realm.sh ─── Keycloak 사용자 설정         │
  │     │                                                     │
  │     └── Client Secret → trino-oauth2 K8s Secret           │
  │           │                                               │
  │           └── install.sh (재실행) → OAuth2 적용             │
  │                                                           │
  ├── setup-opa.sh ─── OPA + Rego 정책 + Trino 재배포 (현재)   │
  │     │                                                     │
  │     └── verify-opa.sh ─── V1~V8 OPA 시나리오 검증           │
  │                                                           │
  └── setup-ranger-users.sh ─── Ranger (deprecated)            │
        │                                                     │
        └── verify-multitenancy.sh ─── (legacy) T1~T12 검증    │
```

## 주의사항

- 스크립트는 `scripts/` 안이 아닌 **저장소 루트**에서 실행 (`./scripts/xxx.sh`)
- zsh에서 `group`은 예약어 — 스크립트 내 변수명으로 사용 금지 (G19)
- `date +%s%3N`은 macOS BSD date에서 미지원 — `python3 -c 'import time; ...'` 사용
- `"..."` 안의 `!`는 zsh history expansion — 작은따옴표 사용 권장
