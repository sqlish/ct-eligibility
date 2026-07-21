-- ============================================================
-- 02b_criteria_split.sql
-- Split eligibility criteria into inclusion / exclusion sections.
--
-- Design decision, reached by profiling all 2,000 rows:
--   * 98.15% use canonical, in-order "Inclusion Criteria:" and
--     "Exclusion Criteria:" headers. For these, splitting is exact,
--     deterministic string work — no LLM needed or wanted.
--   * The remaining ~1.85% are irregular in mutually incompatible ways:
--     bare "Inclusion:" headers, criteria structured by role/condition/
--     person, mid-text mentions of the word "inclusion", "see other
--     study", or no criteria at all. Attempts to catch these with more
--     string rules recovered some rows while silently mis-splitting
--     others. So the rule is deliberately strict: match ONLY the clean
--     in-order canonical case, and route everything else to the LLM,
--     which handles irregular structure far better than accreting
--     brittle special cases would.
--
-- The strict-match/explicit-fallback split is the point: it keeps the
-- deterministic path trustworthy (no silent NULLs) and hands ambiguity
-- to the tool suited for it.
-- ============================================================

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
        -- Canonical headers only. Require the full "inclusion criteria"
        -- / "exclusion criteria" phrasing; anything looser is what kept
        -- matching body text by accident.
        POSITION('inclusion criteria', LOWER(criteria_text)) AS incl_pos,
        POSITION('exclusion criteria', LOWER(criteria_text)) AS excl_pos
    FROM core.trials
    WHERE criteria_text IS NOT NULL
)
SELECT
    nct_id,
    criteria_text,
    criteria_chars,

    -- Only produce a split for the clean, in-order canonical case.
    -- Everything else gets NULL sections AND needs_llm_split = TRUE,
    -- so a row is never both unsplit and unflagged.
    CASE
        WHEN incl_pos > 0 AND excl_pos > incl_pos
            THEN TRIM(SUBSTR(criteria_text, incl_pos, excl_pos - incl_pos))
        ELSE NULL
    END AS inclusion_text,

    CASE
        WHEN incl_pos > 0 AND excl_pos > incl_pos
            THEN TRIM(SUBSTR(criteria_text, excl_pos))
        ELSE NULL
    END AS exclusion_text,

    CASE
        WHEN incl_pos > 0 AND excl_pos > incl_pos THEN 'BOTH_HEADERS'
        ELSE 'IRREGULAR'
    END AS split_method,

    -- One clean boolean: TRUE for everything the deterministic path
    -- did not confidently split.
    (NOT (incl_pos > 0 AND excl_pos > incl_pos)) AS needs_llm_split
FROM pos;


-- ------------------------------------------------------------
-- Check 1: distribution. Expect BOTH_HEADERS = 1963 (98.15%),
-- IRREGULAR ~37, and — critically — ZERO rows that are unsplit but
-- unflagged.
-- ------------------------------------------------------------
SELECT split_method, needs_llm_split, COUNT(*) AS n,
       ROUND(100.0 * COUNT(*) / SUM(COUNT(*)) OVER (), 2) AS pct
FROM core.trial_criteria
GROUP BY 1, 2
ORDER BY 3 DESC;


-- ------------------------------------------------------------
-- Check 2: integrity guarantee. Both of these must return 0.
--   a) split but flagged for LLM  b) unsplit but NOT flagged
-- ------------------------------------------------------------
SELECT
    COUNT_IF(inclusion_text IS NOT NULL AND needs_llm_split)      AS split_but_flagged,
    COUNT_IF(inclusion_text IS NULL     AND NOT needs_llm_split)  AS unsplit_but_unflagged
FROM core.trial_criteria;


-- ------------------------------------------------------------
-- Check 3: eyeball a few clean splits to confirm they're real headers,
-- not mid-text matches.
-- ------------------------------------------------------------
SELECT nct_id,
       LEFT(inclusion_text, 90) AS incl_preview,
       LEFT(exclusion_text, 90) AS excl_preview
FROM core.trial_criteria
WHERE split_method = 'BOTH_HEADERS'
ORDER BY RANDOM()
LIMIT 8;
