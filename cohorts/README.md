# cohorts/

OMOP cohort SQL definitions used to validate the synthetic dataset (the real study cohorts live in the analysis-core repo).
Each file is rendered by SqlRender and executed against the SQL Server CDM to populate the results cohort table.

For complete setup and execution flow, use [docs/GETTING_STARTED.md](../docs/GETTING_STARTED.md).

## Files

| File | Cohort | Description |
|------|--------|-------------|
| `target_surgery.sql` | Target cohort | Target/index event cohort SQL template for exposure or index procedure definition. |
| `outcome_ssi.sql` | Outcome cohort | Outcome cohort SQL template for events observed during follow-up. |
| `comparator_cohort.sql` | Comparator cohort | Optional comparator cohort SQL template used for causal inference studies. |

## Usage

Cohort SQL files are not run directly.

- `workflow/02` validates the files and checks for placeholders.
- `workflow/06` checks that the generated data has enough rows for the configured target and outcome concepts. No analysis runs in this repo, and the cohort SQL is not instantiated here.

SqlRender template parameters used in both files:

| Parameter | Source |
|-----------|--------|
| `@results_schema` | `config$results_schema` |
| `@cohort_table` | `config$cohort_table` |
| `@cdm_schema` | `config$cdm_schema` |
| `@target_cohort_id` / `@outcome_cohort_id` | `config$target_cohort_id` / `config$outcome_cohort_id` |
