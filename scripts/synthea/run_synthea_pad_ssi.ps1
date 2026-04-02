param(
  [Parameter(Mandatory = $false)]
  [string]$SyntheaHome = $env:SYNTHEA_HOME,

  [Parameter(Mandatory = $false)]
  [int]$Population = 1000,

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
  [bool]$RequireModuleOnly = $true
)

$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($SyntheaHome)) {
  $repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..\..")
  $SyntheaHome = Join-Path $repoRoot "external/synthea"
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
  Write-Host "Running Synthea with module '$ModuleName' for $Population patients (CSV output)..." -ForegroundColor Cyan

  $exporterArgs = @("--exporter.csv.export=true", "--exporter.fhir.export=false", "--exporter.json.export=false")

  # This Synthea checkout supports -m for module filtering.
  # Do not use --modules here: App.java treats unknown --args as config keys,
  # which silently disables module restriction.
  # When $RequireModuleOnly is $false we run ALL bundled modules (including the
  # custom pad_ssi.json already copied above) so that medications, full
  # procedures, and the complete clinical picture are generated alongside PAD.
  if ($RequireModuleOnly) {
    $attempts = ,(@("-p", "$Population", "-a", "$AgeRange", "-m", "$ModuleName", "$State") + $exporterArgs)
  } else {
    $attempts = ,(@("-p", "$Population", "-a", "$AgeRange", "$State") + $exporterArgs)
  }

  # Start-Process can split multi-word arguments unless they are explicitly
  # quoted as a single command-line token. This helper keeps states such as
  # "North Carolina" intact when passed to run_synthea.bat.
  $quoteArg = {
    param([string]$value)
    if ($null -eq $value) { return '""' }
    $escaped = $value -replace '"', '\\"'
    if ($escaped -match '[\s"]') { return ('"' + $escaped + '"') }
    return $escaped
  }

  $success = $false
  $usedModuleRestriction = $false

  foreach ($args in $attempts) {
    # Build Groovy-style params array: each token single-quoted, comma-separated.
    # run_synthea.bat passes this directly to gradlew as -Params=[...], so tokens
    # must be valid Groovy string literals (single quotes survive cmd.exe expansion).
    $groovyTokens = $args | ForEach-Object {
      $tok = $_ -replace "'", "''"   # escape any embedded single quotes
      "'$tok'"
    }
    $groovyParams = "[" + ($groovyTokens -join ",") + ",]"
    $gradlewArgs = "run -Params=$groovyParams"

    Write-Host ("Attempt: .\\gradlew.bat " + $gradlewArgs) -ForegroundColor Yellow

    & '.\gradlew.bat' run "-Params=$groovyParams"
    $exitCode = $LASTEXITCODE

    if ($exitCode -eq 0) {
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

  Write-Host "Synthea completed successfully." -ForegroundColor Green
  Write-Host "CSV output folder: $csvOutputDir" -ForegroundColor Green
}
finally {
  Pop-Location
}
