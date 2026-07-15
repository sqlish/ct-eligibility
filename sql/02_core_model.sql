-- ============================================================
-- 02_core_model.sql
-- Flatten raw payloads into a queryable model and split eligibility
-- criteria into inclusion/exclusion sections.
--
-- No AI functions here. Profiling showed 98.15% of criteria use canonical
-- "Inclusion Criteria:" / "Exclusion Criteria:" headers, so section
-- splitting is deterministic string work. Paying an LLM to locate a header
-- would be waste. The LLM is reserved for semantic normalization of the
-- facts inside each section, where regex genuinely cannot go.
-- ============================================================

USE ROLE      ct_engineer;
USE WAREHOUSE ct_wh;
USE DATABASE  ct_trials;
USE SCHEMA    core;


-- ------------------------------------------------------------
-- 1. Flatten the payload into columns.
--    Arrays (phases, conditions) stay as arrays — flatten at query time.
-- ------------------------------------------------------------
CREATE OR REPLACE TABLE core.trials AS
SELECT
    nct_id,
    payload:protocolSection.identificationModule.briefTitle::STRING        AS title,
    payload:protocolSection.identificationModule.officialTitle::STRING     AS official_title,
    payload:protocolSection.sponsorCollaboratorsModule.leadSponsor.name::STRING AS lead_sponsor,
    payload:protocolSection.sponsorCollaboratorsModule.leadSponsor."class"::STRING AS sponsor_class,
    payload:protocolSection.designModule.studyType::STRING                 AS study_type,
    payload:protocolSection.designModule.phases                            AS phases,
    payload:protocolSection.designModule.enrollmentInfo.count::NUMBER      AS enrollment,
    payload:protocolSection.statusModule.overallStatus::STRING             AS overall_status,
    payload:protocolSection.statusModule.startDateStruct.date::STRING      AS start_date_raw,
    payload:protocolSection.conditionsModule.conditions                    AS conditions,
    payload:protocolSection.armsInterventionsModule.interventions          AS interventions,

    -- eligibility: the structured bits the registry already gives us free
    payload:protocolSection.eligibilityModule.minimumAge::STRING           AS min_age_raw,
    payload:protocolSection.eligibilityModule.maximumAge::STRING           AS max_age_raw,
    payload:protocolSection.eligibilityModule.sex::STRING                  AS sex,
    payload:protocolSection.eligibilityModule.healthyVolunteers::BOOLEAN   AS healthy_volunteers,

    -- and the free-text blob that is the actual problem
    payload:protocolSection.eligibilityModule.eligibilityCriteria::STRING  AS criteria_text,

    source_batch,
    ingested_at
FROM raw.studies_raw;


-- ------------------------------------------------------------
-- 2. Split criteria into inclusion / exclusion.
--
--    POSITION-based rather than regex: easier to debug, and the failure
--    mode is visible (split_method tells you which rows fell through)
--    instead of silently returning NULL.
-- ------------------------------------------------------------
CREATE OR REPLACE TABLE core.trial_criteria AS
WITH pos AS (
    SELECT
        nct_id,
        criteria_text,
        POSITION('inclusion criteria', LOWER(criteria_text)) AS incl_pos,
        POSITION('exclusion criteria', LOWER(criteria_text)) AS excl_pos
    FROM core.trials
    WHERE criteria_text IS NOT NULL
)
SELECT
    nct_id,
    criteria_text,
    LENGTH(criteria_text) AS criteria_chars,

    CASE
        -- both headers, inclusion first: the happy path (~98%)
        WHEN incl_pos > 0 AND excl_pos > incl_pos
            THEN TRIM(SUBSTR(criteria_text, incl_pos, excl_pos - incl_pos))
        -- inclusion only, no exclusion section
        WHEN incl_pos > 0
            THEN TRIM(SUBSTR(criteria_text, incl_pos))
        ELSE NULL
    END AS inclusion_text,

    CASE
        WHEN excl_pos > 0 THEN TRIM(SUBSTR(criteria_text, excl_pos))
        ELSE NULL
    END AS exclusion_text,

    -- Provenance for every row. Never let a row be NULL for an unknown reason.
    CASE
        WHEN incl_pos > 0 AND excl_pos > incl_pos THEN 'BOTH_HEADERS'
        WHEN incl_pos > 0 AND excl_pos = 0        THEN 'INCLUSION_ONLY'
        WHEN incl_pos = 0 AND excl_pos > 0        THEN 'EXCLUSION_ONLY'
        WHEN incl_pos > 0 AND excl_pos < incl_pos THEN 'EXCLUSION_FIRST'
        ELSE 'NO_HEADERS'
    END AS split_method
FROM pos;


-- ------------------------------------------------------------
-- 3. Verify the split. This is the test, not a formality.
-- ------------------------------------------------------------
SELECT
    split_method,
    COUNT(*) AS n,
    ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2) AS pct,
    ROUND(AVG(LENGTH(inclusion_text))) AS avg_incl_chars,
    ROUND(AVG(LENGTH(exclusion_text))) AS avg_excl_chars
FROM core.trial_criteria
GROUP BY 1
ORDER BY 2 DESC;
-- Expect BOTH_HEADERS ~1963. Anything in EXCLUSION_FIRST or NO_HEADERS
-- is a row your splitter cannot handle — go look at those specifically.


-- ------------------------------------------------------------
-- 4. Read the rows that broke. This is where you learn something.
-- ------------------------------------------------------------
SELECT nct_id, split_method, criteria_text
FROM core.trial_criteria
WHERE split_method NOT IN ('BOTH_HEADERS')
LIMIT 20;


-- ------------------------------------------------------------
-- 5. Did the split lose any text? Inclusion + exclusion should
--    roughly reconstruct the original (minus any preamble).
-- ------------------------------------------------------------
SELECT
    COUNT(*) AS n,
    COUNT_IF(
        LENGTH(COALESCE(inclusion_text, '')) + LENGTH(COALESCE(exclusion_text, ''))
        < criteria_chars * 0.8
    ) AS rows_losing_over_20pct
FROM core.trial_criteria
WHERE split_method = 'BOTH_HEADERS';
-- Non-zero means text is disappearing — usually a preamble before the
-- first header. Worth knowing before you feed it to a model.
