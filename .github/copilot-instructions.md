# OMOP Study Template — Copilot / Claude Code Instructions

This is a **GitHub Template Repository** for observational studies on an OMOP CDM v5.4
SQL Server database. It supports cohort characterization, prognostic modelling, and
causal inference using the OHDSI R toolstack. The codebase is intentionally self-contained
and offline-capable.

## Study Context

This repository is a template. Study-specific content lives in:
- `config.R` — all settings (schemas, cohort IDs, SQL paths, study dates, output folder)
- `cohorts/` — SQL cohort definitions (target, comparator, outcome)
- `risk_score/` — covariate definition CSVs and score lookup table
- `workflow/02` — study design declaration and artifact validation
- `workflow/07` — analysis package list
- `workflow/08` — analysis code (Sections 7–9)

Infrastructure is pre-wired and should not be modified:
- `R/drivers.R`, `R/connection.R`, `R/cohorts.R` — database and cohort helpers
- `setup/`, `.devcontainer/` — renv and Docker environment
- `workflow/01`, `03–06`, `09` — ETL, QC, and packaging steps

When helping with this project, always read `config.R` first to understand the current
study's schema names, cohort IDs, and file paths before suggesting any code.

## Language and Runtime

- All analysis code is written in **R**. Do not suggest Python, Julia, or any other language.
- R version: **4.5.x**. Do not use syntax or packages unavailable in R 4.5.
- Java 17 (Eclipse Adoptium) is required for `DatabaseConnector` / `rJava`.

## Package Management

- This project uses **renv** for reproducible package management.
  - Always suggest `renv::install()` instead of bare `install.packages()`.
  - Never modify `renv.lock` manually; use `renv::snapshot()` after adding packages.
- CRAN packages must be installed from the mirror `https://archive.linux.duke.edu/cran/`.
  Do not suggest the default `https://cloud.r-project.org` or any other mirror.
- See `setup/install_packages.R` for the canonical install workflow.
- OHDSI packages not on CRAN ship as prebuilt binaries in `internal_repo/bin/`.

## Architecture

- `config.R` — single source of truth; always read via `get_validation_config()`.
- `R/cohorts.R` — `build_cohorts()` reads SQL file paths from `config$target_cohort_sql`,
  `config$comparator_cohort_sql`, `config$outcome_cohort_sql`. Do not hardcode paths.
- `workflow/08` sections 1–6 are pre-wired infrastructure; sections 7–9 are user code.
- All outputs go to `config$output_folder`. Do not hardcode output paths.

## Database

- DBMS: **SQL Server** (connection details from `get_validation_config()`).
- Vocabulary schema: `omop_vocab` (shared across studies).
- CDM schema, results schema, and cohort table are all set in `config.R`.
- Use `DatabaseConnector::connect(connection_details)` / `disconnect()` — never leave
  connections open across functions.
- Use `SqlRender::render()` + `SqlRender::translate(sql, "sql server")` for all SQL.

## Clinical Concept Mapping

- Do **not** rely on pretrained knowledge for OMOP concept IDs.
- Always derive concept mappings from the live vocabulary in the connected database.
- Required lookup workflow:
  1. Query `omop_vocab.concept` to identify candidates and confirm `standard_concept = 'S'`.
  2. Use `omop_vocab.concept_ancestor` to expand descendants when building concept sets.
  3. Verify `invalid_reason IS NULL` before committing any concept ID to code or CSV.
- Use the `/concept-lookup` slash command (`.github/prompts/concept-lookup.prompt.md`)
  before writing any concept ID into code or CSV files.

## Template Customization Assistance

When a user is setting up a new study from this template:

1. Read `config.R` and identify which `TODO [CONFIG]:` items have not yet been filled in
   (still contain placeholder values like `"my_study"`, `"cdm_my_study"`, `0` concept IDs).
2. Read the cohort SQL files referenced in `config$target_cohort_sql` and
   `config$outcome_cohort_sql` and flag any remaining `concept_id = 0` placeholders.
3. Check `risk_score/components.csv` for placeholder rows (`component_id` matching
   `covariate_1`, `covariate_2`, etc.).
4. Check `risk_score/component_concepts.csv` for `concept_id = 0` rows.
5. Summarize what is complete and what still needs filling in before running Step 8.

## Security and Safety

- Never hardcode credentials; all connection parameters come from `get_validation_config()`.
- Do not add calls to external URLs beyond the JDBC driver download in `R/drivers.R`.
- Do not write PHI or PII to disk — output files should contain only aggregate statistics.
- Outputs go to `config$output_folder`, which is gitignored.

## Version Control

After completing any code change, stage, commit, and push the affected files:

1. Stage only the relevant changed files — do not blanket-stage untracked files.
2. Write a concise conventional commit message: `<type>: <short description>`
   — types: `feat`, `fix`, `refactor`, `docs`, `chore`, `test`.
3. Push to `origin main`.
