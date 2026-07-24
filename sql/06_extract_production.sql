-- ============================================================
-- 06_extract_production.sql
-- Apply the eligibility-fact extraction to all trials.
--
-- Differences from 03_extract_test.sql, all of which matter at 2,000 rows:
--
--   * Incremental. The table is created once, then re-runs only process
--     nct_ids not already present. Re-running costs money, so the pipeline
--     must not redo finished work.
--   * Handles irregular rows. Trials flagged needs_llm_split get the full
--     criteria_text rather than split sections — this is the fallback path
--     the flag exists for.
--   * Records which path each row took, so downstream consumers can filter
--     on extraction provenance.
-- ============================================================

USE ROLE      ct_engineer;
USE WAREHOUSE ct_wh;
USE DATABASE  ct_trials;
USE SCHEMA    core;


-- ------------------------------------------------------------
-- 0. Cost estimate. Run this BEFORE the extraction.
--    ~4 chars per token is the usual rough conversion.
-- ------------------------------------------------------------
SELECT
    COUNT(*)                                   AS trials_to_extract,
    ROUND(SUM(LENGTH(COALESCE(inclusion_text, '') || COALESCE(exclusion_text, '')
                     || IFF(needs_llm_split, criteria_text, ''))) / 4) AS est_input_tokens,
    COUNT(*) * 120                             AS est_output_tokens,
    ROUND(SUM(LENGTH(COALESCE(inclusion_text, '') || COALESCE(exclusion_text, ''))) / 4 / 1000000.0, 3)
                                               AS est_input_millions
FROM core.trial_criteria;


-- ------------------------------------------------------------
-- 1. Create the facts table if it doesn't exist yet.
--    Separate from the insert so re-runs don't wipe prior work.
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS core.trial_facts (
    nct_id                            STRING,
    min_bmi                           FLOAT,
    max_bmi                           FLOAT,
    hba1c_threshold                   FLOAT,
    requires_diabetes                 BOOLEAN,
    excludes_diabetes                 BOOLEAN,
    excludes_prior_bariatric_surgery  BOOLEAN,
    excludes_pregnancy                BOOLEAN,
    extraction_path                   STRING,      -- SPLIT_SECTIONS | FULL_TEXT_FALLBACK
    extracted_at                      TIMESTAMP_NTZ
);


-- ------------------------------------------------------------
-- 2. Extract only what's missing.
--
--    The anti-join on trial_facts is the incremental guard: rows already
--    extracted are skipped, so this statement is safe to re-run after an
--    interruption without paying twice.
--
--    Prompt input depends on the split outcome: clean rows get the two
--    sections (cheaper, better-scoped); irregular rows get the raw blob
--    and let the model find the structure.
-- ------------------------------------------------------------
INSERT INTO core.trial_facts
WITH pending AS (
    SELECT
        c.nct_id,
        c.needs_llm_split,
        CASE
            WHEN c.needs_llm_split THEN
                CONCAT('FULL ELIGIBILITY CRITERIA (structure is irregular; ',
                       'identify inclusion vs exclusion yourself):\n', c.criteria_text)
            ELSE
                CONCAT('INCLUSION SECTION:\n', COALESCE(c.inclusion_text, ''), '\n\n',
                       'EXCLUSION SECTION:\n', COALESCE(c.exclusion_text, ''))
        END AS criteria_block
    FROM core.trial_criteria c
    LEFT JOIN core.trial_facts f ON f.nct_id = c.nct_id
    WHERE f.nct_id IS NULL
),
extracted AS (
    SELECT
        nct_id,
        needs_llm_split,
        SNOWFLAKE.CORTEX.TRY_COMPLETE(
            'claude-sonnet-4-6',
            [ { 'role': 'user', 'content': CONCAT(
                'You are extracting structured eligibility facts from a clinical trial. ',
                'Use ONLY the text provided. If a fact is not stated, return null for it. ',
                'Do not infer or guess. ',
                criteria_block
            ) } ],
            {
                'temperature': 0,
                'max_tokens': 500,
                'response_format': {
                    'type': 'json',
                    'schema': {
                        'type': 'object',
                        'properties': {
                            'min_bmi': {'type': ['number','null'],
                                'description': 'Minimum BMI required for inclusion. Absolute BMI only — return null for percentile-based thresholds.'},
                            'max_bmi': {'type': ['number','null'],
                                'description': 'Maximum BMI allowed for inclusion.'},
                            'hba1c_threshold': {'type': ['number','null'],
                                'description': 'HbA1c threshold as a PERCENTAGE. Convert mmol/mol to percent if the trial reports mmol/mol.'},
                            'requires_diabetes': {'type': 'boolean',
                                'description': 'true if a diabetes diagnosis is required for inclusion.'},
                            'excludes_diabetes': {'type': 'boolean',
                                'description': 'true if diabetes in ANY form excludes a patient, including when stated as a subtype such as type 1, type 2, or insulin-dependent diabetes.'},
                            'excludes_prior_bariatric_surgery': {'type': 'boolean',
                                'description': 'true if prior bariatric or weight-loss surgery is an exclusion.'},
                            'excludes_pregnancy': {'type': 'boolean',
                                'description': 'true if pregnancy, breastfeeding, or planned pregnancy is an exclusion.'}
                        },
                        'required': ['min_bmi','max_bmi','hba1c_threshold','requires_diabetes',
                                     'excludes_diabetes','excludes_prior_bariatric_surgery','excludes_pregnancy']
                    }
                }
            }
        ):structured_output[0] AS facts
    FROM pending
)
SELECT
    nct_id,
    facts:raw_message:min_bmi::FLOAT,
    facts:raw_message:max_bmi::FLOAT,
    facts:raw_message:hba1c_threshold::FLOAT,
    facts:raw_message:requires_diabetes::BOOLEAN,
    facts:raw_message:excludes_diabetes::BOOLEAN,
    facts:raw_message:excludes_prior_bariatric_surgery::BOOLEAN,
    facts:raw_message:excludes_pregnancy::BOOLEAN,
    IFF(needs_llm_split, 'FULL_TEXT_FALLBACK', 'SPLIT_SECTIONS'),
    CURRENT_TIMESTAMP()
FROM extracted;


-- ------------------------------------------------------------
-- 3. Verify. Any row with all-NULL facts means TRY_COMPLETE returned
--    NULL for it (a failed call), not that the trial stated nothing.
-- ------------------------------------------------------------
SELECT
    extraction_path,
    COUNT(*) AS n,
    COUNT_IF(min_bmi IS NULL AND max_bmi IS NULL AND hba1c_threshold IS NULL
             AND requires_diabetes IS NULL AND excludes_diabetes IS NULL) AS all_null_rows
FROM core.trial_facts
GROUP BY 1;

SELECT COUNT(*) AS total_trials FROM core.trial_criteria;
SELECT COUNT(*) AS extracted     FROM core.trial_facts;
-- These two should match. If extracted is lower, re-run section 2 —
-- it will pick up only what's missing.


-- ------------------------------------------------------------
-- 4. What the structured data now lets you ask.
-- ------------------------------------------------------------

-- Distribution of BMI floors across the corpus
SELECT min_bmi, COUNT(*) AS trials
FROM core.trial_facts
WHERE min_bmi IS NOT NULL
GROUP BY 1 ORDER BY 1;

-- The question from the top of the README, now over the full population
SELECT t.nct_id, t.title, f.min_bmi, f.max_bmi
FROM core.trial_facts f
JOIN core.trials t USING (nct_id)
WHERE f.min_bmi <= 32
  AND (f.max_bmi IS NULL OR f.max_bmi >= 32)
  AND NOT COALESCE(f.requires_diabetes, FALSE)
  AND NOT COALESCE(f.excludes_diabetes, FALSE)
ORDER BY t.nct_id
LIMIT 25;

-- How restrictive is the corpus overall?
SELECT
    COUNT(*)                                            AS trials,
    COUNT_IF(excludes_pregnancy)                        AS excl_pregnancy,
    COUNT_IF(excludes_prior_bariatric_surgery)          AS excl_bariatric,
    COUNT_IF(excludes_diabetes)                         AS excl_diabetes,
    COUNT_IF(requires_diabetes)                         AS req_diabetes,
    COUNT_IF(hba1c_threshold IS NOT NULL)               AS has_hba1c_gate
FROM core.trial_facts;
