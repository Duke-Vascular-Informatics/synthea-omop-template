#!/usr/bin/env bash
# =============================================================================
# workflow/09_build_portable_analysis_bundle.sh
#
# Step 9 — Build and publish the protected analytic space portable analysis bundle.
#
# PURPOSE
# -------
# Packages the study's analysis into a self-contained bundle for execution on
# the protected analytic space (Phoenix protected analytic space), then pushes
# it to a Git remote so the site can clone or pull it directly.
#
# A dated zip is also written to dist/ as a local fallback (useful if GitLab
# is unreachable from HPC cluster or for offline transfers via scp).
#
# PREREQUISITES
# -------------
# Set the following variables in OMOP_Dev/.env (one level above this repo):
#
#   BUNDLE_GITLAB_REMOTE   Full SSH URL of the target GitLab repo.
#                          e.g. git@your.gitlab.instance:netid/study-bundle.git
#   BUNDLE_GIT_USER_NAME   Your name for git commits inside the bundle repo.
#   BUNDLE_GIT_USER_EMAIL  Your institutional email for git commits.
#
#   INST_OMOP_SERVER              SQL Server hostname for the institutional OMOP DB.
#   INST_OMOP_DATABASE            Database name.
#   INST_OMOP_SPN_HOST            Kerberos SPN hostname (often same as server).
#   INST_OMOP_VOCAB_SCHEMA        Vocabulary schema.
#   INST_OMOP_CDM_SCHEMA          CDM schema.
#   INST_OMOP_RESULTS_SCHEMA      Personal write schema (domain\netid).
#   INST_OMOP_CDM_DATABASE_ID     Short DB identifier for output files.
#   INST_OMOP_CDM_DATABASE_NAME   Human-readable DB name for output files.
#   INST_OMOP_CDM_DATABASE_DESCRIPTION  Description for output files.
#
# SSH authentication: the dev container must have access to an SSH agent with
# your Git remote SSH key loaded.  Docker Desktop on macOS forwards the host
# agent automatically when SSH_AUTH_SOCK is set in devcontainer.json.
# Verify with: ssh -T git@your.gitlab.instance
#
# WHAT THIS SCRIPT DOES
# ---------------------
#   1. Syncs shared R source files from the main project into portable/$STUDY_NAME/
#      so the bundle always reflects the current analysis code.
#   2. Copies the MSSQL JDBC JAR from drivers/jdbc-runtime/ into the bundle.
#   3. Commits the updated bundle to the portable/$STUDY_NAME/.git repo and
#      pushes to the 'main' branch on your.gitlab.instance.
#   4. Builds a dated zip fallback in dist/ for offline transfers.
#
# FILES AUTO-SEEDED ON FIRST RUN (from setup/bundle_templates/, never overwritten)
# -------------------------------------------------------------------------
#   portable/$STUDY_NAME/setup_env.sh        Conda env + kinit setup (Step 1 of 2)
#   portable/$STUDY_NAME/install_r_packages.sh  R package installer wrapper (Step 2 of 2)
#   portable/$STUDY_NAME/install_packages.R  R package installer (called by above)
#   portable/$STUDY_NAME/run_analysis.sh     HPC launcher (sets LD_LIBRARY_PATH, sources .env)
#
# FILES NOT OVERWRITTEN (bundle-specific, must be committed manually)
# -------------------------------------------------------------------------
#   portable/$STUDY_NAME/config.R            HPC cluster SQL Server + conda paths
#   portable/$STUDY_NAME/run_analysis.R      HPC cluster entry-point R script
#   portable/$STUDY_NAME/R/connection.R      Kerberos / JVM setup for the protected analytic space
#
# DEPLOYMENT ON HPC cluster (after this script runs)
# -------------------------------------------
#   ssh <netid>@your.hpc.cluster.hostname
#   cd /path/to/your/workspace/
#   git clone --branch main git@your.gitlab.instance:<remote> <study-name>
#   # — or to pull updates into an existing clone: —
#   cd <study-name> && git pull origin main
#
#   # Place the your HPC support team custom JDBC wrapper one level above the bundle:
#   #   /path/to/your/workspace/drivers/hpc-jdbc-wrapper.jar
#   bash setup_env.sh
#   conda activate openjdk
#   export KRB5CCNAME=FILE:~/krb5cc_java && kinit
#   Rscript run_analysis.R
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# ---------------------------------------------------------------------------
# Load HPC cluster config from .env
# When run on the host Mac: .env is one level up (OMOP_Dev/.env)
# When run inside dev container: vars are already injected by docker-compose
# ---------------------------------------------------------------------------
ENV_FILE="$REPO_ROOT/../.env"
if [[ -f "$ENV_FILE" ]]; then
  # Export BUNDLE_* and INST_OMOP_* variables; eval handles quoted values
  while IFS= read -r line; do
    [[ "$line" =~ ^BUNDLE_|^INST_OMOP_ ]] && export "${line?}"
  done < "$ENV_FILE"
fi

BUNDLE_GITLAB_REMOTE="${BUNDLE_GITLAB_REMOTE:-}"
BUNDLE_GIT_USER_NAME="${BUNDLE_GIT_USER_NAME:-}"
BUNDLE_GIT_USER_EMAIL="${BUNDLE_GIT_USER_EMAIL:-}"
BUNDLE_BRANCH="main"

# Derive the bundle folder name from study_name in study_params.yaml so that
# each study's portable folder is named after the analysis (e.g. my-study).
# Falls back to "transportable_bundle" if study_params.yaml is not yet configured.
STUDY_NAME=$(grep '^study_name:' "$REPO_ROOT/study_params.yaml" 2>/dev/null \
  | sed 's/.*study_name:[[:space:]]*//' \
  | tr -d '"'"'"' ' \
  | tr -d '\r')
STUDY_NAME="${STUDY_NAME:-transportable_bundle}"

# ---------------------------------------------------------------------------
# Validate config
# ---------------------------------------------------------------------------
if [[ -z "$BUNDLE_GITLAB_REMOTE" || "$BUNDLE_GITLAB_REMOTE" == *"CHANGE_ME"* ]]; then
  echo "[Step 9] ERROR: BUNDLE_GITLAB_REMOTE is not set or still contains CHANGE_ME."
  echo "         Edit OMOP_Dev/.env and set BUNDLE_GITLAB_REMOTE to the full SSH URL."
  echo "         Example: git@your.gitlab.instance:netid/your-study-bundle.git"
  exit 1
fi

BUNDLE="$REPO_ROOT/portable/$STUDY_NAME"
DIST="$REPO_ROOT/dist"

if [[ ! -d "$BUNDLE" ]]; then
  echo "[Step 9] ERROR: portable bundle directory not found: $BUNDLE"
  exit 1
fi

mkdir -p "$DIST"

# ---------------------------------------------------------------------------
# generate_bundle_readme — writes README.md to the bundle from study_params.yaml
# ---------------------------------------------------------------------------
generate_bundle_readme() {
  local dest="$1"
  local yaml="$REPO_ROOT/study_params.yaml"

  local sname pred_window study_design outcome_label
  sname=$(grep '^study_name:' "$yaml" \
    | sed 's/.*study_name:[[:space:]]*//' | cut -d'#' -f1 \
    | tr -d '"'"'"' ' | tr -d '\r')
  pred_window=$(grep '^prediction_window_days:' "$yaml" | grep -oE '[0-9]+' | head -1)
  pred_window="${pred_window:-30}"
  study_design=$(grep '^study_design:' "$yaml" \
    | sed 's/.*study_design:[[:space:]]*//' | cut -d'#' -f1 \
    | tr -d '"'"'"' ' | tr -d '\r')
  # outcome_label is nested under report: in study_params.yaml; grab the first match
  outcome_label=$(grep 'outcome_label:' "$yaml" \
    | sed 's/.*outcome_label:[[:space:]]*//' | cut -d'#' -f1 \
    | tr -d '"' | tr -d "'" | tr -d '\r' | head -1)
  outcome_label="${outcome_label:-outcome}"

  local plp int_score char_flag word_rpt
  plp=$(grep 'plp_model_validation:'   "$yaml" | grep -ioE 'true|false' | head -1 | tr A-Z a-z)
  int_score=$(grep '^\s*integer_risk_score:' "$yaml" | grep -ioE 'true|false' | head -1 | tr A-Z a-z)
  char_flag=$(grep 'cohort_characterization:' "$yaml" | grep -ioE 'true|false' | head -1 | tr A-Z a-z)
  word_rpt=$(grep 'word_report:' "$yaml" | grep -ioE 'true|false' | head -1 | tr A-Z a-z)

  local analysis_desc
  if   [[ "$plp"       == "true" ]]; then
    analysis_desc="External validation of a PatientLevelPrediction (PLP) model predicting ${pred_window}-day ${outcome_label}."
  elif [[ "$int_score" == "true" ]]; then
    analysis_desc="External validation of an integer risk score predicting ${pred_window}-day ${outcome_label}."
  elif [[ "$char_flag" == "true" ]]; then
    analysis_desc="Cohort characterization — FeatureExtraction covariate summary of the target cohort."
  else
    analysis_desc="OMOP observational study (${study_design})."
  fi

  cat > "$dest/README.md" << EOF
# ${sname} — Protected Analytic Space Bundle

${analysis_desc}

**Generated:** $(date +%Y-%m-%d) by \`workflow/09_build_portable_analysis_bundle.sh\`

**Authentication:** Kerberos (institutional NetID) — no passwords stored in any file.
**Java:** conda openjdk from miniforge — no system Java required.
**JDBC driver:** pre-bundled in \`drivers/\` — no internet access needed after setup.

---

## Getting Started

**First time setup (run once):**

1. Create the project folder on the HPC login node:
   \`\`\`bash
   mkdir ~/${sname}
   \`\`\`
2. Open that folder in VS Code via the Remote SSH extension.
3. In the VS Code terminal (which opens inside \`~/${sname}\`), clone the repository into the current directory:
   \`\`\`bash
   git clone ${BUNDLE_GITLAB_REMOTE} .
   \`\`\`

**To update an existing clone:**

\`\`\`bash
git pull origin main
\`\`\`

---

## Quick Start

\`\`\`bash
# One-time setup (after cloning)
bash setup_env.sh             # creates conda env, runs kinit, installs R packages
# Edit .env — set OMOP_RESULTS_SCHEMA to your personal write schema (domain\netid)

# Every session
export KRB5CCNAME=FILE:~/krb5cc_java
kinit                      # enter institutional credentials when prompted
conda activate openjdk
bash run_analysis.sh
\`\`\`

Results are written to \`output/\`.

---

## .env — Configuration

Connection details are pre-populated from the study coordinator's workspace.
**You only need to update \`OMOP_RESULTS_SCHEMA\`** if you need to write to a
different schema than the pre-filled value (format: \`domain\\netid\`).

| Field | Description |
|-------|-------------|
| \`OMOP_SERVER\` | SQL Server hostname (pre-filled) |
| \`OMOP_DATABASE\` | Database containing the OMOP CDM (pre-filled) |
| \`OMOP_SPN_HOST\` | Kerberos SPN hostname (pre-filled) |
| \`OMOP_VOCAB_SCHEMA\` | Schema with vocabulary tables (pre-filled) |
| \`OMOP_CDM_SCHEMA\` | Schema with CDM clinical tables (pre-filled) |
| \`OMOP_RESULTS_SCHEMA\` | Write schema — pre-filled; change only if running as a different user |

---

## Output Files

EOF

  if [[ "$plp" == "true" ]]; then
    cat >> "$dest/README.md" << EOF
| File | Description |
|------|-------------|
| \`person_level_scores.csv\` | Per-patient predicted probabilities, observed outcomes, and prediction window flags |
| \`risk_score_eval/person_level_scores.csv\` | Copy used by the report module |
| \`risk_score_eval/covariate_summary.csv\` | Per-covariate activation rates across the validation cohort |
| \`risk_score_eval/metrics.csv\` | AUROC, AUPRC, Brier score, ECE, calibration intercept and slope with 95% bootstrap CIs |
| \`risk_score_eval/ece_subgroup.csv\` | Expected Calibration Error by demographic subgroup |
| \`roc_curve.png\` | ROC curve |
| \`calibration_lookup.png\` | Calibration plot |
EOF
    if [[ "$word_rpt" == "true" ]]; then
      printf '| `%s_report_<date>.docx` | Manuscript-format Word report with performance tables and calibration figures |\n' \
        "$sname" >> "$dest/README.md"
    fi
  elif [[ "$int_score" == "true" ]]; then
    cat >> "$dest/README.md" << EOF
| File | Description |
|------|-------------|
| \`person_level_scores.csv\` | Per-patient covariate points, total score, and predicted probabilities |
| \`risk_score_eval/covariate_summary.csv\` | Covariate-level activation counts and mean points |
| \`risk_score_eval/metrics.csv\` | AUROC, AUPRC, Brier score, ECE, calibration metrics with 95% CIs |
| \`risk_score_eval/calibration_table_lookup.csv\` | Calibration decile table — published lookup model |
| \`risk_score_eval/calibration_table_recalibrated.csv\` | Calibration decile table — recalibrated model |
| \`calibration_lookup.png\` | Calibration plot — lookup model |
| \`calibration_recalibrated.png\` | Calibration plot — recalibrated model |
EOF
    if [[ "$word_rpt" == "true" ]]; then
      printf '| `%s_report_<date>.docx` | Manuscript-format Word report with Tables 1–4, ROC curve, and calibration figures |\n' \
        "$sname" >> "$dest/README.md"
    fi
  else
    echo "See \`output/\` directory for analysis outputs." >> "$dest/README.md"
  fi

  cat >> "$dest/README.md" << 'STATIC_EOF'

---

## Renewing a Kerberos Ticket

Kerberos tickets expire after ~10 hours. On `GSS initiate failed` or `Login failed`:

```bash
export KRB5CCNAME=FILE:~/krb5cc_java
kinit
```

Then re-run `bash run_analysis.sh`.

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---------|-------------|-----|
| `GSS initiate failed` / Kerberos error | Ticket expired | `export KRB5CCNAME=FILE:~/krb5cc_java && kinit` |
| `KDC not found` | Not on HPC login node | Launch shell via cluster portal |
| `Login failed for user` | Wrong `spn_host` | Check `OMOP_SPN_HOST` in `.env`; ask HPC support |
| `JAVA_HOME is not set` | conda env not active | `conda activate openjdk` then re-run |
| `No mssql-jdbc*.jar found` | Missing JAR in drivers/ | Re-transfer bundle; confirm `drivers/mssql-jdbc-*.jre11.jar` exists |
| `fill in the following fields in config.R` | `OMOP_RESULTS_SCHEMA` still placeholder | Edit `.env` |
| `Run this script in a FRESH R session` | Java already loaded | Open new terminal, re-activate conda, re-run |
| `CREATE TABLE permission denied` | Insufficient DB permissions | Ask HPC support for CREATE TABLE on `results_schema` |
STATIC_EOF

  echo "  README.md generated from study_params.yaml"
}

# ---------------------------------------------------------------------------
# generate_bundle_env — writes .env to the bundle with institution-specific
# OMOP connection details sourced from the workspace .env (INST_OMOP_* vars).
#
# Each value is single-quoted so that backslashes in schema names
# (e.g. OMOP_RESULTS_SCHEMA='dhe\apj20') are preserved literally when the
# file is sourced by run_analysis.sh with set -o allexport.
# ---------------------------------------------------------------------------
generate_bundle_env() {
  local dest="$1"

  if [[ -z "${INST_OMOP_SERVER:-}" ]]; then
    echo "  [WARN] INST_OMOP_SERVER not set in .env — .env will contain placeholders."
    echo "         Add INST_OMOP_* variables to OMOP_Dev/.env and re-run step 9."
  fi

  cat > "$dest/.env" << 'ENVHEADER'
# =============================================================================
# .env — Site-specific OMOP connection for the portable analysis bundle.
#
# Generated by workflow/09_build_portable_analysis_bundle.sh from the
# workspace .env (INST_OMOP_* variables).
#
# All connection values are pre-populated by the study coordinator.
# Only change OMOP_RESULTS_SCHEMA if you need to write to a different schema
# (e.g. you are a collaborator with a different domain\netid write schema).
# =============================================================================

# SQL Server connection
ENVHEADER

  printf "OMOP_SERVER='%s'\n"                   "${INST_OMOP_SERVER:-YOUR_SERVER.example.com}"           >> "$dest/.env"
  printf "OMOP_DATABASE='%s'\n"                 "${INST_OMOP_DATABASE:-YOUR_DATABASE}"                   >> "$dest/.env"
  printf "OMOP_SPN_HOST='%s'\n\n"               "${INST_OMOP_SPN_HOST:-YOUR_SPN_HOST}"                   >> "$dest/.env"
  printf "# Schema names\n"                                                                               >> "$dest/.env"
  printf "OMOP_VOCAB_SCHEMA='%s'\n"             "${INST_OMOP_VOCAB_SCHEMA:-omop_vocab}"                  >> "$dest/.env"
  printf "OMOP_CDM_SCHEMA='%s'\n\n"             "${INST_OMOP_CDM_SCHEMA:-omop_cdm}"                      >> "$dest/.env"
  printf "# Personal write schema — pre-filled; change only if running as a different user\n" >> "$dest/.env"
  printf "OMOP_RESULTS_SCHEMA='%s'\n\n"         "${INST_OMOP_RESULTS_SCHEMA:-your_results_schema}"       >> "$dest/.env"
  printf "# Database metadata (written into output files)\n"                                              >> "$dest/.env"
  printf "OMOP_CDM_DATABASE_ID='%s'\n"          "${INST_OMOP_CDM_DATABASE_ID:-your_cdm_v5.4}"            >> "$dest/.env"
  printf "OMOP_CDM_DATABASE_NAME='%s'\n"        "${INST_OMOP_CDM_DATABASE_NAME:-Your Institution OMOP CDM}" >> "$dest/.env"
  printf "OMOP_CDM_DATABASE_DESCRIPTION='%s'\n" \
    "${INST_OMOP_CDM_DATABASE_DESCRIPTION:-Brief description of the patient population and database.}"   >> "$dest/.env"

  echo "  .env written with site-specific OMOP connection details"
}

# ---------------------------------------------------------------------------
# seed_bundle_hpc_scripts — seeds HPC launcher scripts into the bundle on
# first run (only when the file does not already exist).
#
# Each script is copied from setup/bundle_templates/ and the placeholder
# __STUDY_LABEL__ is substituted with $STUDY_NAME so banners and headers
# identify the study. Existing files are never overwritten so site-specific
# customisations (e.g. custom module names, conda env paths) are preserved.
# ---------------------------------------------------------------------------
seed_bundle_hpc_scripts() {
  local dest="$1"
  local label="$2"
  local templates="$REPO_ROOT/setup/bundle_templates"

  if [[ ! -d "$templates" ]]; then
    echo "  [WARN] setup/bundle_templates/ not found — skipping HPC script seeding."
    echo "         Add the templates directory or seed scripts manually."
    return
  fi

  local scripts=("setup_env.sh" "install_r_packages.sh" "install_packages.R" "run_analysis.sh")
  for script in "${scripts[@]}"; do
    local src="$templates/$script"
    local dst="$dest/$script"
    if [[ ! -f "$src" ]]; then
      echo "  [WARN] Template not found, skipping: setup/bundle_templates/$script"
      continue
    fi
    if [[ -f "$dst" ]]; then
      echo "  [SKIP] Already exists (not overwritten): $script"
    else
      sed "s/__STUDY_LABEL__/${label}/g" "$src" > "$dst"
      chmod +x "$dst" 2>/dev/null || true
      echo "  [SEED] $script"
    fi
  done
}

# ---------------------------------------------------------------------------
# Step 1 — Sync shared R source files into the bundle
# ---------------------------------------------------------------------------
echo "[Step 9] Syncing R source files ..."

copy_bundle_file() {
  local src="$REPO_ROOT/$1"
  local dst="$REPO_ROOT/$2"
  if [[ ! -f "$src" ]]; then
    echo "  [WARN] Not found, skipping: $1"
    return
  fi
  mkdir -p "$(dirname "$dst")"
  cp -f "$src" "$dst"
  echo "  $1 -> $2"
}

# Shared R analysis modules
copy_bundle_file "R/drivers.R"               "portable/$STUDY_NAME/R/drivers.R"
copy_bundle_file "R/connection.R"            "portable/$STUDY_NAME/R/connection.R"
copy_bundle_file "R/cohorts.R"               "portable/$STUDY_NAME/R/cohorts.R"
copy_bundle_file "R/cohort_demographics.R"   "portable/$STUDY_NAME/R/cohort_demographics.R"
copy_bundle_file "R/risk_score_pipeline.R"   "portable/$STUDY_NAME/R/risk_score_pipeline.R"
# report_extended.R is loaded as report.R on the protected analytic space (see run_analysis.R)
copy_bundle_file "R/report_extended.R"       "portable/$STUDY_NAME/R/report.R"
# report_helpers.R and report_prognostic.R are sourced by report_extended.R at runtime;
# they must travel with the bundle or the analysis will halt with "No such file or directory".
copy_bundle_file "R/report_helpers.R"        "portable/$STUDY_NAME/R/report_helpers.R"
copy_bundle_file "R/report_prognostic.R"     "portable/$STUDY_NAME/R/report_prognostic.R"

# Integer risk score reference data — copy all CSVs from risk_score/ so the
# correct files are included regardless of study-specific naming conventions
# (e.g. components.csv vs covariates.csv, component_concepts.csv vs covariate_concepts.csv).
for _csv in "$REPO_ROOT/risk_score/"*.csv; do
  [[ -f "$_csv" ]] && copy_bundle_file "risk_score/$(basename "$_csv")" \
    "portable/$STUDY_NAME/risk_score/$(basename "$_csv")"
done

# Model artifacts — copy all .rds and .json files from model/ when present.
# These are needed for the Word report (varImp.rds, modelSettings.rds,
# hyperParamSearch.rds, populationSettings.rds). Subdirectories (e.g.
# python_model/) are skipped; only top-level files are included.
if [[ -d "$REPO_ROOT/model" ]]; then
  for _mf in "$REPO_ROOT/model/"*.rds "$REPO_ROOT/model/"*.json; do
    [[ -f "$_mf" ]] && copy_bundle_file "model/$(basename "$_mf")" \
      "portable/$STUDY_NAME/model/$(basename "$_mf")"
  done
fi

# OMOP cohort SQL templates — copy all .sql files from cohorts/ so the correct
# files are included regardless of study-specific naming conventions.
for _sql in "$REPO_ROOT/cohorts/"*.sql; do
  [[ -f "$_sql" ]] && copy_bundle_file "cohorts/$(basename "$_sql")" \
    "portable/$STUDY_NAME/cohorts/$(basename "$_sql")"
done

# Generate README from study_params.yaml — overwrites any previous README
echo "[Step 9] Generating bundle README ..."
generate_bundle_readme "$BUNDLE"

# Generate .env with institution-specific OMOP connection details from INST_OMOP_*
echo "[Step 9] Generating bundle .env from INST_OMOP_* ..."
generate_bundle_env "$BUNDLE"

# Seed HPC launcher scripts on first run (skips any that already exist)
echo "[Step 9] Seeding HPC launcher scripts ..."
seed_bundle_hpc_scripts "$BUNDLE" "$STUDY_NAME"

# ---------------------------------------------------------------------------
# Step 2 — Sync MSSQL JDBC JAR into bundle/drivers/
# ---------------------------------------------------------------------------
echo "[Step 9] Syncing JDBC JAR ..."

JDBC_JAR=$(find "$REPO_ROOT/drivers/jdbc-runtime" -name "mssql-jdbc-*.jre11.jar" 2>/dev/null | head -1)
if [[ -z "$JDBC_JAR" ]]; then
  echo "  [WARN] JDBC JAR not found in drivers/jdbc-runtime/ — skipping."
else
  mkdir -p "$BUNDLE/drivers"
  cp -f "$JDBC_JAR" "$BUNDLE/drivers/"
  echo "  $(basename "$JDBC_JAR") -> portable/$STUDY_NAME/drivers/"
fi

# ---------------------------------------------------------------------------
# Step 3 — Commit and push to GitLab (main branch)
# ---------------------------------------------------------------------------
echo "[Step 9] Pushing bundle to GitLab ($BUNDLE_GITLAB_REMOTE, branch: $BUNDLE_BRANCH) ..."

# Verify SSH access before attempting push
echo "  Checking SSH connectivity to GitLab ..."
if ! ssh -o BatchMode=yes -o ConnectTimeout=10 \
        -o StrictHostKeyChecking=accept-new \
        "$(echo "$BUNDLE_GITLAB_REMOTE" | sed 's|git@\([^:]*\):.*|\1|')" \
        2>&1 | grep -qiE 'welcome|authenticated|gitlab'; then
  echo "  [WARN] SSH connectivity check was inconclusive — proceeding anyway."
  echo "         If the push fails, run: ssh -T git@your.gitlab.instance"
fi

cd "$BUNDLE"

# Initialise git repo inside the bundle on first run
if [[ ! -d ".git" ]]; then
  echo "  Initialising git repo in portable/$STUDY_NAME/ ..."
  git init -b "$BUNDLE_BRANCH"
  git remote add origin "$BUNDLE_GITLAB_REMOTE"
else
  # Ensure remote is set to the configured URL (update if it changed)
  if git remote get-url origin &>/dev/null; then
    git remote set-url origin "$BUNDLE_GITLAB_REMOTE"
  else
    git remote add origin "$BUNDLE_GITLAB_REMOTE"
  fi
  # Switch to / create the target branch (BUNDLE_BRANCH) if not already on it
  if ! git rev-parse --verify "$BUNDLE_BRANCH" &>/dev/null; then
    git checkout -b "$BUNDLE_BRANCH"
  else
    git checkout "$BUNDLE_BRANCH"
  fi
fi

# Set git identity for bundle commits (uses .env values or falls back to global)
if [[ -n "$BUNDLE_GIT_USER_NAME" && "$BUNDLE_GIT_USER_NAME" != "CHANGE_ME" ]]; then
  git config user.name  "$BUNDLE_GIT_USER_NAME"
  git config user.email "$BUNDLE_GIT_USER_EMAIL"
fi

# Ensure output/ is gitignored inside the bundle (the bundle writes results there at runtime)
if ! grep -qx "output/" .gitignore 2>/dev/null; then
  echo "output/" >> .gitignore
fi

# Stage all changes
git add -A

# Commit only if there are staged changes
COMMIT_MSG="chore: sync analysis bundle $(date -u +%Y-%m-%dT%H:%M:%SZ)"
if git diff --cached --quiet; then
  echo "  No changes to commit — bundle is already up to date."
else
  git commit -m "$COMMIT_MSG"
  echo "  Committed: $COMMIT_MSG"
fi

# Push to remote (--force-with-lease is safer than --force: rejects if remote
# has commits we haven't seen, preventing accidental overwrites)
if git push --force-with-lease origin "$BUNDLE_BRANCH" 2>&1; then
  echo "  [OK] Pushed to $BUNDLE_GITLAB_REMOTE ($BUNDLE_BRANCH)"
else
  # First push to a new remote requires --set-upstream; retry with it
  echo "  Retrying with --set-upstream (first push to new remote) ..."
  git push --set-upstream origin "$BUNDLE_BRANCH"
  echo "  [OK] Pushed (with --set-upstream) to $BUNDLE_GITLAB_REMOTE ($BUNDLE_BRANCH)"
fi

cd "$REPO_ROOT"

# ---------------------------------------------------------------------------
# Step 4 — Build dated zip fallback in dist/
# ---------------------------------------------------------------------------
echo "[Step 9] Building zip fallback ..."

STAMP=$(date +"%Y%m%d")
BASE="${STUDY_NAME}_${STAMP}"

# Find the next available filename for today (STUDY_NAME_YYYYMMDD.zip,
# then _1.zip, _2.zip, ... if multiple builds are made on the same day)
EXISTING_COUNT=$(find "$DIST" -name "${BASE}*.zip" 2>/dev/null | wc -l | tr -d ' ')
if [[ "$EXISTING_COUNT" -eq 0 ]]; then
  ZIP_NAME="${BASE}.zip"
else
  ZIP_NAME="${BASE}_${EXISTING_COUNT}.zip"
fi
ZIP_PATH="$DIST/$ZIP_NAME"

# Zip everything under portable/$STUDY_NAME/ except output/ (created at runtime)
(
  cd "$BUNDLE"
  find . -mindepth 1 \
         ! -path "./output*" \
         ! -path "./.git*" \
    | sort \
    | zip -q "$ZIP_PATH" -@
)

SIZE_MB=$(du -sm "$ZIP_PATH" | cut -f1)
echo ""
echo "[Step 9] GitLab push : $BUNDLE_GITLAB_REMOTE (branch: $BUNDLE_BRANCH)"
echo "[Step 9] Zip fallback: $ZIP_PATH (${SIZE_MB} MB)"
echo ""
echo "Step 9 complete."
echo ""
echo "To deploy on the protected analytic space:"
echo "  git clone --branch $BUNDLE_BRANCH $BUNDLE_GITLAB_REMOTE $STUDY_NAME"
echo "  # or to update an existing clone:"
echo "  cd $STUDY_NAME && git pull origin $BUNDLE_BRANCH"
