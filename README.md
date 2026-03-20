# PAD / OLER - Surgical Site Infection (SSI) External Validation

This project performs external validation of a previously developed SSI prediction model using the OHDSI PatientLevelPrediction framework on a Synthea-generated OMOP CDM v5.4 SQL Server database.

## Purpose

- Reproduce an external validation workflow for a pre-trained SSI model.
- Run validation on `omop_synth` (`cdm_synthea`) with transparent, scriptable steps.
- Support restricted-network environments by prebuilding GitHub-based package binaries.

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
  run_validation.R
  config.R
  install_packages.R
  setup_renv.R
  .Rprofile
  renv.lock
  cohorts/
    target_surgery.sql
    outcome_ssi.sql
  R/
    connection.R
    drivers.R
    cohorts.R
    validation.R
    risk_score_pipeline.R
  run_risk_score_pipeline.R
  risk_score/
    components.csv
    component_concepts.csv
    risk_lookup.csv
  scripts/
    prebuild_github_binaries.R
    generate_synthea_mermaid.R
    run_synthea_pad_ssi.ps1
    run_fhir_to_omop_etl.R
    sql/
      fhir_to_omop_transform_draft.sql
  internal_repo/
    bin/windows/contrib/4.5/
      FeatureExtraction_3.6.0.zip
      CohortGenerator_0.9.0.zip
      PatientLevelPrediction_6.4.0.zip
  synthea/
    modules/
      pad_ssi.json
      pad_ssi.mmd
      pad_ssi.diagram.md
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

`install_packages.R` installs these in this order:
1. From local internal binaries in `internal_repo/bin/windows/contrib/<R-version>/`
2. Fallback to GitHub only if a local binary is missing

This allows installs to run without GitHub access once binaries are prebuilt.

## One-Time Setup

From project root in a fresh R session:

```r
setwd("C:/Users/rapiduser/pad-oler-ssi-val")
source("setup_renv.R")
source("install_packages.R")
```

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

## Run Validation

In a fresh R session:

```r
setwd("C:/Users/rapiduser/pad-oler-ssi-val")
source("run_validation.R")
```

Pipeline stages:
1. Load config
2. Build DB connection details and verify connection
3. Prepare target and outcome cohorts (ATLAS copy mode or local SQL mode)
4. Run `externalValidateDbPlp()`
5. Save outputs and launch PLP result viewer

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

Entry point:

```r
setwd("C:/Users/rapiduser/pad-oler-ssi-val")
source("run_risk_score_pipeline.R")
```

Configuration files:

- `risk_score/components.csv`
  - Defines each score component, lookback window, minimum event count, and points.
- `risk_score/component_concepts.csv`
  - Maps each component to OMOP standard concept IDs and descendant expansion.
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

## Synthea Module

`synthea/modules/pad_ssi.json` is a Synthea Generic Module Framework (GMF) module that
generates synthetic PAD patients who undergo open lower extremity revascularization and
may develop a surgical site infection — exactly matching the target/outcome cohort logic
of this study.

To use it:
1. Copy `synthea/modules/pad_ssi.json` into `<synthea_home>/src/main/resources/modules/`
2. Run Synthea to generate FHIR output (the module co-exists with other modules such as
   `diabetes.json` and `metabolic_syndrome.json`, whose conditions it checks for risk adjustment)
3. If OMOP loading is needed, run Synthea separately with CSV export enabled for the ETL pipeline

### Run Synthea (FHIR, 5000 Patients)

Use the project runner script:

```powershell
.\scripts\run_synthea_pad_ssi.ps1 -SyntheaHome "C:\path\to\synthea" -Population 5000
```

This script:
- copies `synthea/modules/pad_ssi.json` into the Synthea modules folder
- runs Synthea for the requested population
- forces FHIR export (`exporter.fhir.export=true`, `exporter.csv.export=false`)
- prints the output folder at `output/fhir` under your Synthea installation

### Draft FHIR -> OMOP ETL (SQL Server)

This repository includes a draft ETL scaffold to load Synthea FHIR NDJSON into an
OMOP CDM schema on SQL Server:

- `scripts/run_fhir_to_omop_etl.R` (R orchestrator)
- `scripts/sql/fhir_to_omop_transform_draft.sql` (draft SQL transform)

What it does:

1. Reads `.ndjson` files from a FHIR output folder
2. Auto-generates a run name from sample size, module version, and date
3. Writes metadata JSON to `output/etl_runs/<run_name>/metadata.json`
4. Stages raw FHIR resources into `fhir_stage.fhir_raw_resource`
5. Runs draft transforms for:
   - Patient -> `person`
   - Encounter -> `visit_occurrence`
   - Condition -> `condition_occurrence`

Run it in R:

```r
setwd("C:/Users/rapiduser/pad-oler-ssi-val")
source("renv/activate.R")
source("scripts/run_fhir_to_omop_etl.R")

run_fhir_to_omop_etl(
  fhir_input_dir = "C:/path/to/synthea/output/fhir",
  sample_size = 5000L,
  module_version = "v03",
  run_date = Sys.Date()
)
```

Example autogenerated run name:

- `padssi-n5000-modv03-20260320`

Example metadata JSON path:

- `output/etl_runs/padssi-n5000-modv03-20260320/metadata.json`

Note: this is a draft ETL for iterative synthetic testing. Production-grade mapping
still needs full vocabulary mapping from FHIR codes to OMOP standard concepts.

Key clinical parameters modeled:

| Parameter | Value |
|-----------|-------|
| PAD prevalence (age 40+) | 6% |
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

- `scripts/generate_synthea_mermaid.R`
- `synthea/modules/pad_ssi.mmd`
- `synthea/modules/pad_ssi.diagram.md`

Regenerate the diagram after editing the JSON module:

```powershell
& "C:/Program Files/R/R-4.5.2/bin/Rscript.exe" scripts/generate_synthea_mermaid.R synthea/modules/pad_ssi.json synthea/modules/pad_ssi.mmd
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
