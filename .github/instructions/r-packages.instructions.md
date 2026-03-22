---
description: "Use when installing, loading, or suggesting R packages. Enforces CRAN mirror, renv workflow, and local binary installation for offline OHDSI packages (FeatureExtraction, CohortGenerator, PatientLevelPrediction)."
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

## Offline OHDSI GitHub Packages

Three OHDSI packages are pre-built as local Windows binaries. **Never** suggest
`remotes::install_github()`, `pak::pkg_install()`, or any GitHub-based install for these:

| Package | Version | Local binary path |
|---------|---------|-------------------|
| `FeatureExtraction` | 3.6.0 | `internal_repo/bin/windows/contrib/4.5/FeatureExtraction_3.6.0.zip` |
| `CohortGenerator` | 0.9.0 | `internal_repo/bin/windows/contrib/4.5/CohortGenerator_0.9.0.zip` |
| `PatientLevelPrediction` | 6.4.0 | `internal_repo/bin/windows/contrib/4.5/PatientLevelPrediction_6.4.0.zip` |

Use the project helper:

```r
# Defined in install_packages.R
install_from_internal_binary("FeatureExtraction")
install_from_internal_binary("CohortGenerator")
install_from_internal_binary("PatientLevelPrediction")
```

## Other OHDSI Packages

`DatabaseConnector` and `SqlRender` are on CRAN and may be installed normally via `renv::install()`.

## Version Alignment

Do not suggest upgrading any of the three pre-built packages above beyond their pinned versions
without first rebuilding the local binary via `scripts/prebuild_github_binaries.R`.
