-- ============================================================
-- 01_explore.sql
-- Profile the raw payloads BEFORE writing any AI functions.
-- Run these one at a time in a Snowsight worksheet. Read the output.
-- ============================================================

USE ROLE      ct_engineer;
USE WAREHOUSE ct_wh;
USE DATABASE  ct_trials;
USE SCHEMA    raw;


-- ------------------------------------------------------------
-- 1. Sanity: did the load land cleanly?
-- ------------------------------------------------------------
SELECT
    COUNT(*)                   AS total_rows,
    COUNT(DISTINCT nct_id)     AS distinct_trials,
    COUNT(DISTINCT source_batch) AS batches,
    MIN(ingested_at)           AS first_load,
    MAX(ingested_at)           AS last_load
FROM studies_raw;
-- Expect: 2000 / 2000 / 1


-- ------------------------------------------------------------
-- 2. What does one payload actually look like?
--    Click the cell in Snowsight to expand the JSON tree.
-- ------------------------------------------------------------
SELECT payload
FROM studies_raw
LIMIT 1;


-- ------------------------------------------------------------
-- 3. Which top-level modules exist, and how often?
--    This tells you what you can rely on vs. what's optional.
-- ------------------------------------------------------------
SELECT
    f.key   AS module_name,
    COUNT(*) AS trials_with_module,
    ROUND(100.0 * COUNT(*) / (SELECT COUNT(*) FROM studies_raw), 1) AS pct
FROM studies_raw,
     LATERAL FLATTEN(input => payload:protocolSection) f
GROUP BY 1
ORDER BY 2 DESC;


-- ------------------------------------------------------------
-- 4. Pull the fields that matter into a readable shape.
--    Note phases/conditions are ARRAYS — a trial can be PHASE2|PHASE3.
-- ------------------------------------------------------------
SELECT
    nct_id,
    payload:protocolSection.identificationModule.briefTitle::STRING   AS title,
    payload:protocolSection.designModule.studyType::STRING            AS study_type,
    payload:protocolSection.designModule.phases                       AS phases,
    payload:protocolSection.statusModule.overallStatus::STRING        AS status,
    payload:protocolSection.conditionsModule.conditions               AS conditions,
    payload:protocolSection.eligibilityModule.minimumAge::STRING      AS min_age,
    payload:protocolSection.eligibilityModule.maximumAge::STRING      AS max_age,
    payload:protocolSection.eligibilityModule.sex::STRING             AS sex,
    payload:protocolSection.eligibilityModule.healthyVolunteers::BOOLEAN AS healthy_volunteers
FROM studies_raw
LIMIT 20;


-- ------------------------------------------------------------
-- 5. The filters you pushed downstream. Was that call justified?
-- ------------------------------------------------------------
SELECT
    payload:protocolSection.designModule.studyType::STRING AS study_type,
    COUNT(*) AS n
FROM studies_raw
GROUP BY 1 ORDER BY 2 DESC;

SELECT
    f.value::STRING AS phase,
    COUNT(*)        AS n
FROM studies_raw,
     LATERAL FLATTEN(input => payload:protocolSection.designModule.phases) f
GROUP BY 1 ORDER BY 2 DESC;

-- Trials with NO phases key at all (observational studies usually):
SELECT COUNT(*) AS no_phase_key
FROM studies_raw
WHERE payload:protocolSection.designModule.phases IS NULL;


-- ------------------------------------------------------------
-- 6. THE MAIN EVENT: eligibility criteria coverage.
--    If a big chunk are NULL, your usable sample is smaller than 2000.
-- ------------------------------------------------------------
SELECT
    COUNT(*) AS total,
    COUNT(payload:protocolSection.eligibilityModule.eligibilityCriteria) AS has_criteria,
    COUNT(*) - COUNT(payload:protocolSection.eligibilityModule.eligibilityCriteria) AS missing
FROM studies_raw;


-- ------------------------------------------------------------
-- 7. How long is the text? This drives your token cost.
--    ~4 chars per token, so avg_chars/4 ≈ input tokens per row.
-- ------------------------------------------------------------
WITH c AS (
    SELECT LENGTH(payload:protocolSection.eligibilityModule.eligibilityCriteria::STRING) AS len
    FROM studies_raw
    WHERE payload:protocolSection.eligibilityModule.eligibilityCriteria IS NOT NULL
)
SELECT
    MIN(len)                                    AS min_chars,
    ROUND(AVG(len))                             AS avg_chars,
    MEDIAN(len)                                 AS median_chars,
    PERCENTILE_CONT(0.95) WITHIN GROUP (ORDER BY len) AS p95_chars,
    MAX(len)                                    AS max_chars,
    ROUND(SUM(len) / 4)                         AS est_total_input_tokens
FROM c;


-- ------------------------------------------------------------
-- 8. Is the text structured at all? Test your assumptions.
--    If these aren't ~100%, you can't just regex/split on headers —
--    which is the argument for using an LLM here at all.
-- ------------------------------------------------------------
WITH c AS (
    SELECT
        nct_id,
        payload:protocolSection.eligibilityModule.eligibilityCriteria::STRING AS criteria
    FROM studies_raw
    WHERE payload:protocolSection.eligibilityModule.eligibilityCriteria IS NOT NULL
)
SELECT
    COUNT(*)                                          AS n,
    COUNT_IF(criteria ILIKE '%inclusion criteria%')   AS has_inclusion_header,
    COUNT_IF(criteria ILIKE '%exclusion criteria%')   AS has_exclusion_header,
    COUNT_IF(criteria ILIKE '%inclusion criteria%'
         AND criteria ILIKE '%exclusion criteria%')   AS has_both,
    COUNT_IF(criteria NOT ILIKE '%inclusion%'
         AND criteria NOT ILIKE '%exclusion%')        AS has_neither,
    COUNT_IF(criteria LIKE '%*%')                     AS uses_asterisk_bullets,
    COUNT_IF(criteria LIKE '%-%')                     AS uses_dash_bullets
FROM c;


-- ------------------------------------------------------------
-- 9. Read three of them. Actually read them.
--    This is the step people skip, and it's the one that tells you
--    what you're really up against.
-- ------------------------------------------------------------
SELECT
    nct_id,
    payload:protocolSection.eligibilityModule.eligibilityCriteria::STRING AS criteria
FROM studies_raw
WHERE payload:protocolSection.eligibilityModule.eligibilityCriteria IS NOT NULL
ORDER BY LENGTH(criteria) DESC
LIMIT 3;
-- ^ the three longest. Now look at the three shortest:

SELECT
    nct_id,
    payload:protocolSection.eligibilityModule.eligibilityCriteria::STRING AS criteria
FROM studies_raw
WHERE payload:protocolSection.eligibilityModule.eligibilityCriteria IS NOT NULL
ORDER BY LENGTH(criteria) ASC
LIMIT 3;
