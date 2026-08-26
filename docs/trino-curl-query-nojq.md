# curl로 Trino 쿼리 실행하기 (jq 미사용, txt 저장)

`jq`를 사용하지 않고 `grep`/`sed`만으로 `nextUri`를 추출한다.
결과는 각 페이지의 원본 JSON 응답을 그대로 txt 파일에 이어 붙여 저장한다.

인증은 ID/PASSWORD(Basic 인증) 방식이다.

---

## 1. 간단한 단일 curl (결과가 적을 때)

```bash
curl -s -u "myuser:mypassword" \
  -X POST "https://trino.example.com:8443/v1/statement" \
  -H "X-Trino-User: myuser" \
  -H "Content-Type: text/plain" \
  -d "SELECT * FROM my_catalog.my_schema.my_table LIMIT 100" \
  -o result.txt
```

> **주의:** 이렇게 하면 첫 응답만 저장되고 `nextUri`로 이어지는 나머지 결과는 못 받는다. 데이터가 페이지 하나에 다 안 들어오면 아래 스크립트를 사용한다.

---

## 2. nextUri를 끝까지 따라가는 스크립트 (jq 미사용, 권장)

```bash
#!/usr/bin/env bash
set -euo pipefail

# ===== 설정 =====
TRINO_URL="https://trino.example.com:8443"
USER="myuser"
PASSWORD="mypassword"
QUERY="SELECT * FROM my_catalog.my_schema.my_table LIMIT 1000"
OUTPUT="result.txt"
# ================

: > "${OUTPUT}"   # 파일 초기화

# 첫 요청
response=$(curl -s -u "${USER}:${PASSWORD}" \
  -X POST "${TRINO_URL}/v1/statement" \
  -H "X-Trino-User: ${USER}" \
  -H "Content-Type: text/plain" \
  -d "${QUERY}")

while true; do
  # 에러 확인 (error 필드가 있으면 출력하고 종료)
  if echo "${response}" | grep -q '"failureInfo"'; then
    echo "Trino error 발생:" >&2
    echo "${response}" >&2
    exit 1
  fi

  # 원본 응답을 파일에 이어 붙임
  echo "${response}" >> "${OUTPUT}"

  # nextUri 추출 (grep + sed)
  next=$(echo "${response}" \
    | grep -o '"nextUri":"[^"]*"' \
    | head -1 \
    | sed 's/"nextUri":"//; s/"$//')

  # nextUri가 없으면 종료
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

## nextUri 추출 원리

Trino 응답 JSON에는 다음과 같은 필드가 들어 있다.

```json
{"id":"...","nextUri":"https://trino.example.com:8443/v1/statement/...","stats":{...}}
```

`grep -o '"nextUri":"[^"]*"'` 는 `"nextUri":"..."` 부분만 통째로 뽑아내고,
`sed`로 앞뒤 따옴표와 키 이름을 제거해 순수 URL만 남긴다.

```bash
echo "${response}" | grep -o '"nextUri":"[^"]*"' | head -1 | sed 's/"nextUri":"//; s/"$//'
```

`nextUri`가 응답에 없으면 결과 수신이 끝난 것이므로 반복을 멈춘다.

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
명령어에 비밀번호를 직접 넣으면 셸 히스토리나 프로세스 목록에 남는다. 실무에서는 환경변수 사용을 권장한다.

```bash
export TRINO_PW='mypassword'
# 스크립트 안에서 PASSWORD="${TRINO_PW}"
```

### 결과 형태
- 이 방식은 각 페이지의 **원본 JSON 응답 전체**를 txt에 저장한다.
- 데이터 값만 깔끔하게 뽑고 싶다면 `data` 필드 파싱이 필요하지만, jq 없이 순수 셸로 JSON을 정확히 파싱하는 것은 까다롭다. 값만 필요하다면 jq를 사용하는 편이 안전하다.
