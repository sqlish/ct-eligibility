# Clinical Trial Eligibility Structuring

Turning free-text clinical-trial eligibility criteria into structured, queryable facts using Snowflake Cortex — with a validated accuracy measurement, not just an assumption that the AI works.

## The problem

Eligibility criteria on [ClinicalTrials.gov](https://clinicaltrials.gov) are written as free text by humans. They're inconsistent, densely clinical, and not machine-queryable. You cannot ask "which obesity trials accept a patient with BMI 32 and no diabetes?" against the raw registry — the answer is buried in prose like *"BMI ≥ 30 kg/m² or ≥ 27 with a weight-related comorbidity; exclude prior bariatric surgery."*

This project ingests obesity trials from the ClinicalTrials.gov v2 API, lands them in Snowflake, splits eligibility criteria into inclusion/exclusion sections, and uses Cortex AI functions to normalize the clinical facts inside them into structured columns you can filter on.

## What makes this more than a demo

The pipeline is **measured, not assumed.** The extraction was validated against 30 hand-labeled trials (210 individual field labels), reaching **89% field-level accuracy** — with the systematic failure modes characterized rather than hidden:

| Field | Accuracy |
|---|---|
| max_bmi | 96.7% |
| min_bmi | 93.3% |
| excludes_pregnancy | 93.3% |
| requires_diabetes | 90.0% |
| excludes_prior_bariatric_surgery | 90.0% |
| hba1c_threshold | 83.3% |
| excludes_diabetes | 76.7% |

Known failure modes (see [`eval/`](eval/)):
- **Subtype phrasing** — `excludes_diabetes` misses when exclusion is expressed as a specific subtype ("insulin-dependent diabetes") rather than the bare term. This is the largest error source.
- **Unit ambiguity** — HbA1c thresholds appear as both `%` and `mmol/mol`; the schema didn't disambiguate, producing apparent mismatches (e.g. 6.0% vs 42 mmol/mol).
- **BMI stratification** — trials that categorize by BMI band (normal / overweight / obese) blur the eligibility *floor* vs. a descriptive category.

## Design decision: where the AI belongs (and where it doesn't)

The interesting engineering choice was **not** using AI for everything. Profiling all 2,000 trials showed that 98.15% use canonical `Inclusion Criteria:` / `Exclusion Criteria:` headers. Splitting those sections is therefore exact, deterministic string work — spending LLM tokens to locate a header would be waste.

So the design is hybrid:

| Task | Tool | Why |
|---|---|---|
| Split inclusion / exclusion | Deterministic SQL (`POSITION`/`SUBSTR`) | Headers are 98% reliable; free, testable, no tokens |
| Structure clinical facts | Cortex `TRY_COMPLETE` + JSON schema | "BMI ≥ 30", "HbA1c ≥ 7%", condition in/exclusions — regex cannot read these |

The ~1.85% of trials with irregular structure (criteria organized by role, by condition, or absent) are explicitly flagged (`needs_llm_split = TRUE`) and routed to the LLM as a fallback rather than force-fit into brittle string rules. The deterministic path carries a provable integrity guarantee: no row is ever both unsplit and unflagged.

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

## Repo layout

```
sql/
  00_setup.sql                    environment: role, warehouse, db, resource monitor
  01_explore.sql                  payload profiling (drove the design decisions)
  02_core_model.sql               flatten payloads to columns
  02b_criteria_split.sql          deterministic inclusion/exclusion split
  03_extract_test.sql             extraction schema, tested on 20 rows first
  04_eval_sample.sql              freeze a reproducible 30-trial eval set
  05_eval_extract_and_score.sql   run extraction on eval set, score vs. labels
scripts/
  fetch_trials.py                 API ingestion
  gen_keypair.py                  RSA keypair for key-pair auth
  snow_connect.py                 connection helper (key-pair)
  load_trials.py                  stage + load pipeline
  export_eval_template.py         export eval trials for hand-labeling
  load_eval_labels.py             load labels back to Snowflake
eval/
  eval_labels.csv                 ground truth (30 trials, hand-labeled)
```

## Notable technical decisions

- **Downstream filtering.** The API's documented `filter.phase` and `filter.advanced` parameters are rejected by the live v2 endpoint (confirmed by bisecting requests). Phase and study-type filtering are pushed into SQL against the preserved raw payload. Profiling then justified this: 54% of obesity trials have no phase listed, so an API-level phase filter would have silently discarded most of the data.
- **Key-pair authentication.** Password auth is blocked by MFA/TOTP for programmatic access; PATs require an attached network policy. RSA key-pair auth is the standard programmatic path and avoids both.
- **Structured outputs over parsing.** Cortex `response_format` with a JSON schema constrains generation to valid, typed output — eliminating the markdown-fence-stripping and parse-failure handling that a plain-completion approach requires.
- **Idempotent loads.** `MERGE` on `nct_id` with `QUALIFY` dedup means the pipeline is safely re-runnable; overlapping batches never create duplicate rows.

## Data source

[ClinicalTrials.gov v2 API](https://clinicaltrials.gov/data-api/api) — public, no key required. Sample: the 2,000 most recently updated trials matching `query.cond=obesity`.

## Stack

Snowflake (Cortex AI functions, key-pair auth, resource monitors) · Python (requests, snowflake-connector-python, cryptography) · SQL
