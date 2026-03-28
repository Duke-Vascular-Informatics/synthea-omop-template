# -----------------------------------------------------------------------------
# Step 4: Generate Synthea CSV data for the PAD/SSI validation workflow.
#
# High-level behavior:
# 1) Resolve runtime parameters (Synthea path, population size, age range, state).
# 2) Switch working directory to repository root for stable relative paths.
# 3) Invoke the Synthea runner script in module-only mode.
# 4) Always restore prior working directory, even on failure.
# -----------------------------------------------------------------------------

# -----------------------------------------------------------------------------
# Chunk 1 - Runtime parameters
# Purpose:
# Define all user-configurable knobs for Synthea generation.
# Code path notes:
# - SyntheaHome: prefer $env:SYNTHEA_HOME when provided; otherwise use local
#   default path.
# - Population/AgeRange/State: forwarded directly to downstream runner script.
# -----------------------------------------------------------------------------
param(
  [string]$SyntheaHome = $(if ([string]::IsNullOrWhiteSpace($env:SYNTHEA_HOME)) { "C:\Users\rapiduser\source\repos\synthea" } else { $env:SYNTHEA_HOME }),
  [int]$Population = 1000,
  [string]$AgeRange = "40-100",
  [string]$State = "North Carolina"
)

# -----------------------------------------------------------------------------
# Chunk 2 - Fail-fast shell behavior
# Purpose:
# Treat non-terminating PowerShell errors as terminating so workflow failures do
# not continue silently.
# -----------------------------------------------------------------------------
$ErrorActionPreference = "Stop"

# -----------------------------------------------------------------------------
# Chunk 3 - Resolve repository root and set execution location
# Purpose:
# Compute repository root relative to this script file and enter it so all
# script-relative paths remain stable regardless of caller's current directory.
# Code path notes:
# - Push-Location stores prior location on stack.
# - Pop-Location in finally block guarantees restoration.
# -----------------------------------------------------------------------------
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Resolve-Path (Join-Path $scriptDir "..")
Push-Location $repoRoot

# -----------------------------------------------------------------------------
# Chunk 4 - Invoke Synthea module generation script
# Purpose:
# Execute the canonical Synthea runner for PAD/SSI synthetic data generation.
# Code path notes:
# - -RequireModuleOnly $true ensures module artifacts are required and validated.
# - Any error bubbles up due to $ErrorActionPreference = "Stop".
# -----------------------------------------------------------------------------
try {
  & "scripts/synthea/run_synthea_pad_ssi.ps1" `
    -SyntheaHome $SyntheaHome `
    -Population $Population `
    -AgeRange $AgeRange `
    -State $State `
    -RequireModuleOnly $true
}

# -----------------------------------------------------------------------------
# Chunk 5 - Directory cleanup guarantee
# Purpose:
# Restore original working directory regardless of success/failure so this
# script has no persistent side effects on caller shell context.
# -----------------------------------------------------------------------------
finally {
  Pop-Location
}

# -----------------------------------------------------------------------------
# Chunk 6 - Completion banner
# Purpose:
# Provide clear terminal confirmation that Step 4 finished successfully.
# -----------------------------------------------------------------------------
Write-Host "Step 4 complete: Synthea CSV data generated." -ForegroundColor Green
