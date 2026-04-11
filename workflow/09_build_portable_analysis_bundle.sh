#!/usr/bin/env bash
# =============================================================================
# workflow/09_build_portable_analysis_bundle.sh
#
# Step 9 — Build and publish the Duke PRCC portable analysis bundle.
#
# PURPOSE
# -------
# Packages the PAD/OLER SSI integer risk score external validation analysis
# into a self-contained bundle for execution on the Duke PRCC (Phoenix
# Research Computing Cluster), then pushes it to a GitLab remote so PRCC
# can clone or pull it directly.
#
# A dated zip is also written to dist/ as a local fallback (useful if GitLab
# is unreachable from PRCC or for offline transfers via scp).
#
# PREREQUISITES
# -------------
# Set the following variables in OMOP_Dev/.env (one level above this repo):
#
#   PRCC_GITLAB_REMOTE   Full SSH URL of the target GitLab repo.
#                        e.g. git@gitlab.dhe.duke.edu:netid/pad-oler-ssi-prcc.git
#   PRCC_GIT_USER_NAME   Your name for git commits inside the bundle repo.
#   PRCC_GIT_USER_EMAIL  Your Duke email for git commits.
#
# SSH authentication: the dev container must have access to an SSH agent with
# your Duke GitLab key loaded.  Docker Desktop on macOS forwards the host
# agent automatically when SSH_AUTH_SOCK is set in devcontainer.json.
# Verify with: ssh -T git@gitlab.dhe.duke.edu
#
# WHAT THIS SCRIPT DOES
# ---------------------
#   1. Syncs shared R source files from the main project into portable/prcc_bundle/
#      so the bundle always reflects the current analysis code.
#   2. Copies the MSSQL JDBC JAR from drivers/jdbc-runtime/ into the bundle.
#   3. Commits the updated bundle to the portable/prcc_bundle/.git repo and
#      pushes to the 'prcc-bundle' branch on gitlab.dhe.duke.edu.
#   4. Builds a dated zip fallback in dist/ for offline transfers.
#
# FILES NOT OVERWRITTEN (PRCC-specific, checked into portable/prcc_bundle/)
# -------------------------------------------------------------------------
#   portable/prcc_bundle/R/connection.R      Kerberos / JVM setup for PRCC
#   portable/prcc_bundle/config.R            PRCC SQL Server + conda paths
#   portable/prcc_bundle/run_analysis.R      PRCC entry-point script
#   portable/prcc_bundle/install_packages.R  PRCC conda R package installer
#   portable/prcc_bundle/setup_prcc_env.sh   Conda env + kinit helper
#
# DEPLOYMENT ON PRCC (after this script runs)
# -------------------------------------------
#   ssh <netid>@login.rc.duke.edu
#   cd /data/pro00119168/
#   git clone --branch prcc-bundle git@gitlab.dhe.duke.edu:<remote> pad-oler-ssi-prcc
#   # — or to pull updates into an existing clone: —
#   cd pad-oler-ssi-prcc && git pull origin prcc-bundle
#
#   # Place the Duke SOM-HPC custom JDBC wrapper one level above the bundle:
#   #   /data/pro00119168/drivers/prcc-jdbc-mssql-1.0-SNAPSHOT.jar
#   bash setup_prcc_env.sh
#   conda activate openjdk
#   export KRB5CCNAME=FILE:~/krb5cc_java && kinit
#   Rscript run_analysis.R
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# ---------------------------------------------------------------------------
# Load PRCC config from .env
# When run on the host Mac: .env is one level up (OMOP_Dev/.env)
# When run inside dev container: vars are already injected by docker-compose
# ---------------------------------------------------------------------------
ENV_FILE="$REPO_ROOT/../.env"
if [[ -f "$ENV_FILE" ]]; then
  # Export only the PRCC_ variables; eval handles quoted values with spaces
  while IFS= read -r line; do
    [[ "$line" =~ ^PRCC_ ]] && export "${line?}"
  done < "$ENV_FILE"
fi

PRCC_GITLAB_REMOTE="${PRCC_GITLAB_REMOTE:-}"
PRCC_GIT_USER_NAME="${PRCC_GIT_USER_NAME:-}"
PRCC_GIT_USER_EMAIL="${PRCC_GIT_USER_EMAIL:-}"
PRCC_BRANCH="prcc-bundle"

# ---------------------------------------------------------------------------
# Validate config
# ---------------------------------------------------------------------------
if [[ -z "$PRCC_GITLAB_REMOTE" || "$PRCC_GITLAB_REMOTE" == *"CHANGE_ME"* ]]; then
  echo "[Step 9] ERROR: PRCC_GITLAB_REMOTE is not set or still contains CHANGE_ME."
  echo "         Edit OMOP_Dev/.env and set PRCC_GITLAB_REMOTE to the full SSH URL."
  echo "         Example: git@gitlab.dhe.duke.edu:netid/pad-oler-ssi-prcc.git"
  exit 1
fi

BUNDLE="$REPO_ROOT/portable/prcc_bundle"
DIST="$REPO_ROOT/dist"

if [[ ! -d "$BUNDLE" ]]; then
  echo "[Step 9] ERROR: PRCC bundle directory not found: $BUNDLE"
  exit 1
fi

mkdir -p "$DIST"

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
copy_bundle_file "R/risk_score_pipeline.R"   "portable/prcc_bundle/R/risk_score_pipeline.R"
copy_bundle_file "R/cohorts.R"               "portable/prcc_bundle/R/cohorts.R"
copy_bundle_file "R/cohort_demographics.R"   "portable/prcc_bundle/R/cohort_demographics.R"
# report_extended.R is loaded as report.R on PRCC (see run_analysis.R)
copy_bundle_file "R/report_extended.R"       "portable/prcc_bundle/R/report.R"

# Integer risk score reference data
copy_bundle_file "risk_score/components.csv"         "portable/prcc_bundle/risk_score/components.csv"
copy_bundle_file "risk_score/component_concepts.csv" "portable/prcc_bundle/risk_score/component_concepts.csv"
copy_bundle_file "risk_score/risk_lookup.csv"        "portable/prcc_bundle/risk_score/risk_lookup.csv"

# OMOP cohort SQL templates
copy_bundle_file "cohorts/target_surgery.sql"  "portable/prcc_bundle/cohorts/target_surgery.sql"
copy_bundle_file "cohorts/outcome_ssi.sql"     "portable/prcc_bundle/cohorts/outcome_ssi.sql"

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
  echo "  $(basename "$JDBC_JAR") -> portable/prcc_bundle/drivers/"
fi

# ---------------------------------------------------------------------------
# Step 3 — Commit and push to GitLab (prcc-bundle branch)
# ---------------------------------------------------------------------------
echo "[Step 9] Pushing bundle to GitLab ($PRCC_GITLAB_REMOTE, branch: $PRCC_BRANCH) ..."

# Verify SSH access before attempting push
echo "  Checking SSH connectivity to GitLab ..."
if ! ssh -o BatchMode=yes -o ConnectTimeout=10 \
        -o StrictHostKeyChecking=accept-new \
        "$(echo "$PRCC_GITLAB_REMOTE" | sed 's|git@\([^:]*\):.*|\1|')" \
        2>&1 | grep -qiE 'welcome|authenticated|gitlab'; then
  echo "  [WARN] SSH connectivity check was inconclusive — proceeding anyway."
  echo "         If the push fails, run: ssh -T git@gitlab.dhe.duke.edu"
fi

cd "$BUNDLE"

# Initialise git repo inside the bundle on first run
if [[ ! -d ".git" ]]; then
  echo "  Initialising git repo in portable/prcc_bundle/ ..."
  git init -b "$PRCC_BRANCH"
  git remote add origin "$PRCC_GITLAB_REMOTE"
else
  # Ensure remote is set to the configured URL (update if it changed)
  if git remote get-url origin &>/dev/null; then
    git remote set-url origin "$PRCC_GITLAB_REMOTE"
  else
    git remote add origin "$PRCC_GITLAB_REMOTE"
  fi
  # Switch to / create the prcc-bundle branch if not already on it
  if ! git rev-parse --verify "$PRCC_BRANCH" &>/dev/null; then
    git checkout -b "$PRCC_BRANCH"
  else
    git checkout "$PRCC_BRANCH"
  fi
fi

# Set git identity for bundle commits (uses .env values or falls back to global)
if [[ -n "$PRCC_GIT_USER_NAME" && "$PRCC_GIT_USER_NAME" != "CHANGE_ME" ]]; then
  git config user.name  "$PRCC_GIT_USER_NAME"
  git config user.email "$PRCC_GIT_USER_EMAIL"
fi

# Ensure output/ is gitignored inside the bundle (PRCC writes results there at runtime)
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
if git push --force-with-lease origin "$PRCC_BRANCH" 2>&1; then
  echo "  [OK] Pushed to $PRCC_GITLAB_REMOTE ($PRCC_BRANCH)"
else
  # First push to a new remote requires --set-upstream; retry with it
  echo "  Retrying with --set-upstream (first push to new remote) ..."
  git push --set-upstream origin "$PRCC_BRANCH"
  echo "  [OK] Pushed (with --set-upstream) to $PRCC_GITLAB_REMOTE ($PRCC_BRANCH)"
fi

cd "$REPO_ROOT"

# ---------------------------------------------------------------------------
# Step 4 — Build dated zip fallback in dist/
# ---------------------------------------------------------------------------
echo "[Step 9] Building zip fallback ..."

STAMP=$(date +"%Y%m%d")
BASE="pad_oler_ssi_val_prcc_${STAMP}"

# Find the next available filename for today (pad_oler_ssi_val_prcc_YYYYMMDD.zip,
# then _1.zip, _2.zip, ... if multiple builds are made on the same day)
EXISTING_COUNT=$(find "$DIST" -name "${BASE}*.zip" 2>/dev/null | wc -l | tr -d ' ')
if [[ "$EXISTING_COUNT" -eq 0 ]]; then
  ZIP_NAME="${BASE}.zip"
else
  ZIP_NAME="${BASE}_${EXISTING_COUNT}.zip"
fi
ZIP_PATH="$DIST/$ZIP_NAME"

# Zip everything under portable/prcc_bundle/ except output/ (created at runtime)
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
echo "[Step 9] GitLab push : $PRCC_GITLAB_REMOTE (branch: $PRCC_BRANCH)"
echo "[Step 9] Zip fallback: $ZIP_PATH (${SIZE_MB} MB)"
echo ""
echo "Step 9 complete."
echo ""
echo "To deploy on PRCC:"
echo "  git clone --branch $PRCC_BRANCH $PRCC_GITLAB_REMOTE pad-oler-ssi-prcc"
echo "  # or to update an existing clone:"
echo "  cd pad-oler-ssi-prcc && git pull origin $PRCC_BRANCH"
