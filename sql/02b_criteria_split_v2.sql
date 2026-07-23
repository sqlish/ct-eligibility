-- 02b_criteria_split_v2.sql — split eligibility criteria into inclusion / exclusion sections.
-- Supersedes the split in 02_core_model.sql (both build core.trial_criteria; run this one last).
--
-- Design decision, from profiling all 2,000 rows:
--   * 98.15% use canonical, in-order "Inclusion Criteria:" / "Exclusion Criteria:" headers.
--     For these the split is exact, deterministic string work — no LLM needed or wanted.
--   * The other ~1.85% are irregular in mutually incompatible ways: bare "Inclusion:" headers,
--     criteria grouped by role/condition/person, mid-text mentions of "inclusion", "see other
--     study", or no criteria at all. More string rules recovered some rows while silently
--     mis-splitting others. So the rule is deliberately strict: match ONLY the clean in-order
--     canonical case and route everything else to the LLM, which handles irregular structure
--     far better than piling on brittle special cases.
--
-- The strict-match + explicit-fallback split is the point: the deterministic path stays
-- trustworthy (no silent NULLs) and ambiguity is handed to the tool suited for it.

USE ROLE      ct_engineer;
USE WAREHOUSE ct_wh;
USE DATABASE  ct_trials;
USE SCHEMA    core;

CREATE OR REPLACE TABLE core.trial_criteria AS
WITH pos AS (
    SELECT
        nct_id,
        criteria_text,
        LENGTH(criteria_text) AS criteria_chars,
        -- Canonical headers only. Require the full "inclusion criteria" / "exclusion criteria"
        -- phrasing; anything looser is what kept matching body text by accident.
        POSITION('inclusion criteria', LOWER(criteria_text)) AS incl_pos,  -- char index of inclusion header (0 = absent)
        POSITION('exclusion criteria', LOWER(criteria_text)) AS excl_pos   -- char index of exclusion header (0 = absent)
    FROM core.trials
    WHERE criteria_text IS NOT NULL
)
SELECT
    nct_id,
    criteria_text,     -- original full text, kept for reference
    criteria_chars,    -- length of the original text

    -- inclusion section — only produced for the clean, in-order canonical case; NULL otherwise
    CASE
        WHEN incl_pos > 0 AND excl_pos > incl_pos
            THEN TRIM(SUBSTR(criteria_text, incl_pos, excl_pos - incl_pos))
        ELSE NULL
    END AS inclusion_text,

    -- exclusion section — same rule; NULL unless the row split cleanly
    CASE
        WHEN incl_pos > 0 AND excl_pos > incl_pos
            THEN TRIM(SUBSTR(criteria_text, excl_pos))
        ELSE NULL
    END AS exclusion_text,

    -- how the row resolved: BOTH_HEADERS = cleanly split, IRREGULAR = everything else
    CASE
        WHEN incl_pos > 0 AND excl_pos > incl_pos THEN 'BOTH_HEADERS'
        ELSE 'IRREGULAR'
    END AS split_method,

    -- TRUE for every row the deterministic path did not confidently split (the LLM's queue).
    -- Paired with the NULL sections above so a row is never both unsplit AND unflagged.
    (NOT (incl_pos > 0 AND excl_pos > incl_pos)) AS needs_llm_split
FROM pos;


-- Check 1: split distribution. Expect BOTH_HEADERS = 1963 (98.15%), IRREGULAR ~37,
-- and — critically — zero rows that are unsplit but unflagged.
SELECT split_method, needs_llm_split, COUNT(*) AS n,
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2) AS pct  -- share of all rows
FROM core.trial_criteria
GROUP BY 1, 2
ORDER BY 3 DESC;


-- Check 2: integrity guarantee — both counts must be 0.
SELECT
    COUNT_IF(inclusion_text IS NOT NULL AND needs_llm_split)      AS split_but_flagged,      -- split, yet flagged for LLM
    COUNT_IF(inclusion_text IS NULL     AND NOT needs_llm_split)  AS unsplit_but_unflagged   -- unsplit and NOT flagged (the dangerous silent case)
FROM core.trial_criteria;


-- Check 3: eyeball a few clean splits to confirm they're real headers, not mid-text matches.
SELECT nct_id,
       LEFT(inclusion_text, 90) AS incl_preview,  -- first 90 chars of each section
       LEFT(exclusion_text, 90) AS excl_preview
FROM core.trial_criteria
WHERE split_method = 'BOTH_HEADERS'
ORDER BY RANDOM()
LIMIT 8;
