-- 05_eval_extract_and_score.sql — run the extraction on the 30 eval trials, then score it
-- against the hand-labeled ground truth in eval.eval_labels.
--
-- The extraction is materialized (a table, not a view) so scoring can be re-run without
-- paying for inference again.

USE ROLE      ct_engineer;
USE WAREHOUSE ct_wh;
USE DATABASE  ct_trials;
USE SCHEMA    eval;

-- Extract facts for the 30 eval trials and persist them.
-- Same prompt + schema as the production run, so the eval measures what production will do.
CREATE OR REPLACE TABLE eval.eval_predictions AS
SELECT
    s.nct_id,
    SNOWFLAKE.CORTEX.TRY_COMPLETE(
        'claude-sonnet-4-6',
        [ { 'role': 'user', 'content': CONCAT(
            'You are extracting structured eligibility facts from a clinical trial. ',
            'Use ONLY the text provided. If a fact is not stated, return null for it. ',
            'Do not infer or guess. ',
            'INCLUSION SECTION:\n', COALESCE(s.inclusion_text, ''), '\n\n',
            'EXCLUSION SECTION:\n', COALESCE(s.exclusion_text, '')
        ) } ],
        {
            'temperature': 0,
            'max_tokens': 500,
            'response_format': {
                'type': 'json',
                'schema': {
                    'type': 'object',
                    'properties': {
                        'min_bmi': {'type': ['number','null']},
                        'max_bmi': {'type': ['number','null']},
                        'hba1c_threshold': {'type': ['number','null']},
                        'requires_diabetes': {'type': 'boolean'},
                        'excludes_diabetes': {'type': 'boolean'},
                        'excludes_prior_bariatric_surgery': {'type': 'boolean'},
                        'excludes_pregnancy': {'type': 'boolean'}
                    },
                    'required': ['min_bmi','max_bmi','hba1c_threshold',
                                 'requires_diabetes','excludes_diabetes',
                                 'excludes_prior_bariatric_surgery','excludes_pregnancy']
                }
            }
        }
    ):structured_output[0] AS facts
FROM eval.eval_sample s;


-- Flatten the JSON predictions into typed columns so they can be compared to the labels.
CREATE OR REPLACE TABLE eval.eval_pred_flat AS
SELECT
    nct_id,
    facts:raw_message:min_bmi::FLOAT                              AS min_bmi,            -- predicted min BMI (NULL if not stated)
    facts:raw_message:max_bmi::FLOAT                              AS max_bmi,            -- predicted max BMI
    facts:raw_message:hba1c_threshold::FLOAT                      AS hba1c_threshold,    -- predicted HbA1c threshold
    facts:raw_message:requires_diabetes::BOOLEAN                  AS requires_diabetes,  -- diabetes required for inclusion?
    facts:raw_message:excludes_diabetes::BOOLEAN                  AS excludes_diabetes,  -- diabetes an exclusion?
    facts:raw_message:excludes_prior_bariatric_surgery::BOOLEAN   AS excludes_prior_bariatric_surgery,  -- prior bariatric surgery an exclusion?
    facts:raw_message:excludes_pregnancy::BOOLEAN                 AS excludes_pregnancy  -- pregnancy/breastfeeding an exclusion?
FROM eval.eval_predictions;


-- Per-field accuracy. NULL == NULL counts as a match (both agree "not stated");
-- numeric fields are compared with a small tolerance to absorb float noise.
WITH cmp AS (
    SELECT
        l.nct_id,
        EQUAL_NULL(ABS(l.min_bmi - p.min_bmi) < 0.01, TRUE)
            OR EQUAL_NULL(l.min_bmi, p.min_bmi)               AS min_bmi_ok,
        EQUAL_NULL(l.max_bmi, p.max_bmi)
            OR ABS(COALESCE(l.max_bmi,-999) - COALESCE(p.max_bmi,-999)) < 0.01 AS max_bmi_ok,
        EQUAL_NULL(l.hba1c_threshold, p.hba1c_threshold)
            OR ABS(COALESCE(l.hba1c_threshold,-999) - COALESCE(p.hba1c_threshold,-999)) < 0.01 AS hba1c_ok,
        EQUAL_NULL(l.requires_diabetes, p.requires_diabetes)  AS req_dm_ok,
        EQUAL_NULL(l.excludes_diabetes, p.excludes_diabetes)  AS exc_dm_ok,
        EQUAL_NULL(l.excludes_prior_bariatric_surgery, p.excludes_prior_bariatric_surgery) AS exc_bar_ok,
        EQUAL_NULL(l.excludes_pregnancy, p.excludes_pregnancy) AS exc_preg_ok
    FROM eval.eval_labels l
    JOIN eval.eval_pred_flat p USING (nct_id)
)
SELECT 'min_bmi'                          AS field, ROUND(100.0*AVG(IFF(min_bmi_ok,1,0)),1) AS accuracy_pct FROM cmp
UNION ALL SELECT 'max_bmi',               ROUND(100.0*AVG(IFF(max_bmi_ok,1,0)),1) FROM cmp
UNION ALL SELECT 'hba1c_threshold',       ROUND(100.0*AVG(IFF(hba1c_ok,1,0)),1) FROM cmp
UNION ALL SELECT 'requires_diabetes',     ROUND(100.0*AVG(IFF(req_dm_ok,1,0)),1) FROM cmp
UNION ALL SELECT 'excludes_diabetes',     ROUND(100.0*AVG(IFF(exc_dm_ok,1,0)),1) FROM cmp
UNION ALL SELECT 'excludes_prior_bariatric_surgery', ROUND(100.0*AVG(IFF(exc_bar_ok,1,0)),1) FROM cmp
UNION ALL SELECT 'excludes_pregnancy',    ROUND(100.0*AVG(IFF(exc_preg_ok,1,0)),1) FROM cmp
ORDER BY accuracy_pct;


-- Disagreements, itemized — the qualitative half of the eval. One row per label/prediction
-- mismatch, so you can characterize HOW it fails, not just how often.
SELECT
    l.nct_id,
    'min_bmi' AS field, TO_VARCHAR(l.min_bmi) AS labeled, TO_VARCHAR(p.min_bmi) AS predicted
FROM eval.eval_labels l JOIN eval.eval_pred_flat p USING (nct_id)
WHERE NOT EQUAL_NULL(l.min_bmi, p.min_bmi)
UNION ALL SELECT l.nct_id, 'max_bmi', TO_VARCHAR(l.max_bmi), TO_VARCHAR(p.max_bmi)
FROM eval.eval_labels l JOIN eval.eval_pred_flat p USING (nct_id)
WHERE NOT EQUAL_NULL(l.max_bmi, p.max_bmi)
UNION ALL SELECT l.nct_id, 'hba1c_threshold', TO_VARCHAR(l.hba1c_threshold), TO_VARCHAR(p.hba1c_threshold)
FROM eval.eval_labels l JOIN eval.eval_pred_flat p USING (nct_id)
WHERE NOT EQUAL_NULL(l.hba1c_threshold, p.hba1c_threshold)
UNION ALL SELECT l.nct_id, 'excludes_diabetes', TO_VARCHAR(l.excludes_diabetes), TO_VARCHAR(p.excludes_diabetes)
FROM eval.eval_labels l JOIN eval.eval_pred_flat p USING (nct_id)
WHERE NOT EQUAL_NULL(l.excludes_diabetes, p.excludes_diabetes)
UNION ALL SELECT l.nct_id, 'excludes_prior_bariatric_surgery', TO_VARCHAR(l.excludes_prior_bariatric_surgery), TO_VARCHAR(p.excludes_prior_bariatric_surgery)
FROM eval.eval_labels l JOIN eval.eval_pred_flat p USING (nct_id)
WHERE NOT EQUAL_NULL(l.excludes_prior_bariatric_surgery, p.excludes_prior_bariatric_surgery)
UNION ALL SELECT l.nct_id, 'excludes_pregnancy', TO_VARCHAR(l.excludes_pregnancy), TO_VARCHAR(p.excludes_pregnancy)
FROM eval.eval_labels l JOIN eval.eval_pred_flat p USING (nct_id)
WHERE NOT EQUAL_NULL(l.excludes_pregnancy, p.excludes_pregnancy)
UNION ALL SELECT l.nct_id, 'requires_diabetes', TO_VARCHAR(l.requires_diabetes), TO_VARCHAR(p.requires_diabetes)
FROM eval.eval_labels l JOIN eval.eval_pred_flat p USING (nct_id)
WHERE NOT EQUAL_NULL(l.requires_diabetes, p.requires_diabetes)
ORDER BY field, nct_id;


-- Headline number: overall field-level accuracy across all 7 fields (correct fields / total fields).
WITH cmp AS (
    SELECT
        IFF(EQUAL_NULL(l.min_bmi,p.min_bmi),1,0)
      + IFF(EQUAL_NULL(l.max_bmi,p.max_bmi),1,0)
      + IFF(EQUAL_NULL(l.hba1c_threshold,p.hba1c_threshold),1,0)
      + IFF(EQUAL_NULL(l.requires_diabetes,p.requires_diabetes),1,0)
      + IFF(EQUAL_NULL(l.excludes_diabetes,p.excludes_diabetes),1,0)
      + IFF(EQUAL_NULL(l.excludes_prior_bariatric_surgery,p.excludes_prior_bariatric_surgery),1,0)
      + IFF(EQUAL_NULL(l.excludes_pregnancy,p.excludes_pregnancy),1,0) AS correct_fields
    FROM eval.eval_labels l JOIN eval.eval_pred_flat p USING (nct_id)
)
SELECT
    COUNT(*)                                AS trials,        -- eval trials scored
    COUNT(*) * 7                            AS total_fields,  -- 7 fields per trial
    SUM(correct_fields)                     AS correct,       -- fields the model got right
    ROUND(100.0 * SUM(correct_fields) / (COUNT(*)*7), 1) AS overall_accuracy_pct  -- correct / total, as a %
FROM cmp;
