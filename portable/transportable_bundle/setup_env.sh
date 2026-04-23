#!/usr/bin/env bash
# =============================================================================
# setup_env.sh
#
# Step 1 of 2 — Java and Kerberos environment setup for the PAD/OLER SSI
# validation bundle on protected analytic space.
#
# Run this from the HPC cluster shell BEFORE installing R packages or
# running the analysis.  You only need to run this once per session
# (or whenever your Kerberos ticket expires).
#
# FULL SETUP SEQUENCE (first time):
#   bash setup_env.sh        # Step 1 — Java + Kerberos
#   bash install_r_packages.sh    # Step 2 — R packages (first time only)
#
# SUBSEQUENT SESSIONS (packages already installed):
#   bash setup_env.sh                             # renew Kerberos ticket
#   conda activate openjdk                             # activate env first
#   export KRB5CCNAME=FILE:~/krb5cc_java && kinit      # then get ticket
#   bash run_analysis.sh
#
# What this script does:
#   1. Loads the miniforge module and creates the openjdk conda env (first run
#      only; subsequent runs skip creation if the env already exists).
#   2. Obtains a Kerberos ticket via `kinit` using your your institutional credentials.
#      The ticket is stored at ~/krb5cc_java and is valid for ~10 hours.
#      Re-run this script if the ticket expires mid-session.
#
# Prerequisites:
#   - Access to the HPC cluster ("RE Cluster Shell Access" on cluster portal)
#   - A valid your institutional username
#   - Read permission on the OMOP CDM database (contact your HPC support team if needed)
# =============================================================================

set -euo pipefail

BUNDLE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$BUNDLE_DIR"

echo ""
echo "======================================================================"
echo "  PAD/OLER SSI Validation — HPC cluster Environment Setup (Step 1 of 2)"
echo "  Bundle: $BUNDLE_DIR"
echo "======================================================================"
echo ""

# -----------------------------------------------------------------------------
# Step 1 — Java via conda (openjdk + maven from conda-forge)
# -----------------------------------------------------------------------------
echo "[1/2] Setting up Java environment ..."

module load miniforge

if conda env list | grep -qE '^openjdk[[:space:]]'; then
  echo "      conda env 'openjdk' already exists — skipping creation."
  # Ensure the compression libraries required by rJava are present.
  # xz (liblzma) and zlib (libz) must be in the conda env because the
  # conda gcc linker looks for them there rather than in system paths.
  # conda install is a no-op if they are already installed.
  echo "      Checking for required compiler libraries (xz, zlib) ..."
  conda install -n openjdk conda-forge::xz conda-forge::zlib -y --quiet
else
  echo "      Creating conda env 'openjdk' (this takes ~2 minutes on first run) ..."
  # openjdk, maven  : Java runtime and build tools
  # xz, zlib        : compression libraries required by the rJava linker.
  #                   The conda gcc compiler links against these and cannot
  #                   fall back to system libraries, so they must live inside
  #                   the conda env.
  conda create -n openjdk conda-forge::openjdk conda-forge::maven \
                           conda-forge::xz conda-forge::zlib -y
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
echo "[2/2] Obtaining Kerberos ticket (enter your your institutional credentials) ..."

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
# Summary
# -----------------------------------------------------------------------------
cat <<SUMMARY
======================================================================
  Environment setup complete.

  Bundle location: $BUNDLE_DIR

  NEXT STEPS:

  If this is your FIRST time running the analysis, install R packages:
       bash install_r_packages.sh

  If packages are already installed, run the analysis:
       conda activate openjdk
       export KRB5CCNAME=FILE:~/krb5cc_java && kinit
       bash run_analysis.sh

  Before running the analysis, make sure you have:
    1. Edited config.R to fill in all CHANGE_ME values:
         server, database, spn_host, vocab_schema,
         cdm_schema, results_schema

    2. The your HPC support team JDBC wrapper JAR in place:
         $(dirname "$BUNDLE_DIR")/drivers/hpc-jdbc-wrapper.jar
       (Contact your HPC support team/SOM-HPC if you do not have this file.)

  Kerberos tickets expire after ~10 hours. If you get authentication
  errors, re-run this script to renew:
       bash setup_env.sh

  Output will be written to:
       $BUNDLE_DIR/output/risk_score_eval/
======================================================================
SUMMARY
