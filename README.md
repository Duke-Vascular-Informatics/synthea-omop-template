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

### 0 — Prerequisites (do this once per machine)

Before cloning the study repo you need:
1. Docker Desktop running with a SQL Server Developer container
2. The OMOP vocabulary downloaded from Athena and loaded into that container

**→ Follow [docs/SETUP.md](docs/SETUP.md) for the complete step-by-step guide.**

That guide covers the required `OMOP_Dev/` folder layout, the `docker-compose.yml` for
SQL Server, downloading the correct Athena vocabulary bundles, running the CPT-4 rebuild,
and loading the vocabulary into SQL Server. It takes about an hour the first time (mostly
waiting for vocabulary load).

---

### 1 — Create your study repository

Click **"Use this template" → "Create a new repository"** at the top of this page.
Give it a study-specific name (e.g. `colectomy-ssi-omop`, `hip-replace-vte-omop`).

Clone the new repo **inside** your `OMOP_Dev/` folder (the relative paths in the dev
container depend on this):

```bash
cd OMOP_Dev
git clone https://github.com/<your-org>/<your-study>.git
cd <your-study>
```

Then open in the dev container (VS Code → **Reopen in Container**, or
`Cmd+Shift+P` → `Dev Containers: Reopen in Container`).

---

### 2 — Complete the study setup checklist

Run the pre-flight check to see everything that still needs your input:

```bash
Rscript scripts/check_setup.R
# or in Claude Code chat: /check-setup
```

Then work through `CHECKLIST.md` top-to-bottom. All study-specific settings live in
`study_params.yaml`:

| Setting | What to fill in |
|---------|----------------|
| `study_name` | Short identifier, lowercase with underscores |
| `study_design` | `cohort_characterization` \| `prognostic_model` \| `causal_inference` \| `descriptive` |
| `cdm_schema` | CDM schema populated by Step 5 ETL |
| `results_schema` | Schema for cohort table and analysis outputs |
| `cohort_table` | Cohort table name |
| `target.index_event.ancestor_concept_ids` | Index event concept IDs — run `/concept-lookup` first |
| `outcome.ancestor_concept_ids` | Outcome concept IDs — run `/concept-lookup` first |
| `prediction_window_days` | Follow-up window for outcome (days) |
| `study_start_date` / `study_end_date` | Date range for index event inclusion |
| `output_folder` | Where outputs are written (e.g. `output/my_study`) |
| `analyses.*` | Set `true` for each analysis to run in Step 8 |

For every concept ID, look it up before writing it:

```bash
Rscript scripts/concept_lookup.R "<clinical term>" [domain]
# Example: Rscript scripts/concept_lookup.R "total hip replacement" Procedure
# or in Claude Code chat: /concept-lookup total hip replacement Procedure
```

#### Cohort SQL files

Edit the template SQL files in `cohorts/` to match your study phenotype:

- `cohorts/target_surgery.sql` — index event (exposure / target cohort)
- `cohorts/outcome_ssi.sql` — outcome cohort
- `cohorts/comparator_cohort.sql` — comparator cohort (causal inference only)

Replace every `concept_id = 0` placeholder with a verified concept ID from
`/concept-lookup`. Rename the files to match your study and update the `sql_file:`
paths in `study_params.yaml`.

#### Covariate files

- `covariates/covariates.csv` — replace placeholder rows with your study covariates
- `covariates/covariate_concepts.csv` — map each covariate to verified OMOP concept IDs

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
# (skip 3–6 if running against a real CDM already populated)
Rscript workflow/07_setup_analysis_env.R
Rscript workflow/08_run_analysis_and_manuscript_report.R
```

No editing of `workflow/07` or `workflow/08` is needed. All analysis choices are
controlled by the `analyses:` flags in `study_params.yaml`.

---

### 5 — Commit your study definition

```bash
git add study_params.yaml cohorts/ covariates/
git commit -m "Define <study name> cohort, covariates, and analyses"
git push
```

---

## What to change vs. what to leave alone

| Change for every study | Leave as-is |
|------------------------|-------------|
| `study_params.yaml` | `config.R` (infrastructure only — no study edits needed) |
| `cohorts/*.sql` | `R/drivers.R`, `R/connection.R`, `R/cohorts.R` |
| `covariates/*.csv` | `setup/`, `.devcontainer/` |
| `analyses:` flags in `study_params.yaml` | `workflow/07`, `workflow/08` (no code editing) |
| `output_folder` in `study_params.yaml` | `renv.lock` (update only to add a new package) |

---

## Dev Container Setup

The repo ships a `.devcontainer/` folder that provides a fully configured Linux R + Java 17
environment inside Docker via VS Code. No local R or Java installation is needed.

**Complete setup instructions — including SQL Server, the required folder layout,
Athena vocabulary download, and CPT-4 rebuild — are in [docs/SETUP.md](docs/SETUP.md).**

### Quick summary

The dev container uses **relative paths** to find the SQL Server container and the
vocabulary files. Everything must live inside a single parent folder:

```
OMOP_Dev/                  ← parent folder (create once, shared across studies)
  .env                     ← MSSQL_SA_PASSWORD  (never commit)
  docker-compose.yml       ← SQL Server container definition  (see docs/SETUP.md)
  omop_vocab/              ← Athena vocabulary CSVs  (never commit)
  <your-study>/            ← this repo, cloned here
    .devcontainer/
      devcontainer.json
      docker-compose.extend.yml   ← mounts ../../omop_vocab and ../../.env
```

The one-time setup sequence:

```bash
# 1. Create parent folder and .env
mkdir OMOP_Dev && cd OMOP_Dev
echo 'MSSQL_SA_PASSWORD=YourStrong@Passw0rd' > .env

# 2. Create docker-compose.yml (see docs/SETUP.md for full contents) and start SQL Server
docker compose up -d

# 3. Download Athena vocabulary to OMOP_Dev/omop_vocab/ and rebuild CPT-4
#    (see docs/SETUP.md — requires a free UMLS API key for CPT-4)

# 4. Clone study repo inside OMOP_Dev/
git clone https://github.com/<your-org>/<your-study>.git

# 5. Open in VS Code → Reopen in Container

# 6. Inside the container: install R packages and verify DB
Rscript workflow/01_setup_synthea_etl_qc_env.R

# 7. Load OMOP vocabulary into SQL Server (~30–60 min, once per SQL Server instance)
Rscript scripts/setup_omop_vocab_schema.R
```

See [docs/SETUP.md](docs/SETUP.md) for the full `docker-compose.yml` contents, the
complete list of required Athena vocabularies, CPT-4 rebuild instructions, disk space
requirements, and troubleshooting guidance.

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
