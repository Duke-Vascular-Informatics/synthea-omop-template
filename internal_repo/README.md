# internal_repo/

Pre-built Windows R package binaries for air-gapped HPC environments where
CRAN is not accessible. Used by `setup/install_packages.R` as a local CRAN
mirror when `USE_INTERNAL_REPO=true`.

## Current binaries (R 4.5, Windows)

| Package | Binary version | renv.lock version | Status |
|---------|---------------|-------------------|--------|
| ETLSyntheaBuilder | 2.1 | 2.1 | ✅ Current |
| CohortGenerator | 0.9.0 | — | ⚠️ Not in lockfile — may be unused |
| FeatureExtraction | 3.6.0 | 3.13.0 | ❌ Stale — update needed |
| PatientLevelPrediction | 6.4.0 | 6.6.0 | ❌ Stale — update needed |

## Updating binaries

Run the following from any machine (macOS, Linux, or Windows) with internet
access. `download.packages()` fetches pre-built Windows `.zip` binaries
directly from CRAN regardless of the host OS:

```r
options(repos = c(CRAN = "https://cloud.r-project.org"))
dest <- "internal_repo/bin/windows/contrib/4.5"
dir.create(dest, recursive = TRUE, showWarnings = FALSE)

download.packages(
  c("FeatureExtraction", "PatientLevelPrediction"),
  destdir = dest,
  type    = "win.binary"
)
```

After downloading, delete the stale `.zip` files and commit the new ones.

## ⚠️ Warning

Using stale binaries in air-gapped installs will produce version mismatches
with `renv.lock`. Update binaries before deploying to a new HPC site.
