# PAD / OLER - Surgical Site Infection (SSI) External Validation

This project performs external validation of a previously developed SSI prediction model using the OHDSI PatientLevelPrediction framework on a Synthea-generated OMOP CDM v5.4 SQL Server database.

## Purpose

- Reproduce an external validation workflow for a pre-trained SSI model.
- Run validation on `omop_synth` (`cdm_synthea`) with transparent, scriptable steps.
- Support restricted-network environments by prebuilding GitHub-based package binaries.

## Prerequisites

- R 4.5.2+
- Java 17 (Eclipse Adoptium)
- SQL Server instance with OMOP CDM loaded (`localhost:1434`, database `omop_synth`)
- A pre-trained PLP result folder from the original SSI development study

CRAN packages are installed from:
- `https://archive.linux.duke.edu/cran/`

## Repository Structure

```text
pad-oler-ssi-val/
  run_validation.R
  config.R
  install_packages.R
  setup_renv.R
  .Rprofile
  renv.lock
  cohorts/
    target_surgery.sql
    outcome_ssi.sql
  R/
    connection.R
    drivers.R
    cohorts.R
    validation.R
  scripts/
    prebuild_github_binaries.R
  internal_repo/
    bin/windows/contrib/4.5/
      FeatureExtraction_3.6.0.zip
      CohortGenerator_0.9.0.zip
      PatientLevelPrediction_6.4.0.zip
  drivers/
    mssql-jdbc-13.2.1.zip
```

## Package Strategy

### CRAN packages

Installed directly from the Duke CRAN mirror.

### GitHub packages (prebuilt internally)

The following GitHub packages are pinned and supported through prebuilt local binaries:

- `OHDSI/FeatureExtraction` @ `v3.6.0`
- `OHDSI/CohortGenerator` @ `v0.9.0`
- `OHDSI/PatientLevelPrediction` @ `v6.4.0`

`install_packages.R` installs these in this order:
1. From local internal binaries in `internal_repo/bin/windows/contrib/<R-version>/`
2. Fallback to GitHub only if a local binary is missing

This allows installs to run without GitHub access once binaries are prebuilt.

## One-Time Setup

From project root in a fresh R session:

```r
setwd("C:/Users/rapiduser/pad-oler-ssi-val")
source("setup_renv.R")
source("install_packages.R")
```

What this does:
- Activates `renv`
- Installs CRAN dependencies from Duke mirror
- Installs GitHub-pinned OHDSI packages from local internal binaries when available
- Provisions JDBC driver bundle to `drivers/`

## Prebuild GitHub Package Binaries

Run this only on a machine with GitHub access:

```r
setwd("C:/Users/rapiduser/pad-oler-ssi-val")
source("renv/activate.R")
source("scripts/prebuild_github_binaries.R")
```

This generates Windows binaries under:
- `internal_repo/bin/windows/contrib/4.5/`

Commit those binaries so restricted environments can install without GitHub.

## Run Validation

In a fresh R session:

```r
setwd("C:/Users/rapiduser/pad-oler-ssi-val")
source("run_validation.R")
```

Pipeline stages:
1. Load config
2. Build DB connection details and verify connection
3. Prepare target and outcome cohorts (ATLAS copy mode or local SQL mode)
4. Run `externalValidateDbPlp()`
5. Save outputs and launch PLP result viewer

## ATLAS Cohorts

This project is configured to use pre-built cohorts from ATLAS/WebAPI.

- Target cohort ID: `1796269`
- Outcome cohort ID: `1796278`

Default mapping in `config.R`:

```r
use_atlas_cohorts       = TRUE
atlas_cohort_schema     = "results"
atlas_cohort_table      = "cohort"
atlas_target_cohort_id  = 1796269L
atlas_outcome_cohort_id = 1796278L

# Destination IDs used by PLP
target_cohort_id  = 1L
outcome_cohort_id = 2L
```

What happens at runtime:

- Step 3 copies ATLAS cohort `1796269` into the project cohort table as target ID `1`.
- Step 3 copies ATLAS cohort `1796278` into the project cohort table as outcome ID `2`.
- Date filtering is applied using `study_start_date` and `study_end_date` from `config.R`.

If your ATLAS cohort table lives in another schema or table, update
`atlas_cohort_schema` and `atlas_cohort_table` in `config.R`.

## Notes

- `drivers/mssql-jdbc-13.2.1.zip` is tracked so JDBC setup is reproducible.
- Extracted JDBC runtime files remain ignored via `.gitignore`.
- `renv/library` is intentionally not committed.
