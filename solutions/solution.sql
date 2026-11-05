-- =============================================================================
-- The Merger: reference pipeline (fallback / answer key)
--
-- Use this only if you fall behind or want to compare against what CoCo built.
-- Your CoCo-generated SQL can look different and still be correct; the check
-- queries in checks.sql are what tell you it's right.
--
-- Business rules (the same ones given to CoCo in the guide):
--   1. Revenue is in dollars. Web amount_cents / 100.
--   2. The business day is the store's LOCAL date. Web created_at is UTC.
--   3. A web order counts once. Keep the earliest-loaded copy of each order_id.
--   4. Every order gets the unified STORE_ID from RAW.STORE_CROSSWALK.
-- =============================================================================

USE ROLE MERGER_ROLE;
USE WAREHOUSE MERGER_WH;
USE SCHEMA MERGER_DB.ANALYTICS;

-- One row per real order, from both companies, in one shape.
CREATE OR REPLACE DYNAMIC TABLE MERGER_DB.ANALYTICS.ORDERS_UNIFIED
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
  s.TOTAL_USD                     AS AMOUNT_USD
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

-- One row per store per local business day: what the CEO's dashboard reads.
CREATE OR REPLACE DYNAMIC TABLE MERGER_DB.ANALYTICS.DAILY_REVENUE
  TARGET_LAG = '1 hour'
  WAREHOUSE = MERGER_WH
  COMMENT = 'Daily revenue per store and channel, by store-local business date'
AS
SELECT
  BUSINESS_DATE,
  STORE_ID,
  BRAND,
  CHANNEL,
  STORE_NAME,
  CITY,
  COUNT(*)                                AS ORDER_COUNT,
  SUM(AMOUNT_USD)                         AS REVENUE_USD,
  ROUND(SUM(AMOUNT_USD) / COUNT(*), 2)    AS AVG_ORDER_USD
FROM MERGER_DB.ANALYTICS.ORDERS_UNIFIED
GROUP BY BUSINESS_DATE, STORE_ID, BRAND, CHANNEL, STORE_NAME, CITY;

SHOW DYNAMIC TABLES IN SCHEMA MERGER_DB.ANALYTICS;
