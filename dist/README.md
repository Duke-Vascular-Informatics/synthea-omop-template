# dist/

Distributable portable validation bundles. This directory is excluded from git
(see `.gitignore` — `dist/*.zip` entry).

## Contents

Zip archives named `risk_score_validation_bundle_<YYYYMMDD_HHMMSS>.zip`, each containing
a self-contained copy of the risk score pipeline that can be run at any OMOP CDM site
without access to this repository.

## Building a bundle

```powershell
# Build and zip the bundle
powershell -ExecutionPolicy Bypass -File workflow/09_build_portable_analysis_bundle.ps1
```

The bundle is created by `scripts/bundle/build_portable_risk_score_bundle.ps1` and
written here as `dist/risk_score_validation_bundle_<timestamp>.zip`.

## Bundle contents

| Path in zip | Description |
|-------------|-------------|
| `R/` | Helper functions (connection, cohorts, pipeline, reporting) |
| `cohorts/` | Target and outcome cohort SQL definitions |
| `risk_score/` | Component, concept, and lookup CSVs |
| `config.R` | Connection parameter template (recipient fills in credentials) |
| `workflow/08_run_analysis_and_manuscript_report.R` | Analysis entry point |
| `portable/` | Pre-built R package binaries for offline install |
