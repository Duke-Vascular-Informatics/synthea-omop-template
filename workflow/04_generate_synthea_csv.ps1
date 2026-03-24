param(
  [string]$SyntheaHome = $(if ([string]::IsNullOrWhiteSpace($env:SYNTHEA_HOME)) { "C:\Users\rapiduser\source\repos\synthea" } else { $env:SYNTHEA_HOME }),
  [int]$Population = 5000,
  [string]$AgeRange = "40-100",
  [string]$State = "Massachusetts"
)

$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Resolve-Path (Join-Path $scriptDir "..")
Push-Location $repoRoot

try {
  & "scripts/synthea/run_synthea_pad_ssi.ps1" `
    -SyntheaHome $SyntheaHome `
    -Population $Population `
    -AgeRange $AgeRange `
    -State $State `
    -ExportFormat "csv" `
    -RequireModuleOnly $true
}
finally {
  Pop-Location
}

Write-Host "Step 4 complete: Synthea CSV data generated." -ForegroundColor Green
