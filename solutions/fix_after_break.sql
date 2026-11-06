-- =============================================================================
-- The Merger: reference fix for the morning-after surprise (fallback)
--
-- The POS vendor renamed TOTAL_USD to SALE_AMOUNT_USD, so ORDERS_UNIFIED
-- failed with "invalid identifier 'S.TOTAL_USD'" and DAILY_REVENUE was
-- skipped as UPSTREAM_FAILED. Point ORDERS_UNIFIED at the new column name,
-- then refresh. Use this only if you want to compare against CoCo's fix.
-- =============================================================================

USE ROLE MERGER_ROLE;
USE WAREHOUSE MERGER_WH;
USE SCHEMA MERGER_DB.ANALYTICS;

-- CREATE OR ALTER keeps the existing Dynamic Table and its grants, and updates
-- its definition. Changing the query still reinitializes it.
CREATE OR ALTER DYNAMIC TABLE MERGER_DB.ANALYTICS.ORDERS_UNIFIED
  TARGET_LAG = DOWNSTREAM
  WAREHOUSE = MERGER_WH
  COMMENT = 'One row per order from Northbound POS and Daily Grind web, in dollars and store-local time'
AS
SELECT
  s.SALE_ID                       AS ORDER_ID,
  c.STORE_ID,
  c.BRAND,
  'In-store'                      AS CHANNEL,
  c.STORE_NAME,
  c.CITY,
  s.SALE_TIMESTAMP                AS ORDER_TS_LOCAL,
  s.SALE_TIMESTAMP::DATE          AS BUSINESS_DATE,
  s.ITEM_NAME,
  s.QTY,
  s.SALE_AMOUNT_USD               AS AMOUNT_USD   -- was s.TOTAL_USD before the vendor update
FROM MERGER_DB.RAW.STORE_SALES s
JOIN MERGER_DB.RAW.STORE_CROSSWALK c
  ON c.SOURCE_SYSTEM = 'POS'
 AND c.SOURCE_STORE_KEY = s.STORE_NUM::VARCHAR

UNION ALL

SELECT
  w.ORDER_ID,
  c.STORE_ID,
  c.BRAND,
  'Web'                           AS CHANNEL,
  c.STORE_NAME,
  c.CITY,
  CONVERT_TIMEZONE('UTC', c.TIMEZONE, w.CREATED_AT_UTC)        AS ORDER_TS_LOCAL,
  CONVERT_TIMEZONE('UTC', c.TIMEZONE, w.CREATED_AT_UTC)::DATE  AS BUSINESS_DATE,
  w.ITEM_NAME,
  w.QTY,
  (w.AMOUNT_CENTS / 100)::NUMBER(10,2) AS AMOUNT_USD
FROM (
  SELECT
    RAW:order_id::VARCHAR             AS ORDER_ID,
    RAW:store_code::VARCHAR           AS STORE_CODE,
    RAW:created_at::TIMESTAMP_NTZ     AS CREATED_AT_UTC,
    RAW:item::VARCHAR                 AS ITEM_NAME,
    RAW:qty::NUMBER(3,0)              AS QTY,
    RAW:amount_cents::NUMBER(10,0)    AS AMOUNT_CENTS
  FROM MERGER_DB.RAW.WEB_ORDERS
  QUALIFY ROW_NUMBER() OVER (PARTITION BY RAW:order_id::VARCHAR ORDER BY LOADED_AT) = 1
) w
JOIN MERGER_DB.RAW.STORE_CROSSWALK c
  ON c.SOURCE_SYSTEM = 'WEB'
 AND c.SOURCE_STORE_KEY = w.STORE_CODE;

-- Refreshing the dashboard table refreshes ORDERS_UNIFIED first.
ALTER DYNAMIC TABLE MERGER_DB.ANALYTICS.DAILY_REVENUE REFRESH;
