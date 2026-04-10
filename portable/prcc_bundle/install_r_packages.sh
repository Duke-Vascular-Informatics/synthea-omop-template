#!/usr/bin/env bash
# =============================================================================
# install_r_packages.sh
#
# Step 2 of 2 — R package installation for the PAD/OLER SSI validation
# bundle on Duke PRCC.
#
# Run this AFTER setup_prcc_env.sh has completed successfully.
# You only need to run this once — packages persist in your conda
# environment between sessions.
#
# FULL SETUP SEQUENCE (first time):
#   bash setup_prcc_env.sh        # Step 1 — Java + Kerberos
#   bash install_r_packages.sh    # Step 2 — R packages (this script)
#
# What this script does:
#   1. Loads miniforge and activates the openjdk conda environment so that
#      JAVA_HOME is set correctly before R package compilation begins.
#   2. Runs `Rscript install_packages.R`, which:
#        a. Runs R CMD javareconf so R picks up the conda JDK headers
#           (required for rJava compilation).
#        b. Installs all required R packages from the Duke CRAN mirror,
#           skipping any that are already installed.
#        c. Verifies all packages load successfully and prints a summary.
#
# Prerequisites:
#   - setup_prcc_env.sh must have been run first (conda env must exist)
#   - module load R (or R must be on PATH via another mechanism)
# =============================================================================

set -euo pipefail

BUNDLE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$BUNDLE_DIR"

echo ""
echo "======================================================================"
echo "  PAD/OLER SSI Validation — R Package Installation (Step 2 of 2)"
echo "  Bundle: $BUNDLE_DIR"
echo "======================================================================"
echo ""

# -----------------------------------------------------------------------------
# Step 1 — Activate conda environment so JAVA_HOME is set for compilation
#
# rJava must be compiled against the JDK headers in the openjdk conda env.
# If the environment is not active, JAVA_HOME will be unset and rJava
# compilation will fail with "jni.h: No such file or directory".
# -----------------------------------------------------------------------------
echo "[1/2] Activating conda environment ..."

module load miniforge

if ! conda env list | grep -qE '^openjdk[[:space:]]'; then
  echo "ERROR: conda env 'openjdk' not found."
  echo "       Please run setup_prcc_env.sh first:"
  echo "         bash setup_prcc_env.sh"
  exit 1
fi

conda activate openjdk

echo "      JAVA_HOME  = ${JAVA_HOME:-<not set>}"
echo ""

# -----------------------------------------------------------------------------
# Step 2 — Run the R package installer
# -----------------------------------------------------------------------------
echo "[2/2] Installing R packages ..."

if ! command -v Rscript &>/dev/null; then
  echo "ERROR: Rscript not found on PATH."
  echo "       Load the R module before running this script:"
  echo "         module load R"
  exit 1
fi

echo "      Using R: $(command -v Rscript)"
echo ""

Rscript install_packages.R

# -----------------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------------
echo ""
cat <<SUMMARY
======================================================================
  R package installation complete.

  To run the analysis:
       conda activate openjdk
       Rscript run_analysis.R

  Make sure config.R has been edited with your site-specific values
  before running the analysis.
======================================================================
SUMMARY
