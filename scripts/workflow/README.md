# End-to-End Workflow (Numbered 1-9)

This folder provides a consistent, reproducible sequence that maps directly to the study lifecycle.

1. `01_setup_synthea_etl_qc_env.R`
   - Install packages and initialize environment for Synthea generation, ETL, and data quality checks.

2. `02_define_omop_cohort_outcome_covariates.R`
   - Validate cohort/outcome SQL and covariate definition artifacts (OMOP concept-based files).

3. `03_generate_synthea_module_artifacts.R`
   - Validate the disease-specific Synthea module and regenerate Mermaid diagram artifacts.

4. `04_generate_synthea_csv.ps1`
   - Generate Synthea synthetic patients in CSV format using the PAD/SSI module.

5. `05_etl_csv_to_omop.R`
   - ETL Synthea CSV output to OMOP CDM.

6. `06_quality_check_defined_phenotypes.R`
   - Run data quality checks aligned to the defined cohort/outcome/covariate framework.

7. `07_setup_analysis_env.R`
   - Install/verify packages and environment required for integer risk score external validation analysis.

8. `08_run_analysis_and_manuscript_report.R`
   - Run analysis and generate manuscript-format Word report.

9. `09_build_portable_analysis_bundle.ps1`
   - Build portable analysis code bundle for OMOP-structured data reuse.

## Typical execution order

From project root (PowerShell + Rscript):

```powershell
Rscript scripts/workflow/01_setup_synthea_etl_qc_env.R
Rscript scripts/workflow/02_define_omop_cohort_outcome_covariates.R
Rscript scripts/workflow/03_generate_synthea_module_artifacts.R
powershell -ExecutionPolicy Bypass -File scripts/workflow/04_generate_synthea_csv.ps1
Rscript scripts/workflow/05_etl_csv_to_omop.R
Rscript scripts/workflow/06_quality_check_defined_phenotypes.R
Rscript scripts/workflow/07_setup_analysis_env.R
Rscript scripts/workflow/08_run_analysis_and_manuscript_report.R
powershell -ExecutionPolicy Bypass -File scripts/workflow/09_build_portable_analysis_bundle.ps1
```
