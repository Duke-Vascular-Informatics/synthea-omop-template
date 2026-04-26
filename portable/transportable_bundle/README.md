# PAD/OLER SSI Validation — protected analytic space Bundle

External validation of the PAD SSI integer risk score against an institutional
OMOP CDM v5.4 SQL Server database on protected analytic space (Research Computing Cluster).

**Authentication:** Kerberos (your institutional username) — no passwords stored in any file.
**Java:** conda openjdk from miniforge — no system Java installation needed.
**JDBC driver:** pre-bundled in `drivers/` — no internet download needed.

---

## Complete Command Sequence (Summary)

For experienced users, the full workflow in one place:

```bash
# ── One-time setup (first use only) ──────────────────────────────────────────
cd ~/transportable_bundle
bash setup_env.sh          # creates conda env, runs kinit, installs R pkgs
# Edit config.R — fill in server, database, spn_host, vocab_schema,
#                 cdm_schema, results_schema

# ── Every session ─────────────────────────────────────────────────────────────
cd ~/transportable_bundle
export KRB5CCNAME=FILE:~/krb5cc_java
kinit                           # enter your institutional credentials when prompted
conda activate openjdk
bash run_analysis.sh
```

Results are written to `output/risk_score_eval/`.

---

## Detailed Step-by-Step Instructions

### Step 1 — Transfer the bundle to your protected analytic space

From your **local machine**, copy the bundle folder to your HPC cluster home directory:

```bash
scp -r transportable_bundle/ <your_netid>@your.hpc.cluster.hostname:~/
```

Replace `<your_netid>` with your your institutional username (e.g. `abc123`).

Alternatively, use the cluster file browser (OnDemand → Files → Home Directory)
to upload the folder.

> **Note:** The bundle is approximately 1.5 MB (the JDBC JAR is included).
> Transfer should complete in seconds.

---

### Step 2 — Open a HPC cluster shell session

1. Go to **https://your.hpc.cluster.hostname** and log in with your your institutional username.
2. Click **"RE Cluster Shell Access"** (or **Interactive Apps → Shell Access**).
3. A terminal window will open in your browser.

Change to the bundle directory:

```bash
cd ~/transportable_bundle
```

Verify the files are present:

```bash
ls
```

Expected output:
```
R/                   cohorts/             drivers/
README.md            config.R             install_packages.R
output/              risk_score/          run_analysis.R
setup_env.sh
```

---

### Step 3 — Run environment setup

> **When to run:** On first use, and at the start of every new cluster session
> (Kerberos tickets expire after ~10 hours).

```bash
bash setup_env.sh
```

The script runs three sub-steps automatically:

**3a. Java setup (first run only, ~2 minutes)**

```
[1/3] Setting up Java environment ...
      Creating conda env 'openjdk' (this takes ~2 minutes on first run) ...
      conda env created.
      JAVA_HOME  = /hpc/group/somhpc/miniforge3/envs/openjdk
      java -version: openjdk version "17.x.x" ...
```

On subsequent runs, this prints `conda env 'openjdk' already exists — skipping creation.`

**3b. Kerberos ticket — you will be prompted for your password**

```
[2/3] Obtaining Kerberos ticket (enter your your institutional credentials) ...
Password for abc123@your HPC support team.DUKE.EDU:
      Ticket valid. Expires: Apr 07 2026 02:15 AM
```

> **Important:** This is your your institutional credentials. It is passed directly to
> Kerberos and is never stored anywhere. The ticket file is written to
> `~/krb5cc_java` and is valid for approximately 10 hours.

**3c. R package installation (first run only, ~5 minutes)**

```
[3/3] Installing R packages (skips packages already installed) ...
      Using R: /path/to/Rscript
Installing 11 package(s): DatabaseConnector, SqlRender, ...
      All 11 packages verified.
```

On subsequent runs this prints `All packages already installed.`

At the end you will see:

```
======================================================================
  Setup complete.
  ...
======================================================================
```

---

### Step 4 — Edit config.R

Open `config.R` in any text editor (e.g. `nano config.R`) and replace every
`CHANGE_ME` value with your site-specific settings.

**Required fields:**

| Field | What to enter | Example |
|---|---|---|
| `server` | SQL Server hostname | `"your.sql.server.hostname"` |
| `database` | Database containing the OMOP CDM | `"omop_prod"` |
| `spn_host` | Kerberos SPN hostname (usually same as `server`; contact your HPC support team if unsure) | `"your.sql.server.hostname"` |
| `vocab_schema` | Schema holding vocabulary tables (`concept`, `concept_ancestor`, etc.) | `"omop_vocab"` |
| `cdm_schema` | Schema holding CDM clinical tables (`person`, `visit_occurrence`, etc.) | `"cdm_omop_v54"` |
| `results_schema` | Schema where the cohort table will be written (your NetID needs `CREATE TABLE` here) | `"scratch_abc123"` |
| `cdm_database_id` | Short identifier for output file metadata | `"your_institution_omop_v5.4"` |
| `cdm_database_name` | Display name for output metadata | `"Your Institution OMOP CDM"` |

**Example edit with nano:**

```bash
nano config.R
```

Find the lines that read `"CHANGE_ME"` and replace them:

```r
server        = "your.sql.server.hostname",
database      = "omop_prod",
spn_host      = "your.sql.server.hostname",
vocab_schema  = "omop_vocab",
cdm_schema    = "cdm_omop_v54",
results_schema = "scratch_abc123",
```

Save and exit nano: press `Ctrl+O`, then `Enter`, then `Ctrl+X`.

**Optional — ATLAS cohorts:**

If your target and outcome cohorts already exist in an ATLAS results schema,
set `use_atlas_cohorts = TRUE` and supply the ATLAS cohort IDs instead of
running the built-in cohort SQL:

```r
use_atlas_cohorts       = TRUE,
atlas_cohort_schema     = "results",
atlas_cohort_table      = "cohort",
atlas_target_cohort_id  = 1796269L,
atlas_outcome_cohort_id = 1796278L,
```

Leave `use_atlas_cohorts = FALSE` (the default) to build cohorts from the
included SQL templates in `cohorts/`.

---

### Step 5 — Activate the Java environment

Before running R, activate the conda environment that provides Java:

```bash
conda activate openjdk
```

Your prompt will change to show `(openjdk)`:

```
(openjdk) [abc123@login01 transportable_bundle]$
```

> **Important:** R must be started from a shell where the openjdk conda env is
> active. If you close the terminal and reopen it, run `conda activate openjdk`
> again before proceeding.

---

### Step 6 — Run the analysis

```bash
bash run_analysis.sh
```

The script will print progress messages as it runs:

```
[run_analysis] Loading config ...
[run_analysis] Server  : your.sql.server.hostname
[run_analysis] Database: omop_prod
[run_analysis] CDM     : cdm_omop_v54
[run_analysis] Results : scratch_abc123
[run_analysis] Window  : 90-day SSI

[run_analysis] Building connection details (Kerberos) ...
Java configured: /hpc/group/.../envs/openjdk
JDBC driver verified: drivers/mssql-jdbc-13.2.1.jre11.jar
Building connection: your.sql.server.hostname / omop_prod (Kerberos SPN: MSSQLSvc/your.sql.server.hostname)
[run_analysis] Testing database connection ...
[run_analysis] Connection OK.

[run_analysis] Instantiating cohorts ...
Instantiating cohort: Target – Inpatient surgical procedure ...
Done: Target – Inpatient surgical procedure
Instantiating cohort: Outcome – Surgical site infection ...
Done: Outcome – Surgical site infection
  Surgery target cohort  n = ...
  SSI outcome cohort     n = ...

=== Integer risk score pipeline ===
Calculating person-level score covariates ...
Evaluating discrimination and calibration ...
...

[run_analysis] Generating manuscript Word report ...
[run_analysis] Report written to: output/risk_score_eval/pad-oler-ssi-val_report_<date>.docx

[run_analysis] All done.
Output folder: output/risk_score_eval/
```

Total runtime is typically **3–8 minutes** depending on CDM size.

---

### Step 7 — Retrieve output files

Output files are written to `output/risk_score_eval/`. Download them via the
cluster file browser (OnDemand → Files → Home Directory → transportable_bundle →
output/risk_score_eval/) or use `scp`:

```bash
# From your local machine:
scp -r <your_netid>@your.hpc.cluster.hostname:~/transportable_bundle/output/risk_score_eval/ ./
```

**Files produced:**

| File | Description |
|------|-------------|
| `person_level_scores.csv` | Per-patient covariate points, total score, predicted probabilities, binary 90-day SSI outcome |
| `covariate_summary.csv` | Covariate-level activation counts and mean points across the cohort |
| `metrics.csv` | AUROC, AUPRC, Brier score, ECE, calibration intercept and slope with 95% bootstrap CIs (B = 500) for three model specifications |
| `calibration_table_lookup.csv` | Calibration decile table for the published lookup model |
| `calibration_table_recalibrated.csv` | Calibration decile table for the recalibrated model |
| `calibration_lookup.png` | Calibration plot — lookup model |
| `calibration_recalibrated.png` | Calibration plot — recalibrated model |
| `pad-oler-ssi-val_report_<date>.docx` | Manuscript-format Word report with Tables 1–4, ROC curve, and calibration figures |
| `pad_oler_ssi_fringe_<date>.xlsx` | Fringe-case QC workbook: 10 lowest-risk patients with SSI + 10 highest-risk patients without SSI |

---

## Renewing a Kerberos Ticket (Subsequent Sessions)

Kerberos tickets expire after approximately 10 hours. If you receive a
`GSS initiate failed` or `Login failed` error, your ticket has expired.
Renew it without re-running the full setup:

```bash
export KRB5CCNAME=FILE:~/krb5cc_java
kinit
```

Enter your your institutional credentials when prompted, then re-run `bash run_analysis.sh`.

To check whether your current ticket is still valid:

```bash
klist
```

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `GSS initiate failed` / `Kerberos` error | Ticket expired or JAAS config missing | `export KRB5CCNAME=FILE:~/krb5cc_java && kinit`; confirm `jaas.conf` was written (appears in bundle dir after first run) |
| `KDC not found` | Not on HPC login node | Launch **RE Cluster Shell Access** from the cluster portal |
| `Login failed for user` | Wrong `spn_host` | Check `spn_host` in config.R; contact your HPC support team to confirm the correct SPN |
| `JAVA_HOME is not set` | conda env not active | `conda activate openjdk` then re-run |
| `No mssql-jdbc*.jar found` | drivers/ missing JAR | Re-transfer the bundle; confirm `drivers/mssql-jdbc-13.2.1.jre11.jar` exists |
| `fill in the following fields in config.R` | CHANGE_ME not replaced | Edit config.R and fill in all required values (Step 4) |
| `Run this script in a FRESH R session` | R session already had Java loaded | Open a new terminal, re-activate conda, re-run |
| `CREATE TABLE permission denied` | Insufficient DB permissions | Contact your HPC support team to request CREATE TABLE on `results_schema` |

---

## Risk Score Covariates

All 10 covariates are pre-mapped to OMOP standard concept IDs and require no
modification for a standard OMOP CDM v5.4 database:

| Covariate | Points | Concept(s) | Lookback |
|---|---|---|---|
| `female` | +1 | 8532 (Female) | Any time |
| `overweight` | +1 | 3025315 (weight), 3036277 (height) | 365 days |
| `obese` | +3 | 3025315 (weight), 3036277 (height) | 365 days |
| `urgnt` | +1 | 4158569, 4250892 + descendants | 30 days |
| `abi_35` | +1 | 40489833, 46237026 + descendants | 365 days |
| `prrevasc_any` | +1 | 4159960 + descendants | 10 years |
| `prolong_abx` | +2 | 21603553 + descendants | 90 days |
| `optime4h` | +1 | procedure_occurrence timestamps | Index date |
| `mFI_high` | +1 | 201820, 255573, 316139, 316866 + functional status | 365 days |
| `indicationClaudication` | −1 | 442774 + descendants | 365 days |

---

## Cohort Definitions

**Target cohort** (`cohorts/target_surgery.sql`)
Adults ≥ 18 at index with an inpatient visit during which an open
lower-extremity revascularisation procedure was recorded (OMOP concept 4159960
and all descendants, including femoral-popliteal bypass, femorotibial bypass,
aorto-femoral bypass, and femoral endarterectomy). Index date = visit start
date. Patients with any SSI diagnosis (concept 4334801) in the 365 days before
index are excluded.

**Outcome cohort** (`cohorts/outcome_ssi.sql`)
First SSI diagnosis (concept 4334801, SNOMED-CT 433202001, and all OMOP
descendants) within 90 days of the index date.

---

## Java / Conda Technical Notes

- Java is provided by `conda-forge::openjdk` installed via the cluster miniforge
  module — no system-level Java installation is required.
- The conda environment is named `openjdk` and is created once by
  `setup_env.sh`.
- JAVA_HOME is set automatically when you run `conda activate openjdk`; the
  `config.R` and `R/connection.R` files read this environment variable at
  runtime.
- The MSSQL JDBC driver (`drivers/mssql-jdbc-13.2.1.jre11.jar`) is included
  in the bundle — no internet access is required after initial R package
  installation.
- The JDBC connection uses `authenticationScheme=JavaKerberos` with
  `serverSpn=MSSQLSvc/<spn_host>` as described in the protected analytic space SQL Server
  documentation.

---

## Missing Value Handling

When a covariate has no matching records in the OMOP CDM, its event count
defaults to 0 and it contributes 0 points to the total score. This treats
missing data as "no documented evidence" of the risk factor — appropriate
when CDM completeness is high. Review the `score_<covariate_id>` columns in
`person_level_scores.csv` to identify any covariates with zero activation
across the entire cohort (which may indicate a mapping or ETL issue rather
than true clinical absence).

---

## Getting Help

| Issue type | Contact |
|---|---|
| Risk score methodology, concept mappings, study design | Study coordinator |
| cluster access, shell environment, file transfers | HPC support portal |
| SQL Server access, Kerberos SPN, database permissions | HPC support portal |
| R package installation failures | Check CRAN mirror access (see CRAN_MIRROR in .env); open a HPC support ticket |
