# scripts/

Helper and utility scripts that support the numbered workflow steps.
Scripts here are called by workflow steps or run manually as one-time setup tasks —
they are not workflow entry points themselves.

## Top-level files

| File | Description | Called by |
|------|-------------|-----------|
| `quality_check_etl.R` | Post-ETL quality check implementation: validates cohort row counts, concept mapping rates, and optionally runs ACHILLES CDM profiling and OHDSI Data Quality Dashboard. Accepts CLI flags for threshold gates. | `workflow/06_quality_check_defined_phenotypes.R` |
| `run_step8.ps1` | PowerShell convenience launcher for Step 08 on Windows. Runs `workflow/08_run_analysis_and_manuscript_report.R` in the background and redirects stdout/stderr to `logs/`. Machine-specific paths — edit before use. | Manual |

## Subdirectories

| Directory | Purpose |
|-----------|---------|
| `etl/` | Main Synthea CSV → OMOP ETL engine (`run_synthea_full_csv_builder_etl.R`) |
| `synthea/` | Synthea synthetic data generation and module visualization utilities |
| `bundle/` | Build utilities for the portable risk score validation bundle |
| `archive/` | Inactive scripts preserved for reference; not part of the active workflow |

## CLI flags for quality_check_etl.R

Pass these through `workflow/06_quality_check_defined_phenotypes.R`:

| Flag | Default | Description |
|------|---------|-------------|
| `--run_name=<name>` | latest schema | Target CDM schema override |
| `--enforce_thresholds=<true\|false>` | `false` | Fail if row counts fall below minimums |
| `--min_person_rows=<n>` | 100 | Minimum rows in person table |
| `--min_open_revascularization_rows=<n>` | 50 | Minimum qualifying procedures |
| `--min_ssi_condition_rows=<n>` | 5 | Minimum SSI condition records |
| `--min_mapped_condition_pct=<pct>` | 50 | Minimum % conditions with standard concept |
| `--run_achilles=<true\|false>` | `true` | Run ACHILLES CDM profiling |
| `--run_dqd=<true\|false>` | `true` | Run OHDSI Data Quality Dashboard |
| `--achilles_threads=<n>` | 1 | Parallel threads for ACHILLES |
