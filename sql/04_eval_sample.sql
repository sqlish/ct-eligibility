-- ============================================================
-- 04_eval_sample.sql
-- Freeze a reproducible 30-trial sample for the extraction eval.
--
-- Why a fixed table and not just ORDER BY RANDOM():
--   The eval must be reproducible. Anyone cloning the repo should be able
--   to score against the SAME 30 trials the labels correspond to. So we
--   draw once, with a deterministic hash-based order, and persist it.
--
-- Sampling frame: only BOTH_HEADERS rows. The eval measures fact
-- extraction quality on cleanly-split criteria; the irregular tail is a
-- separate concern (the LLM-fallback split), not what we're scoring here.
-- ============================================================

USE ROLE      ct_engineer;
USE WAREHOUSE ct_wh;
USE DATABASE  ct_trials;
USE SCHEMA    eval;

CREATE OR REPLACE TABLE eval.eval_sample AS
SELECT
    c.nct_id,
    t.title,
    c.inclusion_text,
    c.exclusion_text
FROM core.trial_criteria c
JOIN core.trials t USING (nct_id)
WHERE c.split_method = 'BOTH_HEADERS'
-- Deterministic pseudo-random order: hash the id, take the same 30 every
-- time. No seed drift, no dependence on table scan order.
ORDER BY MD5(c.nct_id)
LIMIT 30;

SELECT COUNT(*) AS eval_rows FROM eval.eval_sample;   -- expect 30
