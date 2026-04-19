# scripts/ — 배포 및 설정 스크립트

모든 스크립트는 **저장소 루트에서 실행**한다는 가정 (`ROOT="$(pwd)"`).
`scripts/config.env`를 source하여 `NAMESPACE`, `RELEASE_NAME` 등 공통 설정을 사용.

## 실행 순서

```
[1단계] 클러스터 구축
  └→ ./scripts/install.sh

[2단계] 리소스 튜닝 + 모니터링
  └→ ./scripts/install-monitor.sh

[3단계] 멀티테넌시
  ├→ ./scripts/install-keycloak-ranger.sh     # 인프라 배포
  ├→ ./scripts/setup-keycloak-realm.sh        # Keycloak 사용자/그룹
  ├→ ./scripts/setup-ranger-users.sh          # Ranger 사용자/정책
  └→ ./scripts/verify-multitenancy.sh         # 전체 검증
```

## 스크립트 목록

| 스크립트 | 단계 | 용도 | 멱등성 |
|---|---|---|---|
| `config.env` | 공통 | `NAMESPACE=user-braveji`, `RELEASE_NAME=my-trino` 기본값 정의 | - |
| `install.sh` | 1단계 | cert issuer → MinIO → CNPG PostgreSQL(HMS/analytics) → HMS → Trino helm upgrade | 멱등 |
| `install-monitor.sh` | 2단계 | JMX ConfigMap → Prometheus/Grafana helm → Trino 커스텀 이미지 빌드 + upgrade | 멱등 (SKIP 플래그) |
| `install-keycloak-ranger.sh` | 3단계 | Keycloak PG + Deployment + Ingress → Ranger PG + Deployment + Ingress | 멱등 |
| `setup-keycloak-realm.sh` | 3단계 | Keycloak Realm/Client/Group/User 생성 (13명). Client Secret 출력 | 멱등 |
| `setup-ranger-users.sh` | 3단계 | Ranger PG + Admin 배포 + Trino 서비스/그룹/사용자/정책 + 검증 | 멱등 (SKIP 플래그) |
| `verify-multitenancy.sh` | 3단계 | T1~T12 전체 시나리오 자동 검증 (PASS/FAIL/SKIP 리포트) | 멱등 (읽기 전용) |
| `gc_analysis.sh` | 2단계 | GC 로그 분석 (튜닝 보조) | - |

## 환경변수 override

모든 스크립트는 환경변수로 기본값을 override 가능:

```bash
NAMESPACE=other-ns ./scripts/install.sh
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
install-keycloak-ranger.sh ─── Keycloak + Ranger 인프라 (3단계)│
  │                                                          │
  ├── setup-keycloak-realm.sh ─── Keycloak 사용자 설정         │
  │     │                                                     │
  │     └── Client Secret → trino-oauth2 K8s Secret           │
  │           │                                               │
  │           └── install.sh (재실행) → OAuth2 적용             │
  │                                                           │
  └── setup-ranger-users.sh ─── Ranger 사용자/정책 + 검증      │
        │                                                     │
        └── verify-multitenancy.sh ─── 전체 시나리오 검증       │
```

## 주의사항

- 스크립트는 `scripts/` 안이 아닌 **저장소 루트**에서 실행 (`./scripts/xxx.sh`)
- zsh에서 `group`은 예약어 — 스크립트 내 변수명으로 사용 금지 (G19)
- `date +%s%3N`은 macOS BSD date에서 미지원 — `python3 -c 'import time; ...'` 사용
- `"..."` 안의 `!`는 zsh history expansion — 작은따옴표 사용 권장
