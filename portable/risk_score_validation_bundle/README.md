# Portable OMOP Risk Score Validation Bundle

This folder is designed to be zipped and shared with external OMOP data partners.
It contains only the files needed to run integer risk score validation.

## Contents

- `run_risk_score_pipeline.R` - main entry point
- `config.R` - environment-specific settings template
- `install_packages_risk_score.R` - package install helper
- `R/` - pipeline and database helper functions
- `risk_score/` - component, concept, and lookup CSV inputs
- `drivers/mssql-jdbc-13.2.1.zip` - SQL Server JDBC archive

## How To Use At A New Site

1. Unzip this folder.
2. Edit `config.R` with local SQL Server and OMOP schema details.
3. Fill `risk_score/component_concepts.csv` with site-approved OMOP standard concept IDs.
4. In a fresh R session, run:

```r
setwd("<unzipped_bundle_path>")
source("install_packages_risk_score.R")
source("run_risk_score_pipeline.R")
```

## Output

Results are written to:

- `output/risk_score_eval/`

## Notes

- The bundle expects existing target/outcome cohorts in `results_schema.cohort_table` with IDs from `config.R`.
- `risk_score/risk_lookup.csv` is optional but required for lookup-based calibration metrics.
