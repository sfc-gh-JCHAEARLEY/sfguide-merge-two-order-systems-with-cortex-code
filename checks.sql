-- =============================================================================
-- The Merger: checkpoints
--
-- Run each CHECK block when the guide tells you to. Every row should say PASS.
-- Each block sets its own role and warehouse, so you can run any block on its own.
-- CHECK 4 fails on purpose until you fix the morning-after break.
-- These checks read the tables, not CoCo's chat output, so they tell you
-- whether the data is right no matter how CoCo wrote the SQL.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- CHECK 1 - after setup.sql
-- -----------------------------------------------------------------------------
USE ROLE MERGER_ROLE;
USE WAREHOUSE MERGER_WH;
SELECT check_name, expected, actual, IFF(expected = actual, 'PASS', 'FAIL') AS result
FROM (
  SELECT 'STORE_CROSSWALK rows' AS check_name, 10   AS expected, (SELECT COUNT(*) FROM MERGER_DB.RAW.STORE_CROSSWALK) AS actual
  UNION ALL SELECT 'STORE_SALES rows', 4216, (SELECT COUNT(*) FROM MERGER_DB.RAW.STORE_SALES)
  UNION ALL SELECT 'WEB_ORDERS documents', 3106, (SELECT COUNT(*) FROM MERGER_DB.RAW.WEB_ORDERS)
);

-- -----------------------------------------------------------------------------
-- CHECK 2 - after "Discover the Data"
-- Compare these with what CoCo reported about the two sources.
-- -----------------------------------------------------------------------------
USE ROLE MERGER_ROLE;
USE WAREHOUSE MERGER_WH;
SELECT check_name, expected, actual, IFF(expected = actual, 'PASS', 'FAIL') AS result
FROM (
  SELECT 'Unique web orders' AS check_name, 3040 AS expected,
         (SELECT COUNT(DISTINCT RAW:order_id::VARCHAR) FROM MERGER_DB.RAW.WEB_ORDERS) AS actual
  UNION ALL SELECT 'Duplicate web documents', 66,
         (SELECT COUNT(*) - COUNT(DISTINCT RAW:order_id::VARCHAR) FROM MERGER_DB.RAW.WEB_ORDERS)
  UNION ALL SELECT 'Web store codes missing from crosswalk', 0,
         (SELECT COUNT(*) FROM MERGER_DB.RAW.WEB_ORDERS w
          LEFT JOIN MERGER_DB.RAW.STORE_CROSSWALK c
            ON c.SOURCE_SYSTEM = 'WEB' AND c.SOURCE_STORE_KEY = w.RAW:store_code::VARCHAR
          WHERE c.STORE_ID IS NULL)
);

-- -----------------------------------------------------------------------------
-- CHECK 3 - after "Build the Pipeline"
-- -----------------------------------------------------------------------------
USE ROLE MERGER_ROLE;
USE WAREHOUSE MERGER_WH;
SELECT check_name, expected, actual, IFF(expected = actual, 'PASS', 'FAIL') AS result
FROM (
  SELECT 'ORDERS_UNIFIED rows' AS check_name, '7256' AS expected,
         (SELECT COUNT(*) FROM MERGER_DB.ANALYTICS.ORDERS_UNIFIED)::VARCHAR AS actual
  UNION ALL SELECT 'Orders with no STORE_ID', '0',
         (SELECT COUNT_IF(STORE_ID IS NULL) FROM MERGER_DB.ANALYTICS.ORDERS_UNIFIED)::VARCHAR
  UNION ALL SELECT 'DAILY_REVENUE rows (10 stores x 28 days)', '280',
         (SELECT COUNT(*) FROM MERGER_DB.ANALYTICS.DAILY_REVENUE)::VARCHAR
  UNION ALL SELECT 'Total revenue (USD)', '72702.55',
         (SELECT TO_VARCHAR(SUM(REVENUE_USD), 'FM999999999.00') FROM MERGER_DB.ANALYTICS.DAILY_REVENUE)
  UNION ALL SELECT 'Revenue on Sat Sept 19 (store-local day)', '3372.30',
         (SELECT TO_VARCHAR(SUM(REVENUE_USD), 'FM999999999.00') FROM MERGER_DB.ANALYTICS.DAILY_REVENUE
          WHERE BUSINESS_DATE = '2026-09-19')
);

-- -----------------------------------------------------------------------------
-- CHECK 4 - after "The Morning-After Break" is fixed
-- -----------------------------------------------------------------------------
USE ROLE MERGER_ROLE;
USE WAREHOUSE MERGER_WH;
SELECT check_name, expected, actual, IFF(expected = actual, 'PASS', 'FAIL') AS result
FROM (
  SELECT 'ORDERS_UNIFIED rows' AS check_name, '7406' AS expected,
         (SELECT COUNT(*) FROM MERGER_DB.ANALYTICS.ORDERS_UNIFIED)::VARCHAR AS actual
  UNION ALL SELECT 'Orders on Tue Sept 29 (new batch)', '150',
         (SELECT SUM(ORDER_COUNT) FROM MERGER_DB.ANALYTICS.DAILY_REVENUE
          WHERE BUSINESS_DATE = '2026-09-29')::VARCHAR
  UNION ALL SELECT 'Revenue on Tue Sept 29 (USD)', '1667.75',
         (SELECT TO_VARCHAR(SUM(REVENUE_USD), 'FM999999999.00') FROM MERGER_DB.ANALYTICS.DAILY_REVENUE
          WHERE BUSINESS_DATE = '2026-09-29')
  UNION ALL SELECT 'Total revenue (USD)', '74370.30',
         (SELECT TO_VARCHAR(SUM(REVENUE_USD), 'FM999999999.00') FROM MERGER_DB.ANALYTICS.DAILY_REVENUE)
  UNION ALL SELECT 'Latest DAILY_REVENUE refresh state', 'SUCCEEDED',
         (SELECT STATE FROM TABLE(MERGER_DB.INFORMATION_SCHEMA.DYNAMIC_TABLE_REFRESH_HISTORY(
                   NAME => 'MERGER_DB.ANALYTICS.DAILY_REVENUE'))
          WHERE STATE NOT IN ('SCHEDULED', 'EXECUTING')
          ORDER BY DATA_TIMESTAMP DESC LIMIT 1)
);
