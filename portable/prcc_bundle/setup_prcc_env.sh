#!/usr/bin/env bash
# =============================================================================
# setup_prcc_env.sh
#
# One-time (per session) environment setup for the PAD/OLER SSI validation
# bundle on Duke PRCC.
#
# Run this from the RE Cluster Shell Access terminal BEFORE starting R.
# After running this script, activate the conda environment and then launch R:
#
#   bash setup_prcc_env.sh
#   conda activate openjdk
#   Rscript run_analysis.R
#
# What this script does:
#   1. Loads the miniforge module and creates the openjdk conda env (first run
#      only; subsequent runs skip creation).
#   2. Obtains a Kerberos ticket via `kinit` using your Duke NetID password.
#      The ticket is stored at ~/krb5cc_java and is valid for ~10 hours.
#      Re-run this script (step 2 only) if the ticket expires mid-session.
#   3. Installs required R packages (first run only; skips if already present).
#
# Prerequisites:
#   - Access to the PRCC cluster ("RE Cluster Shell Access" on PRCC dashboard)
#   - A valid Duke NetID
#   - Read permission on the OMOP CDM database (contact DHTS if needed)
# =============================================================================

set -euo pipefail

BUNDLE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$BUNDLE_DIR"

echo ""
echo "======================================================================"
echo "  PAD/OLER SSI Validation — PRCC Environment Setup"
echo "  Bundle: $BUNDLE_DIR"
echo "======================================================================"
echo ""

# -----------------------------------------------------------------------------
# Step 1 — Java via conda (openjdk + maven from conda-forge)
# -----------------------------------------------------------------------------
echo "[1/3] Setting up Java environment ..."

module load miniforge

if conda env list | grep -qE '^openjdk[[:space:]]'; then
  echo "      conda env 'openjdk' already exists — skipping creation."
else
  echo "      Creating conda env 'openjdk' (this takes ~2 minutes on first run) ..."
  conda create -n openjdk conda-forge::openjdk conda-forge::maven -y
  echo "      conda env created."
fi

# Activate to verify Java is reachable.
conda activate openjdk

echo "      JAVA_HOME  = ${JAVA_HOME:-<not set>}"
echo "      java -version: $(java -version 2>&1 | head -1)"
echo ""

# -----------------------------------------------------------------------------
# Step 2 — Kerberos ticket (NetID authentication for SQL Server)
# -----------------------------------------------------------------------------
echo "[2/3] Obtaining Kerberos ticket (enter your Duke NetID password) ..."

export KRB5CCNAME=FILE:~/krb5cc_java
kinit

# Confirm ticket was issued.
if klist -s 2>/dev/null; then
  EXPIRY=$(klist 2>&1 | awk '/Expires/{found=1; next} found{print $1, $2; exit}')
  echo "      Ticket valid. Expires: ${EXPIRY:-unknown}"
else
  echo "WARNING: kinit succeeded but no valid ticket found. Check your NetID password."
fi
echo ""

# -----------------------------------------------------------------------------
# Step 3 — R package installation (first run only)
# -----------------------------------------------------------------------------
echo "[3/3] Installing R packages (skips packages already installed) ..."

# Resolve Rscript — use module-loaded R if available, otherwise system R.
if command -v Rscript &>/dev/null; then
  RSCRIPT=$(command -v Rscript)
else
  echo "ERROR: Rscript not found on PATH. Load the R module first:"
  echo "  module load R"
  exit 1
fi

echo "      Using R: $RSCRIPT"
"$RSCRIPT" install_packages.R
echo ""

# -----------------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------------
cat <<SUMMARY
======================================================================
  Setup complete.

  Bundle location: $BUNDLE_DIR

  To run the analysis:

    1. Edit config.R and fill in all CHANGE_ME values:
         server, database, spn_host, vocab_schema,
         cdm_schema, results_schema

    2. Confirm the Duke SOM-HPC JDBC wrapper JAR is in place:
         $(dirname "$BUNDLE_DIR")/drivers/prcc-jdbc-mssql-1.0-SNAPSHOT.jar
       (Contact DHTS/SOM-HPC if you do not have this file.)

    3. In a fresh terminal:
         cd $BUNDLE_DIR
         conda activate openjdk
         Rscript run_analysis.R

  Kerberos tickets expire after ~10 hours. If you get authentication
  errors on a subsequent run, re-obtain a ticket:
         export KRB5CCNAME=FILE:~/krb5cc_java && kinit

  Output will be written to:
         $BUNDLE_DIR/output/risk_score_eval/
======================================================================
SUMMARY
