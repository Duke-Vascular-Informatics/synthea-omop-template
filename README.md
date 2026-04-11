# PAD / OLER - Surgical Site Infection (SSI) External Validation

External validation of a pre-trained SSI prediction model using OHDSI PatientLevelPrediction,
run on a Synthea-generated OMOP CDM v5.4 SQL Server database. The workflow is intentionally
self-contained and offline-capable.

## Prerequisites

- R 4.5.2+
- Java 17 (Eclipse Adoptium)
- SQL Server instance with OMOP CDM loaded (`localhost:1434`, database `omop_synth`)
- A pre-trained PLP result folder from the original SSI development study
- Synthea (for steps 3–5 only)

CRAN packages are installed from `https://archive.linux.duke.edu/cran/`.

---

## Dev Container Setup (Recommended)

The repo ships a `.devcontainer/` folder that gives you a fully configured Linux R + Java 17 environment inside Docker via VS Code. No local R or Java installation is needed.

### Required folder layout on disk

Clone this repo into an `OMOP_Dev/` parent folder alongside the MSSQL container and vocabulary:

```
OMOP_Dev/
  .env                    ← SA password (never commit)
  docker-compose.yml      ← MSSQL container definition (provided in this repo's parent)
  omop_vocab/             ← Athena vocabulary download (never commit, see below)
  pad-oler-ssi-val/       ← this repo
    .devcontainer/
```

### Step 1 — Install Docker Desktop and start the MSSQL container

1. Download and install **Docker Desktop**: https://www.docker.com/products/docker-desktop/
2. Create the `OMOP_Dev/` folder and clone this repo into it:
   ```bash
   mkdir OMOP_Dev && cd OMOP_Dev
   git clone https://github.com/adam-mdmph/pad-oler-ssi-val.git
   ```
3. Create `OMOP_Dev/.env` with your SQL Server SA password (min 8 chars, upper + lower + digit + symbol):
   ```bash
   echo "MSSQL_SA_PASSWORD=YourStrong@Passw0rd" > .env
   ```
4. Copy the `docker-compose.yml` from `pad-oler-ssi-val/` to `OMOP_Dev/` — it defines the Azure SQL Edge container and shared Docker network.
5. Start the MSSQL container:
   ```bash
   docker compose up -d
   ```
6. Create the project database (first time only):
   ```bash
   docker exec mssql_dev bash -c '/opt/mssql-tools18/bin/sqlcmd -S localhost -U SA -P "YourStrong@Passw0rd" -C -Q "CREATE DATABASE omop_synth;"'
   ```

### Step 2 — Download the OMOP Vocabulary from Athena

The OMOP vocabulary is required for ETL but is **not included in this repo** due to licensing restrictions.

1. Go to https://athena.ohdsi.org and create a free account.
2. Click **Download** and select at minimum: `SNOMED`, `LOINC`, `RxNorm`, `ICD10CM`, `CPT4`.
3. Download and extract the zip to `OMOP_Dev/omop_vocab/`.

   Required files:
   ```
   CONCEPT.csv           CONCEPT_ANCESTOR.csv   CONCEPT_CLASS.csv
   CONCEPT_RELATIONSHIP.csv  CONCEPT_SYNONYM.csv   DOMAIN.csv
   DRUG_STRENGTH.csv     RELATIONSHIP.csv        VOCABULARY.csv
   ```

4. **CPT-4 rebuild (required):** CPT-4 codes are excluded from the Athena download due to AMA licensing. Rebuild them using the script bundled in the vocab folder:
   - macOS/Linux: `bash omop_vocab/cpt.sh`
   - Windows: `omop_vocab\cpt.bat`

   This requires a free **UMLS API key**: https://uts.nlm.nih.gov — register, then retrieve your key from your profile page.

### Step 3 — Install VS Code and the Dev Containers extension

1. Install **VS Code**: https://code.visualstudio.com
2. Open VS Code → Extensions (`Cmd+Shift+X`) → search **Dev Containers** → install **Dev Containers** by Microsoft (`ms-vscode-remote.remote-containers`).

### Step 4 — Open the dev container

1. In VS Code open the `pad-oler-ssi-val/` folder (`File → Open Folder`).
2. When prompted click **Reopen in Container** — or use `Cmd+Shift+P` → `Dev Containers: Reopen in Container`.
3. The first build takes ~5 minutes (downloads R base image, installs Java 17, builds renv cache). Subsequent opens are instant.

### Step 5 — One-time environment and vocabulary setup

Open the VS Code terminal (`` Ctrl+` ``) inside the container and run:

```bash
# Install R packages and verify DB connectivity (~5-10 min, cached after first run)
Rscript workflow/01_setup_synthea_etl_qc_env.R

# Load OMOP vocabulary into shared omop_vocab schema (~30-60 min, once per SQL Server instance)
Rscript scripts/setup_omop_vocab_schema.R
```

After these complete you are ready to run the full workflow (`Steps 1–9`).

---

## Repository Structure

```text
pad-oler-ssi-val/
  config.R                                ← single source of truth for all settings
  workflow/                               ← numbered step scripts (canonical path)
  R/                                      ← reusable R functions
  setup/                                  ← renv + package install helpers
  scripts/                                ← utilities, ETL, Synthea runner
  cohorts/                                ← SQL cohort definitions
  risk_score/                             ← CSV spec files for integer risk score
  synthea/modules/                        ← PAD/SSI Synthea GMF module + diagram
  portable/risk_score_validation_bundle/  ← shareable bundle for external sites
  internal_repo/bin/windows/contrib/4.5/  ← prebuilt OHDSI package binaries
  drivers/                                ← JDBC driver archive
  .github/                                ← Copilot customization files
  output/                                 ← analysis outputs (gitignored)
```

## Package Strategy

### CRAN packages

Installed directly from the Duke CRAN mirror.

### GitHub packages (prebuilt internally)

The following GitHub packages are pinned and supported through prebuilt local binaries:

| Package | Version |
|---------|---------|
| `OHDSI/FeatureExtraction` | v3.6.0 |
| `OHDSI/CohortGenerator` | v0.9.0 |
| `OHDSI/PatientLevelPrediction` | v6.4.0 |

`setup/install_packages.R` installs from CRAN first (Duke mirror), then falls back to
GitHub for OHDSI packages that are not available on CRAN.

## Step 1 — Setup Environment

`workflow/01_setup_synthea_etl_qc_env.R`

Installs packages and initializes the environment for Synthea generation, ETL, and data quality
checks. Run this once in a fresh R session before any other step.

```powershell
Rscript workflow/01_setup_synthea_etl_qc_env.R
```

Equivalent direct setup (from an R session):

```r
setwd("C:/Users/rapiduser/pad-oler-ssi-val")
source("setup/setup_renv.R")
source("setup/install_packages.R")
```

This step:
- Activates `renv`
- Installs CRAN dependencies from the Duke mirror
- Installs GitHub-pinned OHDSI packages when unavailable on CRAN
- Provisions the JDBC driver bundle to `drivers/`
- Runs database connectivity preflight checks

Root-level `setup_renv.R` and `install_packages.R` remain as compatibility wrappers.

---

## Step 2 — Define OMOP Cohorts, Outcome, and Covariates

`workflow/02_define_omop_cohort_outcome_covariates.R`

Validates SQL cohort and outcome definitions and OMOP concept-based covariate artifact files.

> **Vocabulary note:** Cohort SQL files (`cohorts/target_surgery.sql`,
> `cohorts/outcome_ssi.sql`) use ancestor concept IDs verified against the
> OMOP vocabulary loaded in `omop_vocab`. Key ancestors:
>
> | Ancestor concept_id | Concept name | SNOMED-CT | Role |
> |---|---|---|---|
> | 4159960 | Procedure on blood vessel of lower extremity | 397441004 | Target cohort procedure inclusion |
> | 4334801 | Surgical site infection | 433202001 | Outcome inclusion; target cohort washout exclusion |
>
> Previously documented ancestor IDs 4201004, 4318887, 40480632, and 4110523
> do not exist or map to unrelated concepts in the current vocabulary version
> and have been removed.

```powershell
Rscript workflow/02_define_omop_cohort_outcome_covariates.R
```

### ATLAS Cohorts

This project is configured to use pre-built cohorts from ATLAS/WebAPI.

- Target cohort ID: `1796269`
- Outcome cohort ID: `1796278`

Default mapping in `config.R`:

```r
use_atlas_cohorts       = TRUE
atlas_cohort_schema     = "results"
atlas_cohort_table      = "cohort"
atlas_target_cohort_id  = 1796269L
atlas_outcome_cohort_id = 1796278L

# Destination IDs used by PLP
target_cohort_id  = 1L
outcome_cohort_id = 2L
```

At runtime, Step 2 copies ATLAS cohort `1796269` into the project cohort table as target ID `1`
and cohort `1796278` as outcome ID `2`. Date filtering is applied using `study_start_date` and
`study_end_date` from `config.R`. If your ATLAS cohort table lives in a different schema or
table, update `atlas_cohort_schema`/`atlas_cohort_table` in `config.R`.

---

## Step 3 — Generate Synthea Module Artifacts

`workflow/03_generate_synthea_module_artifacts.R`

Validates the PAD/SSI Synthea Generic Module Framework (GMF) module JSON against the 16
required OMOP concept codes and regenerates the HTML state-diagram for SME review.

```powershell
Rscript workflow/03_generate_synthea_module_artifacts.R
```

This step:
- Checks that all 16 required cohort/covariate concepts are present in the module JSON
  (warns on missing codes; does not block diagram generation)
- Re-runs `scripts/synthea/generate_synthea_mermaid.R` to produce the interactive HTML
  diagram at `synthea/modules/pad_ssi.diagram.html`

### Synthea Module Overview

`synthea/modules/pad_ssi.json` models PAD patients who undergo open lower extremity
revascularization and may develop a surgical site infection — matching the target/outcome
cohort logic of this study.

Key clinical parameters:

| Parameter | Value |
|-----------|-------|
| PAD pathway assignment | 100% of generated patients age 40+ |
| SSI — baseline | 6% |
| SSI — with Type 2 diabetes | 12% |
| SSI — with obesity (BMI ≥ 30) | 10% |
| SSI requiring rehospitalization | 15% of SSIs |
| Hospital stay | 3–7 days |
| SSI onset window | 5–83 days post-discharge (extended from 5–25 for 90-day attribution window) |

> **`urgnt` ETL fix (2026-04):** The `Urgent_Case` module state was previously
> typed as `"Observation"`, which routes it to `synthea.observations`.  The ETL
> only maps LOINC codes from that table, causing SNOMED `73994005` (Emergency
> operation → OMOP 4158569) to be silently dropped.  The state has been renamed
> to `Urgent_Case_Procedure` and retyped as `"Procedure"`, which routes it to
> `synthea.procedures` and is correctly mapped to `procedure_occurrence` by the
> ETL.  **Re-run Steps 4 and 5** after applying the updated module to regenerate
> synthetic data with urgnt cases correctly captured.
>
> **90-day SSI onset window (2026-04):** `Post_Discharge_Delay` range was updated
> to `low: 5, high: 83` days to support the extended 90-day outcome window.
> The overall onset envelope (discharge + hospital stay) is therefore 8–90 days
> from the index procedure date.

Primary concept codes (OMOP-mappable):

| Concept | Vocabulary | Code | OMOP concept_id |
|---------|-----------|------|----------------|
| Peripheral arterial disease | SNOMED-CT | 399957001 | 317309 |
| Femoro-popliteal bypass | SNOMED-CT | 112828007 | 4012936 |
| Femoro-tibial bypass | SNOMED-CT | 16589005 | 4166196 |
| Aortobifemoral bypass | SNOMED-CT | 405482000 | 4231680 |
| Femoral endarterectomy | SNOMED-CT | 47575002 | 4040974 |
| **Surgical site infection** | SNOMED-CT | **433202001** | **4334801** |
| Debridement (reoperation) | SNOMED-CT | 118294005 | — |
| Ankle-brachial index | LOINC | 59574-4 | — |
| Wound culture | LOINC | 6463-4 | — |
| Cefazolin (perioperative prophylaxis) | RxNorm | 20496 | — |
| Cephalexin (SSI treatment) | RxNorm | 2673 | — |

> **SSI concept change (2026-04):** The module previously used SNOMED-CT `76844004`
> ("Local infection of wound" → OMOP 4297984), which is not a descendant of any
> standard SSI ancestor in the current OMOP vocabulary. It has been updated to
> `433202001` ("Surgical site infection" → OMOP 4334801), which is the correct
> hierarchical ancestor used by `outcome_ssi.sql` and `target_surgery.sql`.
> Re-run Steps 4 and 5 after this change.

### Visualize the Module

Open `synthea/modules/pad_ssi.diagram.html` in any browser to view the interactive
state-diagram with state types and SNOMED/LOINC/RxNorm codes on each node.

Regenerate after editing the module JSON:

```powershell
& "C:/Program Files/R/R-4.5.2/bin/Rscript.exe" scripts/synthea/generate_synthea_mermaid.R synthea/modules/pad_ssi.json synthea/modules/pad_ssi.diagram.html
```

---

## Step 4 — Generate Synthea CSV

`workflow/04_generate_synthea_csv.ps1`

Generates Synthea synthetic patients in CSV format using the PAD/SSI module.

```powershell
powershell -ExecutionPolicy Bypass -File workflow/04_generate_synthea_csv.ps1 `
  -SyntheaHome "C:\path\to\synthea" -Population 1000
```

Parameters:

| Parameter | Default | Description |
|-----------|---------|-------------|
| `-SyntheaHome` | _(required)_ | Path to Synthea installation |
| `-Population` | `1000` | Number of patients to generate |
| `-AgeRange` | `40-85` | Age range for generated patients |
| `-State` | `Massachusetts` | State for patient demographics |

This calls `scripts/synthea/run_synthea_pad_ssi.ps1`, which:
- Copies `synthea/modules/pad_ssi.json` into the Synthea modules folder
- Runs Synthea with CSV export enabled (`--exporter.csv.export=true`)
- Prints the CSV output folder path

**Run batches of 1000 patients** at a time; re-run Step 5 after each batch to load
CSV output incrementally into the OMOP CDM.

---

## Step 5 — ETL CSV to OMOP

`workflow/05_etl_csv_to_omop.R`

ETLs Synthea CSV output into the OMOP CDM.

Prerequisite: OMOP vocabularies must already be loaded in `cdm_synthea`
(`concept`, `concept_relationship`, `concept_ancestor`) by the separate
`vocab_omop_etl` process. Step 5 now validates vocabulary readiness and exits
with an error if this prerequisite is not met.

```powershell
# Basic (uses csv_input_dir and run_name from config.R or prompts)
Rscript workflow/05_etl_csv_to_omop.R

# With explicit CSV path and run name
Rscript workflow/05_etl_csv_to_omop.R "C:/path/to/synthea/output/csv" "padssi-csv-20260324-120000"

# Named args; reset OMOP staging tables before ETL
Rscript workflow/05_etl_csv_to_omop.R `
  --csv_input_dir=C:/path/to/synthea/output/csv `
  --run_name=padssi-csv-20260324-120000 `
  --reset_before_etl=true
```

Parameters:

| Arg | Description |
|-----|-------------|
| `arg1` / `--csv_input_dir` | Path to Synthea CSV output folder |
| `arg2` / `--run_name` | Label for this ETL run (used in audit fields) |
| `--reset_before_etl` | `true` clears OMOP staging tables before loading |

Deprecated (ignored): `--force_reload_vocab`, `--vocab_file_loc`

---

## Step 6 — Quality Check Defined Phenotypes

`workflow/06_quality_check_defined_phenotypes.R`

Runs data quality checks aligned to the defined cohort/outcome/covariate framework.

```powershell
# Basic
Rscript workflow/06_quality_check_defined_phenotypes.R

# With thresholds enforced
Rscript workflow/06_quality_check_defined_phenotypes.R `
  --run_name=padssi-csv-20260324-120000 `
  --enforce_thresholds=true `
  --min_person_rows=100 `
  --min_open_revascularization_rows=50 `
  --min_ssi_condition_rows=5 `
  --min_mapped_condition_pct=50
```

Parameters accepted by `scripts/quality_check_etl.R` (passed through):

| Arg | Description |
|-----|-------------|
| `--run_name` | ETL run label to filter quality results |
| `--enforce_thresholds` | If `true`, fails the step on threshold violations |
| `--min_person_rows` | Minimum required person count |
| `--min_open_revascularization_rows` | Minimum procedure rows |
| `--min_ssi_condition_rows` | Minimum SSI condition rows |
| `--min_mapped_condition_pct` | Minimum condition code mapping % |

---

## Step 7 — Setup Analysis Environment

`workflow/07_setup_analysis_env.R`

Installs and verifies packages and environment required for integer risk score external
validation analysis.

```powershell
Rscript workflow/07_setup_analysis_env.R
```

---

## Step 8 — Run Analysis and Manuscript Report

`workflow/08_run_analysis_and_manuscript_report.R`

Runs the integer risk score analysis and generates a manuscript-format Word report.

```powershell
Rscript workflow/08_run_analysis_and_manuscript_report.R
```

This step:
1. Loads project configuration and connections
2. Resolves the most-recently-populated CDM schema automatically
3. Verifies all hardcoded OMOP concept IDs against `omop_vocab.concept`
4. Builds target (inpatient open lower-extremity revascularisation) and outcome
   (90-day SSI) cohorts
5. Runs integer risk score analysis with 95% bootstrap percentile CIs (B = 500)
6. Writes score outputs to `output/risk_score_eval/`
7. Generates the manuscript-style report as a Word document (`.docx`)
8. Exports a dated fringe-cases Excel workbook (`.xlsx`) for clinical QC review

> **90-day SSI window (2026-04):** The outcome attribution window was extended
> from 30 days to 90 days post-procedure.  This change is controlled by
> `prediction_window_days = 90L` in `config.R` and requires that Steps 4 and 5
> have been re-run with the updated `pad_ssi.json` Synthea module (which extends
> the `Post_Discharge_Delay` upper bound from 25 to 83 days post-discharge).

### Integer Risk Score Pipeline

Configuration files:

- `risk_score/components.csv` — score component definitions, lookback window, minimum event count, and points
- `risk_score/component_concepts.csv` — maps each component to OMOP standard concept IDs and descendant expansion
- `risk_score/risk_lookup.csv` — optional score-to-risk lookup table from the original publication

> **`indicationClaudication` lookback fix (2026-04):** `lookback_end_day` was
> corrected from `-1` to `0` so that claudication diagnoses recorded on the day
> of surgery (the index date) are captured.  This aligns Table 1 and Table 2
> prevalence counts.

All components are fully mapped:

| Component | Concept(s) | Notes |
|---|---|---|
| `female` | 8532 | Biological sex = Female |
| `overweight` | 3025315 (weight), 3036277 (height) | BMI 25–30 derived from measurements |
| `obese` | 3025315 (weight), 3036277 (height) | BMI ≥ 30 derived from measurements |
| `urgnt` | 4158569, 4250892 + descendants | Emergency or urgent procedure flag — **requires Synthea re-run** after the `Urgent_Case_Procedure` state-type fix in `pad_ssi.json` (see Synthea module note below) |
| `abi_35` | 40489833, 46237026 + descendants | Ankle-brachial index measurement < 0.35 |
| `prrevasc_any` | 4159960 + descendants | Prior lower-extremity vascular procedure |
| `prolong_abx` | 21603553 + descendants | Non-prophylactic antibiotic (start ≤ index − 1 day, duration > 2 days) |
| `optime4h` | 4159960 + descendants ⚠️ **datetime-derived** | Operative time ≥ 240 min computed as `DATEDIFF(MINUTE, procedure_datetime, procedure_end_datetime) >= 240` on any revascularization procedure descended from 4159960. Simple concept presence lookup is insufficient; scoring pipeline must use the datetime diff. Synthea generates sub-day timestamps via the module `duration` field (fem-pop 2–5h, endarterectomy 1–3h, aorto-fem 2–4h, fem-tibial 2–5h); valid synthetic signal is available after re-running Steps 4 and 5. |
| `mFI_high` | 201820, 255573, 316139, 316866 + functional status OR set | Composite modified Frailty Index ≥ 2/5: diabetes, COPD, CHF, hypertension, functional status. Functional status is satisfied if **any** of the following [vocab query] concept sets is documented: 4086506 Frailty + descendants, 4159704 Functional independence measure (no descendants), 4167605 Barthel index + descendants, 4306934 Impaired mobility + descendants. |
| `indicationClaudication` | 442774 + descendants | Intermittent claudication as surgical indication |

Output files (written to `output/risk_score_eval/`):

| File | Description |
|------|-------------|
| `person_level_scores.csv` | Per-person component points, total score, predicted probabilities, and binary outcome |
| `component_summary.csv` | Component-level aggregate summary (n_positive, mean_points) |
| `metrics.csv` | AUROC, AUPRC, Brier, ECE, CalibrationIntercept, CalibrationSlope for three model specs; includes `ci_lower` and `ci_upper` columns (95% bootstrap percentile CIs, B = 500) |
| `calibration_table_lookup.csv` | Calibration by lookup probability (if lookup populated) |
| `calibration_table_recalibrated.csv` | Calibration by logistic-mapped score |
| `calibration_lookup.png` | Calibration plot (if lookup populated) |
| `calibration_recalibrated.png` | Calibration plot (recalibrated) |
| `pad-oler-ssi-val_report_<date>.docx` | Manuscript-format Word report |
| `pad_oler_ssi_fringe_<date>.xlsx` | Fringe-cases Excel: 10 lowest-risk patients with SSI + 10 highest-risk patients without SSI (two sheets) |

### Missing Value Handling

When a component has no matching records in the OMOP CDM, the event count is set to 0 and
the component contributes 0 points. The total score is still computed. This treats missing
data as "no documented evidence" of the risk factor — appropriate when CDM completeness is
high and absent data should be interpreted conservatively.

See `person_level_scores.csv` (`score_<component_id>` columns) to review which components
had evidence per person.

---

## Step 9 — Build Portable PRCC Analysis Bundle

Packages the analysis into a self-contained bundle for external validation on the Duke PRCC
(Research Computing Cluster) against an institutional OMOP CDM v5.4 SQL Server database.

**Bundle location:** `portable/prcc_bundle/`
**Distributable zip:** `dist/pad_oler_ssi_val_prcc_<date>.zip`

The bundle includes all required R scripts, SQL cohort definitions, JDBC driver, and a
step-by-step `README.md` runbook. Authentication uses Kerberos (Duke NetID) — no passwords
are stored in any file. Java is provided by `conda-forge::openjdk` via the PRCC miniforge
module; no system-level Java installation is needed.

**All packages are available on CRAN** (no GitHub-only dependencies):
`DatabaseConnector`, `SqlRender`, `dplyr`, `ggplot2`, `pROC`, `PRROC`, `readr`,
`officer`, `flextable`, `writexl`.

To deploy, transfer `pad_oler_ssi_val_prcc_<date>.zip` to PRCC, unzip, and follow the
runbook in `portable/prcc_bundle/README.md`. In brief:

```bash
bash setup_prcc_env.sh     # one-time: conda Java env + kinit + R packages
# edit config.R            # fill in server, database, schema names
conda activate openjdk
Rscript run_analysis.R
```

Output is written to `output/risk_score_eval/` inside the bundle directory.

---

## GitHub Copilot Customizations

This repository ships Copilot instruction and prompt files so AI-assisted coding automatically
follows project conventions — no need to repeat constraints in chat.

### Always-on Instructions

| File | Scope | Purpose |
|------|-------|---------|
| `.github/copilot-instructions.md` | Every chat request | Language (R only), CRAN mirror, offline packages, DB config, security rules |
| `.github/instructions/r-packages.instructions.md` | `*.R` files | CRAN mirror enforcement, `renv` workflow, local binary installs for OHDSI packages |
| `.github/instructions/omop-ohdsi.instructions.md` | `*.R` and `*.sql` files | `DatabaseConnector`/`SqlRender` patterns, OMOP CDM table reference, cohort conventions, PLP validation-only guard, concept lookup requirement |

The `.instructions.md` files are auto-attached by VS Code Copilot when a matching file
is open or referenced, and discoverable on-demand from their `description` fields.

### Slash Commands (Prompts)

| Command | File | Purpose |
|---------|------|---------|
| `/concept-lookup` | `.github/prompts/concept-lookup.prompt.md` | Live OMOP vocabulary lookup against `cdm_synthea.concept` via the MSSQL MCP tools |

**`/concept-lookup` usage:**

Type `/concept-lookup` in chat before writing any concept ID into code or CSV files:

```
/concept-lookup peripheral arterial disease condition
/concept-lookup cefazolin drug
/concept-lookup ankle brachial index measurement
/concept-lookup femoral popliteal bypass procedure
```

The prompt connects to `omop_synth`, queries `cdm_synthea.concept` for standard concepts
(`standard_concept = 'S'`), and falls back to `concept_synonym` if fewer than 3 direct
matches are found. It returns a ranked table and a single recommended `concept_id`.
This ensures concept IDs are grounded in the actual vocabulary loaded by the Synthea ETL
rather than assumed from training data.

### Prebuild GitHub Package Binaries

Run only on a machine with GitHub access:

```r
setwd("C:/Users/rapiduser/pad-oler-ssi-val")
source("renv/activate.R")
source("scripts/bundle/prebuild_github_binaries.R")
```

This generates Windows binaries under `internal_repo/bin/windows/contrib/4.5/`.
Commit those binaries so restricted environments can install without GitHub access.

---

## Notes

- `drivers/mssql-jdbc-13.2.1.zip` is tracked so JDBC setup is reproducible.
- Extracted JDBC runtime files remain ignored via `.gitignore`.
- `renv/library` is intentionally not committed.
