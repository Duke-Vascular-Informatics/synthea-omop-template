# OMOP Study Template — Claude Code Instructions

This is a **GitHub Template Repository** for observational studies on an OMOP CDM v5.4
SQL Server database. It supports cohort characterization, prognostic modelling, and causal
inference using the OHDSI HADES R toolstack. The codebase is intentionally self-contained
and offline-capable.

---

## Project Context

Study-specific content lives in:
- `config.R` — all settings (schemas, cohort IDs, SQL paths, study dates, output folder)
- `cohorts/` — SQL cohort definitions (target, comparator, outcome)
- `covariates/` — covariate definition CSVs and score lookup table
- `workflow/02` — study design declaration and artifact validation
- `workflow/07` — analysis package list
- `workflow/08` — analysis code (Sections 7–9)

Infrastructure is pre-wired and should not be modified:
- `R/drivers.R`, `R/connection.R`, `R/cohorts.R` — database and cohort helpers
- `setup/`, `.devcontainer/` — renv and Docker environment
- `workflow/01`, `03–06`, `09` — ETL, QC, and packaging steps

**Always read `config.R` first** to understand the current study's schema names, cohort IDs,
and file paths before suggesting any code.

---

## Language and Runtime

- All analysis code is written in **R**. Do not suggest Python, Julia, or any other language.
- R version: **4.5.x**. Do not use syntax or packages unavailable in R 4.5.
- Java 17 (Eclipse Adoptium) is required for `DatabaseConnector` / `rJava`.

---

## Rule 1 — Concept ID Transparency (MANDATORY)

Every OMOP concept ID recommendation must be tagged with one of two labels:

- **[pretraining]** — derived from AI training data only. Treat as a starting hypothesis.
  You **must** accompany this tag with an explicit warning: *"This concept ID has not been
  verified against the live vocabulary. Run a vocabulary query before using it in code or CSV."*
- **[vocab query]** — confirmed by a live query against `omop_vocab` in this SQL Server
  instance. Safe to use for this vocabulary version.

**Hard rule:** Never write a concept ID into code, SQL, or a CSV file without first running
a live vocabulary query and labelling it **[vocab query]**. Pretraining concept IDs are
vocabulary-version-dependent and have been observed to map to completely wrong concepts
(e.g., ancestor IDs cited in OHDSI documentation mapped to unrelated domains in this
vocabulary build).

### Vocabulary lookup workflow

Before committing any concept ID:

```sql
-- Step 1: Find candidate standard concepts
SELECT concept_id, concept_name, domain_id, vocabulary_id, standard_concept, invalid_reason
FROM omop_vocab.concept
WHERE concept_name LIKE '%your term%'
  AND standard_concept = 'S'
  AND invalid_reason IS NULL;

-- Step 2: Expand descendants via concept_ancestor
SELECT c.concept_id, c.concept_name, c.domain_id
FROM omop_vocab.concept_ancestor ca
JOIN omop_vocab.concept c ON c.concept_id = ca.descendant_concept_id
WHERE ca.ancestor_concept_id = <your_chosen_concept_id>
  AND c.standard_concept = 'S'
  AND c.invalid_reason IS NULL;
```

Two ways to run a vocabulary lookup:

**Interactive (Claude Code chat):**
```
/concept-lookup <clinical term> [domain]
```

**Standalone R script (terminal / batch):**
```bash
Rscript scripts/concept_lookup.R "<clinical term>" [domain]
# Examples:
Rscript scripts/concept_lookup.R "total hip replacement" Procedure
Rscript scripts/concept_lookup.R "venous thromboembolism" Condition
```

Both perform the same two-step query (name/synonym match, then descendant expansion)
and label results `[vocab query]`. The R script is preferred for batch lookups or when
a database connection is not available in the chat environment.

---

## Rule 2 — Package Selection Priority

When selecting packages for any analysis task, apply this strict priority order:

1. **HADES packages first** — use the OHDSI Health Analytics Data-to-Evidence Suite
   (HADES) when a method is covered. Key HADES packages: `DatabaseConnector`, `SqlRender`,
   `FeatureExtraction`, `PatientLevelPrediction`, `CohortMethod`, `CohortDiagnostics`,
   `CohortGenerator`, `EvidenceSynthesis`, `SelfControlledCaseSeries`, `EmpiricalCalibration`.
   Consult the **Book of OHDSI** (https://ohdsi.github.io/TheBookOfOhdsi/) for the canonical
   approach before reaching for any other package.

2. **tidyverse packages second** — when the task falls outside the scope of HADES (data
   wrangling, visualization, string manipulation, I/O), prefer tidyverse packages: `dplyr`,
   `tidyr`, `ggplot2`, `readr`, `purrr`, `stringr`, `lubridate`, `forcats`.

3. **Project CRAN mirror only** — any package must be available on the project CRAN mirror
   (configured via `CRAN_MIRROR` in `.env`; defaults to `https://cloud.r-project.org`).
   Do not suggest packages that are only on GitHub, Bioconductor, or any other source
   unless they are OHDSI HADES packages pre-built in `internal_repo/bin/`.

4. **Never suggest** `dbplyr`, `odbc`, `DBI` directly, or any Python/Julia dependency.

### HADES reference by study design

| Study design | Primary HADES packages |
|---|---|
| Cohort characterization | `FeatureExtraction`, `CohortDiagnostics` |
| Prognostic modelling | `PatientLevelPrediction`, `FeatureExtraction` |
| Causal inference | `CohortMethod`, `FeatureExtraction`, `EvidenceSynthesis` |
| SCCS | `SelfControlledCaseSeries`, `EmpiricalCalibration` |
| Data quality | `DataQualityDashboard` |

### Package management

- Install via `renv::install()` — never bare `install.packages()`
- After adding a package: `renv::snapshot()`
- CRAN mirror: `options(repos = c(CRAN = Sys.getenv("CRAN_MIRROR", unset = "https://cloud.r-project.org")))`

---

## Rule 3 — Verbose Comments (OHDSI GitHub Style)

All code must include verbose inline comments following the conventions used in OHDSI
GitHub repositories (e.g., HADES package source code, Book of OHDSI example scripts).

**Required commenting style:**

- **File header**: every R script opens with a block comment identifying purpose, inputs,
  outputs, and any important assumptions or prerequisites.
- **Section headers**: use `# ============` banners for major sections (matching the
  numbered sections in `workflow/08_run_analysis_and_manuscript_report.R`).
- **Function-level**: document what each function does, its parameters, return value, and
  side effects before the function definition.
- **Non-obvious logic**: comment every non-trivial SQL join, window function, or
  HADES configuration argument explaining *why*, not just *what*.
- **Concept IDs inline**: every hardcoded concept ID must have a trailing comment
  identifying the concept name and its source label, e.g.:
  ```r
  procedure_concept_id = 4301351  # [vocab query] SNOMED: Coronary artery bypass graft
  ancestor_concept_id  = 0        # [REPLACE] TODO: insert verified ancestor concept ID
  ```
- **TODO blocks**: use `# TODO [LABEL]:` tags (matching the project convention) so they
  are findable by `Rscript scripts/find_todos.R` (cross-platform).

**Do not**:
- Leave concept IDs with no comment explaining what they represent.
- Write "magic number" SQL filters without explaining the clinical rationale.
- Skip comments in SQL files — SQL comments (`--`) are as important as R comments.

---

## Architecture

- `config.R` — single source of truth; always read via `get_validation_config()`.
- `R/cohorts.R` — `build_cohorts()` reads SQL file paths from `config$target_cohort_sql`,
  `config$comparator_cohort_sql`, `config$outcome_cohort_sql`. Do not hardcode paths.
- `workflow/08` is fully driven by `analyses:` flags in `study_params.yaml` — no code
  editing is needed. Enable analyses by setting their flags to `true`.
- All outputs go to `config$output_folder`. Do not hardcode output paths.

---

## Database

- DBMS: **SQL Server** (connection details from `get_validation_config()`).
- Vocabulary schema: `omop_vocab` (shared across studies).
- CDM schema, results schema, and cohort table are all set in `config.R`.
- Use `DatabaseConnector::connect(connection_details)` / `disconnect()` — never leave
  connections open across functions.
- Use `SqlRender::render()` + `SqlRender::translate(sql, "sql server")` for all SQL.

---

## Template Customization Assistance

### Automated pre-flight check

The fastest way to assess setup status is to run the dedicated check script or skill:

**Terminal:**
```bash
Rscript scripts/check_setup.R
```

**Claude Code chat:**
```
/check-setup
```

Both scan `study_params.yaml`, cohort SQL files, and covariate CSVs without a database
connection and print a sectioned [OK] / [WARN] / [FAIL] checklist. Exit code 0 = ready
for Step 8; exit code 1 = items require attention.

### Manual checklist (when assisting interactively)

When a user asks for setup help and hasn't run the script, perform these checks inline:

1. Read `study_params.yaml` and identify fields still at their default placeholder values
   (`"my_study"`, `"cdm_my_study"`, `"my_study_results"`, `"my_study_cohort"`,
   `"output/my_study"`, concept IDs = `0`).
2. Read the cohort SQL files referenced in `target.sql_file` and `outcome.sql_file`
   (and `comparator.sql_file` when `comparator.cohort_id` is set) and flag any lines
   containing `concept_id = 0`.
3. Check `covariates/covariates.csv` for placeholder rows (`covariate_id` matching
   `covariate_1`, `covariate_2`, etc.).
4. Check `covariates/covariate_concepts.csv` for `concept_id = 0` rows.
5. Check the `analyses:` flags — confirm at least one is set to `true`.
6. Summarize what is complete and what still needs filling in before running Step 8,
   using the same [OK] / [WARN] / [FAIL] format as `scripts/check_setup.R`.

---

## Security and Safety

- Never hardcode credentials; all connection parameters come from `get_validation_config()`.
- Do not add calls to external URLs beyond the JDBC driver download in `R/drivers.R`.
- Do not write PHI or PII to disk — output files should contain only aggregate statistics.
- Outputs go to `config$output_folder`, which is gitignored.

---

## Version Control

After completing any code change, stage, commit, and push the affected files:

1. Stage only the relevant changed files — do not blanket-stage untracked files.
2. Write a concise conventional commit message: `<type>: <short description>`
   — types: `feat`, `fix`, `refactor`, `docs`, `chore`, `test`.
3. Push to `origin main`.
