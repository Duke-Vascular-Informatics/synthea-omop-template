# covariates/

CSV specification files that define the covariates (patient features) used in your study.
These files are the primary inputs to `R/risk_score_pipeline.R` and Step 8 analysis code.

They support any study design — prognostic models, causal inference, cohort characterization —
wherever you need a structured, reusable covariate specification rather than defining
covariates inline in R code.

## Files

| File | Description |
|------|-------------|
| `components.csv` | One row per covariate. Defines the covariate name, OMOP domain, lookback window (days relative to index date), minimum event count to qualify, and optional point value (for scored models). |
| `component_concepts.csv` | OMOP concept IDs for each covariate component. Supports `include_descendants = TRUE` for ancestor rollup via `concept_ancestor`. Optional `concept_role` and `value_concept_ids` columns for measurement and observation sub-typing. |
| `risk_lookup.csv` | Optional. Maps an integer total score to a calibrated predicted probability. Leave empty if using logistic regression output only, or remove from `config.R` if not building a scored model. |

## When to use these files

**Use this CSV approach when:**
- You have a pre-specified covariate list (e.g. from a published risk model or a protocol).
- You want to version-control the exact concepts used.
- You are building an integer risk score with point values per covariate.

**Use `FeatureExtraction::createCovariateSettings()` instead when:**
- You want automated, data-driven covariate extraction across all OMOP domains.
- You are running PatientLevelPrediction or CohortMethod with a broad feature set.
- You do not have a pre-specified covariate list.

Set both covariate file paths to `NULL` in `config.R` and `workflow/02` to skip this
CSV pipeline and define covariates directly in Step 8.

## Filling in the files

1. **`components.csv`** — replace the placeholder rows (`covariate_1`, `covariate_2`, ...)
   with your study's covariates. See the column documentation header in the file.
2. **`component_concepts.csv`** — for each component, add one or more rows mapping the
   component to verified standard OMOP concept IDs. Use `/concept-lookup` to find IDs.
3. **`risk_lookup.csv`** — populate from a published model's score table, or leave empty.

Run `Rscript workflow/02_define_omop_cohort_outcome_covariates.R` after editing to
validate the files for missing columns, unknown component IDs, and `concept_id = 0`
placeholders.
