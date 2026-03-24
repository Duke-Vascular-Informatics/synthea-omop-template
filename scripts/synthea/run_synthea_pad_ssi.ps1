param(
  [Parameter(Mandatory = $false)]
  [string]$SyntheaHome = $(if ([string]::IsNullOrWhiteSpace($env:SYNTHEA_HOME)) { "C:\Users\rapiduser\source\repos\synthea" } else { $env:SYNTHEA_HOME }),

  [Parameter(Mandatory = $false)]
  [int]$Population = 5000,

  [Parameter(Mandatory = $false)]
  [string]$ModuleFile = "c:\Users\rapiduser\pad-oler-ssi-val\synthea\modules\pad_ssi.json",

  [Parameter(Mandatory = $false)]
  [string]$ModuleName = "pad_ssi",

  [Parameter(Mandatory = $false)]
  [string]$State = "Massachusetts"
,

  [Parameter(Mandatory = $false)]
  [string]$AgeRange = "40-100"
,

  [Parameter(Mandatory = $false)]
  [ValidateSet("csv", "fhir", "both")]
  [string]$ExportFormat = "csv"
,

  [Parameter(Mandatory = $false)]
  [bool]$RequireModuleOnly = $true
)

$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($SyntheaHome)) {
  throw "SyntheaHome not provided. Pass -SyntheaHome <path> or set SYNTHEA_HOME."
}

$syntheaBat = Join-Path $SyntheaHome "run_synthea.bat"
if (!(Test-Path $syntheaBat)) {
  if ($RequireModuleOnly) {
    throw @"
Module-only generation requires a full Synthea checkout with run_synthea.bat.
Current SyntheaHome appears to be a standalone jar distribution:
  $SyntheaHome

The standalone jar CLI supports -d (extra module directory) but does not expose
a module whitelist flag, so it cannot guarantee generation only through
pad_ssi.json.
"@
  }
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
  Write-Host "Running Synthea with module '$ModuleName' for $Population patients ($ExportFormat output)..." -ForegroundColor Cyan

  switch ($ExportFormat) {
    "csv"  { $exporterArgs = @("--exporter.csv.export=true",  "--exporter.fhir.export=false") }
    "fhir" { $exporterArgs = @("--exporter.csv.export=false", "--exporter.fhir.export=true") }
    "both" { $exporterArgs = @("--exporter.csv.export=true",  "--exporter.fhir.export=true") }
  }

  # This Synthea checkout supports -m for module filtering.
  # Do not use --modules here: App.java treats unknown --args as config keys,
  # which silently disables module restriction.
  $attempts = ,(@("-p", "$Population", "-a", "$AgeRange", "-m", "$ModuleName", "$State") + $exporterArgs)

  $success = $false
  $usedModuleRestriction = $false

  foreach ($args in $attempts) {
    Write-Host ("Attempt: .\\run_synthea.bat " + ($args -join " ")) -ForegroundColor Yellow
    & $syntheaBat @args
    if ($LASTEXITCODE -eq 0) {
      $success = $true
      $usedModuleRestriction = $true
      break
    }
  }

  if (-not $success) {
    throw "Synthea failed for all module-restricted command variants. Check console logs above."
  }

  if ($RequireModuleOnly -and -not $usedModuleRestriction) {
    throw "Module-only execution was required, but no module-restricted invocation succeeded."
  }

  $csvOutputDir = Join-Path $SyntheaHome "output\csv"
  $fhirOutputDir = Join-Path $SyntheaHome "output\fhir"

  Write-Host "Synthea completed successfully." -ForegroundColor Green
  if ($ExportFormat -eq "csv" -or $ExportFormat -eq "both") {
    Write-Host "CSV output folder : $csvOutputDir" -ForegroundColor Green
  }
  if ($ExportFormat -eq "fhir" -or $ExportFormat -eq "both") {
    Write-Host "FHIR output folder: $fhirOutputDir" -ForegroundColor Green
  }
}
finally {
  Pop-Location
}
