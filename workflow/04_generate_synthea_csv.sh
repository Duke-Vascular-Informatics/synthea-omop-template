#!/usr/bin/env bash
# =============================================================================
# Step 4 (Linux/macOS): Generate Synthea CSV data for the study template workflow.
# Replaces 04_generate_synthea_csv.ps1 for non-Windows environments.
#
# Usage:
#   bash workflow/04_generate_synthea_csv.sh [population] [age_range] [state]
#
# Environment:
#   SYNTHEA_SEED            Integer seed passed to Synthea (-s). If unset a random seed is
#                           drawn, and ALWAYS recorded in output/generation_params.txt, so
#                           any dataset can be regenerated with the same population.
#   SYNTHEA_OVERWRITE_OUTPUT=true
#                           Delete existing output/ instead of archiving it (default: move
#                           it to output_prev_<timestamp>/ so a previous dataset's source
#                           CSVs are never destroyed silently).
#
# Defaults:
#   population = 1000
#   age_range  = 18-100
#   state      = "North Carolina"
#
# RESEARCHER_ADJUSTS: Set age_range to match your study's eligible age range
# (e.g., 60-100 for older surgical cohorts, 18-65 for working-age studies).
# =============================================================================

set -euo pipefail

POPULATION=${1:-1000}
AGE_RANGE=${2:-18-100}
STATE=${3:-"North Carolina"}

# Resolve repo root relative to this script
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SYNTHEA_HOME="${SYNTHEA_HOME:-$REPO_ROOT/external/synthea}"

# Auto-detect the study module JSON (any .json that isn't the generic template stub).
MODULE_FILE="$(find "$REPO_ROOT/synthea/modules" -maxdepth 1 -name '*.json' \
  ! -name 'study_template.json' | head -1)"
if [ -z "$MODULE_FILE" ]; then
  echo "ERROR: No study module JSON found in synthea/modules/."
  echo "Create one and run Step 3 first."
  exit 1
fi
MODULE_NAME="$(basename "$MODULE_FILE" .json)"

MODULES_DIR="$SYNTHEA_HOME/src/main/resources/modules"
SYNCED_MODULE="$MODULES_DIR/${MODULE_NAME}.json"

echo "=== Step 4: Generate Synthea CSV (module: $MODULE_NAME) ==="
echo "  Synthea home : $SYNTHEA_HOME"
echo "  Population   : $POPULATION"
echo "  Age range    : $AGE_RANGE"
echo "  State        : $STATE"

# Pre-flight: ensure external/synthea submodule is initialised.
# git submodule update --init is idempotent — safe to run every time.
if [ ! -d "$SYNTHEA_HOME/.git" ] && [ ! -f "$SYNTHEA_HOME/.git" ]; then
  echo "Initialising external/synthea submodule..."
  git -C "$REPO_ROOT" submodule update --init external/synthea
fi

# Pre-flight checks
if [ ! -d "$MODULES_DIR" ]; then
  echo "ERROR: Synthea modules directory not found: $MODULES_DIR"
  echo "The external/synthea submodule may not have cloned correctly."
  echo "Run: git submodule update --init external/synthea"
  exit 1
fi

if [ ! -f "$SYNCED_MODULE" ]; then
  echo "ERROR: Module not found at $SYNCED_MODULE"
  echo "Run Step 3 first: Rscript workflow/03_generate_synthea_module_artifacts.R"
  exit 1
fi

echo "Verified Step 3 module sync: $SYNCED_MODULE"

# Run Synthea from its home directory
cd "$SYNTHEA_HOME"

# ---- Seed: always explicit, always recorded --------------------------------
# Without -s every run is different and the registry's generation_params.seed stays
# null, so a lost dataset can be rebuilt in shape only (this is how pad_oler_ssi v1
# became unrecoverable). A random seed is drawn when none is given.
SEED="${SYNTHEA_SEED:-$(( (RANDOM << 15) | RANDOM ))}"

# ---- Do not clobber a previous run's CSVs -----------------------------------
# Synthea writes into output/ and overwrites what is there. Those CSVs can be the
# only source of a dataset whose seed was never recorded.
if [ -d output ] && [ -n "$(ls -A output 2>/dev/null)" ]; then
  if [ "${SYNTHEA_OVERWRITE_OUTPUT:-false}" = "true" ]; then
    echo "SYNTHEA_OVERWRITE_OUTPUT=true: deleting existing output/"
    rm -rf output
  else
    ARCHIVE="output_prev_$(date +%Y%m%d_%H%M%S)"
    echo "Existing output/ found ($(du -sh output | cut -f1)); moving to $ARCHIVE/ (delete it when no longer needed)."
    mv output "$ARCHIVE"
  fi
fi

echo "Running Synthea (population=$POPULATION, age=$AGE_RANGE, state=$STATE, seed=$SEED)..."

./run_synthea \
  -s "$SEED" \
  -p "$POPULATION" \
  -a "$AGE_RANGE" \
  --exporter.csv.export=true \
  --exporter.fhir.export=false \
  --exporter.json.export=false \
  "$STATE"

CSV_OUTPUT="$SYNTHEA_HOME/output/csv"
# Provenance for synthetic_data/registry.yaml (generation_params).
{
  echo "date=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "module=$MODULE_NAME"
  echo "module_sha256=$( (sha256sum "$SYNCED_MODULE" 2>/dev/null || shasum -a 256 "$SYNCED_MODULE") | cut -d' ' -f1)"
  echo "population=$POPULATION"
  echo "age_range=$AGE_RANGE"
  echo "state=$STATE"
  echo "seed=$SEED"
  echo "synthea_commit=$(git -C "$SYNTHEA_HOME" rev-parse --short HEAD 2>/dev/null || echo unknown)"
  echo "patients_csv_rows=$(($(wc -l < "$CSV_OUTPUT/patients.csv") - 1))"
} > "$SYNTHEA_HOME/output/generation_params.txt"

echo ""
echo "Step 4 complete: Synthea CSV data generated."
echo "CSV output folder: $CSV_OUTPUT"
echo "Provenance (seed etc.): $SYNTHEA_HOME/output/generation_params.txt -> copy into registry generation_params."
