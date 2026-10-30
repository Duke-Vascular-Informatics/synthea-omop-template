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
| **2** | **`02_define_omop_cohort_outcome_covariates.R`** | **Edit `consumers.yaml`** | List the cohorts of every consuming study that the module and the data must support |
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

## Step 2 — What the dataset must support (`02_define_omop_cohort_outcome_covariates.R`)

A `-synth` repo defines no cohorts, outcomes or covariates of its own. What the dataset must
contain is defined by the studies that will use it, listed in `consumers.yaml`; their cohort
definitions (`inst/Cohorts.csv` and `inst/cohorts/*.json` in each Strategus repo) are read
directly, so nothing is copied here and nothing can drift.

Step 2 does not connect to a database. It prints, for every consuming study, the cohorts the
Synthea module must be able to produce and the final data must contain, by role (target, outcome,
covariate), and reports anything that would stop the later checks from running (a study repo not
cloned, a missing manifest or cohort JSON, an unresolvable target or outcome id). It also registers
this repo in the workspace `studies.yaml` on first run. The same list drives Step 3 (does the module
cover these cohorts?) and Step 6 (does the final data contain them?).

Edit `consumers.yaml`, then run Step 2 early and often.

---

## Step parameters

**Step 4** (`04_generate_synthea_csv.sh [population] [age_range] [state]`):
```bash
SYNTHEA_SEED=12345 bash workflow/04_generate_synthea_csv.sh 5000 18-100 "North Carolina"
```
The seed is always recorded (a random one is drawn if unset) in `external/synthea/output/generation_params.txt`
with the module hash and population — copy it into the registry's `generation_params`. An existing `output/` is
moved to `output_prev_<timestamp>/`, never overwritten (`SYNTHEA_OVERWRITE_OUTPUT=true` deletes it instead).

**Step 5** (`05_etl_csv_to_omop.R`) takes **no command-line flags** — passing one is an error. Configure with
environment variables:
```bash
SYNTHEA_CSV_DIR=/path/to/synthea/output/csv \
SYNTHEA_SKIP_CLAIMS=true \
  bash scripts/run_logged.sh logs/step5.log Rscript workflow/05_etl_csv_to_omop.R
```
- `SYNTHEA_SKIP_CLAIMS=true` stages `claims.csv` / `claims_transactions.csv` header-only. Those two files are the
  largest (6.1 GB for 5,000 patients) and only feed the `cost` table; loading them whole needs ~1.8x their size in RAM.
- A memory guard refuses to start if the largest CSV would not fit in available RAM; `SYNTHEA_FORCE_FULL_LOAD=true` bypasses it.
- The target schema comes from `study_params.yaml` `cdm_schema` (the same field Step 6 reads); it is no longer set in two places.
- `scripts/run_logged.sh` appends `[RUN_LOGGED] EXIT=<code>` to the log, labelling exit 137 as an out-of-memory kill.
- **Resume an interrupted run:** the staging load is checkpointed per CSV (`<synthea_schema>.etl_load_checkpoint`: file
  size+mtime, loaded row count). After a crash or OOM kill, rerun with `SYNTHEA_RESUME=true`:
  ```bash
  SYNTHEA_RESUME=true SYNTHEA_SKIP_CLAIMS=true bash scripts/run_logged.sh logs/step5.log Rscript workflow/05_etl_csv_to_omop.R
  ```
  Staging tables are kept, CSVs whose checkpoint is still valid are skipped, and a table that was mid-load is truncated and
  reloaded (no duplicate rows). A CSV whose size/mtime changed, or whose staging row count no longer matches, is reloaded.
  Without `SYNTHEA_RESUME` a run is a clean rebuild and discards old checkpoints. Only the staging load is resumable; the later
  ETL phases (event tables, eras) always run in full. With no checkpoint table present, `SYNTHEA_RESUME` falls back to a fresh run.

**Step 3** also checks the module's state graph (missing transition targets, unreachable states, distributions that
do not sum to 1 — fatal) and, when a database is reachable, that every SNOMED/LOINC/RxNorm/CVX code resolves to a
standard concept (`MODULE_VOCAB_CHECK=off|warn|strict`, default `warn`).

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
For a consumer with `discharge_disposition_check: true` (analyses that depend on discharge
disposition) it also verifies the dataset has discharge dispositions loaded, mapped, and both home
and non-home (`output/qc/discharge_disposition_qc.csv`). It reads `consumers.yaml`, renders each consuming Strategus study's cohorts from their
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
