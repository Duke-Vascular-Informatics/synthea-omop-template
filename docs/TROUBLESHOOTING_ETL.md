# Troubleshooting: Synthetic Data Generation and ETL

Use this when Step 13 commands fail.

## Validate Run Order

Run in order:

```bash
Rscript workflow/01_setup_synthea_etl_qc_env.R
Rscript workflow/03_generate_synthea_module_artifacts.R
bash workflow/04_generate_synthea_csv.sh
Rscript workflow/05_etl_csv_to_omop.R
Rscript workflow/06_quality_check_defined_phenotypes.R
```

On Windows, use:

```powershell
powershell -ExecutionPolicy Bypass -File workflow/04_generate_synthea_csv.ps1
```

## Common Failure Patterns

- Missing Synthea CSV output:
  - Re-run Step 4 generator script (`.sh` or `.ps1`)
  - Check file paths expected by ETL scripts

- ETL fails on table/schema permissions:
  - Verify `cdm_schema` and `results_schema` in `study_params.yaml`
  - Confirm SQL user has create/insert privileges on target schema

- QC script reports low/empty counts:
  - Re-check cohort concept IDs and SQL placeholders (`concept_id = 0`)
  - Re-run `Rscript scripts/check_setup.R`

## Logs and Escalation

If still blocked, collect support diagnostics:

```bash
Rscript scripts/create_support_bundle.R
```

Share the archive path reported by the script when requesting help.
