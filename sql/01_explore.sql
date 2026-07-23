-- 01_explore.sql — profile the raw payloads before writing any AI functions.
-- Run these one query at a time in a Snowsight worksheet.

USE ROLE      ct_engineer;
USE WAREHOUSE ct_wh;
USE DATABASE  ct_trials;
USE SCHEMA    raw;


-- did the load land cleanly?
SELECT
    COUNT(*)                   AS total_rows,        -- rows loaded
    COUNT(DISTINCT nct_id)     AS distinct_trials,   -- should equal total_rows (no dupes)
    COUNT(DISTINCT source_batch) AS batches,         -- how many fetch runs are in here
    MIN(ingested_at)           AS first_load,        -- earliest load timestamp
    MAX(ingested_at)           AS last_load          -- most recent load timestamp
FROM studies_raw;
-- expect 2000 / 2000 / 1


-- eyeball one full payload (click the cell in Snowsight to expand the JSON tree)
SELECT payload
FROM studies_raw
LIMIT 1;


-- which top-level modules exist, and in what share of trials — shows what's reliable vs. optional
SELECT
    f.key   AS module_name,           -- name of a protocolSection sub-module
    COUNT(*) AS trials_with_module,   -- how many trials contain it
    ROUND(100.0 * COUNT(*) / (SELECT COUNT(*) FROM studies_raw), 1) AS pct  -- as a % of all trials
FROM studies_raw,
     LATERAL FLATTEN(input => payload:protocolSection) f
GROUP BY 1
ORDER BY 2 DESC;


-- pull the fields that matter into a readable shape.
-- phases/conditions stay as arrays — a trial can be PHASE2|PHASE3.
SELECT
    nct_id,
    payload:protocolSection.identificationModule.briefTitle::STRING   AS title,        -- short trial title
    payload:protocolSection.designModule.studyType::STRING            AS study_type,   -- INTERVENTIONAL / OBSERVATIONAL
    payload:protocolSection.designModule.phases                       AS phases,       -- array, e.g. ["PHASE2","PHASE3"]
    payload:protocolSection.statusModule.overallStatus::STRING        AS status,       -- RECRUITING / COMPLETED / ...
    payload:protocolSection.conditionsModule.conditions               AS conditions,   -- array of conditions studied
    payload:protocolSection.eligibilityModule.minimumAge::STRING      AS min_age,      -- e.g. "18 Years"
    payload:protocolSection.eligibilityModule.maximumAge::STRING      AS max_age,      -- e.g. "65 Years" (often absent)
    payload:protocolSection.eligibilityModule.sex::STRING             AS sex,          -- ALL / FEMALE / MALE
    payload:protocolSection.eligibilityModule.healthyVolunteers::BOOLEAN AS healthy_volunteers  -- accepts healthy people?
FROM studies_raw
LIMIT 20;


-- sanity-check the filters pushed upstream into the fetch script — was dropping them justified?
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

-- trials with no phases key at all (usually observational studies)
SELECT COUNT(*) AS no_phase_key
FROM studies_raw
WHERE payload:protocolSection.designModule.phases IS NULL;


-- eligibility-criteria coverage: how many trials actually carry the free text we need.
-- lots of NULLs here would mean the usable sample is smaller than the row count.
SELECT
    COUNT(*) AS total,
    COUNT(payload:protocolSection.eligibilityModule.eligibilityCriteria) AS has_criteria,          -- non-null criteria
    COUNT(*) - COUNT(payload:protocolSection.eligibilityModule.eligibilityCriteria) AS missing     -- trials with none
FROM studies_raw;


-- criteria text length -> rough token cost. ~4 chars per token, so avg_chars/4 ≈ input tokens per row.
WITH c AS (
    SELECT LENGTH(payload:protocolSection.eligibilityModule.eligibilityCriteria::STRING) AS len
    FROM studies_raw
    WHERE payload:protocolSection.eligibilityModule.eligibilityCriteria IS NOT NULL
)
SELECT
    MIN(len)                                    AS min_chars,     -- shortest criteria block
    ROUND(AVG(len))                             AS avg_chars,     -- average length
    MEDIAN(len)                                 AS median_chars,  -- typical length (robust to outliers)
    PERCENTILE_CONT(0.95) WITHIN GROUP (ORDER BY len) AS p95_chars,  -- 95th percentile (the long tail)
    MAX(len)                                    AS max_chars,     -- longest single block
    ROUND(SUM(len) / 4)                         AS est_total_input_tokens  -- ballpark total input tokens
FROM c;


-- is the criteria text structured? if these header rates aren't near 100%, a plain regex
-- split won't hold — which is exactly the argument for reaching to an LLM on the messy tail.
WITH c AS (
    SELECT
        nct_id,
        payload:protocolSection.eligibilityModule.eligibilityCriteria::STRING AS criteria
    FROM studies_raw
    WHERE payload:protocolSection.eligibilityModule.eligibilityCriteria IS NOT NULL
)
SELECT
    COUNT(*)                                          AS n,                     -- trials with criteria text
    COUNT_IF(criteria ILIKE '%inclusion criteria%')   AS has_inclusion_header,  -- has an "inclusion criteria" header
    COUNT_IF(criteria ILIKE '%exclusion criteria%')   AS has_exclusion_header,  -- has an "exclusion criteria" header
    COUNT_IF(criteria ILIKE '%inclusion criteria%'
         AND criteria ILIKE '%exclusion criteria%')   AS has_both,             -- has both (the splittable case)
    COUNT_IF(criteria NOT ILIKE '%inclusion%'
         AND criteria NOT ILIKE '%exclusion%')        AS has_neither,          -- has neither word at all
    COUNT_IF(criteria LIKE '%*%')                     AS uses_asterisk_bullets, -- bulleted with '*'
    COUNT_IF(criteria LIKE '%-%')                     AS uses_dash_bullets      -- bulleted with '-'
FROM c;


-- longest and shortest criteria blocks -- the outliers are where the header-split
-- assumptions tend to break, so read a few by hand before trusting the aggregates.
SELECT
    nct_id,
    payload:protocolSection.eligibilityModule.eligibilityCriteria::STRING AS criteria
FROM studies_raw
WHERE payload:protocolSection.eligibilityModule.eligibilityCriteria IS NOT NULL
ORDER BY LENGTH(criteria) DESC
LIMIT 3;

-- now the short tail:
SELECT
    nct_id,
    payload:protocolSection.eligibilityModule.eligibilityCriteria::STRING AS criteria
FROM studies_raw
WHERE payload:protocolSection.eligibilityModule.eligibilityCriteria IS NOT NULL
ORDER BY LENGTH(criteria) ASC
LIMIT 3;
