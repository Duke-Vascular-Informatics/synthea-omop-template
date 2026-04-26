# R/

Core R helper functions for the PAD/SSI validation pipeline. These files are sourced
by the numbered workflow steps — they are not a package and should not be run directly.

## Files

| File | Purpose | Sourced by |
|------|---------|------------|
| `connection.R` | Builds DatabaseConnector connection details for SQL Server with JDBC/Windows auth; retry helpers for transient DB errors | Steps 01, 05, 06, 07, 08 |
| `drivers.R` | Downloads and stages the Microsoft JDBC 13.2.1 driver bundle into `drivers/` on first run | Step 01 via `connection.R` |
| `db_maintenance.R` | SQL Server maintenance utilities: pre-grows transaction log and tempdb before bulk ETL to prevent auto-growth stalls | Step 05 |
| `cohorts.R` | Creates OMOP results schema and cohort table; instantiates target surgery and SSI outcome cohorts from SQL files | Step 08 |
| `cohort_demographics.R` | Queries OMOP CDM for cohort summary statistics and demographic/procedural characteristics for Table 1 | Step 08 via `report_extended.R` |
| `risk_score_pipeline.R` | Integer risk score pipeline: reads covariate specs, queries OMOP for each covariate, computes person-level scores, AUROC/AUPRC, and calibration metrics | Step 08 |
| `report_extended.R` | Generates the manuscript-format Word report with cohort characteristics table, covariate prevalence, discrimination metrics, ROC curve, and calibration plots | Step 08 |

## Key functions available for testing

Pure functions (no database required) are covered by unit tests in `tests/testthat/`:

- `is_transient_db_error()`, `with_db_retry()` — connection retry logic
- `clamp_probability()`, `compute_ece()`, `compute_binary_metrics()` — statistical helpers
- `get_domain_mapping()`, `build_calibration_table()` — pipeline utilities
- `build_combined_feature_table()` — cohort demographics
- `read_score_specs()` — spec file validation
