# curl로 Trino 쿼리 실행하기

Trino REST API는 쿼리를 한 번의 요청으로 끝내지 않고, `/v1/statement`에 쿼리를 POST한 뒤 응답에 담긴 `nextUri`를 계속 따라가며 결과를 가져오는 방식이다. 그래서 순수 curl 한 줄보다는 반복 처리를 넣은 스크립트가 안정적이다.

인증은 ID/PASSWORD(Basic 인증) 방식이며, 결과는 파일로 저장한다.

---

## 1. 간단한 단일 curl (결과가 적을 때)

```bash
curl -s -u "myuser:mypassword" \
  -X POST "https://trino.example.com:8443/v1/statement" \
  -H "X-Trino-User: myuser" \
  -H "Content-Type: text/plain" \
  -d "SELECT * FROM my_catalog.my_schema.my_table LIMIT 100" \
  -o result.json
```

> **주의:** 이렇게 하면 첫 응답만 저장되고 `nextUri`로 이어지는 나머지 결과는 못 받는다. 데이터가 페이지 하나에 다 안 들어오면 아래 스크립트를 사용한다.

---

## 2. nextUri를 끝까지 따라가는 스크립트 (권장)

`jq`가 설치되어 있어야 한다 (`sudo apt install jq`).

```bash
#!/usr/bin/env bash
set -euo pipefail

# ===== 설정 =====
TRINO_URL="https://trino.example.com:8443"
USER="myuser"
PASSWORD="mypassword"
QUERY="SELECT * FROM my_catalog.my_schema.my_table LIMIT 1000"
OUTPUT="result.csv"
# ================

# 첫 요청
response=$(curl -s -u "${USER}:${PASSWORD}" \
  -X POST "${TRINO_URL}/v1/statement" \
  -H "X-Trino-User: ${USER}" \
  -H "Content-Type: text/plain" \
  -d "${QUERY}")

# 컬럼 헤더 저장용 플래그
header_written=false
: > "${OUTPUT}"   # 파일 초기화

while true; do
  # 에러 확인
  err=$(echo "${response}" | jq -r '.error.message // empty')
  if [ -n "${err}" ]; then
    echo "Trino error: ${err}" >&2
    exit 1
  fi

  # 헤더(컬럼명) 한 번만 기록
  if [ "${header_written}" = false ]; then
    cols=$(echo "${response}" | jq -r '.columns // empty | map(.name) | @csv')
    if [ -n "${cols}" ]; then
      echo "${cols}" >> "${OUTPUT}"
      header_written=true
    fi
  fi

  # 데이터 행 기록
  echo "${response}" | jq -r '.data // empty | .[] | @csv' >> "${OUTPUT}"

  # 다음 페이지 URI 확인
  next=$(echo "${response}" | jq -r '.nextUri // empty')
  if [ -z "${next}" ]; then
    break
  fi

  # 다음 페이지 요청
  response=$(curl -s -u "${USER}:${PASSWORD}" \
    -H "X-Trino-User: ${USER}" \
    "${next}")
done

echo "완료: ${OUTPUT} 저장됨"
```

---

## 참고사항

### HTTPS 필수
Trino는 Basic 인증(`-u ID:PASSWORD`)을 평문 HTTP에서는 거부한다. 반드시 `https://` 엔드포인트(보통 8443 포트)를 써야 하고, 사설 인증서라면 `-k` 옵션을 추가해야 할 수 있다.

### 필수 헤더
`X-Trino-User`는 대부분 필수다. 구버전 Trino/PrestoSQL이라면 `X-Presto-User`로 바뀔 수 있다. 카탈로그·스키마를 헤더로 지정하려면 다음을 추가한다.

```bash
-H "X-Trino-Catalog: my_catalog" \
-H "X-Trino-Schema: my_schema"
```

### 비밀번호 노출 방지
명령어에 비밀번호를 직접 넣으면 셸 히스토리나 프로세스 목록에 남는다. 실무에서는 환경변수나 `.netrc` 파일 사용을 권장한다.

```bash
export TRINO_PW='mypassword'
# 스크립트 안에서 PASSWORD="${TRINO_PW}"
```

### 응답 상태값
- `state` 필드로 쿼리 진행 상태 확인 가능 (`QUEUED`, `RUNNING`, `FINISHED`, `FAILED`)
- `nextUri`가 없으면 모든 결과 수신 완료
- 에러 시 `error.message`에 메시지가 담긴다
