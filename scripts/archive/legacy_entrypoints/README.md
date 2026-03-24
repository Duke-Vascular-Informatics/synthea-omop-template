# Archived Legacy Entrypoints

This folder stores previous top-level and script-level runner entrypoints that were replaced by the canonical numbered workflow in `workflow/`.

Archived files are kept for historical traceability only and are not part of the supported execution path.

Current supported execution options:

1. Run individual numbered scripts in `workflow/01_...` through `workflow/09_...`

Archived in second-pass cleanup:

- `run_validation.R`
- `run_risk_score_pipeline.R`
- `run_report.R`
- `wipe_and_reload_etl.R`
- `gen_validation_report.R`
- `run_etlsyntheabuilder_etl.R`
- `run_fhir_to_omop_etl.R`
