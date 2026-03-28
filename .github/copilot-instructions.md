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

## GitHub Package Fallback

Some OHDSI packages are not on CRAN and must be installed from GitHub when unavailable on CRAN.

- Use CRAN first (via `renv::install()`), then fall back to `remotes::install_github()` for non-CRAN packages.
- Current GitHub fallback packages in `setup/install_packages.R`:
  - `FeatureExtraction` (`OHDSI/FeatureExtraction`, `v3.6.0`)
  - `CohortGenerator` (`OHDSI/CohortGenerator`, `v0.9.0`)
  - `PatientLevelPrediction` (`OHDSI/PatientLevelPrediction`, `v6.4.0`)
  - `ETLSyntheaBuilder` (`OHDSI/ETL-Synthea`, `v2.1.0`)

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

## Clinical Code Mapping

- When mapping clinical terms or source codes (for example SNOMED, ICD, CPT, LOINC), do **not** rely on pretrained model memory.
- Always derive concept mappings from the live OMOP vocabulary in this database.
- Required lookup workflow:
  1. Query `cdm_synthea.concept` to identify candidate concepts and confirm `standard_concept` status.
  2. Use `cdm_synthea.concept_relationship` to map source/non-standard concepts to standard concepts and verify relationship semantics.
  3. Use `cdm_synthea.concept_ancestor` to expand descendants/ancestors when building concept sets.
- Do not hard-code concept IDs unless they have been validated against these tables in the current database instance.

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
