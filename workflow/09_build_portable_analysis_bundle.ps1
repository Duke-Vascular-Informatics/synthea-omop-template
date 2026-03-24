param()

$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Resolve-Path (Join-Path $scriptDir "..")
Push-Location $repoRoot

try {
	& "scripts/bundle/build_portable_risk_score_bundle.ps1"
}
finally {
	Pop-Location
}

Write-Host "Step 9 complete: portable analysis bundle built under portable/risk_score_validation_bundle." -ForegroundColor Green
