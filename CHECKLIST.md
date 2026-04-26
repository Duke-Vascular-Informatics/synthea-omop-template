# Study Setup Checklist

Work through this list top-to-bottom before running Step 8.
All study-specific settings live in `study_params.yaml`.
Run `Rscript scripts/find_todos.R` at any time to see remaining placeholders.

---

## Step 1 — Edit order

> **Complete in this order:**
> 1. Edit `study_params.yaml` → 2. Run `/concept-lookup` for every concept ID →
> 3. Fill `covariates/covariates.csv` and `covariates/covariate_concepts.csv` →
> 4. Run `Rscript workflow/02_define_omop_cohort_outcome_covariates.R` to validate

---

## study_params.yaml

- [ ] `study_name` — short study identifier (lowercase, underscores only)
- [ ] `study_design` — `cohort_characterization` | `prognostic_model` | `causal_inference` | `descriptive`
- [ ] `study_start_date` / `study_end_date` — date range for index event inclusion
- [ ] `cdm_schema` — CDM schema populated by Step 5 ETL
- [ ] `results_schema` — study-specific results schema (created automatically if absent)
- [ ] `cohort_table` — study-specific cohort table name
- [ ] `target.visit_concept_ids` — visit type filter (9201 Inpatient / 9202 Outpatient / 9203 ED); `[]` for all
- [ ] `target.min_age_at_index` — minimum age in years; `0` for no restriction
- [ ] `target.index_event.ancestor_concept_ids` — **[REQUIRES vocab query]** index procedure/condition/drug concept IDs
- [ ] `target.washout.ancestor_concept_ids` — **[REQUIRES vocab query]** washout condition concept IDs; `[]` to disable
- [ ] `outcome.ancestor_concept_ids` — **[REQUIRES vocab query]** outcome condition concept IDs
- [ ] `prediction_window_days` — days after index to count outcome
- [ ] `output_folder` — update to match `study_name`
- [ ] `cdm_database_id` / `cdm_database_name` / `cdm_database_description` — metadata for reports

> **Comparator cohort** (causal inference only): set `comparator.cohort_id` to an integer and
> fill in `comparator.index_event.ancestor_concept_ids` in `study_params.yaml`.
> `cohorts/comparator_cohort.sql` is already in the repo — no file creation needed.

---

## covariates/covariates.csv

> Only needed if using the custom CSV-based covariate pipeline.
> Set `covariate_definitions_file = NULL` in `config.R` if using
> `FeatureExtraction::createCovariateSettings()` in Step 8 instead.

- [ ] Replace placeholder rows (`covariate_1`, `covariate_2`, etc.) with your study covariates
- [ ] Set `domain` to one of: `condition`, `drug`, `procedure`, `measurement`, `observation`, `visit`, `demographic`, `bmi`, `operative_time`
- [ ] Set `lookback_start_day` and `lookback_end_day` relative to index date
- [ ] Set `points` for a scored model, or `1` for binary presence/absence

---

## covariates/covariate_concepts.csv

- [ ] Replace all `concept_id = 0` rows with verified standard OMOP concept IDs
- [ ] Run `/concept-lookup` for each covariate before writing any concept ID
- [ ] Set `include_descendants = TRUE` to use `concept_ancestor` rollup

---

## workflow/07_setup_analysis_env.R

- [ ] Uncomment the packages your Step 8 analysis needs
- [ ] **Run Step 7**: `Rscript workflow/07_setup_analysis_env.R`

---

## workflow/08_run_analysis_and_manuscript_report.R

- [ ] Uncomment the `library()` calls for your analysis packages (Section 4)
- [ ] Write your analysis code in **Section 7**
- [ ] Write your output code in **Section 8**
- [ ] **Run Step 8 in a fresh R session**: `Rscript workflow/08_run_analysis_and_manuscript_report.R`

---

## Final check

- [ ] `Rscript scripts/find_todos.R` — no remaining placeholders
- [ ] `Rscript workflow/02_define_omop_cohort_outcome_covariates.R` — passes with no warnings
- [ ] `Rscript workflow/07_setup_analysis_env.R` — all packages verified
- [ ] `Rscript workflow/08_run_analysis_and_manuscript_report.R` — runs to completion
- [ ] Output files in `config$output_folder` — review for correctness
- [ ] Commit: `git add study_params.yaml covariates/ workflow/07* workflow/08*`
      `git commit -m "Define <study name> cohort, covariates, and analysis"`
      `git push`
