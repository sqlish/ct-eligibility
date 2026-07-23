-- 00_setup.sql — one-time environment setup (run once as ACCOUNTADMIN in a Snowsight worksheet).

USE ROLE ACCOUNTADMIN;

-- Target environment (already provisioned):
--   Region  : AWS_US_EAST_1   -- Cortex runs natively here, no cross-region setup needed


-- Budget guardrail. Create this BEFORE the warehouse so the warehouse is capped from birth.
-- Caps warehouse compute only; AI-function token spend is billed separately and is NOT covered here.
CREATE OR REPLACE RESOURCE MONITOR ct_monitor
  WITH CREDIT_QUOTA = 25          -- monthly compute-credit ceiling
  FREQUENCY = MONTHLY
  START_TIMESTAMP = IMMEDIATELY
  TRIGGERS
    ON 50  PERCENT DO NOTIFY      -- warn at half the quota
    ON 80  PERCENT DO NOTIFY      -- warn again near the limit
    ON 100 PERCENT DO SUSPEND;    -- hard stop: suspend the warehouse at the quota


-- Warehouse. XSMALL; 60s auto-suspend.
CREATE OR REPLACE WAREHOUSE ct_wh
  WAREHOUSE_SIZE       = XSMALL
  AUTO_SUSPEND         = 60       -- seconds idle before it suspends and stops billing
  AUTO_RESUME          = TRUE     -- wake automatically on the next query
  INITIALLY_SUSPENDED  = TRUE     -- don't start billing the moment it's created
  RESOURCE_MONITOR     = ct_monitor;


-- Database, schemas, and role.
--   raw  = untouched API payloads (never mutate these)
--   core = modeled / enriched tables
--   eval = hand labels + accuracy results
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

-- Cortex access. Newer accounts may also need the account-level USE AI FUNCTIONS
-- privilege — if the smoke test throws a privilege error, uncomment the GRANT below.
GRANT DATABASE ROLE SNOWFLAKE.CORTEX_USER TO ROLE ct_engineer;
-- GRANT USE AI FUNCTIONS ON ACCOUNT TO ROLE ct_engineer;

GRANT ROLE ct_engineer TO USER <YOUR_USER>;   -- replace with your Snowflake username


-- Smoke test: confirm Cortex works before building any pipeline on top of it.
USE ROLE      ct_engineer;
USE WAREHOUSE ct_wh;
USE DATABASE  ct_trials;
USE SCHEMA    core;

SELECT AI_COMPLETE('claude-sonnet-4-6', 'Reply with exactly one word: ok') AS smoke_test;

-- Expect 'ok'.
-- Privilege error   -> uncomment the USE AI FUNCTIONS grant above.
-- Model-not-found   -> run SELECT * FROM SNOWFLAKE.CORTEX.AVAILABLE_MODELS() and pick a current model.


-- Landing zone for the ingestion script: a JSON stage plus the raw target table.
CREATE STAGE IF NOT EXISTS ct_trials.raw.trials_stage
  FILE_FORMAT = (TYPE = JSON);

CREATE TABLE IF NOT EXISTS ct_trials.raw.studies_raw (
  nct_id        STRING,                                    -- trial's ClinicalTrials.gov ID (the key)
  payload       VARIANT,                                   -- full raw study JSON, stored untouched
  ingested_at   TIMESTAMP_NTZ DEFAULT CURRENT_TIMESTAMP(), -- when this row was last loaded
  source_batch  STRING                                     -- which fetch batch this row came from
);
