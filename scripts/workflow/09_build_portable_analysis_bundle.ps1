param()

$ErrorActionPreference = "Stop"

& "scripts/build_portable_risk_score_bundle.ps1"

Write-Host "Step 9 complete: portable analysis bundle built under portable/risk_score_validation_bundle." -ForegroundColor Green
