#!/usr/bin/env bash
# =============================================================================
# Step 4 (Linux/macOS): Generate Synthea CSV data for the study template workflow.
# Replaces 04_generate_synthea_csv.ps1 for non-Windows environments.
#
# Usage:
#   bash workflow/04_generate_synthea_csv.sh [population] [age_range] [state]
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
MODULE_NAME="study_template"
MODULE_FILE="$REPO_ROOT/synthea/modules/${MODULE_NAME}.json"
MODULES_DIR="$SYNTHEA_HOME/src/main/resources/modules"
SYNCED_MODULE="$MODULES_DIR/${MODULE_NAME}.json"

echo "=== Step 4: Generate Synthea CSV (module: $MODULE_NAME) ==="
echo "  Synthea home : $SYNTHEA_HOME"
echo "  Population   : $POPULATION"
echo "  Age range    : $AGE_RANGE"
echo "  State        : $STATE"

# Pre-flight checks
if [ ! -d "$MODULES_DIR" ]; then
  echo "ERROR: Synthea modules directory not found: $MODULES_DIR"
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

echo "Running Synthea (population=$POPULATION, age=$AGE_RANGE, state=$STATE)..."

./run_synthea \
  -p "$POPULATION" \
  -a "$AGE_RANGE" \
  --exporter.csv.export=true \
  --exporter.fhir.export=false \
  --exporter.json.export=false \
  "$STATE"

CSV_OUTPUT="$SYNTHEA_HOME/output/csv"
echo ""
echo "Step 4 complete: Synthea CSV data generated."
echo "CSV output folder: $CSV_OUTPUT"
