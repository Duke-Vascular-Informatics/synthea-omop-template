# OMOP Study Template

This GitHub repo is a reusable starter kit for electronic health care record based observational studies, utilizing an OMOP CDM v5.4 SQL Server database.
The type of analyses supported include **cohort characterization**, **prognostic modelling**, and **causal inference**
using Synthea-generated synthetic patient data and the OHDSI toolstack (DatabaseConnector, SqlRender, FeatureExtraction,
PatientLevelPrediction, CohortMethod).

The template is self-contained and optimized to develop analytic code with any AI coding assistant
(GitHub Copilot, Claude Code, or others). The purpose of this development workflow is to create
transportable offline-capable code: all R packages are pinned in `renv.lock`, the JDBC driver is bundled,
and OHDSI packages ship as prebuilt binaries so the resulting analytic code runs in air-gapped or
restricted-network environments.

---

## Recommended Flow

The recommended path is now post-clone:
1. Create `OMOP_Dev/`
2. Clone the study repo into it
3. Check whether Docker + shared OMOP resources already exist on that machine
4. Run setup only for missing pieces
5. Open in the dev container

The actual dependency is on the dev container and database-connected scripts, not on `git clone` itself.

**→ Start with [docs/GETTING_STARTED.md](docs/GETTING_STARTED.md)** for complete step-by-step instructions from scratch.

---

## Study-Specific Setup (after cloning)

### 1 — Create your study repository first

Click **"Use this template" → "Create a new repository"** at the top of this page.
Give it a study-specific name using this convention:

`<disease_cohort_abbrev>_<treatment_abbrev>_<outcome_abbrev>_<methodology_abbrev>`

Use lowercase abbreviations separated by underscores.

Recommended methodology abbreviations:
- `char` = cohort characterization
- `plp` = prognostic model
- `ci` = causal inference
- `desc` = descriptive study

Examples:
- `pad_stent_male_ci`
- `oa_thr_vte_plp`
- `crc_colectomy_ssi_char`

Clone the new repo **inside** your `OMOP_Dev/` folder (the relative paths in the dev
container depend on this):

```bash
cd OMOP_Dev
git clone https://github.com/<your-org>/<your-study>.git
cd <your-study>
```

Then check whether the local machine already has the shared setup (`.env`, `docker-compose.yml`,
`omop_vocab/`, and a healthy `mssql_dev` container). Only complete the missing pieces.

---

### 2 — Complete local machine setup if needed

If the machine is not already set up, run the automated setup script from the parent `OMOP_Dev/` folder:

```bash
# macOS / Linux
cd ~/OMOP_Dev
bash <your-study>/setup/setup_docker_and_vocab.sh

# Windows (PowerShell)
cd $env:USERPROFILE/OMOP_Dev
powershell -ExecutionPolicy Bypass -File <your-study>\setup\setup_docker_and_vocab.ps1
```

These scripts automate:
- Creating the required `OMOP_Dev` folder structure
- Generating `.env` with SQL Server password
- Starting the SQL Server container
- Creating the `omop_synth` database
- Guiding you through Athena vocabulary download

If your machine already has `.env`, `docker-compose.yml`, `OMOP_Dev/omop_vocab/CONCEPT.csv`, and a healthy `mssql_dev` container, skip this step.

Only after that should you open in the dev container (VS Code → **Reopen in Container**, or
`Cmd+Shift+P` → `Dev Containers: Reopen in Container`).

---

### 3 — Complete the study setup checklist

Run the pre-flight check to see everything that still needs your input:

```bash
Rscript scripts/check_setup.R
```

Then work through your study configuration in `study_params.yaml`:

| Setting | What to fill in |
|---------|----------------|
| `study_name` | Match the repo naming convention: `<disease_cohort_abbrev>_<treatment_abbrev>_<outcome_abbrev>_<methodology_abbrev>` |
| `study_design` | `cohort_characterization` \| `prognostic_model` \| `causal_inference` \| `descriptive` |
| `cdm_schema` | CDM schema populated by Step 5 ETL |
| `results_schema` | Schema for cohort table and analysis outputs |
| `cohort_table` | Cohort table name |
| `target.index_event.ancestor_concept_ids` | Index event concept IDs — look these up first! |
| `outcome.ancestor_concept_ids` | Outcome concept IDs — look these up first! |
| `prediction_window_days` | Follow-up window for outcome (days) |
| `study_start_date` / `study_end_date` | Date range for index event inclusion |
| `output_folder` | Where outputs are written (e.g. `output/my_study`) |
| `analyses.*` | Set `true` for each analysis to run |

For every concept ID, look it up before writing it:

```bash
Rscript scripts/concept_lookup.R "<clinical term>" [domain]
# Example: Rscript scripts/concept_lookup.R "total hip replacement" Procedure
```

#### Cohort SQL files

Edit the template SQL files in `cohorts/` to match your study phenotype:

- `cohorts/target_surgery.sql` — index event (exposure / target cohort)
- `cohorts/outcome_ssi.sql` — outcome cohort
- `cohorts/comparator_cohort.sql` — comparator cohort (causal inference only)

Replace every `concept_id = 0` placeholder with a verified concept ID.
Rename the files to match your study and update the `sql_file:` paths in `study_params.yaml`.

#### Covariate files

- `covariates/covariates.csv` — replace placeholder rows with your study covariates
- `covariates/covariate_concepts.csv` — map each covariate to verified OMOP concept IDs

---

### 4 — Run Step 2 to validate your artifacts

```bash
Rscript workflow/02_define_omop_cohort_outcome_covariates.R
```

Step 2 validates that all phenotype files exist, are non-empty, have the correct
columns, and contain no `concept_id = 0` placeholders. Fix any warnings before
proceeding.

---

### 5 — Run the full workflow

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

### 6 — Commit your study definition

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

## AI Assistant Integration

This repo ships coding convention files that work with any AI coding assistant
(GitHub Copilot, Claude Code, or others):

1. **Concept ID transparency** — every concept ID recommendation must be tagged `[vocab query]`
   (confirmed against live vocabulary) or `[pretraining]` (unverified, with explicit warning).
2. **HADES-first package selection** — use OHDSI HADES packages for all OHDSI methodology;
   fall back to tidyverse; all packages must be on the project CRAN mirror.
3. **Verbose comments** — all code follows OHDSI GitHub repository commenting conventions.

| File | Scope | Purpose |
|------|-------|---------|
| `CLAUDE.md` | Every session | Core coding conventions (concept IDs, packages, comments, architecture) |
| `.github/copilot-instructions.md` | GitHub Copilot | Points all assistants to `CLAUDE.md` |
| `.github/instructions/r-packages.instructions.md` | `*.R` files | HADES priority, CRAN mirror, renv workflow |
| `.github/instructions/omop-ohdsi.instructions.md` | `*.R` and `*.sql` | DatabaseConnector/SqlRender patterns, concept ID lookup, OMOP CDM conventions |

**Concept Lookup (terminal):**

```bash
Rscript scripts/concept_lookup.R "peripheral arterial disease" Condition
Rscript scripts/concept_lookup.R "cefazolin" Drug
Rscript scripts/concept_lookup.R "ankle brachial index" Measurement
```

Queries the live OMOP vocabulary in the connected SQL Server and returns ranked
candidate concepts with recommendation. Use this before writing any concept ID into
code or CSV files.

---

## Documentation

| Resource | Purpose | Audience |
|----------|---------|----------|
| **[docs/GETTING_STARTED.md](docs/GETTING_STARTED.md)** | 13-step end-to-end workflow from VS Code download to transportable code packet | New users, first time setup |
| **[docs/SETUP.md](docs/SETUP.md)** | Detailed Docker, SQL Server, Athena vocabulary, and dev container setup | Docker/infrastructure details |
| **[CHECKLIST.md](CHECKLIST.md)** | Quick visual reference for workflow phases and key commands | Quick reference during work |
| **[CLAUDE.md](CLAUDE.md)** | Coding conventions, package rules, comment style, architecture | Developers, AI assistants |
| **[setup/setup_docker_and_vocab.sh](setup/setup_docker_and_vocab.sh)** | Automated Docker + vocabulary setup (macOS/Linux) | Automation-first users |
| **[setup/setup_docker_and_vocab.ps1](setup/setup_docker_and_vocab.ps1)** | Automated Docker + vocabulary setup (Windows PowerShell) | Windows users |
| **[Book of OHDSI](https://ohdsi.github.io/TheBookOfOhdsi/)** | OHDSI methodology reference (cohorts, phenotypes, causal inference) | OHDSI methods questions |
| **[OHDSI Forums](https://forums.ohdsi.org)** | Community Q&A and discussion | Troubleshooting, best practices |

---

## Quick Links

**New to this template?**
→ Start with [docs/GETTING_STARTED.md](docs/GETTING_STARTED.md)

**Docker/environment setup help?**
→ From `OMOP_Dev/`, run `bash <your-study>/setup/setup_docker_and_vocab.sh` (or the PowerShell equivalent on Windows)
→ Or see [docs/SETUP.md](docs/SETUP.md) for manual steps

**Need a quick reference?**
→ See [CHECKLIST.md](CHECKLIST.md)

**Coding conventions?**
→ Read [CLAUDE.md](CLAUDE.md)

**OHDSI methodology questions?**
→ Check [Book of OHDSI](https://ohdsi.github.io/TheBookOfOhdsi/) or [OHDSI Forums](https://forums.ohdsi.org)

---

## Notes

- `drivers/mssql-jdbc-13.2.1.zip` is tracked so JDBC setup is reproducible offline.
- `renv/library/` is intentionally not committed (restored from `renv.lock` on first run).
- `output/` is gitignored — commit outputs separately if needed for reproducibility.
