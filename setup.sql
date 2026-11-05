-- =============================================================================
-- The Merger: Two Systems, One Revenue Number
-- Setup script: run this once, top to bottom (Run All).
--
-- Northbound Coffee (the acquirer) runs in-store POS registers.
-- Daily Grind (the company it just bought) takes web and app pickup orders.
-- Their order systems disagree on almost everything. That's on purpose.
--
-- Everything below is generated deterministically, so every attendee gets the
-- same rows and the same expected totals.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Part 1 (ACCOUNTADMIN): create a lab role that owns only what this lab needs.
-- You and CoCo work as MERGER_ROLE for the rest of the lab.
-- -----------------------------------------------------------------------------
USE ROLE ACCOUNTADMIN;

CREATE ROLE IF NOT EXISTS MERGER_ROLE
  COMMENT = 'Lab role for The Merger quickstart';
GRANT ROLE MERGER_ROLE TO ROLE SYSADMIN;

SET MY_USER = CURRENT_USER();
GRANT ROLE MERGER_ROLE TO USER IDENTIFIER($MY_USER);

-- CoCo needs a Cortex database role. Most accounts already grant CORTEX_USER
-- to PUBLIC; granting it here makes the lab work even where that was revoked.
GRANT DATABASE ROLE SNOWFLAKE.CORTEX_USER TO ROLE MERGER_ROLE;

CREATE WAREHOUSE IF NOT EXISTS MERGER_WH
  WAREHOUSE_SIZE = XSMALL
  AUTO_SUSPEND = 60
  AUTO_RESUME = TRUE
  INITIALLY_SUSPENDED = TRUE;
GRANT USAGE, OPERATE ON WAREHOUSE MERGER_WH TO ROLE MERGER_ROLE;

CREATE OR REPLACE DATABASE MERGER_DB;
GRANT OWNERSHIP ON DATABASE MERGER_DB TO ROLE MERGER_ROLE;

-- -----------------------------------------------------------------------------
-- Part 2 (MERGER_ROLE): build the source data.
-- -----------------------------------------------------------------------------
USE ROLE MERGER_ROLE;
USE WAREHOUSE MERGER_WH;

CREATE SCHEMA IF NOT EXISTS MERGER_DB.RAW;
CREATE SCHEMA IF NOT EXISTS MERGER_DB.ANALYTICS;

USE SCHEMA MERGER_DB.RAW;

-- -----------------------------------------------------------------------------
-- Store crosswalk: the one table both companies agree on.
-- POS stores are keyed by a register number, web stores by a location code.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE TABLE STORE_CROSSWALK (
  STORE_ID          VARCHAR COMMENT 'Unified store ID used after the merger',
  BRAND             VARCHAR COMMENT 'Northbound Coffee or Daily Grind',
  SOURCE_SYSTEM     VARCHAR COMMENT 'POS (STORE_SALES) or WEB (WEB_ORDERS)',
  SOURCE_STORE_KEY  VARCHAR COMMENT 'Store key as it appears in the source system',
  STORE_NAME        VARCHAR,
  CITY              VARCHAR,
  TIMEZONE          VARCHAR COMMENT 'IANA time zone of the store'
) COMMENT = 'Maps each source system store key to one unified STORE_ID';

INSERT INTO STORE_CROSSWALK VALUES
  ('S01', 'Northbound Coffee', 'POS', '101',       'Pike Place',     'Seattle',  'America/Los_Angeles'),
  ('S02', 'Northbound Coffee', 'POS', '102',       'Pearl District', 'Portland', 'America/Los_Angeles'),
  ('S03', 'Northbound Coffee', 'POS', '103',       'LoDo',           'Denver',   'America/Denver'),
  ('S04', 'Northbound Coffee', 'POS', '104',       'Wicker Park',    'Chicago',  'America/Chicago'),
  ('S05', 'Northbound Coffee', 'POS', '105',       'Back Bay',       'Boston',   'America/New_York'),
  ('S06', 'Daily Grind',       'WEB', 'DG-SF-01',  'Mission',        'San Francisco', 'America/Los_Angeles'),
  ('S07', 'Daily Grind',       'WEB', 'DG-PHX-01', 'Roosevelt Row',  'Phoenix',  'America/Phoenix'),
  ('S08', 'Daily Grind',       'WEB', 'DG-AUS-01', 'South Congress', 'Austin',   'America/Chicago'),
  ('S09', 'Daily Grind',       'WEB', 'DG-ATL-01', 'Midtown',        'Atlanta',  'America/New_York'),
  ('S10', 'Daily Grind',       'WEB', 'DG-NYC-01', 'Williamsburg',   'Brooklyn', 'America/New_York');

-- -----------------------------------------------------------------------------
-- Northbound Coffee POS export (lands as CSV, loaded into typed columns).
--   * Amounts are in DOLLARS (TOTAL_USD)
--   * Timestamps are STORE-LOCAL wall-clock time, with no time zone
--   * Stores are identified by a numeric register number (STORE_NUM)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE TABLE STORE_SALES (
  SALE_ID         VARCHAR,
  STORE_NUM       NUMBER(3,0),
  SALE_TIMESTAMP  TIMESTAMP_NTZ COMMENT 'Store-local time',
  ITEM_NAME       VARCHAR,
  QTY             NUMBER(3,0),
  TOTAL_USD       NUMBER(10,2) COMMENT 'Sale total in dollars',
  TENDER          VARCHAR
) COMMENT = 'Northbound Coffee in-store POS export';

INSERT INTO STORE_SALES
WITH menu (item_idx, item_name, price) AS (
  SELECT * FROM VALUES
    (0, 'Drip Coffee', 3.25), (1, 'Latte', 5.25), (2, 'Cold Brew', 4.75),
    (3, 'Mocha', 5.75), (4, 'Croissant', 3.95), (5, 'Breakfast Sandwich', 7.50)
),
g AS (
  SELECT ROW_NUMBER() OVER (ORDER BY SEQ4()) AS n
  FROM TABLE(GENERATOR(ROWCOUNT => 5000))
),
shaped AS (
  SELECT
    n,
    101 + MOD(n, 5)                                   AS store_num,
    MOD(ABS(HASH(n, 'pos_day')), 28)                  AS day_offset,
    -- 6:00am to 7:59pm local, weighted toward the morning rush
    LEAST(MOD(ABS(HASH(n, 'pos_min1')), 840),
          MOD(ABS(HASH(n, 'pos_min2')), 840))         AS minute_offset,
    MOD(ABS(HASH(n, 'pos_item')), 6)                  AS item_idx,
    1 + MOD(ABS(HASH(n, 'pos_qty')), 3)               AS qty,
    MOD(ABS(HASH(n, 'pos_keep')), 100)                AS keep_roll
  FROM g
)
SELECT
  'NB-' || LPAD(s.n::VARCHAR, 6, '0'),
  s.store_num,
  DATEADD(minute, s.minute_offset,
          DATEADD(day, s.day_offset, '2026-09-01 06:00:00'::TIMESTAMP_NTZ)),
  m.item_name,
  s.qty,
  m.price * s.qty,
  IFF(MOD(s.n, 4) = 0, 'CASH', 'CARD')
FROM shaped s
JOIN menu m ON m.item_idx = s.item_idx
-- Busier on weekends: keep fewer weekday rows
WHERE s.keep_roll < IFF(DAYOFWEEKISO(DATEADD(day, s.day_offset, '2026-09-01'::DATE)) >= 6, 100, 78);

-- -----------------------------------------------------------------------------
-- Daily Grind web and app orders (lands as JSON, one document per row).
--   * Amounts are in CENTS (amount_cents)
--   * Timestamps are UTC ISO-8601 strings (created_at ends in Z)
--   * Stores are identified by a location code (store_code)
--   * The order API retried some requests, so some orders arrive twice
-- -----------------------------------------------------------------------------
CREATE OR REPLACE TABLE WEB_ORDERS (
  RAW        VARIANT       COMMENT 'Order document as received from the web/app API',
  LOADED_AT  TIMESTAMP_NTZ COMMENT 'When the document landed in Snowflake (UTC)'
) COMMENT = 'Daily Grind web and app orders (JSON)';

INSERT INTO WEB_ORDERS
WITH menu (item_idx, item_name, price) AS (
  SELECT * FROM VALUES
    (0, 'Drip Coffee', 3.25), (1, 'Latte', 5.25), (2, 'Cold Brew', 4.75),
    (3, 'Mocha', 5.75), (4, 'Croissant', 3.95), (5, 'Breakfast Sandwich', 7.50)
),
g AS (
  SELECT ROW_NUMBER() OVER (ORDER BY SEQ4()) AS n
  FROM TABLE(GENERATOR(ROWCOUNT => 3600))
),
shaped AS (
  SELECT
    g.n,
    c.source_store_key AS store_code,
    c.timezone,
    MOD(ABS(HASH(g.n, 'web_day')), 28)                AS day_offset,
    -- 6:00am to 9:59pm local; app orders skew later in the day
    GREATEST(MOD(ABS(HASH(g.n, 'web_min1')), 960),
             MOD(ABS(HASH(g.n, 'web_min2')), 960))    AS minute_offset,
    MOD(ABS(HASH(g.n, 'web_item')), 6)                AS item_idx,
    1 + MOD(ABS(HASH(g.n, 'web_qty')), 3)             AS qty,
    MOD(ABS(HASH(g.n, 'web_sec')), 60)                AS sec,
    MOD(ABS(HASH(g.n, 'web_keep')), 100)              AS keep_roll
  FROM g
  JOIN STORE_CROSSWALK c
    ON c.source_system = 'WEB'
   AND c.store_id = 'S' || LPAD((6 + MOD(g.n, 5))::VARCHAR, 2, '0')
),
orders AS (
  SELECT
    s.n,
    OBJECT_CONSTRUCT(
      'order_id',     'DG-' || LPAD(s.n::VARCHAR, 6, '0'),
      'store_code',   s.store_code,
      'created_at',   TO_VARCHAR(
                        CONVERT_TIMEZONE(s.timezone, 'UTC',
                          DATEADD(second, s.sec,
                            DATEADD(minute, s.minute_offset,
                              DATEADD(day, s.day_offset, '2026-09-01 06:00:00'::TIMESTAMP_NTZ)))),
                        'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
      'channel',      IFF(MOD(s.n, 3) = 0, 'web', 'app'),
      'item',         m.item_name,
      'qty',          s.qty,
      'amount_cents', (m.price * s.qty * 100)::NUMBER(10,0)
    ) AS doc,
    DATEADD(day, s.day_offset, '2026-09-01 12:00:00'::TIMESTAMP_NTZ) AS loaded_at
  FROM shaped s
  JOIN menu m ON m.item_idx = s.item_idx
  WHERE s.keep_roll < IFF(DAYOFWEEKISO(DATEADD(day, s.day_offset, '2026-09-01'::DATE)) >= 6, 100, 80)
)
SELECT doc, loaded_at FROM orders
UNION ALL
-- API retries: every 40th order was delivered a second time, an hour later
SELECT doc, DATEADD(hour, 1, loaded_at) FROM orders WHERE MOD(n, 40) = 0;

-- -----------------------------------------------------------------------------
-- Quick look: you should see three tables in MERGER_DB.RAW
-- -----------------------------------------------------------------------------
SELECT 'STORE_CROSSWALK' AS table_name, COUNT(*) AS row_count FROM STORE_CROSSWALK
UNION ALL SELECT 'STORE_SALES', COUNT(*) FROM STORE_SALES
UNION ALL SELECT 'WEB_ORDERS',  COUNT(*) FROM WEB_ORDERS
ORDER BY table_name;
