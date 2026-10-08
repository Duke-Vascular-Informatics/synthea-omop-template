# Getting Started: From Zero to a Synthetic Dataset

This guide takes you from a working charon workspace to a **reusable,
analysis-specific synthetic OMOP CDM dataset**: author a Synthea module,
generate patients, load them into OMOP CDM v5.4, quality-check them, and
register the result so other repos can use it.

## What this repo is, and is not

This template is **only** for generating synthetic data. It contains no
analysis, no report and no deployment bundle:

| Where | What happens there |
|---|---|
| **A `-synth` repo (this template)** | Synthea module → generation → ETL → QC (`workflow/01–06`). Ends at registering the dataset. |
| A `<study>` analysis-core repo ([`strategus-study-template`](https://github.com/Duke-Vascular-Informatics/strategus-study-template)) | **All of the analysis**: cohorts, analytic strategy, result extraction. |
| A `<study>-report` repo ([`omop-report-template`](https://github.com/Duke-Vascular-Informatics/omop-report-template)) | The manuscript tables, figures and narrative, from the analysis's aggregate outputs. |

**Why a study needs synthetic data at all.** The analysis is written and
tested against synthetic patients, so the team can build the cohorts, choose
the analytic strategy, and produce publication-ready tables and figures
*before* anyone sees a real result. That keeps the analysis hypothesis-driven
and limits the opportunity for p-hacking. The finished, reviewed code is then
run once in the secure environment. So the synthetic data must contain the
patients, exposures, outcomes and covariates the analysis will need.

**Who this guide is for.** You know OMOP/OHDSI basics, can read R and Python,
and know roughly what Java is for. You have read the
[charon README](https://github.com/Duke-Vascular-Informatics/charon/blob/main/README.md).

Related references (these live in the charon workspace, not in this repo):
- Workspace setup and troubleshooting: [charon `docs/GETTING_STARTED.md`](https://github.com/Duke-Vascular-Informatics/charon/blob/main/docs/GETTING_STARTED.md), [`docs/SETUP.md`](https://github.com/Duke-Vascular-Informatics/charon/blob/main/docs/SETUP.md)
- Vocabulary load problems: [`docs/TROUBLESHOOTING_VOCAB_LOAD.md`](https://github.com/Duke-Vascular-Informatics/charon/blob/main/docs/TROUBLESHOOTING_VOCAB_LOAD.md)
- Git/GitHub auth: [`docs/GIT_GITHUB_AUTH.md`](https://github.com/Duke-Vascular-Informatics/charon/blob/main/docs/GIT_GITHUB_AUTH.md)
- ETL problems: [`TROUBLESHOOTING_ETL.md`](https://github.com/Duke-Vascular-Informatics/charon/blob/main/docs/TROUBLESHOOTING_ETL.md)
- Commands: [COMMANDS.md](COMMANDS.md)

**Time:** ~2 hours for a first dataset once the workspace exists; the Synthea
module design is the variable part.

---

## Step 1: Complete the Workspace Setup (one-time per machine)

A `-synth` repo does not set up its own Docker, SQL Server or vocabulary. It
lives inside a charon workspace that provides them. If this machine does not
yet have one, complete **Steps 1–9** of the charon
[Getting Started guide](https://github.com/Duke-Vascular-Informatics/charon/blob/main/docs/GETTING_STARTED.md) first. That gives you:

- the dev container (R, Java, Python) and the shared SQL Server (`mssql_dev`);
- the OMOP vocabulary loaded into the `omop_vocab` schema of `omop_synth`;
- your `.env`, GitHub token, and git identity.

**Match the toolchain to your secure environment before the first build.** The
container's R, Java and Python versions must match those of the secure
analytics environment where the analysis will eventually run, because the
synthetic data is used to develop code for that environment. See
[charon Step 6.0](https://github.com/Duke-Vascular-Informatics/charon/blob/main/docs/GETTING_STARTED.md#60-match-the-container-to-your-secure-environment-before-the-first-build).

Skip this step if the workspace is already set up. You can confirm with:

```bash
echo $IN_DEV_CONTAINER          # true, when your terminal is inside the container
echo $MSSQL_HOST                # mssql_dev
```

---

## Step 2: Check Whether a Dataset Already Exists (5 minutes)

Generating data takes time. Before creating a repo, check whether the
workspace's registry already has a dataset that fits (same disease,
procedure and outcome):

```bash
# From the workspace root
Rscript synthetic_data/scripts/lookup_dataset.R --disease "<clinical term>"
```

If one fits, **reuse it instead** (same-machine schema, regenerate from its
module, or download its clinical tables). See
[`synthetic_data/README.md`](https://github.com/Duke-Vascular-Informatics/charon/blob/main/synthetic_data/README.md). Only continue
here if nothing fits.

---

## Step 3: Create Your Synth Repository from Template (5 minutes)

1. On GitHub, open this template → **Use this template** → **Create a new
   repository**.
2. Name it `<study>-synth`; the `-synth` suffix is the workspace convention for
   a data-generation-only repo.
3. Set visibility to **Private**.
4. In the container terminal, clone it **inside the workspace root** as a
   sibling of your other study repos, and create your working branch:

```bash
cd /workspace
git clone https://github.com/<your-org>/<study>-synth.git
cd <study>-synth
BRANCH=$(gh api user --jq .login)
git checkout -b "$BRANCH"
git push -u origin "$BRANCH"
```

Add the folder to the workspace `.gitignore` and register it in the
workspace `studies.yaml` (`pipeline_role: synth`). Work only on your own
branch; changes reach `main` through a pull request.

```
/workspace/
├── <study>/            ← analysis-core (strategus-study-template)
├── <study>-report/     ← report (omop-report-template)
└── <study>-synth/      ← this repo: data generation only
```

---

## Step 4: Open in the Dev Container and Bootstrap (10 minutes)

Work from the container terminal, inside `/workspace/<study>-synth`. Run the
per-repo bootstrap once. It restores packages, provisions the JDBC driver and
tests the database connection:

```bash
Rscript workflow/01_setup_synthea_etl_qc_env.R
```

If the connection test reports `localhost:1433` refused, see the "Connection
refused" section of the
[charon guide](https://github.com/Duke-Vascular-Informatics/charon/blob/main/docs/GETTING_STARTED.md#connection-refused-on-localhost1433).

---

## Step 5: Define the Cohorts and Covariates Your Data Must Support (30 to 60 minutes)

The point of this step is to say what the synthetic data **must contain** so
that the analysis repo's cohorts, outcomes and covariates will find patients
(`workflow/06` later checks the generated data against these concepts).
Fill in `cohorts/` and `covariates/` **only as far as is needed to validate
the generated data**; the real study definitions belong in the analysis-core
repo and should match these.

### 5.1 Review what still needs input

```bash
Rscript scripts/check_setup.R       # [OK] / [WARN] / [FAIL] per item; no database needed
```

### 5.2 Edit `study_params.yaml`

Set the study identity (`study_name`), the schema names (`cdm_schema`,
`results_schema`, `cohort_table`), `output_folder`, the date range, and the
generation parameters (population size, age range, seed). Leave every
`analyses:` flag `false`: those blocks are read by this repo's code but never
acted on, because no analysis runs here.

### 5.3 Look up every concept ID (Rule 1)

Replace each `0` placeholder only with a verified concept ID. Check, in order:
the OHDSI Phenotype Library, your lab's labelled ATLAS definitions, the local
catalog (`phenotype_library/catalog.yaml`), and only then a live vocabulary
query. All of these tools are in the charon README's "Rules you must follow"
and `phenotype_library/README.md`. The live query is:

```bash
Rscript scripts/concept_lookup.R "<clinical term>" <Domain>
```

Tag each ID `[vocab query]` (confirmed against your loaded vocabulary) or
`[pretraining]` (unverified; do not commit it). After a live lookup, add the
result to the catalog so the next study skips it.

### 5.4 Edit the cohort SQL

In `cohorts/`: `target_surgery.sql` (index event), `outcome_ssi.sql`
(outcome), and `comparator_cohort.sql` if the analysis compares groups.
Replace every `concept_id = 0` and explain each ID in a trailing comment:

```sql
WHERE c.procedure_concept_id IN (<id>, <id>)  -- [vocab query] <concept name> (<vocabulary>)
```

### 5.5 Edit the covariate files

- `covariates/covariates.csv`: one row per covariate (name, OMOP domain, lookback window, minimum events)
- `covariates/covariate_concepts.csv`: the concept IDs behind each covariate

```csv
covariate_id,concept_id,include_descendants
diabetes,<id>,TRUE
```

See `covariates/README.md` for every column.

### 5.6 Validate

```bash
Rscript workflow/02_define_omop_cohort_outcome_covariates.R
Rscript scripts/check_setup.R       # no [FAIL] items
```

Commit the study definition on your branch.

---

## Step 6: Design the Analysis-Specific Synthea Module (30 minutes)

Synthea simulates patients from **modules**: JSON state machines that decide
which conditions, procedures and medications each patient gets. This step
shapes the dataset to the analysis.

1. Open the default module in `synthea/modules/` (for example
   `surgical_site_infection_study.json`) to see the structure.
2. Edit it so the population contains what Step 5 requires: the index
   event, the outcome at a plausible rate, and the comorbidities and
   exposures used as covariates (prevalence, procedure rates, medication
   patterns).
3. Validate it and regenerate its diagram:

```bash
Rscript workflow/03_generate_synthea_module_artifacts.R
```

Realism matters for testing the pipeline (event rates, timing, coding), but
remember the data is synthetic: it shows that the analysis plan works, not
what the real effect will be.

---

## Step 7: Generate Synthetic Data, Run ETL, and Check Quality (60 minutes)

```bash
bash workflow/04_generate_synthea_csv.sh           # Synthea (Java) writes synthetic patient CSVs
Rscript workflow/05_etl_csv_to_omop.R              # CSV -> OMOP CDM v5.4 in config$cdm_schema
Rscript workflow/06_quality_check_defined_phenotypes.R   # data quality + phenotype validation
```

On Windows run
`powershell -ExecutionPolicy Bypass -File workflow/04_generate_synthea_csv.ps1`
for the first command. Never run `.sh`/`.ps1` files with `Rscript`.

The ETL links to the shared `omop_vocab` schema rather than reloading it. QC
confirms the target-procedure and outcome concepts you configured in Step 5
appear in enough rows (thresholds and flags are in `workflow/README.md`; pass
`--enforce_thresholds=true` to make a shortfall fail the step). If a step fails, use the
[ETL troubleshooting guide](https://github.com/Duke-Vascular-Informatics/charon/blob/main/docs/TROUBLESHOOTING_ETL.md).

---

## Step 8: Register Your Synthetic Dataset (10 minutes)

The dataset is generated, loaded and checked. This repo's job ends here.

1. Add an entry to `synthetic_data/registry.yaml` in the workspace
   root: the disease/procedure covered, the outcomes present, `source_repo`
   (this repo), `producer_role: synth`, and the schema name. The file's header
   comment lists every field. **Never** include vocabulary tables in anything
   you export or share.
2. Commit this repo's changes on your branch and open a PR into `main`:

```bash
git add synthea/modules/ cohorts/ covariates/ study_params.yaml
git commit -m "feat: synthetic dataset for <disease/procedure/outcome>"
git push
```

Your analysis-core repo can now point at the registered dataset (see
[`synthetic_data/README.md`](https://github.com/Duke-Vascular-Informatics/charon/blob/main/synthetic_data/README.md)). Analysis and the
manuscript happen there and in the report repo.

---

## Troubleshooting

- Workspace, container, Docker, vocabulary: the charon guides linked above
- Synthea generation and ETL: [charon `TROUBLESHOOTING_ETL.md`](https://github.com/Duke-Vascular-Informatics/charon/blob/main/docs/TROUBLESHOOTING_ETL.md)
- Concept lookup and coding rules: [CLAUDE.md](../CLAUDE.md)

## Getting Help

- **OHDSI Community**: [forums.ohdsi.org](https://forums.ohdsi.org)
- **Book of OHDSI**: [ohdsi.github.io/TheBookOfOhdsi](https://ohdsi.github.io/TheBookOfOhdsi)
- **Your coding assistant**: ask it to explain any step or help debug errors

## Key Files to Know

| File | Purpose |
|---|---|
| `config.R` | Infrastructure settings (do not edit) |
| `study_params.yaml` | Identity, schemas, generation parameters (edit) |
| `synthea/modules/*.json` | The Synthea disease/procedure module (edit; the main work) |
| `cohorts/*.sql`, `covariates/*.csv` | What the data must support, for validation (edit) |
| `workflow/01–06` | The generation pipeline (do not edit) |
| `output/` | Generation logs and QC output (gitignored) |

## Version Info

- **R / Java / Python:** the versions chosen for your workspace to match your secure analytics environment (charon `.env`: `R_VERSION`, `JAVA_VERSION`, `PYTHON_VERSION`)
- **SQL Server:** Azure SQL Edge (ARM64) or SQL Server 2022 (AMD64)
- **OMOP CDM:** v5.4
