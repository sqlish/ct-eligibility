-- 04_eval_sample.sql — freeze a reproducible 30-trial sample for the extraction eval.
--
-- A fixed table rather than ORDER BY RANDOM(): the eval has to be reproducible, anyone
-- cloning the repo scores against the SAME 30 trials the labels correspond to.
--
-- Sampling frame is BOTH_HEADERS rows only. This measures extraction quality on cleanly-split
-- criteria; the irregular tail (the LLM-fallback split) is a separate concern, not scored here.

USE ROLE      ct_engineer;
USE WAREHOUSE ct_wh;
USE DATABASE  ct_trials;
USE SCHEMA    eval;

CREATE OR REPLACE TABLE eval.eval_sample AS
SELECT
    c.nct_id,          -- trial ID (key, joins to labels and predictions)
    t.title,           -- trial title, for the human labeler's context
    c.inclusion_text,  -- inclusion section the labeler reads and the model extracts from
    c.exclusion_text   -- exclusion section, same
FROM core.trial_criteria c
JOIN core.trials t USING (nct_id)
WHERE c.split_method = 'BOTH_HEADERS'
-- deterministic pseudo-random order: hash the id, take the same 30 every time.
-- no seed drift, no dependence on table scan order.
ORDER BY MD5(c.nct_id)
LIMIT 30;

SELECT COUNT(*) AS eval_rows FROM eval.eval_sample;   -- expect 30
