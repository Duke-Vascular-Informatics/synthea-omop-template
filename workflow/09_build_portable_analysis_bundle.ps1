param()

# =============================================================================
# workflow/09_build_portable_analysis_bundle.ps1
#
# Step 9 - Build the Duke PRCC portable analysis bundle.
#
# What this script does:
#   1. Syncs the latest R source files from the main project into
#      portable/prcc_bundle/ so the bundle always reflects the current code.
#   2. Copies the MSSQL JDBC JAR from drivers/jdbc-runtime/ into
#      portable/prcc_bundle/drivers/.
#   3. Builds a dated zip: dist/pad_oler_ssi_val_prcc_<YYYYMMDD>.zip
#      Previous zips in dist/ are retained.
#
# NOTE: portable/prcc_bundle/R/connection.R, config.R, run_analysis.R,
#       install_packages.R, and setup_prcc_env.sh are PRCC-specific and are
#       NOT overwritten by this script.
# =============================================================================

$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot  = Resolve-Path (Join-Path $scriptDir "..")
Push-Location $repoRoot

try {

    $bundle = Join-Path $repoRoot "portable\prcc_bundle"
    $dist   = Join-Path $repoRoot "dist"

    if (!(Test-Path $bundle)) { throw "PRCC bundle directory not found: $bundle" }
    if (!(Test-Path $dist))   { New-Item -ItemType Directory -Path $dist | Out-Null }

    # -------------------------------------------------------------------------
    # Step 1 - Sync R source files from main project into bundle
    # -------------------------------------------------------------------------
    Write-Host "[Step 9] Syncing R source files ..." -ForegroundColor Cyan

    function Copy-BundleFile($src, $dst) {
        $srcPath = Join-Path $repoRoot $src
        $dstPath = Join-Path $repoRoot $dst
        if (!(Test-Path $srcPath)) { Write-Warning "Not found, skipping: $src"; return }
        $dstDir = Split-Path -Parent $dstPath
        if (!(Test-Path $dstDir)) { New-Item -ItemType Directory -Path $dstDir | Out-Null }
        Copy-Item -Path $srcPath -Destination $dstPath -Force
        Write-Host "  $src -> $dst"
    }

    Copy-BundleFile "R\risk_score_pipeline.R"        "portable\prcc_bundle\R\risk_score_pipeline.R"
    Copy-BundleFile "R\cohorts.R"                    "portable\prcc_bundle\R\cohorts.R"
    Copy-BundleFile "R\cohort_demographics.R"        "portable\prcc_bundle\R\cohort_demographics.R"
    Copy-BundleFile "R\report_extended.R"            "portable\prcc_bundle\R\report.R"
    Copy-BundleFile "risk_score\components.csv"          "portable\prcc_bundle\risk_score\components.csv"
    Copy-BundleFile "risk_score\component_concepts.csv"  "portable\prcc_bundle\risk_score\component_concepts.csv"
    Copy-BundleFile "risk_score\risk_lookup.csv"         "portable\prcc_bundle\risk_score\risk_lookup.csv"
    Copy-BundleFile "cohorts\target_surgery.sql"     "portable\prcc_bundle\cohorts\target_surgery.sql"
    Copy-BundleFile "cohorts\outcome_ssi.sql"        "portable\prcc_bundle\cohorts\outcome_ssi.sql"

    # -------------------------------------------------------------------------
    # Step 2 - Sync MSSQL JDBC JAR into bundle/drivers/
    # -------------------------------------------------------------------------
    Write-Host "[Step 9] Syncing JDBC JAR ..." -ForegroundColor Cyan

    $jdbcSrc = Get-ChildItem -Path (Join-Path $repoRoot "drivers\jdbc-runtime") `
                             -Filter "mssql-jdbc-*.jre11.jar" `
                             -ErrorAction SilentlyContinue | Select-Object -First 1

    if ($null -eq $jdbcSrc) {
        Write-Warning "JDBC JAR not found in drivers\jdbc-runtime\ - skipping."
    } else {
        $jdbcDst = Join-Path $bundle "drivers\$($jdbcSrc.Name)"
        Copy-Item -Path $jdbcSrc.FullName -Destination $jdbcDst -Force
        Write-Host "  $($jdbcSrc.Name) -> portable\prcc_bundle\drivers\"
    }

    # -------------------------------------------------------------------------
    # Step 3 - Build dated zip (previous zips are kept)
    # -------------------------------------------------------------------------
    Write-Host "[Step 9] Building zip ..." -ForegroundColor Cyan

    $stamp   = Get-Date -Format "yyyyMMdd"
    $zipName = "pad_oler_ssi_val_prcc_$stamp.zip"
    $zipPath = Join-Path $dist $zipName

    Compress-Archive -Path (Join-Path $bundle "*") -DestinationPath $zipPath -Force

    $sizeMB = [math]::Round((Get-Item $zipPath).Length / 1MB, 1)
    Write-Host ""
    Write-Host "Step 9 complete: $zipName ($sizeMB MB)" -ForegroundColor Green
    Write-Host "Location: $zipPath" -ForegroundColor Green

} finally {
    Pop-Location
}
