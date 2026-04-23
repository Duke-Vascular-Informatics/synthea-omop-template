# OMOP Study Template

This GitHub repo is a reusable starter kit for electronic health care record based observational studies, utilizing an OMOP CDM v5.4 SQL Server database.
The type of analyses supported include **cohort characterization**, **prognostic modelling**, and **causal inference**
using Synthea-generated synthetic patient data and the OHDSI toolstack (DatabaseConnector, SqlRender, FeatureExtraction,
PatientLevelPrediction, CohortMethod).

The template is self-contained and optimized to develop analytic code utilizing claude code.  The purpose of this development workflow is to create tranportable offline-capable code: all R packages are pinned in
`renv.lock`, the JDBC driver is bundled, and OHDSI packages ship as prebuilt binaries
so the resulting analytic code runs in air-gapped or restricted-network environments.

---

## Using this Template

### 1 — Create your study repository

Click **"Use this template" → "Create a new repository"** at the top of this page.
Give it a study-specific name (e.g. `colectomy-ssi-omop`, `hip-replace-vte-omop`).

Clone the new repo and open it in the dev container (see [Dev Container Setup](#dev-container-setup)):

```bash
git clone https://github.com/<your-org>/<your-study>.git
cd <your-study>
# VS Code → "Reopen in Container"
```

---

### 2 — Complete the setup checklist

Work through the files below **in order**. Each one feeds the next.
Run this command first to see every placeholder that needs your input:

```r
Rscript scripts/find_todos.R
```

#### `config.R` — study identity and infrastructure

| Setting | What to change |
|---------|---------------|
| `cdm_schema` | CDM schema populated by Step 5 ETL (e.g. `"cdm_my_study_01"`) |
| `results_schema` | Schema for cohort table and outputs (e.g. `"my_study_results"`) |
| `cohort_table` | Cohort table name (e.g. `"my_study_cohort"`) |
| `target_cohort_id` / `comparator_cohort_id` / `outcome_cohort_id` | Integer IDs for each cohort population |
| `target_cohort_sql` / `comparator_cohort_sql` / `outcome_cohort_sql` | Paths to your renamed SQL files |
| `study_name` | Short identifier used in output file names |
| `prediction_window_days` | Follow-up window for outcome attribution (days) |
| `study_start_date` / `study_end_date` | Date range for index event inclusion |
| `output_folder` | Where outputs (CSVs, plots, reports) are written |

#### `cohorts/target_surgery.sql` — exposure / target cohort

Rename the file to match your study (e.g. `cohorts/hip_replacement_index.sql`) and
update `config$target_cohort_sql` to match. Then edit the SQL:

- Replace `concept_id = 0` in the `AND EXISTS` block with your exposure concept ancestor ID(s)
- Set `visit_concept_id` (9201 inpatient / 9202 outpatient / 9203 ED) or remove the filter
- Adjust or remove the minimum age filter
- Replace `concept_id = 0` in the `NOT EXISTS` washout block with your washout concept ID,
  or remove the block entirely

#### `cohorts/outcome_ssi.sql` — outcome cohort

Rename (e.g. `cohorts/vte_outcome.sql`) and update `config$outcome_cohort_sql`. Then edit:

- Replace `ancestor_concept_id = 0` with your outcome concept ancestor ID
- Add or remove `NOT EXISTS` exclusion blocks for unrelated sub-types
- Set to `NULL` in config if your design has no formal outcome (cohort characterization)

#### `cohorts/comparator_cohort.sql` *(causal inference only)*

Create this file (copy and adapt `target_surgery.sql`) and set `config$comparator_cohort_sql`
and `config$comparator_cohort_id`. Leave `comparator_cohort_sql = NULL` for other designs.

#### `covariates/components.csv` — covariate definitions

Replace the placeholder rows (`covariate_1`, `covariate_2`, …) with your study covariates.
Each row defines one scored predictor: domain, lookback window (days), and point value.
See the inline column documentation in the file for full details.

Set both covariate paths to `NULL` in config if you will define covariates using a
`FeatureExtraction::createCovariateSettings()` object in Step 8 instead.

#### `covariates/component_concepts.csv` — OMOP concept mappings

Map each `component_id` from `components.csv` to one or more verified standard OMOP
concept IDs. Use the concept lookup query in the file header to find the right IDs.
Replace all `concept_id = 0` placeholders before running Step 8.

#### `covariates/risk_lookup.csv` — score-to-probability table *(optional)*

Populate from your model's published lookup table, or leave empty to use
recalibrated logistic regression only.

#### `workflow/07_setup_analysis_env.R` — analysis packages

Uncomment the packages your Step 8 analysis needs. Reference lists for each study
design are in the file.

#### `workflow/08_run_analysis_and_manuscript_report.R` — analysis code

Sections 1–6 are pre-wired (renv, Java, connection, cohort instantiation).
Fill in **Section 7** (your analysis) and **Section 8** (your output).
Starter patterns for all three study designs are provided as commented examples.

---

### 3 — Run Step 2 to validate your artifacts

```bash
Rscript workflow/02_define_omop_cohort_outcome_covariates.R
```

Step 2 validates that all phenotype files exist, are non-empty, have the correct
columns, and contain no `concept_id = 0` placeholders. Fix any warnings before
proceeding.

---

### 4 — Run the full workflow

```bash
Rscript workflow/01_setup_synthea_etl_qc_env.R   # install packages, verify DB
Rscript workflow/02_define_omop_cohort_outcome_covariates.R
# Steps 3–6: Synthea module, synthetic data generation, ETL, QC
# (skip 3–6 if running against a real CDM that is already populated)
Rscript workflow/07_setup_analysis_env.R
Rscript workflow/08_run_analysis_and_manuscript_report.R
```

---

### 5 — Commit your study definition

```bash
git add config.R cohorts/ covariates/ workflow/07* workflow/08*
git commit -m "Define <study name> cohort, covariates, and analysis"
git push
```

---

## What to change vs. what to leave alone

| Change for every study | Leave as-is |
|------------------------|-------------|
| `config.R` (all TODO items) | `R/drivers.R`, `R/connection.R` |
| `cohorts/*.sql` | `setup/`, `.devcontainer/` |
| `covariates/*.csv` | `renv.lock` (update only if you need a different package version) |
| `workflow/07` package list | `workflow/01`, `03–06` |
| `workflow/08` sections 7–9 | `R/cohorts.R` |

---

## Dev Container Setup

The repo ships a `.devcontainer/` folder that provides a fully configured Linux R + Java 17
environment inside Docker via VS Code. No local R or Java installation is needed.

### Required folder layout

Clone this repo into an `OMOP_Dev/` parent folder alongside the MSSQL container:

```
OMOP_Dev/
  .env                      ← SA password (never commit)
  docker-compose.yml        ← MSSQL container definition
  omop_vocab/               ← Athena vocabulary download (never commit)
  <your-study>/             ← this repo
    .devcontainer/
```

### Step 1 — Install Docker Desktop and start the MSSQL container

```bash
mkdir OMOP_Dev && cd OMOP_Dev
git clone https://github.com/<your-org>/<your-study>.git

# Create the .env file with your SQL Server SA password
# If you have not created a SQL Server password before, you can create one now. Avoid using an exclamation mark in the password
echo "MSSQL_SA_PASSWORD=YourStrong@Passw0rd" > .env

# Copy docker-compose.yml from the repo to OMOP_Dev/ and start the container
docker compose up -d

# Create the project database (first time only)
docker exec mssql_dev bash -c \
  '/opt/mssql-tools18/bin/sqlcmd -S localhost -U SA -P "YourStrong@Passw0rd" -C -Q "CREATE DATABASE omop_synth;"'
```

### Step 2 — Download the OMOP Vocabulary from Athena

1. Go to [athena.ohdsi.org](https://athena.ohdsi.org) and create a free account.
2. Download at minimum: `SNOMED`, `LOINC`, `RxNorm`, `ICD10CM`, `CPT4`.
3. Extract to `OMOP_Dev/omop_vocab/`.
4. Rebuild CPT-4 codes (requires a free [UMLS API key](https://uts.nlm.nih.gov)):
   ```bash
   bash omop_vocab/cpt.sh   # macOS/Linux
   # omop_vocab\cpt.bat <UMLS API Key> 4   # Windows
   ```

### Step 3 — Install VS Code and open the dev container

1. Install [VS Code](https://code.visualstudio.com) and the **Dev Containers** extension
   (`ms-vscode-remote.remote-containers`).
2. Open the study folder in VS Code.
3. When prompted, click **Reopen in Container** — or use
   `Cmd+Shift+P` → `Dev Containers: Reopen in Container`.
4. First build takes ~5 minutes; subsequent opens are instant.

### Step 4 — One-time environment and vocabulary setup

```bash
# Install R packages and verify DB connectivity (~5–10 min, cached after first run)
Rscript workflow/01_setup_synthea_etl_qc_env.R

# Load OMOP vocabulary into shared omop_vocab schema (~30–60 min, once per SQL Server instance)
Rscript scripts/setup_omop_vocab_schema.R
```

---

## Workflow Reference

| Step | Script | Purpose |
|------|--------|---------|
| 1 | `workflow/01_setup_synthea_etl_qc_env.R` | Install packages, verify DB connectivity, provision JDBC driver |
| 2 | `workflow/02_define_omop_cohort_outcome_covariates.R` | **Validate your study definition** — cohort SQL, covariate CSVs, concept IDs |
| 3 | `workflow/03_generate_synthea_module_artifacts.R` | Validate Synthea disease module and regenerate HTML diagram |
| 4 | `workflow/04_generate_synthea_csv.ps1` / `.sh` | Generate Synthea synthetic patients (skip for real CDM data) |
| 5 | `workflow/05_etl_csv_to_omop.R` | ETL Synthea CSV → OMOP CDM (skip for real CDM data) |
| 6 | `workflow/06_quality_check_defined_phenotypes.R` | Post-ETL data quality checks |
| 7 | `workflow/07_setup_analysis_env.R` | Verify analysis packages are installed |
| 8 | `workflow/08_run_analysis_and_manuscript_report.R` | **Your analysis and outputs** |
| 9 | `workflow/09_build_portable_analysis_bundle.ps1` / `.sh` | Package bundle for deployment to external sites |

Each step script is standalone and resolves the project root automatically, so it can be
run from any shell working directory:

```bash
Rscript workflow/08_run_analysis_and_manuscript_report.R
```

Step 8 must be run in a **fresh R session** (the Java/JDBC guard will stop it otherwise).

---

## Repository Structure

```
<your-study>/
  config.R                    ← single source of truth for all settings
  workflow/                   ← numbered step scripts (01–09)
  R/                          ← reusable infrastructure functions
  setup/                      ← renv + package install helpers
  scripts/                    ← ETL, Synthea runner, QC utilities
  cohorts/                    ← SQL cohort definitions (edit these)
  covariates/                 ← covariate CSV spec files (edit these)
  synthea/modules/            ← Synthea disease module + diagram
  portable/                   ← self-contained bundle for external sites
  internal_repo/              ← prebuilt OHDSI package binaries
  drivers/                    ← JDBC driver archive
  .devcontainer/              ← Docker R + Java 17 dev environment
  .github/                    ← Claude Code / AI assistant instructions
  output/                     ← analysis outputs (gitignored)
```

---

## Package Management

R packages are pinned in `renv.lock` (R 4.5.2, cloud.r-project.org). OHDSI packages not
available on CRAN ship as prebuilt binaries in `internal_repo/bin/` for offline
installation.

To add a new package:

```r
renv::install("package_name")
renv::snapshot()
```

To rebuild OHDSI prebuilt binaries after updating a pinned version:

```r
source("renv/activate.R")
source("scripts/bundle/prebuild_github_binaries.R")
```

---

## Claude Code Integration

This repo ships a `CLAUDE.md` file at the project root that Claude Code reads automatically
on every session. It encodes three hard rules for AI-assisted coding:

1. **Concept ID transparency** — every concept ID recommendation must be tagged `[vocab query]`
   (confirmed against the live vocabulary) or `[pretraining]` (unverified, with explicit warning).
2. **HADES-first package selection** — use OHDSI HADES packages for all OHDSI methodology;
   fall back to tidyverse; all packages must be on the project CRAN mirror.
3. **Verbose comments** — all code follows OHDSI GitHub repository commenting conventions.

| File | Scope | Purpose |
|------|-------|---------|
| `CLAUDE.md` | Every session | Primary Claude Code instructions (three hard rules + project context) |
| `.github/instructions/r-packages.instructions.md` | `*.R` files | HADES priority, CRAN mirror, renv workflow |
| `.github/instructions/omop-ohdsi.instructions.md` | `*.R` and `*.sql` | DatabaseConnector/SqlRender patterns, concept ID lookup, OMOP CDM conventions |

**`/concept-lookup` slash command:**

```
/concept-lookup peripheral arterial disease condition
/concept-lookup cefazolin drug
/concept-lookup ankle brachial index measurement
```

Queries the live OMOP vocabulary in the connected database and returns a ranked
table of candidate concepts with a single recommended `concept_id`. Use this
before writing any concept ID into code or CSV files.

---

## Notes

- `drivers/mssql-jdbc-13.2.1.zip` is tracked so JDBC setup is reproducible offline.
- `renv/library/` is intentionally not committed (restored from `renv.lock` on first run).
- `output/` is gitignored — commit outputs separately if needed for reproducibility.
