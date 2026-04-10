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
# Step 2 — Set Kerberos ticket cache and verify ticket is valid
#
# KRB5CCNAME tells the JDBC Kerberos login module where to find the ticket
# cache file obtained by `kinit`.  It must be set in the shell environment
# before R starts — the JDBC driver reads it at connection time.
#
# Even if setup_prcc_env.sh was run earlier, KRB5CCNAME is only exported
# for that shell session.  A new terminal window will not have it.  We
# set it here unconditionally so run_analysis.sh is self-contained.
# -----------------------------------------------------------------------------
echo "[2/4] Setting Kerberos ticket cache ..."

export KRB5CCNAME=FILE:~/krb5cc_java

# Verify a valid ticket exists before spending time launching R.
if ! klist -s 2>/dev/null; then
  echo ""
  echo "ERROR: No valid Kerberos ticket found."
  echo "       Obtain a ticket first, then re-run this script:"
  echo "         export KRB5CCNAME=FILE:~/krb5cc_java && kinit"
  exit 1
fi

EXPIRY=$(klist 2>&1 | awk '/Expires/{found=1; next} found{print $1, $2; exit}')
echo "      KRB5CCNAME: $KRB5CCNAME"
echo "      Ticket valid. Expires: ${EXPIRY:-unknown}"
echo ""

# -----------------------------------------------------------------------------
# Step 3 — Find libjvm.so and set LD_LIBRARY_PATH before R starts
#
# libjvm.so is the JVM shared library that rJava loads via dyn.load().
# Its exact location inside the conda JDK varies by platform and conda
# package version — it may be at:
#   $JAVA_HOME/lib/server/libjvm.so          (typical Linux JDK layout)
#   $CONDA_PREFIX/lib/jvm/lib/server/libjvm.so (some conda openjdk packages)
#   $CONDA_PREFIX/lib/server/libjvm.so
#
# We use `find` to locate it dynamically rather than hardcoding the path.
#
# IMPORTANT: This MUST be set in the shell before Rscript is called.
# Setting LD_LIBRARY_PATH inside R with Sys.setenv() is NOT reliable for
# dyn.load() because the OS dynamic linker on some Linux configurations
# reads LD_LIBRARY_PATH from the process environment at launch time.
# -----------------------------------------------------------------------------
echo "[3/4] Locating libjvm.so and configuring library paths ..."

# Search the entire conda env for libjvm.so.
JVM_LIB=$(find "${CONDA_PREFIX}" -name "libjvm.so" 2>/dev/null | head -1)

if [[ -z "$JVM_LIB" ]]; then
  # Fallback: search JAVA_HOME directly.
  JVM_LIB=$(find "${JAVA_HOME}" -name "libjvm.so" 2>/dev/null | head -1)
fi

if [[ -z "$JVM_LIB" ]]; then
  echo ""
  echo "ERROR: libjvm.so not found anywhere under CONDA_PREFIX or JAVA_HOME."
  echo "       CONDA_PREFIX = ${CONDA_PREFIX}"
  echo "       JAVA_HOME    = ${JAVA_HOME}"
  echo "       Try: conda install -n openjdk conda-forge::openjdk --force-reinstall"
  exit 1
fi

JVM_LIB_DIR="$(dirname "$JVM_LIB")"
echo "      libjvm.so found: $JVM_LIB"

export LD_LIBRARY_PATH="${JVM_LIB_DIR}:${CONDA_PREFIX}/lib:${LD_LIBRARY_PATH:-}"
echo "      LD_LIBRARY_PATH: ${LD_LIBRARY_PATH}"
echo ""

# -----------------------------------------------------------------------------
# Step 3 — Launch the analysis
# -----------------------------------------------------------------------------
echo "[4/4] Launching analysis ..."
echo ""

Rscript run_analysis.R

echo ""
echo "======================================================================"
echo "  Analysis complete."
echo "  Output: $BUNDLE_DIR/output/risk_score_eval/"
echo "======================================================================"
