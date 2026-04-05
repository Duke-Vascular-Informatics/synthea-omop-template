# scripts/archive/

Inactive scripts preserved for historical reference. These files are **not part of the
active workflow** and are excluded from linting (see `.lintr`).

Do not source or run these scripts without reviewing their contents — paths and
assumptions may be stale.

## Subdirectories

| Directory | Contents |
|-----------|----------|
| `legacy_entrypoints/` | Root-level entry point scripts superseded by the numbered `workflow/` steps (e.g., `run_validation.R`, `run_report.R`, `install_packages.R`, `setup_renv.R`) |
| `R/` | Earlier versions of `report.R` and `validation.R` superseded by `R/report_extended.R` |
| `etl/` | Earlier ETL scripts superseded by `scripts/etl/run_synthea_full_csv_builder_etl.R`; manual drug era SQL; one-off reset utilities |
| `sql/` | Draft SQL transforms (FHIR→OMOP, Synthea CSV→OMOP, schema cleanup) that predate the ETLSyntheaBuilder approach |
| `workflow/` | One-off `reset_omop_and_staging.R` utility not part of the numbered workflow |
| `*.R` (top-level) | Standalone diagnostic and index-building utilities (`diag_concept_ancestor.R`, `create_concept_ancestor_indexes.R`, `fix_sql_server_transaction_log.R`) |
