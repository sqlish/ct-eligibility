# Clinical Trial Eligibility Structuring

Turns the free-text eligibility criteria on ClinicalTrials.gov into structured, queryable facts with Snowflake Cortex, and measures the extraction's accuracy against a hand-labeled set.

## The problem

Eligibility criteria on [ClinicalTrials.gov](https://clinicaltrials.gov) are free text written by humans: inconsistent, densely clinical, and not queryable. There's no way to ask "which obesity trials accept a patient with BMI 32 and no diabetes?" against the raw registry, because the answer is buried in prose like *"BMI ≥ 30 kg/m² or ≥ 27 with a weight-related comorbidity; exclude prior bariatric surgery."*

This project pulls obesity trials from the ClinicalTrials.gov v2 API, lands them in Snowflake, splits the criteria into inclusion/exclusion sections, and uses Cortex to normalize the clinical facts inside them into columns you can filter on.

## Accuracy

The extraction is checked against 30 hand-labeled trials (210 field labels, 7 per trial), at 89% field-level accuracy. By field:

| Field | Accuracy |
|---|---|
| max_bmi | 96.7% |
| min_bmi | 93.3% |
| excludes_pregnancy | 93.3% |
| requires_diabetes | 90.0% |
| excludes_prior_bariatric_surgery | 90.0% |
| hba1c_threshold | 83.3% |
| excludes_diabetes | 76.7% |

The failure modes are characterized rather than hidden (details in [`eval/`](eval/)):

- **Subtype phrasing.** `excludes_diabetes`, the weakest field at 76.7%, misses when the exclusion names a subtype like "insulin-dependent diabetes" instead of the bare term. This is the biggest single error source.
- **Unit ambiguity.** HbA1c thresholds show up as both `%` and `mmol/mol`. The schema doesn't disambiguate, so 6.0% and 42 mmol/mol get scored as a mismatch even though they're the same threshold.
- **BMI stratification.** Trials that bucket patients into BMI bands (normal / overweight / obese) blur the eligibility floor against a merely descriptive category.

## Where the AI is used, and where it isn't

Not everything here is an LLM. Profiling all 2,000 trials showed 98.15% use canonical `Inclusion Criteria:` / `Exclusion Criteria:` headers, so splitting those sections is exact string work: deterministic, free, and testable. Spending tokens to locate a header would be waste. The model is reserved for the part regex can't do, which is reading the clinical facts inside each section.

| Task | Tool | Why |
|---|---|---|
| Split inclusion / exclusion | SQL `POSITION` / `SUBSTR` | headers are 98% reliable; free, testable, no tokens |
| Structure clinical facts | Cortex `TRY_COMPLETE` + JSON schema | "BMI ≥ 30", "HbA1c ≥ 7%", condition in/exclusions — regex can't read these |

The ~1.85% of trials with irregular structure (criteria grouped by role or condition, or missing entirely) are flagged with `needs_llm_split = TRUE` and routed to the LLM instead of being force-fit into more string rules. The deterministic path holds one invariant: no row is ever both unsplit and unflagged.

## Architecture

```
ClinicalTrials.gov v2 API
        │  fetch_trials.py  (paginated, raw JSON preserved)
        ▼
   local NDJSON
        │  load_trials.py  (PUT → COPY INTO → MERGE, idempotent on nct_id)
        ▼
   raw.studies_raw  (2,000 trials, VARIANT payloads)
        │  02_core_model.sql  (flatten)
        ▼
   core.trials + core.trial_criteria  (deterministic inclusion/exclusion split)
        │  Cortex TRY_COMPLETE + response_format schema
        ▼
   structured eligibility facts  (min/max BMI, HbA1c, diabetes, bariatric, pregnancy)
        │
        └── eval/  (30 hand-labeled trials → 89% field-level accuracy)
```

## Requirements

- Python 3.9+
- A Snowflake account with Cortex AI functions enabled. Cortex is native in AWS regions; other regions need cross-region inference turned on.
- `pip install -r requirements.txt` (requests, snowflake-connector-python, cryptography, python-dotenv)

## Running it

The scripts and SQL files run in numbered order. SQL files run in a Snowsight worksheet; Python runs locally.

1. **Install.** `python -m venv .venv && .venv/Scripts/activate` (or `source .venv/bin/activate`), then `pip install -r requirements.txt`.
2. **Configure `.env`** in the repo root:
   ```
   SNOWFLAKE_ACCOUNT=your_account_locator
   SNOWFLAKE_USER=your_user
   SNOWFLAKE_ROLE=ct_engineer
   SNOWFLAKE_WAREHOUSE=ct_wh
   SNOWFLAKE_DATABASE=ct_trials
   SNOWFLAKE_SCHEMA=core
   ```
3. **Key-pair auth.** `python scripts/gen_keypair.py` writes `rsa_key.p8` and prints an `ALTER USER … SET RSA_PUBLIC_KEY` statement — run it once in Snowsight as `ACCOUNTADMIN`.
4. **Provision.** Set your username in `sql/00_setup.sql`, then run it as `ACCOUNTADMIN`. It creates the warehouse, database, schemas, role, and resource monitor, and smoke-tests Cortex.
5. **Ingest.** `python scripts/fetch_trials.py` (API → local NDJSON), then `python scripts/load_trials.py` (NDJSON → `raw.studies_raw`).
6. **Model.** Run `sql/01_explore.sql` (optional profiling), `sql/02_core_model.sql`, and `sql/02b_criteria_split_v2.sql`.
7. **Evaluate.** `sql/04_eval_sample.sql` → `python scripts/export_eval_template.py` → hand-label `eval/eval_labels.csv` → `python scripts/load_eval_labels.py` → `sql/05_eval_extract_and_score.sql`.

## Example query

Once the facts are columns, the question from the top of this README is a `WHERE` clause. This scores the extraction on the 30-trial eval set (`eval.eval_pred_flat`); the same extraction call scales to the full population by running it against `core.trial_criteria`.

```sql
-- obesity trials that would accept a patient with BMI 32 and no diabetes
SELECT t.nct_id, t.title
FROM eval.eval_pred_flat f
JOIN core.trials t USING (nct_id)
WHERE f.min_bmi <= 32                          -- patient clears the BMI floor
  AND (f.max_bmi IS NULL OR f.max_bmi >= 32)   -- and is under any ceiling
  AND NOT COALESCE(f.requires_diabetes, FALSE);-- trial doesn't require diabetes
```

## Repo layout

```
sql/
  00_setup.sql                    environment: role, warehouse, db, resource monitor
  01_explore.sql                  payload profiling (drove the design decisions)
  02_core_model.sql               flatten payloads to columns
  02b_criteria_split_v2.sql       deterministic inclusion/exclusion split (supersedes 02)
  03_extract_test.sql             extraction schema, tested on 20 rows first
  04_eval_sample.sql              freeze a reproducible 30-trial eval set
  05_eval_extract_and_score.sql   run extraction on eval set, score vs. labels
scripts/
  fetch_trials.py                 API ingestion
  gen_keypair.py                  RSA keypair for key-pair auth
  snow_connect.py                 connection helper (key-pair)
  load_trials.py                  stage + load pipeline
  export_eval_template.py         export eval trials for blind hand-labeling
  load_eval_labels.py             load labels back to Snowflake
eval/
  eval_template.csv               blank labeling template (criteria + empty label columns)
  eval_labels.csv                 ground truth (30 trials, hand-labeled)
```

## Notable technical decisions

- **Downstream filtering.** The API's documented `filter.phase` and `filter.advanced` parameters are rejected by the live v2 endpoint (confirmed by bisecting requests). Phase and study-type filtering are pushed into SQL against the preserved raw payload. Profiling then justified this: 54% of obesity trials have no phase listed, so an API-level phase filter would have silently discarded most of the data.
- **Key-pair authentication.** Password auth is blocked by MFA/TOTP for programmatic access, and PATs require an attached network policy. RSA key-pair auth is the standard programmatic path and avoids both.
- **Structured outputs over parsing.** Cortex `response_format` with a JSON schema constrains generation to valid, typed output, which removes the markdown-fence stripping and parse-failure handling a plain-completion approach needs.
- **Idempotent loads.** `MERGE` on `nct_id` with `QUALIFY` dedup makes the pipeline safely re-runnable; overlapping batches never create duplicate rows.

## Data source

[ClinicalTrials.gov v2 API](https://clinicaltrials.gov/data-api/api) — public, no key required. Sample: the 2,000 most recently updated trials matching `query.cond=obesity`.

## Stack

Snowflake (Cortex AI functions, key-pair auth, resource monitors) · Python (requests, snowflake-connector-python, cryptography) · SQL
