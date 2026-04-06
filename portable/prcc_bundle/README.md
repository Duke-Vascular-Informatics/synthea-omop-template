# PAD/OLER SSI Validation — Duke PRCC Bundle

External validation of the PAD SSI integer risk score against an institutional
OMOP CDM v5.4 SQL Server database on Duke PRCC (RE Cluster).

Authentication uses **Kerberos (NetID)** — no passwords are stored in any file.
Java is provided by the **conda openjdk** environment (no system Java needed).

---

## Bundle Contents

```
prcc_bundle/
  README.md                    ← this file
  config.R                     ← site settings (FILL IN before running)
  run_analysis.R               ← main entry point
  install_packages.R           ← R package installer
  setup_prcc_env.sh            ← environment setup (conda Java + kinit)
  R/
    connection.R               ← Kerberos JDBC connection builder
    drivers.R                  ← JDBC JAR verification
    risk_score_pipeline.R      ← integer risk score computation
    cohorts.R                  ← cohort SQL instantiation helpers
    report.R                   ← manuscript Word report generator
    cohort_demographics.R      ← Table 1 demographic query helpers
  risk_score/
    components.csv             ← score component definitions
    component_concepts.csv     ← OMOP concept ID mappings
    risk_lookup.csv            ← published score-to-risk lookup table
  cohorts/
    target_surgery.sql         ← target cohort (inpatient revascularisation)
    outcome_ssi.sql            ← outcome cohort (90-day SSI)
  drivers/
    mssql-jdbc-13.2.1.jre11.jar ← MSSQL JDBC driver (bundled, no download)
  output/
    risk_score_eval/           ← results written here at runtime
```

---

## Quick Start

### Step 1 — Transfer the bundle to PRCC

```bash
# From your local machine:
scp -r prcc_bundle/ <netid>@prcc.dhe.duke.edu:~/
```

Or copy via the PRCC file browser.

### Step 2 — Open a shell session

Log into **RE Cluster Shell Access** from the PRCC dashboard.

```bash
cd ~/prcc_bundle
```

### Step 3 — Run environment setup (first time + each new session)

```bash
bash setup_prcc_env.sh
```

This will:
- Create/activate the `openjdk` conda environment (first run ~2 min)
- Run `kinit` — enter your **Duke NetID password** when prompted
- Install all required R packages (first run ~5 min)

### Step 4 — Edit config.R

Open `config.R` and replace every `CHANGE_ME` value:

| Field | Description |
|---|---|
| `server` | SQL Server hostname (e.g. `dbserver01.dhe.duke.edu`) |
| `database` | Database name containing the OMOP CDM |
| `spn_host` | Kerberos SPN hostname — usually same as `server`; contact DHTS if unsure |
| `vocab_schema` | Schema with vocabulary tables (`concept`, `concept_ancestor`, etc.) |
| `cdm_schema` | Schema with CDM clinical tables (`person`, `visit_occurrence`, etc.) |
| `results_schema` | Schema where cohort table will be written (needs CREATE TABLE permission) |
| `cdm_database_id` | Short identifier string for output metadata |
| `cdm_database_name` | Display name for output metadata |

Optional: set `use_atlas_cohorts = TRUE` and provide `atlas_target_cohort_id` /
`atlas_outcome_cohort_id` if the target and outcome cohorts already exist in your
ATLAS results schema — this skips cohort SQL instantiation.

### Step 5 — Run the analysis

```bash
conda activate openjdk
Rscript run_analysis.R
```

Output is written to `output/risk_score_eval/`.

---

## Output Files

| File | Description |
|------|-------------|
| `person_level_scores.csv` | Per-patient component points, total score, predicted probabilities, binary outcome |
| `component_summary.csv` | Component-level n_positive and mean_points |
| `metrics.csv` | AUROC, AUPRC, Brier, ECE, calibration intercept/slope + 95% bootstrap CIs |
| `calibration_table_lookup.csv` | Calibration decile table (lookup model) |
| `calibration_table_recalibrated.csv` | Calibration decile table (recalibrated model) |
| `calibration_*.png` | Calibration plots |
| `pad-oler-ssi-val_report_<date>.docx` | Manuscript-format Word report |
| `pad_oler_ssi_fringe_<date>.xlsx` | Fringe-case QC workbook (false negatives + false positives) |

---

## Risk Score Components

All 10 components are pre-mapped to OMOP standard concept IDs:

| Component | Concept(s) | Notes |
|---|---|---|
| `female` | 8532 | Biological sex = Female |
| `overweight` | 3025315 (weight), 3036277 (height) | BMI 25–30 derived from measurements |
| `obese` | 3025315 (weight), 3036277 (height) | BMI ≥ 30 |
| `urgnt` | 4158569, 4250892 + descendants | Emergency or urgent procedure flag |
| `abi_35` | 40489833, 46237026 + descendants | Ankle-brachial index < 0.35 |
| `prrevasc_any` | 4159960 + descendants | Prior lower-extremity revascularisation (10-year lookback) |
| `prolong_abx` | 21603553 + descendants | Non-prophylactic antibiotic > 2 days (90-day lookback) |
| `optime4h` | procedure_occurrence timestamps | Operative time > 240 min |
| `mFI_high` | 201820, 255573, 316139, 316866 + functional status concepts | mFI ≥ 2/5 |
| `indicationClaudication` | 442774 + descendants | Claudication as indication (protective, −1 point) |

---

## Cohort Definitions

**Target cohort** (`cohorts/target_surgery.sql`):
- Adults ≥ 18 with an inpatient visit where open lower-extremity revascularisation
  was recorded (OMOP concept 4159960 and descendants)
- Index date = visit start date
- Exclusion: any SSI diagnosis (concept 4334801) in the 365 days before index

**Outcome cohort** (`cohorts/outcome_ssi.sql`):
- First SSI diagnosis (concept 4334801 and all descendants) within
  `prediction_window_days` (default 90) days of index

---

## Kerberos Troubleshooting

| Symptom | Fix |
|---|---|
| `GSS initiate failed` / `Kerberos` error | Run `kinit` — your ticket has expired |
| `KDC not found` | You may not be on a PRCC login node; launch RE Cluster Shell Access |
| `Login failed for user` | `spn_host` in config.R may be wrong — contact DHTS |
| `JAVA_HOME not set` | Run `conda activate openjdk` before starting R |
| `No mssql-jdbc*.jar found` | Re-unzip the bundle; drivers/ must contain the JAR |

Kerberos tickets expire after approximately 10 hours. To renew:
```bash
export KRB5CCNAME=FILE:~/krb5cc_java
kinit
```

---

## Java / Conda Notes

- Java is provided by `conda-forge::openjdk` via miniforge (PRCC module).
- No system-level Java installation is required.
- The `setup_prcc_env.sh` script creates a conda env named `openjdk` once.
- The JDBC driver (`drivers/mssql-jdbc-13.2.1.jre11.jar`) is bundled — no
  internet download required at runtime.

---

## Missing Value Handling

When a component has no matching records in the OMOP CDM, its event count is
set to 0 and it contributes 0 points to the total score. This treats missing
data as "no documented evidence" of the risk factor, appropriate when CDM
completeness is high. Review `person_level_scores.csv` (`score_<component_id>`
columns) to identify components with zero activation across the cohort.

---

## Contact

For questions about the risk score methodology or concept mappings, contact
the study coordinator. For PRCC access, Java/Kerberos issues, or SQL Server
permissions, open a ticket at the Duke DHTS Service Portal.
