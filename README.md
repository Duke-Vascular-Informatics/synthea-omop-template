# PAD / OLER – Surgical Site Infection (SSI) External Validation

External validation of a previously developed surgical site infection prediction
model using the [OHDSI PatientLevelPrediction (PLP)](https://ohdsi.github.io/PatientLevelPrediction/)
framework on a Synthea-generated OMOP CDM v5.4 SQL Server database.

---

## Background

This project validates a patient-level prediction model for **30-day surgical
site infection** that was developed in a prior study (PAD / OLER).  External
validation on a new database quantifies how well the model generalises beyond
its training population and supports the OHDSI FAIR-data principles for
reproducible, network-level research.

The validation database is constructed by the companion project
[`synthea-omop-etl`](../synthea-omop-etl), which maps synthetic Synthea 3.3.0
patient records into OMOP CDM 5.4 on a local SQL Server instance.

---

## Prerequisites

| Dependency | Version | Notes |
|---|---|---|
| R | ≥ 4.5.2 | `C:\Program Files\R\R-4.5.2` |
| Java (JDK) | 17 (Eclipse Adoptium) | Required by DatabaseConnector / JDBC |
| SQL Server | 2019+ | `localhost:1434`, database `omop_synth` |
| `synthea-omop-etl` | — | Must have been run first to populate `cdm_synthea` |
| Pre-trained PLP model | PLP v6 `plpResult` folder | See [Configuration](#configuration) |

The MSSQL JDBC driver (mssql-jdbc 13.2.1) is downloaded automatically into
the project-local `drivers/` folder the first time `install_packages.R` (or
`run_validation.R`) is run.  No companion project or manual driver installation
is required.

---

## Project Structure

```
pad-oler-ssi-val/
│
├── run_validation.R          # ★ Single entry point – run this to execute
│                             #   the full pipeline end-to-end
│
├── config.R                  # Central configuration (DB connection, schema
│                             #   names, cohort IDs, model path, output path)
│
├── install_packages.R        # One-time package installer (PLP v6, OHDSI
│                             #   packages, CRAN dependencies)
├── setup_renv.R              # One-time renv initialisation
├── renv.lock                 # Reproducible package snapshot
├── .Rprofile                 # Activates renv + sets CRAN mirror
├── .gitignore
│
├── cohorts/
│   ├── target_surgery.sql    # OHDSI SQL: inpatient surgical patients
│   │                         #   (age ≥ 18, 365-day prior-SSI washout)
│   └── outcome_ssi.sql       # OHDSI SQL: wound / SSI diagnosis concepts
│                             #   (SNOMED ancestor hierarchy)
│
├── R/
    ├── connection.R          # Builds DatabaseConnector connection details
    │                         #   using Windows Integrated Security / JDBC;
    │                         #   triggers driver provisioning if needed
    ├── drivers.R             # Downloads mssql-jdbc-13.2.1.zip from Microsoft
    │                         #   and stages jar + auth DLL into drivers/
    │                         #   (no-op on subsequent runs)
    ├── cohorts.R             # Creates results schema + cohort table,
    │                         #   instantiates both cohorts, logs row counts
    └── validation.R          # Loads plpResult, builds PLP settings objects,
                              #   calls externalValidateDbPlp(), prints summary
```

Output is written to `output/ssi_validation/` (git-ignored).

The `drivers/` folder is populated automatically on first run:

```
drivers/
├── mssql-jdbc-13.2.1.zip          # downloaded from go.microsoft.com
├── sqljdbc_13.2/enu/              # extracted bundle (git-ignored)
│   ├── jars/mssql-jdbc-13.2.1.jre11.jar
│   └── auth/x64/mssql-jdbc_auth-13.2.1.x64.dll
└── jdbc-runtime/                  # staged jar used by DatabaseConnector
    └── mssql-jdbc-13.2.1.jre11.jar
```

Only the zip is tracked in git; extracted files and runtime jars are
git-ignored.

---

## Configuration

All settings are centralised in [`config.R`](config.R).  The two values most
likely to need adjustment before a first run are:

```r
# Path to the plpResult folder from the original SSI development study.
# Must contain a model sub-directory with model.rds (PLP v6 layout).
model_path = file.path("..", "ssi-model", "plpResult")

# Study date window – should match the training study to enable temporal
# drift analysis.
study_start_date = "2010-01-01"
study_end_date   = "2023-12-31"
```

Database connection parameters (`server`, `database`, `sql_server_port`,
`cdm_schema`, `results_schema`) can also be changed there without touching
any other file.

---

## Cohort Definitions

### Target cohort – Inpatient surgical patients (`cohort_definition_id = 1`)

- **Index date**: first inpatient (`visit_concept_id` 9201 or 262) visit start
  date within the study window
- **Inclusion**: age ≥ 18 at index; ≥ 1 procedure record during the visit
- **Exclusion**: any wound / SSI diagnosis (SNOMED ancestors 4201004, 4318887)
  in the 365 days before index (prior-event washout)

### Outcome cohort – Surgical site infection (`cohort_definition_id = 2`)

- **Index date**: first SSI/wound-infection condition occurrence per person
- **Concepts**: descendants of SNOMED ancestors:
  - `4201004` – Infection of wound
  - `4318887` – Surgical wound infection
  - `40480632` – Infected wound
  - `4110523` – Complication of procedure (catches ICD-10 T81.4 mappings)

> **Tip**: Verify concept coverage in your database before running:
> ```sql
> SELECT c.concept_id, c.concept_name, c.vocabulary_id
> FROM   cdm_synthea.concept c
> JOIN   cdm_synthea.concept_ancestor ca
>   ON   ca.descendant_concept_id = c.concept_id
> WHERE  ca.ancestor_concept_id IN (4201004, 4318887, 40480632, 4110523)
>   AND  c.standard_concept = 'S';
> ```

---

## Running the Pipeline

### 1. One-time setup (run once per machine / R version upgrade)

Open a **fresh R session** in the project root:

```r
setwd("C:/Users/rapiduser/pad-oler-ssi-val")
source("setup_renv.R")        # initialises renv
source("install_packages.R")  # installs PLP v6, all dependencies,
                               # AND downloads the JDBC driver bundle
```

`install_packages.R` will download `mssql-jdbc-13.2.1.zip` from
`go.microsoft.com` into `drivers/` on first run (~8 MB).  Subsequent calls
skip the download if the file already exists.

### 2. Execute the validation

Open a **new fresh R session** (avoids Java class-loader conflicts):

```r
setwd("C:/Users/rapiduser/pad-oler-ssi-val")
source("run_validation.R")
```

The pipeline will:

| Step | Action |
|------|--------|
| 1 | Load configuration from `config.R` |
| 2 | Build JDBC connection details and verify connectivity |
| 3 | Create `plp_results` schema and `ssi_val_cohort` table; instantiate both cohorts |
| 4 | Load the pre-trained PLP model and call `externalValidateDbPlp()` |
| 5 | Print AUROC / AUPRC / Brier score summary; launch PLP Shiny viewer |

Results are written to `output/ssi_validation/`.

### 3. Browse results

The Shiny viewer launches automatically at the end of Step 5.  To reopen it
later without re-running the pipeline:

```r
setwd("C:/Users/rapiduser/pad-oler-ssi-val")
source("renv/activate.R")
library(PatientLevelPrediction)
result <- PatientLevelPrediction::loadPlpResult("output/ssi_validation/<db_id>")
PatientLevelPrediction::viewPlp(result)
```

---

## Recalibration

Two recalibration strategies are applied automatically during validation to
account for potential covariate / outcome prevalence shift between the training
database and this Synthea population:

- **Weak recalibration** – adjusts the intercept and slope of the calibration
  curve.
- **Recalibration-in-the-large** – shifts the overall predicted probability to
  match the observed outcome rate in the validation database.

Both recalibrated and uncalibrated metrics are reported.

---

## Related Projects

| Project | Purpose |
|---------|---------|
| [`synthea-omop-etl`](../synthea-omop-etl) | Populates the `omop_synth` / `cdm_synthea` OMOP database used here |
| `ssi-model` | Original SSI PLP development study (produces the `plpResult` loaded by this project) |
> **Note**: this project is self-contained with respect to database drivers.
> The only external dependency at runtime is the `omop_synth` SQL Server
> database (populated by `synthea-omop-etl`) and the pre-trained `plpResult`
> model folder.