# PAD/OLER SSI Validation Study — Copilot Instructions

This is an R-based OHDSI external validation study for a Surgical Site Infection (SSI)
prediction model in patients with peripheral arterial disease (PAD). The codebase is
intentionally self-contained and offline-capable.

## Language and Runtime

- All analysis code is written in **R**. Do not suggest Python, Julia, or any other language.
- R version: **4.5.x**. Do not use syntax or packages unavailable in R 4.5.
- Java 17 (Eclipse Adoptium) is required for `DatabaseConnector`/`rJava` — path is
  `C:/Program Files/Eclipse Adoptium/jdk-17.0.18.8-hotspot`.

## Package Management

- This project uses **renv** for reproducible package management.
  - Always suggest `renv::install()` instead of bare `install.packages()`.
  - Never modify `renv.lock` manually; use `renv::snapshot()` after adding packages.
- CRAN packages must be installed from the mirror `https://archive.linux.duke.edu/cran/`.
  Do not suggest the default `https://cloud.r-project.org` or any other mirror.
- See `setup/install_packages.R` for the canonical install workflow.

## Offline GitHub Packages

Three OHDSI packages are **locally hosted as pre-built Windows binaries** — never suggest
installing them from GitHub with `remotes::install_github()` or `pak`:

| Package | Version | Local binary |
|---------|---------|--------------|
| `FeatureExtraction` | 3.6.0 | `internal_repo/bin/windows/contrib/4.5/FeatureExtraction_3.6.0.zip` |
| `CohortGenerator` | 0.9.0 | `internal_repo/bin/windows/contrib/4.5/CohortGenerator_0.9.0.zip` |
| `PatientLevelPrediction` | 6.4.0 | `internal_repo/bin/windows/contrib/4.5/PatientLevelPrediction_6.4.0.zip` |

Use the `install_from_internal_binary()` helper in `setup/install_packages.R` for these packages.

## Architecture

- `config.R` — single source of truth for all settings (connection, schema names, cohort IDs,
  file paths). Always read config via `get_validation_config()`.
- `R/` — all reusable R functions (cohorts, database helpers, risk score pipeline).
- `run_validation.R` — entry point for PLP external validation.
- `run_risk_score_pipeline.R` — entry point for integer risk score evaluation.
- `risk_score/` — CSV spec files defining score components, concept mappings, and risk lookup.
- `cohorts/` — SQL cohort definitions (used when ATLAS cohorts are unavailable).
- `output/` — all analysis outputs (gitignored).

## Database

- DBMS: **SQL Server 2019** (`localhost:1434`, database `omop_synth`).
- CDM schema: `cdm_synthea` (OMOP CDM v5).
- Results schema: `plp_results`.
- See `omop-ohdsi.instructions.md` for OMOP/OHDSI coding conventions.

## Security and Safety

- Never hardcode credentials; all connection parameters come from `get_validation_config()`.
- Do not add calls to external URLs or APIs beyond the JDBC driver download in `R/drivers.R`.
- Do not write PHI or PII to disk — output CSVs contain only aggregate statistics.

## Version Control

After completing any major code change (new features, bug fixes, refactors, documentation
updates, or file additions/deletions), always stage, commit, and push the affected files to
GitHub:

1. Stage only the relevant changed files (do not blanket-stage unrelated untracked files).
2. Write a concise conventional commit message: `<type>: <short description>`
   — types: `feat`, `fix`, `refactor`, `docs`, `chore`, `test`.
3. Push to `origin main`.

Use the GitKraken MCP git tools (`mcp_gitkraken_git_add_or_commit`, `mcp_gitkraken_git_push`)
for staging, committing, and pushing unless the user explicitly asks to use the terminal.
