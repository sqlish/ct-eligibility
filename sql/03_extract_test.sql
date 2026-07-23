-- 03_extract_test.sql — test the eligibility-fact extraction on 20 rows before running all 2,000.
--
-- Kept separate from the full run because every row costs tokens: same reasoning as testing a
-- database load on a sample, except here the cost is real money. Read the 20 outputs, confirm the
-- schema behaves, then scale up.
--
-- Tooling choices:
--   * response_format (schema-constrained): the model can't emit a field outside the schema or a
--     wrong type, so there's no markdown-fence stripping or PARSE_JSON failure path (which the
--     older COMPLETE + REGEXP_REPLACE approach needed).
--   * TRY_COMPLETE: the safe variant — returns NULL on a failed row instead of aborting the whole
--     2,000-row statement.
--   * temperature 0: extraction must be deterministic, not creative.
--
-- Scope: the 6 facts (across 7 fields — BMI has a min and a max) that live ONLY in free text.
-- Age/sex/healthy-volunteer status are already structured in core.trials from the registry, so
-- they're not re-extracted — that would be paying tokens for data we already have.

USE ROLE      ct_engineer;
USE WAREHOUSE ct_wh;
USE DATABASE  ct_trials;
USE SCHEMA    core;

-- 20 cleanly-split trials at random — the sample we inspect before the full run
WITH test_rows AS (
    SELECT
        nct_id,
        inclusion_text,
        exclusion_text
    FROM core.trial_criteria
    WHERE split_method = 'BOTH_HEADERS'   -- clean rows only for the test
    ORDER BY RANDOM()
    LIMIT 20
)
SELECT
    nct_id,
    inclusion_text,
    exclusion_text,
    -- ask the model for the 7 facts as strict JSON; :structured_output[0] pulls the parsed object out
    SNOWFLAKE.CORTEX.TRY_COMPLETE(
        'claude-sonnet-4-6',
        [ { 'role': 'user', 'content': CONCAT(
            'You are extracting structured eligibility facts from a clinical trial. ',
            'Use ONLY the text provided. If a fact is not stated, return null for it. ',
            'Do not infer or guess. ',
            'INCLUSION SECTION:\n', COALESCE(inclusion_text, ''), '\n\n',
            'EXCLUSION SECTION:\n', COALESCE(exclusion_text, '')
        ) } ],
        {
            'temperature': 0,
            'max_tokens': 500,
            'response_format': {
                'type': 'json',
                'schema': {
                    'type': 'object',
                    'properties': {
                        'min_bmi': {
                            'type': ['number','null'],
                            'description': 'Minimum BMI required for inclusion, e.g. 30 for "BMI >= 30". null if not stated.'
                        },
                        'max_bmi': {
                            'type': ['number','null'],
                            'description': 'Maximum BMI allowed, e.g. 45 for "BMI <= 45" or "BMI 30-45". null if not stated.'
                        },
                        'hba1c_threshold': {
                            'type': ['number','null'],
                            'description': 'HbA1c percentage threshold mentioned in criteria, e.g. 7.0 for "HbA1c >= 7.0%". null if not mentioned.'
                        },
                        'requires_diabetes': {
                            'type': 'boolean',
                            'description': 'true if a diabetes diagnosis is REQUIRED for inclusion.'
                        },
                        'excludes_diabetes': {
                            'type': 'boolean',
                            'description': 'true if diabetes is an EXCLUSION criterion.'
                        },
                        'excludes_prior_bariatric_surgery': {
                            'type': 'boolean',
                            'description': 'true if prior bariatric or weight-loss surgery is an exclusion.'
                        },
                        'excludes_pregnancy': {
                            'type': 'boolean',
                            'description': 'true if pregnancy or breastfeeding is an exclusion.'
                        }
                    },
                    'required': [
                        'min_bmi','max_bmi','hba1c_threshold',
                        'requires_diabetes','excludes_diabetes',
                        'excludes_prior_bariatric_surgery','excludes_pregnancy'
                    ]
                }
            }
        }
    ):structured_output[0] AS facts
FROM test_rows;
