"""
Trino REST API 예제: requests 라이브러리로 쿼리를 실행하고 상태를 확인한다.

Trino는 HTTP 프로토콜로 동작한다.
  1. POST /v1/statement  로 쿼리 제출
  2. 응답의 nextUri 를 nextUri 가 사라질 때까지 GET 으로 폴링
  3. 각 응답의 stats.state 값이 현재 쿼리 상태
     (QUEUED -> PLANNING -> STARTING -> RUNNING -> FINISHING -> FINISHED / FAILED)

필요 패키지:  pip install requests
"""

import time
import requests


# ---------------------------------------------------------------------------
# 접속 설정
# ---------------------------------------------------------------------------
TRINO_HOST = "http://localhost:8080"   # Trino 코디네이터 주소
TRINO_USER = "trino_user"              # X-Trino-User (필수)
TRINO_CATALOG = "hive"                 # 선택
TRINO_SCHEMA = "default"               # 선택

# 인증이 필요한 클러스터라면 아래처럼 basic auth 등을 사용 (보통 https 필수)
#   AUTH = ("username", "password")
AUTH = None


def _build_headers():
    """Trino 요청 헤더. (구버전 호환이 필요하면 X-Presto-* 헤더를 함께 보낸다.)"""
    headers = {
        "X-Trino-User": TRINO_USER,
        "Content-Type": "text/plain",
    }
    if TRINO_CATALOG:
        headers["X-Trino-Catalog"] = TRINO_CATALOG
    if TRINO_SCHEMA:
        headers["X-Trino-Schema"] = TRINO_SCHEMA
    return headers


def _get_with_retry(url, headers):
    """nextUri 폴링용 GET. 503(자원 부족)이면 잠깐 쉬고 재시도한다."""
    while True:
        resp = requests.get(url, headers=headers, auth=AUTH, timeout=30)
        # Trino 프로토콜상 503 은 "잠시 후 다시 시도" 의미
        if resp.status_code == 503:
            time.sleep(0.1)
            continue
        resp.raise_for_status()
        return resp.json()


def execute_query(sql):
    """
    쿼리를 실행하고, 진행 상태를 출력하면서 결과를 모아 반환한다.

    반환값: (columns, rows, final_state)
    """
    headers = _build_headers()

    # 1) 쿼리 제출 -------------------------------------------------------------
    resp = requests.post(
        f"{TRINO_HOST}/v1/statement",
        data=sql.encode("utf-8"),
        headers=headers,
        auth=AUTH,
        timeout=30,
    )
    resp.raise_for_status()
    result = resp.json()

    query_id = result.get("id")
    info_uri = result.get("infoUri")  # 웹 UI 에서 쿼리 상세를 볼 수 있는 링크
    print(f"[제출 완료] Query ID = {query_id}")
    print(f"[Info URI ] {info_uri}\n")

    columns = None
    rows = []
    state = None

    # 2) nextUri 가 사라질 때까지 폴링 ----------------------------------------
    while True:
        # --- 현재 상태(stats.state) 확인 ---
        stats = result.get("stats", {})
        state = stats.get("state")
        completed = stats.get("completedSplits", 0)
        total = stats.get("totalSplits", 0)
        processed_rows = stats.get("processedRows", 0)
        elapsed_ms = stats.get("elapsedTimeMillis", 0)

        print(
            f"[상태] state={state:<10} "
            f"splits={completed}/{total} "
            f"rows={processed_rows} "
            f"elapsed={elapsed_ms}ms"
        )

        # --- 에러가 있으면 즉시 중단 ---
        if "error" in result:
            err = result["error"]
            raise RuntimeError(
                f"쿼리 실패: {err.get('message')} "
                f"(name={err.get('errorName')}, code={err.get('errorCode')})"
            )

        # --- 컬럼 / 데이터 수집 ---
        if columns is None and "columns" in result:
            columns = [c["name"] for c in result["columns"]]
        if "data" in result:
            rows.extend(result["data"])

        # --- 다음 페이지가 없으면 종료 ---
        next_uri = result.get("nextUri")
        if not next_uri:
            break

        # --- 다음 페이지 가져오기 ---
        result = _get_with_retry(next_uri, headers)

    print(f"\n[최종 상태] {state}")
    return columns, rows, state


def cancel_query(next_uri):
    """진행 중인 쿼리를 취소하려면 nextUri 로 DELETE 요청을 보낸다."""
    requests.delete(next_uri, headers=_build_headers(), auth=AUTH, timeout=30)


if __name__ == "__main__":
    query = "SELECT id, name FROM tpch.tiny.nation LIMIT 5"

    try:
        columns, rows, final_state = execute_query(query)

        print("\n===== 결과 =====")
        print(columns)
        for row in rows:
            print(row)

    except requests.HTTPError as e:
        print(f"HTTP 오류: {e}  (응답: {e.response.text})")
    except RuntimeError as e:
        print(e)
