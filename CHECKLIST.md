# Study Setup Checklist

Work through this list top-to-bottom before running Step 8.
Each item maps to a `TODO [CONFIG]` or `TODO [*]` placeholder in the codebase.
Run `Rscript scripts/find_todos.R` at any time to see all remaining placeholders.

---

## Step 1 — Edit order

> **Important:** Complete files in this order. Each file feeds the next.
> 1. Rename SQL files (if needed) → 2. Edit `config.R` → 3. Edit cohort SQL files →
> 4. Run `/concept-lookup` for every concept ID → 5. Fill covariate CSVs →
> 6. Run `Rscript workflow/02_define_omop_cohort_outcome_covariates.R` to validate

---

## config.R

- [ ] `cdm_schema` — set to the CDM schema populated by the ETL (e.g. `"cdm_hip_replace_01"`)
- [ ] `results_schema` — set to a study-specific results schema (e.g. `"hip_replace_results"`)
- [ ] `cohort_table` — set to a study-specific cohort table name (e.g. `"hip_replace_cohort"`)
- [ ] `target_cohort_id` — integer ID for the target / exposure cohort (default `1L` is fine)
- [ ] `comparator_cohort_id` — set to an integer (e.g. `2L`) for causal inference; leave `NA` otherwise
- [ ] `outcome_cohort_id` — integer ID for the outcome cohort (default `2L` is fine; use `3L` if comparator is `2L`)
- [ ] `target_cohort_sql` — update path if you renamed the target SQL file
- [ ] `comparator_cohort_sql` — set path if using causal inference design; otherwise leave `NULL`
- [ ] `outcome_cohort_sql` — update path if you renamed the outcome SQL file
- [ ] `study_name` — short identifier used in output file names (lowercase, underscores only)
- [ ] `prediction_window_days` — days after index date to count the outcome (e.g. `90L`)
- [ ] `study_start_date` — earliest index date to include (e.g. `"2017-01-01"`)
- [ ] `study_end_date` — latest index date to include (e.g. `"2023-12-31"`)
- [ ] `output_folder` — update the folder name to match `study_name`
- [ ] `cdm_database_id` — short identifier for the database (used in PLP result objects)
- [ ] `cdm_database_name` — human-readable database name for reports
- [ ] `cdm_database_description` — one-sentence description of the patient population

---

## cohorts/target_surgery.sql (rename first if needed)

> Before editing: run `/concept-lookup <your exposure> procedure` (or condition/drug)
> to find verified concept IDs. See `docs/omop_primer.md` Section 3 for guidance.

- [ ] Rename the file to reflect your exposure (e.g. `cohorts/hip_replacement_index.sql`)
      and update `config$target_cohort_sql` to match
- [ ] **Index event** — replace `concept_id = 0` in the `AND EXISTS` block with your
      verified exposure ancestor concept ID(s)
- [ ] **Visit type filter** — change `visit_concept_id = 9201` to the correct visit type,
      or remove the filter if the exposure can occur across visit types
- [ ] **Age filter** — change `>= 18` to your minimum age threshold, or remove if not needed
- [ ] **Index date** — confirm `vo.visit_start_date` is the right date field, or switch to
      `po.procedure_date`, `de.drug_exposure_start_date`, etc.
- [ ] **Cohort end date** — choose the right exit strategy (visit end, fixed window, death,
      or end of observation period)
- [ ] **One entry per person** — confirm `ASC` (first event) is the right ordering, or
      change to `DESC` or remove the `ROW_NUMBER` filter
- [ ] **Washout block** — replace `concept_id = 0` with your washout concept ID, adjust
      the washout window (days), or remove the block if no washout is needed

---

## cohorts/outcome_ssi.sql (rename first if needed)

> Before editing: run `/concept-lookup <your outcome> condition` (or procedure/measurement)
> to find verified concept IDs.

- [ ] Rename the file to reflect your outcome (e.g. `cohorts/vte_90day.sql`)
      and update `config$outcome_cohort_sql` to match
- [ ] **Outcome event** — replace `ancestor_concept_id = 0` with your verified outcome
      ancestor concept ID
- [ ] **OMOP domain** — confirm the outcome is a `condition_occurrence`; if it is a
      procedure, measurement, or readmission adapt the inner query accordingly
- [ ] **Exclusion blocks** — uncomment and fill in the `NOT EXISTS` blocks for any
      outcome sub-types that should be excluded, or remove them if not needed
- [ ] Set `config$outcome_cohort_sql = NULL` in `config.R` if your study design is
      `cohort_characterization` or `descriptive` (no formal outcome)

---

## cohorts/comparator_cohort.sql *(causal inference only)*

- [ ] Create this file (copy and adapt `target_surgery.sql`)
- [ ] Update `config$comparator_cohort_sql` and `config$comparator_cohort_id` in `config.R`
- [ ] Fill in the comparator exposure concept IDs using `/concept-lookup`

---

## covariates/components.csv

> Only needed if using the custom CSV-based covariate pipeline.
> Set `covariate_components_path = NULL` in `workflow/02` if using
> `FeatureExtraction::createCovariateSettings()` in Step 8 instead.

- [ ] Replace placeholder rows (`covariate_1`, `covariate_2`, etc.) with your study covariates
- [ ] Set `domain` to one of: `condition`, `drug`, `procedure`, `measurement`,
      `observation`, `visit`, `demographic`, `bmi`, `operative_time`
- [ ] Set `lookback_start_day` and `lookback_end_day` relative to the index date
      (e.g. `-365` and `0` for conditions in the year before index)
- [ ] Set `points` for a scored risk model, or `1` for binary presence/absence covariates
- [ ] See the column documentation header in the file for all options

---

## covariates/component_concepts.csv

> Only needed if `covariates/components.csv` is populated.

- [ ] Replace all `concept_id = 0` rows with verified standard OMOP concept IDs
- [ ] Run `/concept-lookup` for each covariate before writing any concept ID
- [ ] Set `include_descendants = TRUE` to use `concept_ancestor` rollup for the concept set,
      or `FALSE` to match only the exact concept ID

---

## workflow/02_define_omop_cohort_outcome_covariates.R

- [ ] Set `study_design` to the correct design type (see the decision guide in the file)
- [ ] Update `target_cohort_sql_path` to match your renamed SQL file
- [ ] Update `outcome_cohort_sql_path` (or set to `NULL` if not applicable)
- [ ] Set `comparator_cohort_sql_path` (or leave `NULL`)
- [ ] Set `prediction_window_days`, `min_prior_observation_days`, `covariate_lookback_days`
- [ ] **Run Step 2** to validate: `Rscript workflow/02_define_omop_cohort_outcome_covariates.R`
      Fix any warnings before proceeding to Step 8.

---

## workflow/07_setup_analysis_env.R

- [ ] Uncomment the packages your Step 8 analysis needs
- [ ] **Run Step 7** to verify all packages are installed:
      `Rscript workflow/07_setup_analysis_env.R`

---

## workflow/08_run_analysis_and_manuscript_report.R

- [ ] Uncomment the `library()` calls for your analysis packages (Section 4)
- [ ] Write your analysis code in **Section 7** (uncomment and adapt a starter pattern)
- [ ] Write your output code in **Section 8** (CSV, Word report, plots, Excel)
- [ ] Update the completion message in **Section 9** to describe what was produced
- [ ] **Run Step 8 in a fresh R session:**
      `Rscript workflow/08_run_analysis_and_manuscript_report.R`

---

## Final check

- [ ] `Rscript workflow/02_define_omop_cohort_outcome_covariates.R` — passes with no warnings
- [ ] `Rscript workflow/07_setup_analysis_env.R` — all packages verified
- [ ] `Rscript workflow/08_run_analysis_and_manuscript_report.R` — runs to completion
- [ ] Output files written to `config$output_folder` — review for correctness
- [ ] Commit: `git add config.R cohorts/ covariates/ workflow/07* workflow/08*`
      `git commit -m "Define <study name> cohort, covariates, and analysis"`
      `git push`
