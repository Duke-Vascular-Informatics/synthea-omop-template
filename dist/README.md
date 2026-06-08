# dist/

Dated zip archives of the portable analysis bundle, written here by
`workflow/09_build_portable_analysis_bundle.sh` as a local fallback
(e.g. for offline transfer via scp when the GitLab remote is unreachable).

This directory is excluded from git (see `.gitignore`).

## Building a bundle

```bash
# bash
bash workflow/09_build_portable_analysis_bundle.sh

# PowerShell
powershell -ExecutionPolicy Bypass -File workflow/09_build_portable_analysis_bundle.ps1
```

The primary delivery mechanism is a push to the institutional GitLab remote
configured in `.env` (`BUNDLE_GITLAB_REMOTE`). The zip written here is a
secondary fallback only.

## Bundle contents

| Path | Description |
|------|-------------|
| `R/` | Analysis pipeline helpers (connection, cohorts, reporting) |
| `cohorts/` | Target and outcome cohort SQL definitions |
| `covariates/` | Covariate and concept CSVs |
| `config.R` | Connection parameter template (recipient fills in credentials) |
| `run_analysis.R` | Analysis entry point |
| `drivers/` | MSSQL JDBC JAR for offline SQL Server connectivity |
