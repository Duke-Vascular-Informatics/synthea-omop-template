param(
  [string]$SyntheaHome = $(if ([string]::IsNullOrWhiteSpace($env:SYNTHEA_HOME)) { "C:\Users\rapiduser\source\repos\synthea" } else { $env:SYNTHEA_HOME }),
  [int]$Population = 5000,
  [string]$AgeRange = "40-100",
  [string]$State = "Massachusetts"
)

$ErrorActionPreference = "Stop"

& "scripts/run_synthea_pad_ssi.ps1" `
  -SyntheaHome $SyntheaHome `
  -Population $Population `
  -AgeRange $AgeRange `
  -State $State `
  -ExportFormat "csv" `
  -RequireModuleOnly $true

Write-Host "Step 4 complete: Synthea CSV data generated." -ForegroundColor Green
