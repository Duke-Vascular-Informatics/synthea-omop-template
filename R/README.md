# R/

Core R helper functions for synthetic data generation. These files are sourced
by the numbered workflow steps — they are not a package and should not be run directly.

## Files used by Steps 1–6

| File | Purpose | Sourced by |
|------|---------|------------|
| `connection.R` | Builds DatabaseConnector connection details for SQL Server with JDBC/Windows auth; retry helpers for transient DB errors | Steps 01, 05, 06 |
| `drivers.R` | Downloads and stages the Microsoft JDBC 13.2.1 driver bundle into `drivers/` on first run | Step 01 via `connection.R` |
| `db_maintenance.R` | SQL Server maintenance utilities: pre-grows transaction log and tempdb before bulk ETL to prevent auto-growth stalls | Step 05 |

## Key functions available for testing

Pure functions (no database required) are covered by unit tests in `tests/testthat/`:

- `is_transient_db_error()`, `with_db_retry()` — connection retry logic

## Retained from a previous version (not used by Steps 1–6)

`cohorts.R`, `cohort_demographics.R`, `risk_score_pipeline.R`, `report_extended.R`,
`report_helpers.R`, `report_prognostic.R`, `report_descriptive.R`, and `report_causal.R`
supported a full in-repo analysis-and-manuscript-report workflow (the old `workflow/08`)
that this template no longer documents or recommends — see git history for how they were
used. New analysis work belongs in a separate repo built from `strategus-study-template`.
