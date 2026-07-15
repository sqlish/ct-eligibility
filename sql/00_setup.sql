-- ============================================================
-- 00_setup.sql
-- Clinical Trial Eligibility Structuring — environment setup
-- Run once, as ACCOUNTADMIN, in a Snowsight worksheet.
-- ============================================================

USE ROLE ACCOUNTADMIN;

-- ------------------------------------------------------------
-- 1. Environment (confirmed)
--    Region  : AWS_US_EAST_1  -- native Cortex, no cross-region needed
--    Account : WKC88042
--    User    : SQLISH
-- ------------------------------------------------------------


-- ------------------------------------------------------------
-- 2. Budget guardrail — do this BEFORE creating the warehouse.
--    NOTE: this caps warehouse compute only. AI function token
--    spend is billed separately and is NOT covered here.
-- ------------------------------------------------------------
CREATE OR REPLACE RESOURCE MONITOR ct_monitor
  WITH CREDIT_QUOTA = 25
  FREQUENCY = MONTHLY
  START_TIMESTAMP = IMMEDIATELY
  TRIGGERS
    ON 50  PERCENT DO NOTIFY
    ON 80  PERCENT DO NOTIFY
    ON 100 PERCENT DO SUSPEND;


-- ------------------------------------------------------------
-- 3. Warehouse — XSMALL is plenty. 60s auto-suspend matters more
--    than size for keeping the bill down.
-- ------------------------------------------------------------
CREATE OR REPLACE WAREHOUSE ct_wh
  WAREHOUSE_SIZE       = XSMALL
  AUTO_SUSPEND         = 60
  AUTO_RESUME          = TRUE
  INITIALLY_SUSPENDED  = TRUE
  RESOURCE_MONITOR     = ct_monitor;


-- ------------------------------------------------------------
-- 4. Database, schemas, role
--    RAW  = untouched API payloads (never mutate these)
--    CORE = enriched / modeled tables
--    EVAL = hand labels + accuracy results
-- ------------------------------------------------------------
CREATE DATABASE IF NOT EXISTS ct_trials;
CREATE SCHEMA   IF NOT EXISTS ct_trials.raw;
CREATE SCHEMA   IF NOT EXISTS ct_trials.core;
CREATE SCHEMA   IF NOT EXISTS ct_trials.eval;

CREATE ROLE IF NOT EXISTS ct_engineer;

GRANT USAGE, OPERATE ON WAREHOUSE ct_wh   TO ROLE ct_engineer;
GRANT USAGE            ON DATABASE ct_trials TO ROLE ct_engineer;
GRANT ALL              ON SCHEMA ct_trials.raw  TO ROLE ct_engineer;
GRANT ALL              ON SCHEMA ct_trials.core TO ROLE ct_engineer;
GRANT ALL              ON SCHEMA ct_trials.eval TO ROLE ct_engineer;

-- Cortex access. Newer accounts may also require the account-level
-- USE AI FUNCTIONS privilege — if the smoke test throws a privilege
-- error, uncomment the GRANT below.
GRANT DATABASE ROLE SNOWFLAKE.CORTEX_USER TO ROLE ct_engineer;
-- GRANT USE AI FUNCTIONS ON ACCOUNT TO ROLE ct_engineer;

GRANT ROLE ct_engineer TO USER SQLISH;


-- ------------------------------------------------------------
-- 5. Smoke test — prove Cortex works before you write any pipeline.
-- ------------------------------------------------------------
USE ROLE      ct_engineer;
USE WAREHOUSE ct_wh;
USE DATABASE  ct_trials;
USE SCHEMA    core;

SELECT AI_COMPLETE('claude-sonnet-4-6', 'Reply with exactly one word: ok') AS smoke_test;

-- Expected: 'ok'
-- If you get a privilege error -> uncomment the AI FUNCTIONS grant in section 4.
-- If you get a model-not-found error -> run:
--   SELECT * FROM SNOWFLAKE.CORTEX.AVAILABLE_MODELS();  -- and pick a current one


-- ------------------------------------------------------------
-- 6. Landing zone for the ingestion script (next step)
-- ------------------------------------------------------------
CREATE STAGE IF NOT EXISTS ct_trials.raw.trials_stage
  FILE_FORMAT = (TYPE = JSON);

CREATE TABLE IF NOT EXISTS ct_trials.raw.studies_raw (
  nct_id        STRING,
  payload       VARIANT,
  ingested_at   TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(),
  source_batch  STRING
);
