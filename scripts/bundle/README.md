# scripts/bundle/

Build utilities for packaging the portable risk score validation bundle.
The bundle is a self-contained zip that can be distributed to sites with an
OMOP CDM and run without access to this repository.

## Files

| File | Description | Called by |
|------|-------------|-----------|
| `build_portable_risk_score_bundle.ps1` | Creates the distributable `dist/risk_score_validation_bundle_<timestamp>.zip`. Copies R scripts, cohort SQL, risk score CSVs, and a minimal renv lockfile into a staging directory and zips it. | `workflow/09_build_portable_analysis_bundle.ps1` |
| `prebuild_github_binaries.R` | Pre-builds and caches CRAN/GitHub binary packages into `portable/` so the bundle can install dependencies without internet access at the target site. Run once before building the bundle. | Manual (see README.md §Portable bundle) |

## Bundle contents

The output zip in `dist/` includes:
- `R/` helper functions
- `cohorts/` SQL definitions
- `risk_score/` component and concept CSVs
- `config.R` template (with placeholder connection parameters)
- `workflow/08_run_analysis_and_manuscript_report.R`
- Pre-built R package binaries from `portable/`
