# PAD / OLER - Surgical Site Infection (SSI) External Validation

This project performs external validation of a previously developed SSI prediction model using the OHDSI PatientLevelPrediction framework on a Synthea-generated OMOP CDM v5.4 SQL Server database.

## Purpose

- Reproduce an external validation workflow for a pre-trained SSI model.
- Run validation on `omop_synth` (`cdm_synthea`) with transparent, scriptable steps.
- Support restricted-network environments by prebuilding GitHub-based package binaries.

## Canonical 1-9 Workflow

The project now follows a consistent numbered workflow matching the full study lifecycle.

Use the scripts in `workflow/` in this order:

1. `workflow/01_setup_synthea_etl_qc_env.R`
2. `workflow/02_define_omop_cohort_outcome_covariates.R`
3. `workflow/03_generate_synthea_module_artifacts.R`
4. `workflow/04_generate_synthea_csv.ps1`
5. `workflow/05_etl_csv_to_omop.R`
6. `workflow/06_quality_check_defined_phenotypes.R`
7. `workflow/07_setup_analysis_env.R`
8. `workflow/08_run_analysis_and_manuscript_report.R`
9. `workflow/09_build_portable_analysis_bundle.ps1`

For command examples and details, see `workflow/README.md`.

Run steps directly as standalone scripts.

Each script in `workflow/` can be run independently and auto-resolves repo root.

Examples:

```powershell
Rscript workflow/00_preflight_checks.R
Rscript workflow/01_setup_synthea_etl_qc_env.R
Rscript workflow/02_define_omop_cohort_outcome_covariates.R
Rscript workflow/03_generate_synthea_module_artifacts.R
powershell -ExecutionPolicy Bypass -File workflow/04_generate_synthea_csv.ps1
Rscript workflow/05_etl_csv_to_omop.R
Rscript workflow/05_etl_csv_to_omop.R --reset_before_etl=true
Rscript workflow/06_quality_check_defined_phenotypes.R --run_name=padssi-csv-20260324-120000 --enforce_thresholds=true --min_person_rows=100
Rscript workflow/07_setup_analysis_env.R
Rscript workflow/08_run_analysis_and_manuscript_report.R
powershell -ExecutionPolicy Bypass -File workflow/09_build_portable_analysis_bundle.ps1
```

The canonical Step 8 keeps report output as a shareable Word document (`.docx`) in `output/risk_score_eval/`.

Legacy one-off entrypoint scripts were archived to:

- `scripts/archive/legacy_entrypoints/`

## Prerequisites

- R 4.5.2+
- Java 17 (Eclipse Adoptium)
- SQL Server instance with OMOP CDM loaded (`localhost:1434`, database `omop_synth`)
- A pre-trained PLP result folder from the original SSI development study

CRAN packages are installed from:
- `https://archive.linux.duke.edu/cran/`

## Repository Structure

```text
pad-oler-ssi-val/
  config.R
  install_packages.R
  setup_renv.R
  .Rprofile
  renv.lock
  setup/
    install_packages.R
    setup_renv.R
  cohorts/
    target_surgery.sql
    outcome_ssi.sql
  R/
    connection.R
    drivers.R
    cohorts.R
    validation.R
    risk_score_pipeline.R
  risk_score/
    components.csv
    component_concepts.csv
    risk_lookup.csv
  workflow/
    00_preflight_checks.R
    01_setup_synthea_etl_qc_env.R
    ...
    09_build_portable_analysis_bundle.ps1
  scripts/
    archive/
      legacy_entrypoints/
    bundle/
      build_portable_risk_score_bundle.ps1
    etl/
      reset_omop_and_staging.R
      run_synthea_csv_to_omop_etl.R
    synthea/
      generate_synthea_mermaid.R
      run_synthea_pad_ssi.ps1
    prebuild_github_binaries.R
    sql/
  internal_repo/
    bin/windows/contrib/4.5/
      FeatureExtraction_3.6.0.zip
      CohortGenerator_0.9.0.zip
      PatientLevelPrediction_6.4.0.zip
  synthea/
    modules/
      pad_ssi.json
      pad_ssi.diagram.html
  portable/
    risk_score_validation_bundle/
      run_risk_score_pipeline.R
      config.R
      install_packages_risk_score.R
      README.md
      R/
        connection.R
        drivers.R
        risk_score_pipeline.R
      risk_score/
        components.csv
        component_concepts.csv
        risk_lookup.csv
      drivers/
        mssql-jdbc-13.2.1.zip
  .github/
    copilot-instructions.md
    instructions/
      r-packages.instructions.md
      omop-ohdsi.instructions.md
    prompts/
      concept-lookup.prompt.md
  drivers/
    mssql-jdbc-13.2.1.zip
```

## Package Strategy

### CRAN packages

Installed directly from the Duke CRAN mirror.

### GitHub packages (prebuilt internally)

The following GitHub packages are pinned and supported through prebuilt local binaries:

- `OHDSI/FeatureExtraction` @ `v3.6.0`
- `OHDSI/CohortGenerator` @ `v0.9.0`
- `OHDSI/PatientLevelPrediction` @ `v6.4.0`

`setup/install_packages.R` installs these in this order:
1. From local internal binaries in `internal_repo/bin/windows/contrib/<R-version>/`
2. Fallback to GitHub only if a local binary is missing

This allows installs to run without GitHub access once binaries are prebuilt.

## One-Time Setup

From project root in a fresh R session:

```r
setwd("C:/Users/rapiduser/pad-oler-ssi-val")
source("setup/setup_renv.R")
source("setup/install_packages.R")
```

Root-level `setup_renv.R` and `install_packages.R` remain as compatibility wrappers.

What this does:
- Activates `renv`
- Installs CRAN dependencies from Duke mirror
- Installs GitHub-pinned OHDSI packages from local internal binaries when available
- Provisions JDBC driver bundle to `drivers/`

## Prebuild GitHub Package Binaries

Run this only on a machine with GitHub access:

```r
setwd("C:/Users/rapiduser/pad-oler-ssi-val")
source("renv/activate.R")
source("scripts/prebuild_github_binaries.R")
```

This generates Windows binaries under:
- `internal_repo/bin/windows/contrib/4.5/`

Commit those binaries so restricted environments can install without GitHub.

## Run Analysis and Report

Use the canonical workflow (recommended):

```powershell
Rscript workflow/07_setup_analysis_env.R
Rscript workflow/08_run_analysis_and_manuscript_report.R
```

Or run the analysis step directly in a fresh R session:

```r
setwd("C:/Users/rapiduser/pad-oler-ssi-val")
source("workflow/08_run_analysis_and_manuscript_report.R")
```

This step executes the canonical Step 8 workflow script, which:

1. Loads project configuration and connections
2. Builds target/outcome cohorts
3. Runs integer risk score analysis
4. Writes score outputs to `output/risk_score_eval/`
5. Generates the manuscript-style report

## ATLAS Cohorts

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

What happens at runtime:

- Step 3 copies ATLAS cohort `1796269` into the project cohort table as target ID `1`.
- Step 3 copies ATLAS cohort `1796278` into the project cohort table as outcome ID `2`.
- Date filtering is applied using `study_start_date` and `study_end_date` from `config.R`.

If your ATLAS cohort table lives in another schema or table, update
`atlas_cohort_schema` and `atlas_cohort_table` in `config.R`.

## Integer Risk Score Pipeline

This repository also includes a configurable pipeline for evaluating a simple
integer-based risk score in the same target/outcome cohorts.

Canonical entry point:

```r
setwd("C:/Users/rapiduser/pad-oler-ssi-val")
source("workflow/08_run_analysis_and_manuscript_report.R")
```

Configuration files:

- `risk_score/components.csv`
  - Defines each score component, lookback window, minimum event count, and points.
- `risk_score/component_concepts.csv`
  - Maps each component to OMOP standard concept IDs and descendant expansion.
  - All components are fully mapped:

  | Component | Concept(s) | Notes |
  |---|---|---|
  | `female` | 8532 | Biological sex = Female |
  | `overweight` | 3025315 (weight), 3036277 (height) | BMI 25–30 derived from measurements |
  | `obese` | 3025315 (weight), 3036277 (height) | BMI ≥ 30 derived from measurements |
  | `urgnt` | 4158569, 4250892 + descendants | Emergency or urgent procedure flag |
  | `abi_35` | 40489833, 46237026 + descendants | Ankle-brachial index measurement < 0.35 |
  | `prrevasc_any` | 4159960 + descendants | Prior lower-extremity vascular procedure |
  | `prolong_abx` | 21603553 + descendants | Non-prophylactic antibiotic (start ≤ index − 1 day, duration > 2 days) |
  | `optime4h` | procedure_end_datetime (primary) | Operative time > 240 minutes; measurement table used if concept present |
  | `mFI_high` | 201820, 255573, 316139, 316866, 4215267 | Composite modified Frailty Index > 0.25 (≥2/5 conditions: diabetes, COPD, CHF, hypertension, functional status) |
  | `indicationClaudication` | 442774 + descendants | Intermittent claudication as surgical indication |

- `risk_score/risk_lookup.csv`
  - Optional score-to-risk lookup table from the original score publication.

Behavior:

- Computes person-level component points and total score for the target cohort.
- Defines 30-day outcome from the configured outcome cohort (`prediction_window_days`).
- Evaluates discrimination (AUROC, AUPRC).
- Evaluates calibration when probabilities are available:
  - lookup-based probabilities (if `risk_lookup.csv` is populated)
  - recalibrated probabilities using logistic mapping from score.

Output files (written to `output/risk_score_eval/`):

- `person_level_scores.csv`
- `component_summary.csv`
- `metrics.csv`
- `calibration_table_lookup.csv` (if lookup is available)
- `calibration_table_recalibrated.csv`
- `calibration_lookup.png` (if lookup is available)
- `calibration_recalibrated.png`

### Missing Value Handling

The risk score pipeline handles missing component data by **treating missing values as null/zero evidence**.

**Approach:**
- When a component's event count cannot be determined from the OMOP CDM (no matching records), 
  the component's event count is set to 0.
- The component score is then calculated normally: if `event_count < min_count`, the component 
  scores 0 points; otherwise, it scores the full component points.
- The total risk score is computed by summing all component scores, even if some components 
  had no matching data.

**Interpretation:**
- A total score of 15 could mean: (1) patient has 15 points worth of evidence, OR 
  (2) three of five components had no data, so those components contributed 0 points by default.
- The output file `person_level_scores.csv` includes individual component scores 
  (`score_<component_id>` columns), so you can review which components had evidence.

**Clinical Context:**
This approach assumes that **missing data from the EMR equals no documented evidence** of that 
risk factor. It is suitable when:
- Data completeness is expected to be high (well-curated OMOP CDM)
- Missing values should not prevent risk score calculation
- A missing risk factor is treated conservatively as "nil risk" rather than "unknown risk"

If your use case requires **marking scores as incomplete when data is missing**, contact the 
development team to discuss alternative imputation or missing-data handling strategies.

### Portable Bundle For External OMOP Sites

To make risk score validation easy to share and run at other OMOP sites, this repo
includes a curated portable bundle under:

- `portable/risk_score_validation_bundle/`

Create a downloadable zip in one command:

```powershell
.\scripts\build_portable_risk_score_bundle.ps1
```

This creates:

- `dist/risk_score_validation_bundle_<timestamp>.zip`

The zip contains only the required risk score scripts, templates, and JDBC artifact,
so collaborators can unzip, edit `config.R`, and run `run_risk_score_pipeline.R`
directly against their OMOP database.

## Synthea Module

`synthea/modules/pad_ssi.json` is a Synthea Generic Module Framework (GMF) module that
generates synthetic PAD patients who undergo open lower extremity revascularization and
may develop a surgical site infection — exactly matching the target/outcome cohort logic
of this study.

To use it:
1. Copy `synthea/modules/pad_ssi.json` into `<synthea_home>/src/main/resources/modules/`
2. Run Synthea with CSV export to generate the OMOP ETL input files
3. Run the ETL pipeline (Step 5) to load the CSV output into the OMOP CDM

### Run Synthea (CSV, 1000 Patients)

Use the project runner script:

```powershell
.\scripts\synthea\run_synthea_pad_ssi.ps1 -SyntheaHome "C:\path\to\synthea" -Population 1000
```

This script:
- copies `synthea/modules/pad_ssi.json` into the Synthea modules folder
- runs Synthea for the requested population with CSV export enabled
- prints the output folder at `output/csv` under your Synthea installation

Run batches of 1000 patients at a time; re-run Step 5 after each batch to load
incremental CSV output into the OMOP CDM.

Key clinical parameters modeled:

| Parameter | Value |
|-----------|-------|
| PAD pathway assignment | 100% of generated patients age 40+ |
| SSI — baseline | 6% |
| SSI — with Type 2 diabetes | 12% |
| SSI — with obesity (BMI ≥ 30) | 10% |
| SSI requiring rehospitalization | 15% of SSIs |
| Hospital stay | 3–7 days |
| SSI onset window | 5–25 days post-discharge |

Primary concept codes (OMOP-mappable):

| Concept | Vocabulary | Code |
|---------|-----------|------|
| Peripheral arterial occlusive disease | SNOMED-CT | 399957001 |
| Bypass of femoral artery to popliteal artery | SNOMED-CT | 232723009 |
| Infection of surgical wound | SNOMED-CT | 76844004 |
| Debridement (reoperation) | SNOMED-CT | 118294005 |
| Ankle-brachial index | LOINC | 59574-4 |
| Wound culture | LOINC | 6463-4 |
| Cefazolin (perioperative prophylaxis) | RxNorm | 20496 |
| Cephalexin (SSI treatment) | RxNorm | 2673 |

### Visualize the Module (Mermaid)

This repository includes a local generator script and a rendered Mermaid file:

- `scripts/synthea/generate_synthea_mermaid.R`
- `synthea/modules/pad_ssi.mmd`
- `synthea/modules/pad_ssi.diagram.md`

Regenerate the diagram after editing the JSON module:

```powershell
& "C:/Program Files/R/R-4.5.2/bin/Rscript.exe" scripts/synthea/generate_synthea_mermaid.R synthea/modules/pad_ssi.json synthea/modules/pad_ssi.diagram.html
```

The generator also refreshes `synthea/modules/pad_ssi.diagram.md` automatically
for Markdown preview.

Open `synthea/modules/pad_ssi.mmd` in VS Code and use a Mermaid preview extension,
or paste it into the built-in Mermaid renderer in Chat for quick visualization.

View the `.diagram.md` diagram in VS Code:

1. Open `synthea/modules/pad_ssi.diagram.md`.
2. Install a Mermaid preview extension if needed (for example, **Markdown Preview Mermaid Support**).
3. Preview the file:
  - `Ctrl+Shift+V` (preview in current tab), or
  - `Ctrl+K` then `V` (side-by-side preview).
4. If preview still does not render, close and reopen the preview tab to clear extension cache.

## GitHub Copilot Customizations

This repository ships Copilot instruction and prompt files so AI-assisted coding automatically
follows project conventions — no need to repeat constraints in chat.

### Always-on Instructions

| File | Scope | Purpose |
|------|-------|------|
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

## Notes

- `drivers/mssql-jdbc-13.2.1.zip` is tracked so JDBC setup is reproducible.
- Extracted JDBC runtime files remain ignored via `.gitignore`.
- `renv/library` is intentionally not committed.
