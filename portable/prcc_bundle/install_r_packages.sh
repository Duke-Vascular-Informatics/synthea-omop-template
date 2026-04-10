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
# Step 2 — Set a user-writable R package library
#
# R is installed system-wide on PRCC and users do not have write access to
# the system library ($(R RHOME)/library).  R_LIBS_USER tells R to install
# packages into a directory under the user's home folder instead.
#
# The directory is created if it does not already exist.  R automatically
# prepends R_LIBS_USER to .libPaths() at startup, so packages installed here
# are found by all subsequent R sessions on this node.
# -----------------------------------------------------------------------------
echo "[2/3] Configuring user R package library ..."

# Detect R version for the library path (e.g. ~/R/x86_64-pc-linux-gnu-library/4.3)
R_VERSION=$(Rscript -e "cat(paste(R.version\$major, R.version\$minor, sep='.'))" 2>/dev/null | tr -d ' ')
R_PLATFORM=$(Rscript -e "cat(R.version\$platform)" 2>/dev/null | tr -d ' ')
USER_RLIB="${HOME}/R/${R_PLATFORM}-library/${R_VERSION%.*}"

mkdir -p "$USER_RLIB"
export R_LIBS_USER="$USER_RLIB"

echo "      R version  : $R_VERSION"
echo "      R platform : $R_PLATFORM"
echo "      R_LIBS_USER: $R_LIBS_USER"
echo ""

# -----------------------------------------------------------------------------
# Step 3 — Run the R package installer
# -----------------------------------------------------------------------------
echo "[3/3] Installing R packages ..."

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
