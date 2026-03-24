param(
  [Parameter(Mandatory = $false)]
  [string]$BundleRoot = "portable/risk_score_validation_bundle",

  [Parameter(Mandatory = $false)]
  [string]$OutDir = "dist"
)

$ErrorActionPreference = "Stop"

if (!(Test-Path $BundleRoot)) {
  throw "Bundle root not found: $BundleRoot"
}

if (!(Test-Path $OutDir)) {
  New-Item -ItemType Directory -Path $OutDir | Out-Null
}

$stamp = Get-Date -Format "yyyyMMdd_HHmmss"
$zipPath = Join-Path $OutDir ("risk_score_validation_bundle_" + $stamp + ".zip")

if (Test-Path $zipPath) {
  Remove-Item $zipPath -Force
}

Compress-Archive -Path (Join-Path $BundleRoot "*") -DestinationPath $zipPath -Force
Write-Host "Created bundle: $zipPath" -ForegroundColor Green
