# PAD/OLER SSI Validation — Duke PRCC Bundle

External validation of the PAD SSI integer risk score against an institutional
OMOP CDM v5.4 SQL Server database on Duke PRCC (Research Computing Cluster).

**Authentication:** Kerberos (Duke NetID) — no passwords stored in any file.
**Java:** conda openjdk from miniforge — no system Java installation needed.
**JDBC driver:** pre-bundled in `drivers/` — no internet download needed.

---

## Complete Command Sequence (Summary)

For experienced users, the full workflow in one place:

```bash
# ── One-time setup (first use only) ──────────────────────────────────────────
cd ~/prcc_bundle
bash setup_prcc_env.sh          # creates conda env, runs kinit, installs R pkgs
# Edit config.R — fill in server, database, spn_host, vocab_schema,
#                 cdm_schema, results_schema

# ── Every session ─────────────────────────────────────────────────────────────
cd ~/prcc_bundle
export KRB5CCNAME=FILE:~/krb5cc_java
kinit                           # enter Duke NetID password when prompted
conda activate openjdk
Rscript run_analysis.R
```

Results are written to `output/risk_score_eval/`.

---

## Detailed Step-by-Step Instructions

### Step 1 — Transfer the bundle to PRCC

From your **local machine**, copy the bundle folder to your PRCC home directory:

```bash
scp -r prcc_bundle/ <your_netid>@prcc.dhe.duke.edu:~/
```

Replace `<your_netid>` with your Duke NetID (e.g. `abc123`).

Alternatively, use the PRCC file browser (OnDemand → Files → Home Directory)
to upload the folder.

> **Note:** The bundle is approximately 1.5 MB (the JDBC JAR is included).
> Transfer should complete in seconds.

---

### Step 2 — Open a PRCC shell session

1. Go to **https://prcc.oit.duke.edu** and log in with your Duke NetID.
2. Click **"RE Cluster Shell Access"** (or **Interactive Apps → Shell Access**).
3. A terminal window will open in your browser.

Change to the bundle directory:

```bash
cd ~/prcc_bundle
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
setup_prcc_env.sh
```

---

### Step 3 — Run environment setup

> **When to run:** On first use, and at the start of every new PRCC session
> (Kerberos tickets expire after ~10 hours).

```bash
bash setup_prcc_env.sh
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
[2/3] Obtaining Kerberos ticket (enter your Duke NetID password) ...
Password for abc123@DHTS.DUKE.EDU:
      Ticket valid. Expires: Apr 07 2026 02:15 AM
```

> **Important:** This is your Duke NetID password. It is passed directly to
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
| `server` | SQL Server hostname | `"dbserver01.dhe.duke.edu"` |
| `database` | Database containing the OMOP CDM | `"omop_prod"` |
| `spn_host` | Kerberos SPN hostname (usually same as `server`; contact DHTS if unsure) | `"dbserver01.dhe.duke.edu"` |
| `vocab_schema` | Schema holding vocabulary tables (`concept`, `concept_ancestor`, etc.) | `"omop_vocab"` |
| `cdm_schema` | Schema holding CDM clinical tables (`person`, `visit_occurrence`, etc.) | `"cdm_omop_v54"` |
| `results_schema` | Schema where the cohort table will be written (your NetID needs `CREATE TABLE` here) | `"scratch_abc123"` |
| `cdm_database_id` | Short identifier for output file metadata | `"duke_omop_v5.4"` |
| `cdm_database_name` | Display name for output metadata | `"Duke SOM OMOP CDM"` |

**Example edit with nano:**

```bash
nano config.R
```

Find the lines that read `"CHANGE_ME"` and replace them:

```r
server        = "dbserver01.dhe.duke.edu",
database      = "omop_prod",
spn_host      = "dbserver01.dhe.duke.edu",
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
(openjdk) [abc123@login01 prcc_bundle]$
```

> **Important:** R must be started from a shell where the openjdk conda env is
> active. If you close the terminal and reopen it, run `conda activate openjdk`
> again before proceeding.

---

### Step 6 — Run the analysis

```bash
Rscript run_analysis.R
```

The script will print progress messages as it runs:

```
[run_analysis] Loading config ...
[run_analysis] Server  : dbserver01.dhe.duke.edu
[run_analysis] Database: omop_prod
[run_analysis] CDM     : cdm_omop_v54
[run_analysis] Results : scratch_abc123
[run_analysis] Window  : 90-day SSI

[run_analysis] Building connection details (Kerberos) ...
Java configured: /hpc/group/.../envs/openjdk
JDBC driver verified: drivers/mssql-jdbc-13.2.1.jre11.jar
Building connection: dbserver01.dhe.duke.edu / omop_prod (Kerberos SPN: MSSQLSvc/dbserver01.dhe.duke.edu)
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
Calculating person-level score components ...
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
PRCC file browser (OnDemand → Files → Home Directory → prcc_bundle →
output/risk_score_eval/) or use `scp`:

```bash
# From your local machine:
scp -r <your_netid>@prcc.dhe.duke.edu:~/prcc_bundle/output/risk_score_eval/ ./
```

**Files produced:**

| File | Description |
|------|-------------|
| `person_level_scores.csv` | Per-patient component points, total score, predicted probabilities, binary 90-day SSI outcome |
| `component_summary.csv` | Component-level activation counts and mean points across the cohort |
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

Enter your Duke NetID password when prompted, then re-run `Rscript run_analysis.R`.

To check whether your current ticket is still valid:

```bash
klist
```

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| `GSS initiate failed` / `Kerberos` error | Ticket expired | `export KRB5CCNAME=FILE:~/krb5cc_java && kinit` |
| `KDC not found` | Not on PRCC login node | Launch **RE Cluster Shell Access** from the PRCC dashboard |
| `Login failed for user` | Wrong `spn_host` | Check `spn_host` in config.R; open a DHTS ticket to confirm the correct SPN |
| `JAVA_HOME is not set` | conda env not active | `conda activate openjdk` then re-run |
| `No mssql-jdbc*.jar found` | drivers/ missing JAR | Re-transfer the bundle; confirm `drivers/mssql-jdbc-13.2.1.jre11.jar` exists |
| `fill in the following fields in config.R` | CHANGE_ME not replaced | Edit config.R and fill in all required values (Step 4) |
| `Run this script in a FRESH R session` | R session already had Java loaded | Open a new terminal, re-activate conda, re-run |
| `CREATE TABLE permission denied` | Insufficient DB permissions | Contact DHTS to request CREATE TABLE on `results_schema` |

---

## Risk Score Components

All 10 components are pre-mapped to OMOP standard concept IDs and require no
modification for a standard OMOP CDM v5.4 database:

| Component | Points | Concept(s) | Lookback |
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

- Java is provided by `conda-forge::openjdk` installed via the PRCC miniforge
  module — no system-level Java installation is required.
- The conda environment is named `openjdk` and is created once by
  `setup_prcc_env.sh`.
- JAVA_HOME is set automatically when you run `conda activate openjdk`; the
  `config.R` and `R/connection.R` files read this environment variable at
  runtime.
- The MSSQL JDBC driver (`drivers/mssql-jdbc-13.2.1.jre11.jar`) is included
  in the bundle — no internet access is required after initial R package
  installation.
- The JDBC connection uses `authenticationScheme=JavaKerberos` with
  `serverSpn=MSSQLSvc/<spn_host>` as described in the Duke PRCC SQL Server
  documentation.

---

## Missing Value Handling

When a component has no matching records in the OMOP CDM, its event count
defaults to 0 and it contributes 0 points to the total score. This treats
missing data as "no documented evidence" of the risk factor — appropriate
when CDM completeness is high. Review the `score_<component_id>` columns in
`person_level_scores.csv` to identify any components with zero activation
across the entire cohort (which may indicate a mapping or ETL issue rather
than true clinical absence).

---

## Getting Help

| Issue type | Contact |
|---|---|
| Risk score methodology, concept mappings, study design | Study coordinator |
| PRCC access, shell environment, file transfers | PRCC support portal |
| SQL Server access, Kerberos SPN, database permissions | DHTS Service Portal |
| R package installation failures | Check Duke CRAN mirror access; open a PRCC ticket |
