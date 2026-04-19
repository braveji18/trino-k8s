# 운영 가이드 + 사용자 온보딩

3단계 멀티테넌시 완료 후 운영/관리에 필요한 절차 모음.

---

## 1. 시스템 접속 정보

| 서비스 | URL | 계정 |
|---|---|---|
| **Trino Web UI** | https://braveji.trino.quantumcns.ai/ui/ | Keycloak OAuth2 로그인 |
| **Keycloak Admin** | https://braveji-keycloak.trino.quantumcns.ai/admin/ | admin / changeme-keycloak-admin |
| **Ranger Admin** | https://braveji-ranger.trino.quantumcns.ai/ | admin / Admin1234! |
| **Grafana** | https://braveji-grafana.trino.quantumcns.ai/ | admin / changeme-grafana |
| **Prometheus** | https://braveji-prom.trino.quantumcns.ai/ | (인증 없음) |

---

## 2. 사용자 관리 — 추가/삭제/그룹 변경

사용자 추가 시 **Keycloak + Ranger 양쪽 모두** 등록 필요.

### 2-1. 사용자 추가 절차

**Step 1 — Keycloak에 사용자 생성**:

```bash
KEYCLOAK_URL="http://keycloak:8080"
REALM="trino"

kubectl -n user-braveji exec deploy/keycloak -- curl -s \
  -X POST "$KEYCLOAK_URL/admin/realms/$REALM/users" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer <ADMIN_TOKEN>" \
  -d '{
    "username": "new_analyst1",
    "firstName": "New",
    "lastName": "Analyst",
    "email": "new_analyst1@example.com",
    "enabled": true,
    "credentials": [{"type": "password", "value": "changeme-user", "temporary": false}]
  }'
```

또는 Keycloak Admin Console에서 GUI로 생성.

**Step 2 — Keycloak 그룹 배정**:

Users → new_analyst1 → Groups → Join Group → `trino-analyst`

**Step 3 — Ranger에 사용자 등록**:

```bash
kubectl -n user-braveji exec deploy/ranger-admin -- \
  curl -s -u admin:Admin1234! -X POST \
  "http://localhost:6080/service/xusers/secure/users" \
  -H "Content-Type: application/json" \
  -d '{"name":"new_analyst1","firstName":"New","lastName":"Analyst","password":"Changeme1","userRoleList":["ROLE_USER"]}'
```

**Step 4 — Ranger 그룹 매핑**:

사용자 ID를 확인한 후 PUT으로 그룹 배정:

```bash
kubectl -n user-braveji exec deploy/ranger-admin -- \
  curl -s -u admin:Admin1234! -X PUT \
  "http://localhost:6080/service/xusers/secure/users/<USER_ID>" \
  -H "Content-Type: application/json" \
  -d '{"id":<USER_ID>,"name":"new_analyst1","firstName":"New","lastName":"Analyst","password":"Changeme1","groupIdList":[3],"userRoleList":["ROLE_USER"]}'
```

> 그룹 ID: trino-etl=2, trino-analyst=3, trino-bi=4, trino-admin=5

### 2-2. 사용자 이름 규칙

| 접두사 | 그룹 | Resource Group | 권한 |
|---|---|---|---|
| `etl_` | trino-etl | root.etl | DDL+DML (hive, iceberg, postgresql) |
| `analyst_` | trino-analyst | root.interactive.analyst | SELECT only |
| `bi_` | trino-bi | root.interactive.bi | SELECT only |
| `admin_` | trino-admin | root.admin | 전체 |

> **G37**: Keycloak username과 Ranger username이 정확히 일치해야 함.

---

## 3. Ranger 정책 관리

### 3-1. 정책 변경 절차

1. Ranger Admin UI 접속: https://braveji-ranger.trino.quantumcns.ai/
2. Access Manager → Service Manager → `trino-braveji` 클릭
3. 정책 목록에서 수정할 정책 클릭 → Edit
4. 그룹/사용자/권한 수정 → Save
5. **30초 이내** Trino coordinator에 자동 반영 (pollIntervalMs=30000)

> coordinator 재시작 불필요. Ranger plugin이 30초마다 정책을 poll.

### 3-2. 현재 정책 요약

| 정책 ID | 리소스 | admin | etl | analyst/bi |
|---|---|---|---|---|
| 6 | catalog/schema/table/column | all | select,insert,create,drop,alter,delete | select |
| 7 | catalog/schema | all | create,drop,alter,show | show |
| 8 | catalog | all | use,create,show | use,show |
| 1 | trinouser | impersonate | impersonate | impersonate |
| 9 | queryid | execute | execute | execute |
| 13 | systemproperty | alter,show | show | show |

### 3-3. 감사 로그 확인

현재 Log4J 방식 (coordinator 로그):

```bash
kubectl -n user-braveji logs deploy/my-trino-trino-coordinator --tail=20 | grep ranger.audit
```

`result: 1` = 허용, `result: 0` = 거부

---

## 4. Resource Group 변경

### 4-1. 변경 절차

1. `helm/values.yaml`의 `resourceGroupsConfig` 수정
2. `./scripts/install.sh` 실행 (helm upgrade)
3. coordinator 자동 재시작 → 새 설정 적용

### 4-2. 주요 설정 값

| 그룹 | softMemoryLimit | hardConcurrencyLimit | maxQueued |
|---|---|---|---|
| root.etl | 60% | 5 | 20 |
| root.interactive.analyst | 50% (of interactive) | 15 | 30 |
| root.interactive.bi | 60% (of interactive) | 20 | 50 |
| root.admin | 20% | 10 | 20 |

> `manifests/trino/resource-groups.json`은 참조 사본. 실제 반영은 values.yaml.

---

## 5. K8s ResourceQuota 조정

### 5-1. 현재 Quota

```bash
kubectl -n user-braveji describe resourcequota trino-resource-quota
```

| 리소스 | Hard |
|---|---|
| requests.cpu | 80 |
| limits.cpu | 120 |
| requests.memory | 320Gi |
| limits.memory | 440Gi |
| pods | 30 |
| services | 25 |

### 5-2. 조정 시

`manifests/trino/resource-quota.yaml` 수정 후:

```bash
kubectl -n user-braveji apply -f manifests/trino/resource-quota.yaml
```

---

## 6. 장애 대응

### 6-1. 쿼리 킬

```bash
kubectl -n user-braveji exec deploy/my-trino-trino-coordinator -- \
  curl -s -X PUT http://localhost:8080/v1/query/<QUERY_ID>/killed \
  -H "Authorization: Bearer <ADMIN_TOKEN>" \
  -H "X-Trino-User: admin_trino"
```

### 6-2. coordinator/worker 재시작

```bash
kubectl -n user-braveji delete pod -l app.kubernetes.io/component=coordinator
kubectl -n user-braveji delete pod -l app.kubernetes.io/component=worker
```

### 6-3. Ranger Admin 재시작

```bash
kubectl -n user-braveji delete pod -l app=ranger-admin
```

> Ranger Admin은 stateless (DB에 상태 저장). Pod 재시작 시 setup.sh가
> `.setupDone` 파일을 확인하여 DB 초기화를 건너뜀.

### 6-4. Grafana 알림 확인

| 알림 | 조건 | 대응 |
|---|---|---|
| TrinoHighQueuedQueries | queuedqueries > 10 (2분) | 워커 수 확인, 대형 쿼리 킬 |
| TrinoHighFailedRate | 실패율 > 0.1/s (5분) | coordinator 로그 확인, 메모리 부족 여부 |
| TrinoHeapPressure | Heap > 85% (5분) | JVM heap 증설 또는 쿼리 부하 분산 |

---

## 7. 사용자 온보딩 — 접속 가이드

### 7-1. 브라우저 (Web UI)

1. https://braveji.trino.quantumcns.ai/ui/ 접속
2. Keycloak 로그인 화면에서 본인 계정으로 로그인
3. Trino Web UI에서 쿼리 실행 + 모니터링

### 7-2. CLI (외부 HTTPS)

```bash
TRINO_URL="https://braveji.trino.quantumcns.ai"
KC_URL="https://braveji-keycloak.trino.quantumcns.ai"

TOKEN=$(curl -sk -X POST \
  "$KC_URL/realms/trino/protocol/openid-connect/token" \
  -d "grant_type=password" -d "client_id=trino" \
  -d "client_secret=<CLIENT_SECRET>" \
  -d "username=<USERNAME>" -d "password=<PASSWORD>" \
  | python3 -c 'import sys,json; print(json.load(sys.stdin)["access_token"])')

trino --server "$TRINO_URL" --access-token "$TOKEN" --execute "SELECT 1"
```

### 7-3. JDBC (BI 도구)

```
jdbc:trino://braveji.trino.quantumcns.ai:443?SSL=true&accessToken=<TOKEN>
```

### 7-4. 그룹별 허용 카탈로그

| 그룹 | 카탈로그 | 권한 |
|---|---|---|
| 데이터 엔지니어 (etl_) | hive, iceberg, postgresql | DDL+DML |
| 분석가 (analyst_) | hive, iceberg, postgresql, tpch | SELECT only |
| BI 도구 (bi_) | hive, iceberg, postgresql | SELECT only |
| 관리자 (admin_) | 전체 | 전체 |

### 7-5. 쿼리 제한 사항

| 항목 | ETL | 분석가 | BI | 관리자 |
|---|---|---|---|---|
| 동시 쿼리 | 5 | 15 | 20 | 10 |
| 최대 큐 | 20 | 30 | 50 | 20 |
| SET SESSION | 허용 (query_max_memory_per_node 제외) | 불가 | 불가 | 전체 허용 |
| DDL (CREATE/DROP) | 허용 | 불가 | 불가 | 허용 |

### 7-6. 쿼리가 느릴 때 확인사항

1. **큐잉 여부**: Trino Web UI → Query List → State가 `QUEUED`인지 확인
2. **리소스 부족**: Grafana → Trino Cluster Overview → Worker Memory Pool 확인
3. **GC 스파이크**: Grafana → GC Collection Time → 1초 이상 pause 확인
4. **Spill 발생**: Grafana → Spill Bytes → 0이 아니면 메모리 부족으로 디스크 사용 중
5. **Ranger 거부**: coordinator 로그에서 `ranger.audit` + `result:0` 확인

---

## 8. 배포 스크립트 참조

| 스크립트 | 용도 |
|---|---|
| `./scripts/install.sh` | Trino 스택 전체 설치/업그레이드 |
| `./scripts/install-monitor.sh` | Prometheus + Grafana + JMX 이미지 |
| `./scripts/install-keycloak-ranger.sh` | Keycloak + Ranger 인프라 배포 |
| `./scripts/setup-keycloak-realm.sh` | Keycloak 사용자/그룹 설정 |
| `./scripts/setup-ranger-users.sh` | Ranger 사용자/정책 + 검증 |
| `./scripts/verify-multitenancy.sh` | 전체 시나리오 검증 (T1~T12) |

상세: [scripts/README.md](../scripts/README.md)
