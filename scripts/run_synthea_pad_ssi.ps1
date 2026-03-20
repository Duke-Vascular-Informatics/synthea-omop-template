param(
  [Parameter(Mandatory = $false)]
  [string]$SyntheaHome = $env:SYNTHEA_HOME,

  [Parameter(Mandatory = $false)]
  [int]$Population = 5000,

  [Parameter(Mandatory = $false)]
  [string]$ModuleFile = "c:\Users\rapiduser\pad-oler-ssi-val\synthea\modules\pad_ssi.json",

  [Parameter(Mandatory = $false)]
  [string]$ModuleName = "pad_ssi",

  [Parameter(Mandatory = $false)]
  [string]$State = "Massachusetts"
)

$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($SyntheaHome)) {
  throw "SyntheaHome not provided. Pass -SyntheaHome <path> or set SYNTHEA_HOME."
}

$syntheaBat = Join-Path $SyntheaHome "run_synthea.bat"
if (!(Test-Path $syntheaBat)) {
  throw "Could not find run_synthea.bat at: $syntheaBat"
}

if (!(Test-Path $ModuleFile)) {
  throw "Module file not found: $ModuleFile"
}

$modulesDir = Join-Path $SyntheaHome "src\main\resources\modules"
if (!(Test-Path $modulesDir)) {
  throw "Could not find Synthea modules directory: $modulesDir"
}

# Ensure the custom module is available to Synthea.
Copy-Item -Path $ModuleFile -Destination (Join-Path $modulesDir "$ModuleName.json") -Force

Push-Location $SyntheaHome
try {
  Write-Host "Running Synthea with module '$ModuleName' for $Population patients (FHIR output)..." -ForegroundColor Cyan

  # Force FHIR-only export.
  $exporterArgs = @("--exporter.csv.export=false", "--exporter.fhir.export=true")

  # Different Synthea versions use either --modules or -m.
  $attempts = @(
    (@("-p", "$Population", "--modules", "$ModuleName", "$State") + $exporterArgs),
    (@("-p", "$Population", "-m", "$ModuleName", "$State") + $exporterArgs),
    (@("-p", "$Population", "$State") + $exporterArgs)
  )

  $success = $false

  foreach ($args in $attempts) {
    Write-Host ("Attempt: .\\run_synthea.bat " + ($args -join " ")) -ForegroundColor Yellow
    & $syntheaBat @args
    if ($LASTEXITCODE -eq 0) {
      $success = $true
      break
    }
  }

  if (-not $success) {
    throw "Synthea failed for all command variants. Check console logs above."
  }

  $fhirOutputDir = Join-Path $SyntheaHome "output\fhir"
  Write-Host "Synthea completed successfully." -ForegroundColor Green
  Write-Host "FHIR output folder: $fhirOutputDir" -ForegroundColor Green
}
finally {
  Pop-Location
}
