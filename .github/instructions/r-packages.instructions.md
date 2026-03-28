---
description: "Use when installing, loading, or suggesting R packages. Enforces CRAN mirror, renv workflow, and CRAN-first with GitHub fallback for non-CRAN OHDSI packages."
applyTo: "**/*.R"
---

# R Package Management Rules

## CRAN Mirror

Always use the project-approved CRAN mirror — never suggest the default or any other mirror:

```r
options(repos = c(CRAN = "https://archive.linux.duke.edu/cran/"))
```

## renv

This project uses `renv` for reproducible package management:

- **Install packages**: `renv::install("package")` — never bare `install.packages()`
- **After adding packages**: run `renv::snapshot()` to update `renv.lock`
- **Restore environment**: `renv::restore()` on a fresh clone
- Never edit `renv.lock` manually

## OHDSI Packages Not On CRAN

Use CRAN first. When a required package is not available on CRAN, use GitHub fallback via
`remotes::install_github()` with the pinned refs in `setup/install_packages.R`.

Current GitHub fallback set:

| Package | Repo | Ref |
|---------|------|-----|
| `FeatureExtraction` | `OHDSI/FeatureExtraction` | `v3.6.0` |
| `CohortGenerator` | `OHDSI/CohortGenerator` | `v0.9.0` |
| `PatientLevelPrediction` | `OHDSI/PatientLevelPrediction` | `v6.4.0` |
| `ETLSyntheaBuilder` | `OHDSI/ETL-Synthea` | `v2.1.0` |

## Other OHDSI Packages

`DatabaseConnector` and `SqlRender` are on CRAN and may be installed normally via `renv::install()`.

## Version Alignment

Do not suggest upgrading pinned GitHub package refs without validating compatibility first.
Keep R version compatibility in mind (currently R 4.5) and python version 3.9.25 for OHDSI package build scripts.
