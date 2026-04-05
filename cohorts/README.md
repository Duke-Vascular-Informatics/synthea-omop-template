# cohorts/

OMOP cohort SQL definitions for the PAD/SSI validation study.
Each file is rendered by SqlRender and executed against the SQL Server CDM to populate the results cohort table.

## Files

| File | Cohort | Description |
|------|--------|-------------|
| `target_surgery.sql` | Target cohort | Open revascularization procedures for PAD (aorto-bifemoral bypass, fem-pop bypass, fem-tibial bypass, aorto-iliac bypass). Filtered to inpatient visits; one index date per patient (most recent procedure). |
| `outcome_ssi.sql` | Outcome cohort | Surgical site infection (SSI) diagnosis occurring within the prediction window after the index procedure. |

## Usage

Cohort SQL files are not run directly. They are loaded and executed by `R/cohorts.R`
during Step 08 (`workflow/08_run_analysis_and_manuscript_report.R`).

SqlRender template parameters used in both files:

| Parameter | Source |
|-----------|--------|
| `@results_schema` | `config$results_schema` |
| `@cohort_table` | `config$cohort_table` |
| `@cdm_schema` | `config$cdm_schema` |
| `@target_cohort_id` / `@outcome_cohort_id` | `config$target_cohort_id` / `config$outcome_cohort_id` |
