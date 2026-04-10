#!/usr/bin/env bash
# =============================================================================
# run_analysis.sh — PAD/OLER SSI Validation Bundle — PRCC launcher
#
# Use this script to launch the analysis on PRCC instead of calling
# Rscript directly.  It sets the required environment variables in the
# shell BEFORE R starts, which is necessary for libjvm.so to be found.
#
# USAGE:
#   bash run_analysis.sh
#
# PREREQUISITES (run once per session before this script):
#   bash setup_prcc_env.sh     # creates conda env + obtains Kerberos ticket
#
# WHY A WRAPPER SCRIPT:
#   rJava loads libjvm.so (the JVM shared library) via dyn.load() when
#   library(rJava) is called inside R.  The OS dynamic linker resolves
#   shared libraries using LD_LIBRARY_PATH from the shell environment that
#   launched the R process.  Setting LD_LIBRARY_PATH inside R with
#   Sys.setenv() is not reliable for this because the dynamic linker may
#   have already cached the search path when R started.
#
#   libjvm.so lives at $JAVA_HOME/lib/server/ inside the conda openjdk env.
#   That path is not in any default system library search path, so it must
#   be added to LD_LIBRARY_PATH in the shell before Rscript is called.
# =============================================================================

set -euo pipefail

BUNDLE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$BUNDLE_DIR"

echo ""
echo "======================================================================"
echo "  PAD/OLER SSI Validation — Analysis Launcher"
echo "  Bundle: $BUNDLE_DIR"
echo "======================================================================"
echo ""

# -----------------------------------------------------------------------------
# Step 1 — Activate conda environment
# -----------------------------------------------------------------------------
echo "[1/3] Activating conda environment ..."

module load miniforge
conda activate openjdk

if [[ -z "${JAVA_HOME:-}" ]]; then
  echo "ERROR: JAVA_HOME is not set after conda activate openjdk."
  echo "       Try running: bash setup_prcc_env.sh"
  exit 1
fi

echo "      JAVA_HOME: $JAVA_HOME"

# -----------------------------------------------------------------------------
# Step 2 — Set LD_LIBRARY_PATH so the dynamic linker can find libjvm.so
#
# libjvm.so is at $JAVA_HOME/lib/server/ inside the conda JDK.
# This must be in LD_LIBRARY_PATH BEFORE Rscript is called — setting it
# inside R with Sys.setenv() is not sufficient because the OS dynamic
# linker reads LD_LIBRARY_PATH from the process environment at startup.
# -----------------------------------------------------------------------------
echo "[2/3] Configuring library paths ..."

export LD_LIBRARY_PATH="${JAVA_HOME}/lib/server:${CONDA_PREFIX}/lib:${LD_LIBRARY_PATH:-}"

echo "      LD_LIBRARY_PATH includes: ${JAVA_HOME}/lib/server"

# Verify libjvm.so is actually there before launching R.
JVM_LIB="${JAVA_HOME}/lib/server/libjvm.so"
if [[ ! -f "$JVM_LIB" ]]; then
  echo ""
  echo "ERROR: libjvm.so not found at expected path: $JVM_LIB"
  echo "       The conda openjdk environment may be incomplete."
  echo "       Try: conda install -n openjdk conda-forge::openjdk --force-reinstall"
  exit 1
fi

echo "      libjvm.so found: $JVM_LIB"
echo ""

# -----------------------------------------------------------------------------
# Step 3 — Launch the analysis
# -----------------------------------------------------------------------------
echo "[3/3] Launching analysis ..."
echo ""

Rscript run_analysis.R

echo ""
echo "======================================================================"
echo "  Analysis complete."
echo "  Output: $BUNDLE_DIR/output/risk_score_eval/"
echo "======================================================================"
