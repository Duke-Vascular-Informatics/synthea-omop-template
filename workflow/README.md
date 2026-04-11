# End-to-End Workflow (Numbered 1-9)

This folder provides a consistent, reproducible sequence that maps directly to the study lifecycle.

1. `01_setup_synthea_etl_qc_env.R`
   - Install packages and initialize environment for Synthea generation, ETL, and data quality checks.
   - **Automatically clones the [synthea-pad](https://github.com/adam-mdmph/synthea-pad) repo into `external/synthea/`** if not already present. No manual setup required.

2. `02_define_omop_cohort_outcome_covariates.R`
   - Validate cohort/outcome SQL and covariate definition artifacts (OMOP concept-based files).

3. `03_generate_synthea_module_artifacts.R`
   - Validate the disease-specific Synthea module and regenerate Mermaid diagram artifacts.

4. `04_generate_synthea_csv.ps1` (Windows) / `04_generate_synthea_csv.sh` (Linux/macOS)
   - Generate Synthea synthetic patients in CSV format using the PAD/SSI module.
   - Requires `external/synthea/` to be present (cloned automatically by Step 1).

5. `05_etl_csv_to_omop.R`
   - ETL Synthea CSV output to OMOP CDM.
   - Requires vocabularies to be preloaded by external `vocab_omop_etl`.

6. `06_quality_check_defined_phenotypes.R`
   - Run data quality checks aligned to the defined cohort/outcome/covariate framework.

7. `07_setup_analysis_env.R`
   - Install/verify packages and environment required for integer risk score external validation analysis.

8. `08_run_analysis_and_manuscript_report.R`
   - Run analysis and generate manuscript-format Word report.

9. `09_build_portable_analysis_bundle.sh` (Linux/macOS dev container) / `09_build_portable_analysis_bundle.ps1` (Windows legacy)
   - Syncs the latest analysis code into `portable/prcc_bundle/`, then pushes it to the
     `prcc-bundle` branch at `git@gitlab.dhe.duke.edu:apj20/pad-oler-ssi-val.git`.
   - PRCC can then deploy with: `git clone --branch prcc-bundle <remote>`
   - A dated zip fallback is also written to `dist/` for offline transfers.
   - **Prerequisites:** set `PRCC_GITLAB_REMOTE`, `PRCC_GIT_USER_NAME`, `PRCC_GIT_USER_EMAIL`
     in `OMOP_Dev/.env`. SSH key for `gitlab.dhe.duke.edu` must be loaded in your SSH agent.

## Standalone step execution

Each step script is standalone and can be run directly.
Each script auto-resolves the repository root from its own location, so you can run it from any current working directory.

Step 8 generates a shareable Word report (`.docx`) under `output/risk_score_eval/`.

Examples:

```powershell
# R-based steps
Rscript workflow/01_setup_synthea_etl_qc_env.R
Rscript workflow/02_define_omop_cohort_outcome_covariates.R
Rscript workflow/03_generate_synthea_module_artifacts.R
Rscript workflow/05_etl_csv_to_omop.R "C:/Users/rapiduser/source/repos/synthea/output/csv" "padssi-csv-20260324-120000"
Rscript workflow/05_etl_csv_to_omop.R --csv_input_dir=C:/Users/rapiduser/source/repos/synthea/output/csv --run_name=padssi-csv-20260324-120000 --reset_before_etl=true
Rscript workflow/06_quality_check_defined_phenotypes.R --run_name=padssi-csv-20260324-120000 --enforce_thresholds=true --min_person_rows=100 --min_open_revascularization_rows=50 --min_ssi_condition_rows=5 --min_mapped_condition_pct=50
Rscript workflow/07_setup_analysis_env.R
Rscript workflow/08_run_analysis_and_manuscript_report.R

# PowerShell-based steps (Windows)
powershell -ExecutionPolicy Bypass -File workflow/04_generate_synthea_csv.ps1

# Bash equivalents (Linux/macOS dev container)
bash workflow/04_generate_synthea_csv.sh
bash workflow/09_build_portable_analysis_bundle.sh
```

## Step parameters

- `workflow/04_generate_synthea_csv.ps1`: `-SyntheaHome`, `-Population`, `-AgeRange`, `-State`
- `workflow/05_etl_csv_to_omop.R`: arg1 = `csv_input_dir`, arg2 = `run_name`; optional named args `--csv_input_dir=...`, `--run_name=...`, `--reset_before_etl=true|false`
- `workflow/05_etl_csv_to_omop.R`: vocabulary loading flags are deprecated and ignored (`--force_reload_vocab`, `--vocab_file_loc`)
- `workflow/06_quality_check_defined_phenotypes.R`: pass-through args accepted by `scripts/quality_check_etl.R`, including `--run_name=...`, `--enforce_thresholds=true|false`, `--min_person_rows=...`, `--min_open_revascularization_rows=...`, `--min_ssi_condition_rows=...`, `--min_mapped_condition_pct=...`

## Typical execution order

From project root (PowerShell + Rscript):

```powershell
Rscript workflow/01_setup_synthea_etl_qc_env.R
Rscript workflow/02_define_omop_cohort_outcome_covariates.R
Rscript workflow/03_generate_synthea_module_artifacts.R
powershell -ExecutionPolicy Bypass -File workflow/04_generate_synthea_csv.ps1
Rscript workflow/05_etl_csv_to_omop.R
Rscript workflow/06_quality_check_defined_phenotypes.R
Rscript workflow/07_setup_analysis_env.R
Rscript workflow/08_run_analysis_and_manuscript_report.R
```

Legacy one-off entrypoint scripts were archived under `scripts/archive/legacy_entrypoints/` and are no longer the supported path.
