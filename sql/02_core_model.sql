-- 02_core_model.sql — flatten raw payloads into a queryable model and split the
-- eligibility criteria into inclusion / exclusion sections.
--
-- No AI functions here. Profiling showed ~98% of criteria use canonical
-- "Inclusion Criteria:" / "Exclusion Criteria:" headers, so the split is deterministic
-- string work;

USE ROLE      ct_engineer;
USE WAREHOUSE ct_wh;
USE DATABASE  ct_trials;
USE SCHEMA    core;


-- Flatten the JSON payload into typed columns.
-- Arrays (phases, conditions, interventions) stay as arrays — flatten them at query time.
CREATE OR REPLACE TABLE core.trials AS
SELECT
    nct_id,                                                                            -- trial ID (key, joins back to raw)
    payload:protocolSection.identificationModule.briefTitle::STRING        AS title,           -- short trial title
    payload:protocolSection.identificationModule.officialTitle::STRING     AS official_title,  -- full formal title
    payload:protocolSection.sponsorCollaboratorsModule.leadSponsor.name::STRING AS lead_sponsor,   -- lead sponsor org name
    payload:protocolSection.sponsorCollaboratorsModule.leadSponsor."class"::STRING AS sponsor_class, -- sponsor type (INDUSTRY / NIH / OTHER)
    payload:protocolSection.designModule.studyType::STRING                 AS study_type,      -- INTERVENTIONAL / OBSERVATIONAL
    payload:protocolSection.designModule.phases                            AS phases,          -- array of phases, e.g. ["PHASE2","PHASE3"]
    payload:protocolSection.designModule.enrollmentInfo.count::NUMBER      AS enrollment,      -- target/actual participant count
    payload:protocolSection.statusModule.overallStatus::STRING             AS overall_status,  -- RECRUITING / COMPLETED / ...
    payload:protocolSection.statusModule.startDateStruct.date::STRING      AS start_date_raw,  -- start date as given, unparsed
    payload:protocolSection.conditionsModule.conditions                    AS conditions,      -- array of conditions studied
    payload:protocolSection.armsInterventionsModule.interventions          AS interventions,   -- array of interventions (drug/device/...)

    -- eligibility fields the registry already gives us structured
    payload:protocolSection.eligibilityModule.minimumAge::STRING           AS min_age_raw,     -- lower age bound, e.g. "18 Years"
    payload:protocolSection.eligibilityModule.maximumAge::STRING           AS max_age_raw,     -- upper age bound, e.g. "65 Years" (often absent)
    payload:protocolSection.eligibilityModule.sex::STRING                  AS sex,             -- eligible sex: ALL / FEMALE / MALE
    payload:protocolSection.eligibilityModule.healthyVolunteers::BOOLEAN   AS healthy_volunteers, -- accepts healthy volunteers?

    -- the free-text blob that is the actual problem this project exists to solve
    payload:protocolSection.eligibilityModule.eligibilityCriteria::STRING  AS criteria_text,   -- raw inclusion/exclusion prose

    source_batch,   -- which fetch batch this row came from (carried from raw)
    ingested_at     -- when the row was loaded (carried from raw)
FROM raw.studies_raw;


-- Split each criteria blob into an inclusion section and an exclusion section.
-- POSITION-based, not regex: easier to debug, and when a row doesn't fit, split_method
-- records why instead of the row silently coming back NULL.
CREATE OR REPLACE TABLE core.trial_criteria AS
WITH pos AS (
    SELECT
        nct_id,
        criteria_text,
        POSITION('inclusion criteria', LOWER(criteria_text)) AS incl_pos,  -- char index of the inclusion header (0 = not found)
        POSITION('exclusion criteria', LOWER(criteria_text)) AS excl_pos   -- char index of the exclusion header (0 = not found)
    FROM core.trials
    WHERE criteria_text IS NOT NULL
)
SELECT
    nct_id,
    criteria_text,                          -- original full text, kept for reference
    LENGTH(criteria_text) AS criteria_chars, -- total length, used later to detect dropped text

    -- inclusion section = text between the inclusion header and the exclusion header
    CASE
        -- both headers, inclusion first: the happy path (~98%)
        WHEN incl_pos > 0 AND excl_pos > incl_pos
            THEN TRIM(SUBSTR(criteria_text, incl_pos, excl_pos - incl_pos))
        -- inclusion only, no exclusion section
        WHEN incl_pos > 0
            THEN TRIM(SUBSTR(criteria_text, incl_pos))
        ELSE NULL
    END AS inclusion_text,

    -- exclusion section = everything from the exclusion header onward
    CASE
        WHEN excl_pos > 0 THEN TRIM(SUBSTR(criteria_text, excl_pos))
        ELSE NULL
    END AS exclusion_text,

    -- provenance for every row: how the split resolved, so a NULL is never unexplained
    CASE
        WHEN incl_pos > 0 AND excl_pos > incl_pos THEN 'BOTH_HEADERS'     -- clean, in-order split
        WHEN incl_pos > 0 AND excl_pos = 0        THEN 'INCLUSION_ONLY'   -- inclusion header, no exclusion
        WHEN incl_pos = 0 AND excl_pos > 0        THEN 'EXCLUSION_ONLY'   -- exclusion header, no inclusion
        WHEN incl_pos > 0 AND excl_pos < incl_pos THEN 'EXCLUSION_FIRST'  -- headers out of order
        ELSE 'NO_HEADERS'                                                 -- neither header present
    END AS split_method
FROM pos;


-- Verify the split distribution — this is the actual test of the splitter, not a formality.
SELECT
    split_method,
    COUNT(*) AS n,                                              -- rows in each split category
    ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2) AS pct,  -- share of all rows
    ROUND(AVG(LENGTH(inclusion_text))) AS avg_incl_chars,       -- avg inclusion length per category
    ROUND(AVG(LENGTH(exclusion_text))) AS avg_excl_chars        -- avg exclusion length per category
FROM core.trial_criteria
GROUP BY 1
ORDER BY 2 DESC;
-- expect BOTH_HEADERS ~1963; anything in EXCLUSION_FIRST or NO_HEADERS is a row the
-- splitter can't handle — inspect those specifically.


-- read the rows that didn't cleanly split
SELECT nct_id, split_method, criteria_text
FROM core.trial_criteria
WHERE split_method NOT IN ('BOTH_HEADERS')
LIMIT 20;


-- did the split drop any text? inclusion + exclusion should roughly reconstruct the
-- original (minus any preamble before the first header).
SELECT
    COUNT(*) AS n,
    COUNT_IF(
        LENGTH(COALESCE(inclusion_text, '')) + LENGTH(COALESCE(exclusion_text, ''))
        < criteria_chars * 0.8
    ) AS rows_losing_over_20pct   -- rows where >20% of the text vanished in the split
FROM core.trial_criteria
WHERE split_method = 'BOTH_HEADERS';
-- non-zero usually means a preamble before the first header — worth knowing before extraction.
