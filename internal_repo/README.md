# internal_repo/

Pre-built Windows R package binaries for air-gapped HPC environments where
CRAN is not accessible. Used by `setup/install_packages.R` as a local CRAN
mirror when `USE_INTERNAL_REPO=true`.

## Current binaries (R 4.5, Windows)

| Package | Binary version | renv.lock version | Status |
|---------|---------------|-------------------|--------|
| ETLSyntheaBuilder | 2.1 | 2.1 | ✅ Current |
| CohortGenerator | 0.9.0 | — | ⚠️ Not in lockfile — may be unused |
| FeatureExtraction | 3.6.0 | 3.13.0 | ❌ Stale — rebuild needed |
| PatientLevelPrediction | 6.4.0 | 6.6.0 | ❌ Stale — rebuild needed |

## Rebuilding stale binaries

Stale binaries must be rebuilt on a Windows machine with R 4.5 and internet
access, then committed here. To rebuild:

```r
# On a Windows machine with R 4.5 and internet access
options(repos = c(CRAN = "https://cloud.r-project.org"))
install.packages("pkgbuild")

# Build binary for a specific package version
pkgbuild::build(binary = TRUE)
```

Or download pre-built binaries from the OHDSI HADES releases and place the
`.zip` files in `internal_repo/bin/windows/contrib/4.5/`.

## ⚠️ Warning

Using stale binaries in air-gapped installs will produce version mismatches
with `renv.lock`. Update binaries before deploying to a new HPC site.
