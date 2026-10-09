# workflow/ — Numbered Synthetic Data Generation Steps (01–06)

Each script is a self-contained step in the synthetic-dataset generation lifecycle.
Scripts auto-resolve the project root from their own file path, so they can be run from
any shell working directory.

Use [docs/GETTING_STARTED.md](../docs/GETTING_STARTED.md) for the canonical run order.
This file is a step-level reference for what each workflow script does.

> A previous version of this template also included `workflow/07–09` for a full
> in-repo analysis, manuscript report, and bundle-packaging workflow. That code has
> been removed: new analysis work belongs in a separate repo built from
> `strategus-study-template`, and the manuscript in one built from
> `omop-report-template`. The removed code remains in git history.

---

## Steps at a glance

| Step | Script | Customize? | Purpose |
|------|--------|:----------:|---------|
| 1 | `01_setup_synthea_etl_qc_env.R` | — | Install packages, verify DB connectivity, provision JDBC driver |
| **2** | **`02_define_omop_cohort_outcome_covariates.R`** | **Yes** | Declare study design, validate cohort SQL and covariate files |
| 3 | `03_generate_synthea_module_artifacts.R` | — | Validate Synthea disease module JSON, regenerate HTML diagram, and check the module can produce the cohorts of every study in `consumers.yaml` (`scripts/module_coverage_check.R`) |
| 4 | `04_generate_synthea_csv.ps1` / `.sh` | — | Generate synthetic patients |
| 5 | `05_etl_csv_to_omop.R` | — | ETL Synthea CSV → OMOP CDM tables |
| 6 | `06_quality_check_defined_phenotypes.R` | — | Post-ETL data quality checks, then consumer-study QC of every study in `consumers.yaml` (`scripts/consumer_cohort_qc.R`) — the last step this repo documents |

Step 2 is the primary required customization. Steps 1, 3–6 are infrastructure and do
not normally need changes. After Step 6, register the dataset in
`synthetic_data/registry.yaml` at the workspace root.

---

## Execution

Use [docs/GETTING_STARTED.md](../docs/GETTING_STARTED.md) for complete execution commands,
skip logic, and platform-specific instructions.

Run `workflow/01_setup_synthea_etl_qc_env.R` first after opening this repo in the
dev container. Treat Step 1 as per-repo bootstrap (packages + DB preflight), not as shared
workspace infrastructure setup.

---

## Step 2 — Study definition (`02_define_omop_cohort_outcome_covariates.R`)

The primary customization checkpoint. Contains three user-facing sections at the top of
the file:

**Section A — Study design**
Set `study_design` to one of:
- `"cohort_characterization"` — single cohort, no outcome required
- `"prognostic_model"` — target cohort + outcome + covariates
- `"causal_inference"` — target + comparator + outcome + covariates
- `"descriptive"` — target + comparator, no formal outcome
- `"custom"` — any other design; minimal validation

This setting shapes the SYNTHETIC DATA you generate (which cohorts/covariates need to
be populated and validated) — it does not configure an in-repo analysis.

**Section B — Phenotype artifact paths**
Set file paths to your cohort SQL files and covariate CSVs. Paths are relative to
the project root. Set any path to `NULL` to mark it as not applicable for your design.

**Section C — Study parameters**
Set `prediction_window_days`, `min_prior_observation_days`, `covariate_lookback_days`,
and any other study-specific numeric parameters.

The validation logic (Chunks 3–5) adapts to your study design: a
`cohort_characterization` run will not warn about a missing outcome cohort, a
`causal_inference` run will warn if the comparator path is NULL, etc.

Run Step 2 early and often as you fill in your phenotype files — it catches
placeholder `concept_id = 0` values and structural issues before generating synthetic
data.

---

## Step parameters

**Step 5** (`05_etl_csv_to_omop.R`):
```bash
Rscript workflow/05_etl_csv_to_omop.R \
  --csv_input_dir=/path/to/synthea/output/csv \
  --run_name=my_study_run_001 \
  --reset_before_etl=true
```

**Step 6** (`06_quality_check_defined_phenotypes.R`):
```bash
Rscript workflow/06_quality_check_defined_phenotypes.R \
  --run_name=my_study_run_001 \
  --enforce_thresholds=true \
  --min_person_rows=100
```

**Consumer-study QC** (part of Step 6; flags are forwarded to `scripts/consumer_cohort_qc.R`):
```bash
Rscript workflow/06_quality_check_defined_phenotypes.R --enforce_thresholds=true
Rscript workflow/06_quality_check_defined_phenotypes.R --skip_consumer_qc=true   # generic QC only
Rscript scripts/consumer_cohort_qc.R --enforce_thresholds=true                   # consumer check only
```
It reads `consumers.yaml`, renders each consuming Strategus study's cohorts from their
circe JSON, instantiates them against the active CDM schema, and fails any cohort below its
per-role minimum (target, outcome-in-target, covariate). With no consumers listed it only warns.

**Module coverage check** (part of Step 3; flags are forwarded to `scripts/module_coverage_check.R`):
```bash
Rscript workflow/03_generate_synthea_module_artifacts.R --enforce_coverage=true
Rscript workflow/03_generate_synthea_module_artifacts.R --skip_coverage_check=true
Rscript scripts/module_coverage_check.R --enforce_coverage=true     # coverage check only
```
Before data generation it checks that the custom module **and** Synthea's built-in modules (all of
which workflow 04 runs) can emit the concepts in each consuming study's cohorts. Step 2 prints
the requirements (`consumers.yaml`), Step 3 checks the module, Step 6 checks the final data.
