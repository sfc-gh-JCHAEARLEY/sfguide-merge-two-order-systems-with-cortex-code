-- =============================================================================
-- The Merger: the morning-after surprise
--
-- Northbound's POS vendor shipped a "minor" update. The new export renamed
-- TOTAL_USD to SALE_AMOUNT_USD, and the first batch in the new format
-- (Tuesday, Sept 29) landed overnight.
--
-- Run this whole script. The LAST statement is expected to FAIL.
-- That failure is the point: your job is to have CoCo find and fix it.
-- =============================================================================

USE ROLE MERGER_ROLE;
USE WAREHOUSE MERGER_WH;
USE SCHEMA MERGER_DB.RAW;

-- 1. The vendor's schema change
ALTER TABLE MERGER_DB.RAW.STORE_SALES RENAME COLUMN TOTAL_USD TO SALE_AMOUNT_USD;

-- 2. The first batch in the new format: Tuesday, Sept 29
INSERT INTO MERGER_DB.RAW.STORE_SALES
  (SALE_ID, STORE_NUM, SALE_TIMESTAMP, ITEM_NAME, QTY, SALE_AMOUNT_USD, TENDER)
WITH menu (item_idx, item_name, price) AS (
  SELECT * FROM VALUES
    (0, 'Drip Coffee', 3.25), (1, 'Latte', 5.25), (2, 'Cold Brew', 4.75),
    (3, 'Mocha', 5.75), (4, 'Croissant', 3.95), (5, 'Breakfast Sandwich', 7.50)
),
g AS (
  SELECT 900000 + ROW_NUMBER() OVER (ORDER BY SEQ4()) AS n
  FROM TABLE(GENERATOR(ROWCOUNT => 150))
)
SELECT
  'NB-' || LPAD(g.n::VARCHAR, 6, '0'),
  101 + MOD(g.n, 5),
  DATEADD(minute,
          LEAST(MOD(ABS(HASH(g.n, 'pos_min1')), 840), MOD(ABS(HASH(g.n, 'pos_min2')), 840)),
          '2026-09-29 06:00:00'::TIMESTAMP_NTZ),
  m.item_name,
  1 + MOD(ABS(HASH(g.n, 'pos_qty')), 3),
  m.price * (1 + MOD(ABS(HASH(g.n, 'pos_qty')), 3)),
  IFF(MOD(g.n, 4) = 0, 'CASH', 'CARD')
FROM g
JOIN menu m ON m.item_idx = MOD(ABS(HASH(g.n, 'pos_item')), 6);

-- 3. The CEO asks for fresh numbers.
--    Expected: this statement FAILS.
ALTER DYNAMIC TABLE MERGER_DB.ANALYTICS.DAILY_REVENUE REFRESH;
