# R/

Core R helper functions for synthetic data generation. These files are sourced
by the numbered workflow steps — they are not a package and should not be run directly.

## Files used by Steps 1–6

| File | Purpose | Sourced by |
|------|---------|------------|
| `connection.R` | Builds DatabaseConnector connection details for SQL Server with JDBC/Windows auth; retry helpers for transient DB errors | Steps 01, 05, 06 |
| `drivers.R` | Downloads and stages the Microsoft JDBC 13.2.1 driver bundle into `drivers/` on first run | Step 01 via `connection.R` |
| `consumer_qc.R` | Consumer-study QC: renders each consuming Strategus study's cohorts from circe JSON, instantiates them against the synthetic CDM with CohortGenerator, and counts subjects per role | `scripts/consumer_cohort_qc.R` (Step 06) |
| `db_maintenance.R` | SQL Server maintenance utilities: pre-grows transaction log and tempdb before bulk ETL to prevent auto-growth stalls | Step 05 |

## Key functions available for testing

Pure functions (no database required) are covered by unit tests in `tests/testthat/`:

- `is_transient_db_error()`, `with_db_retry()` — connection retry logic

## Removed

`cohorts.R` (cohort instantiation, ATLAS-cohort copy, `additional_outcomes`) and the
analysis and manuscript-report code (`risk_score_pipeline.R`, `report_*.R`,
`plp_validation_pipeline.R`, `cohort_demographics.R`, and the old `workflow/07–08`) have
been removed; nothing here called them. Cohorts are instantiated by Strategus in the
analysis-core repo, and `consumer_qc.R` instantiates the consuming studies' cohorts
into scratch tables to QC this dataset. The code remains in git history.
