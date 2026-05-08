-- ============================================================================
-- CROSS JOIN UNNEST 행 폭증 튜닝 — 단계별 적층 비교
--   v1 : ① 필터 푸시다운
--   v2 : ① + ② zip() 단일 UNNEST
--   v3 : ① + ② + ③ ROW 명명 필드 캐스팅
-- 세 쿼리 모두 동일 결과 반환. 각 단계 효과를 격리해 EXPLAIN ANALYZE 비교 가능.
-- 공통 패턴: raw_stock(원본) → today_stock(① 필터 푸시다운) → UNNEST → AGG
-- 각 버전의 차이는 CROSS JOIN UNNEST(...) 라인과 SELECT 필드 접근 방식에만 존재.
-- ============================================================================


-- ----------------------------------------------------------------------------
-- v1) ① 필터 푸시다운
--   WHERE 를 UNNEST 이전 CTE 단계에서 적용해 폭증된 행이 아닌 원본 행에서 가지치기.
--   입력 N행, 회사 K개, 필터 통과율 p% 일 때 산출 행 수: N*K → (N*p)*K.
-- ----------------------------------------------------------------------------
WITH
    raw_stock AS (
        SELECT dt, company_code, stock_min, stock_max, stock_end
        FROM (
            VALUES
                ('2026-01-01', ARRAY['TESLA', 'NVIDIA'], ARRAY[300, 244], ARRAY[310, 249], ARRAY[310, 247]),
                ('2026-01-02', ARRAY['TESLA', 'NVIDIA'], ARRAY[300, 244], ARRAY[310, 249], ARRAY[310, 247]),
                ('2026-01-03', ARRAY['TESLA', 'NVIDIA'], ARRAY[300, 244], ARRAY[310, 249], ARRAY[310, 247]),
                ('2026-01-04', ARRAY['TESLA', 'NVIDIA'], ARRAY[300, 244], ARRAY[310, 249], ARRAY[310, 247])
        ) AS t(dt, company_code, stock_min, stock_max, stock_end)
    ),
    today_stock AS (   -- ① UNNEST 이전 가지치기
        SELECT *
        FROM raw_stock
        WHERE dt BETWEEN '2026-01-01' AND '2026-01-10'
    )
SELECT
    dt
  , PARAM_NM
  , AVG(MEAN_VALUE) AS MEAN_VALUE
  , AVG(MAX_VALUE)  AS MAX_VALUE
  , AVG(END_VALUE)  AS END_VALUE
FROM today_stock
CROSS JOIN UNNEST(company_code, stock_min, stock_max, stock_end)
       AS t(PARAM_NM, MEAN_VALUE, MAX_VALUE, END_VALUE)
GROUP BY dt, PARAM_NM;


-- ----------------------------------------------------------------------------
-- v2) ① + ② zip() 단일 UNNEST
--   4개 ARRAY 병렬 UNNEST 는 컬럼별 길이검증/NULL 패딩/메타관리 비용이 누적.
--   zip() 으로 ARRAY(ROW(...)) 단일 컬렉션을 만들어 UNNEST 를 1회로 통합
--   → 페이지 처리 단순화, 할당 단일화, 캐시 친화적. 필드는 rec[1]..rec[4].
-- ----------------------------------------------------------------------------
WITH
    raw_stock AS (
        SELECT dt, company_code, stock_min, stock_max, stock_end
        FROM (
            VALUES
                ('2026-01-01', ARRAY['TESLA', 'NVIDIA'], ARRAY[300, 244], ARRAY[310, 249], ARRAY[310, 247]),
                ('2026-01-02', ARRAY['TESLA', 'NVIDIA'], ARRAY[300, 244], ARRAY[310, 249], ARRAY[310, 247]),
                ('2026-01-03', ARRAY['TESLA', 'NVIDIA'], ARRAY[300, 244], ARRAY[310, 249], ARRAY[310, 247]),
                ('2026-01-04', ARRAY['TESLA', 'NVIDIA'], ARRAY[300, 244], ARRAY[310, 249], ARRAY[310, 247])
        ) AS t(dt, company_code, stock_min, stock_max, stock_end)
    ),
    today_stock AS (
        SELECT *
        FROM raw_stock
        WHERE dt BETWEEN '2026-01-01' AND '2026-01-10'
    )
SELECT
    dt
  , rec[1]      AS PARAM_NM
  , AVG(rec[2]) AS MEAN_VALUE
  , AVG(rec[3]) AS MAX_VALUE
  , AVG(rec[4]) AS END_VALUE
FROM today_stock
CROSS JOIN UNNEST(zip(company_code, stock_min, stock_max, stock_end)) AS u(rec)
GROUP BY dt, rec[1];


-- ----------------------------------------------------------------------------
-- v3) ① + ② + ③ ROW 명명 필드 캐스팅
--   zip() 산출은 익명 ROW(T1..T4). CAST(... AS ARRAY(ROW(name TYPE, ...))) 로
--   명명 필드 타입을 부여:
--     - 가독성: rec[1] → rec.param_nm
--     - 옵티마이저가 필드 타입을 일찍 인지(이후 비교/집계 타입 추론에 도움)
--     - INTEGER 명시 캐스팅으로 AVG 입력 타입 모호성 제거
--   여기선 zip 결과를 별도 CTE(stock_records)로 분리해 UNNEST 라인 자체도 짧게 유지.
-- ----------------------------------------------------------------------------
WITH
    raw_stock AS (
        SELECT dt, company_code, stock_min, stock_max, stock_end
        FROM (
            VALUES
                ('2026-01-01', ARRAY['TESLA', 'NVIDIA'], ARRAY[300, 244], ARRAY[310, 249], ARRAY[310, 247]),
                ('2026-01-02', ARRAY['TESLA', 'NVIDIA'], ARRAY[300, 244], ARRAY[310, 249], ARRAY[310, 247]),
                ('2026-01-03', ARRAY['TESLA', 'NVIDIA'], ARRAY[300, 244], ARRAY[310, 249], ARRAY[310, 247]),
                ('2026-01-04', ARRAY['TESLA', 'NVIDIA'], ARRAY[300, 244], ARRAY[310, 249], ARRAY[310, 247])
        ) AS t(dt, company_code, stock_min, stock_max, stock_end)
    ),
    today_stock AS (
        SELECT *
        FROM raw_stock
        WHERE dt BETWEEN '2026-01-01' AND '2026-01-10'
    ),
    stock_records AS (   -- ② + ③ : zip 결과를 명명 ROW 배열로 한 번에 만들어 둠
        SELECT
            dt,
            CAST(
                zip(company_code, stock_min, stock_max, stock_end)
                AS ARRAY(ROW(
                    param_nm   VARCHAR,
                    mean_value INTEGER,
                    max_value  INTEGER,
                    end_value  INTEGER
                ))
            ) AS records
        FROM today_stock
    )
SELECT
    dt
  , rec.param_nm        AS PARAM_NM
  , AVG(rec.mean_value) AS MEAN_VALUE
  , AVG(rec.max_value)  AS MAX_VALUE
  , AVG(rec.end_value)  AS END_VALUE
FROM stock_records
CROSS JOIN UNNEST(records) AS u(rec)
GROUP BY dt, rec.param_nm;
