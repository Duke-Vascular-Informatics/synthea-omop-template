param()

# =============================================================================
# workflow/09_build_portable_analysis_bundle.ps1
#
# Step 9 - Build the Duke PRCC portable analysis bundle.
#
# PURPOSE
# -------
# This script packages the PAD/OLER SSI integer risk score external validation
# analysis into a self-contained zip file that can be transferred to and run on
# the Duke PRCC (Phoenix Research Computing Cluster).
#
# The bundle lives in portable/prcc_bundle/ in this repository.  Step 9 keeps
# that bundle up-to-date by pulling in the latest shared R source files and
# JDBC driver JAR from the main project before zipping everything up.
#
# DEPLOYMENT WORKFLOW
# -------------------
# 1. Run this script on the developer workstation to produce a dated zip in
#    dist/ (e.g. dist/pad_oler_ssi_val_prcc_20260410.zip).
# 2. Transfer the zip to PRCC:
#      scp dist/pad_oler_ssi_val_prcc_<date>.zip <netid>@login.rc.duke.edu:/data/pro00119168/
# 3. On PRCC, unzip keeping the dated zip folder name (do NOT rename it):
#      cd /data/pro00119168
#      unzip pad_oler_ssi_val_prcc_<date>.zip -d pad_oler_ssi_val_prcc_<date>
#    This produces: /data/pro00119168/pad_oler_ssi_val_prcc_<date>/
# 4. Also place the Duke SOM-HPC custom JDBC wrapper JAR one level above the
#    bundle, in a drivers/ sibling folder:
#      /data/pro00119168/drivers/prcc-jdbc-mssql-1.0-SNAPSHOT.jar
#    config.R resolves this path automatically as dirname(bundle)/drivers/.
#    (This JAR is provided by Duke DHTS/SOM-HPC and is NOT included in the
#    bundle because it is a site-specific file we do not redistribute.)
# 5. Follow setup_prcc_env.sh and config.R instructions to fill in credentials
#    and database connection details, then run:
#      cd /data/pro00119168/pad_oler_ssi_val_prcc_<date>
#      bash setup_prcc_env.sh
#      conda activate openjdk
#      export KRB5CCNAME=FILE:~/krb5cc_java && kinit
#      Rscript run_analysis.R
#
# WHAT THIS SCRIPT DOES
# ---------------------
#   1. Syncs shared R source files from the main project (R/, risk_score/,
#      cohorts/) into portable/prcc_bundle/ so the bundle always reflects the
#      current analysis code.
#   2. Copies the standard MSSQL JDBC JAR from drivers/jdbc-runtime/ into
#      portable/prcc_bundle/drivers/ so PRCC has the driver it needs.
#   3. Builds a dated zip: dist/pad_oler_ssi_val_prcc_<YYYYMMDD>.zip.
#      Previous zips in dist/ are retained so that any version already
#      transferred to PRCC can still be reproduced or compared.
#
# FILES THAT ARE *NOT* OVERWRITTEN BY THIS SCRIPT
# ------------------------------------------------
# The following files inside portable/prcc_bundle/ are PRCC-specific.  They
# contain site-specific configuration, Kerberos authentication logic, and
# install steps that differ between the developer workstation and PRCC.
# Overwriting them with the main-project versions would break PRCC execution:
#
#   portable/prcc_bundle/R/connection.R
#       Configures the JVM (JAVA_HOME, heap, JAAS config), adds both JDBC JARs
#       to the classpath via rJava::.jaddClassPath(), and builds the full JDBC
#       URL with authenticationScheme=JavaKerberos.  Completely different from
#       the standard Windows ODBC connection used on the developer workstation.
#
#   portable/prcc_bundle/config.R
#       Resolves JAVA_HOME from the active conda environment, sets the path to
#       the Duke SOM-HPC custom JAR (~/drivers/), and contains CHANGE_ME
#       placeholders for the PRCC-specific SQL Server host, database, and
#       schema names.
#
#   portable/prcc_bundle/run_analysis.R
#       Entry-point script for PRCC execution.  Calls configure_java_prcc()
#       BEFORE library(DatabaseConnector) — this ordering is required so that
#       java.parameters and the classpath are set before the JVM starts.
#
#   portable/prcc_bundle/install_packages.R
#       Installs R packages from CRAN/Bioconductor using the miniforge/conda R
#       environment available on PRCC; includes packages not needed on Windows.
#
#   portable/prcc_bundle/setup_prcc_env.sh
#       Shell script that activates the conda openjdk environment, obtains a
#       Kerberos ticket (kinit), and sets KRB5CCNAME so the JAAS config can
#       find the ticket cache file.
# =============================================================================

$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot  = Resolve-Path (Join-Path $scriptDir "..")
Push-Location $repoRoot

try {

    $bundle = Join-Path $repoRoot "portable\prcc_bundle"
    $dist   = Join-Path $repoRoot "dist"

    # Verify the bundle skeleton exists.  It is checked into version control and
    # must be present before this script runs.  The dist/ output directory is
    # created on first use if it does not yet exist.
    if (!(Test-Path $bundle)) { throw "PRCC bundle directory not found: $bundle" }
    if (!(Test-Path $dist))   { New-Item -ItemType Directory -Path $dist | Out-Null }

    # -------------------------------------------------------------------------
    # Step 1 - Sync R source files from main project into bundle
    #
    # WHY: The analysis R source files (risk score pipeline, cohort definitions,
    # demographics, report generation) are developed and tested on the developer
    # workstation under R/ and related directories.  The PRCC bundle must always
    # run the same version of these shared files.  Rather than maintaining two
    # separate copies manually, this script copies the canonical versions into
    # the bundle at build time.
    #
    # The helper function Copy-BundleFile handles three things:
    #   a) Warns and skips gracefully if a source file is unexpectedly missing
    #      (so a missing optional file doesn't abort the whole build).
    #   b) Creates intermediate destination directories if they don't exist yet.
    #   c) Logs each copy operation to the console for traceability.
    #
    # FILE INVENTORY (what each file does):
    #
    #   R/risk_score_pipeline.R
    #       Core pipeline: joins cohort table to OMOP condition/procedure data,
    #       scores each patient using the integer risk score components, computes
    #       AUROC, AUPRC, ECE, calibration tables, bootstrap CIs, subgroup bias
    #       assessment, and writes all output CSVs and PNGs.
    #
    #   R/cohorts.R
    #       Instantiates target (PAD surgery) and outcome (SSI) cohorts from SQL
    #       templates.  Handles both custom SQL (cohorts/*.sql) and pre-existing
    #       ATLAS cohorts via use_atlas_cohorts flag in config.R.
    #
    #   R/cohort_demographics.R
    #       Queries the OMOP person table to retrieve sex, race, ethnicity, and
    #       age at index for each patient.  Used by the subgroup bias assessment
    #       section of the pipeline (compute_subgroup_bias).
    #
    #   R/report_extended.R  →  portable/prcc_bundle/R/report.R
    #       Generates the manuscript-ready Word document (officer/flextable),
    #       including the discrimination/calibration table, calibration plots,
    #       and the subgroup ECE forest plot.  Note the filename translation:
    #       the bundle always calls this file report.R regardless of the source
    #       name in the main project.
    #
    #   risk_score/components.csv
    #       Lookup table of integer risk score component names, weights, and
    #       directions.  Defines which clinical covariates contribute to the
    #       score and by how many points.
    #
    #   risk_score/component_concepts.csv
    #       Maps each risk score component to one or more OMOP standard concept
    #       IDs so the pipeline can look up the component in the CDM without
    #       hard-coding vocabulary-specific codes.
    #
    #   risk_score/risk_lookup.csv
    #       Pre-computed risk probability lookup table: maps each possible
    #       integer total score to the predicted 90-day SSI probability from the
    #       original derivation study.
    #
    #   cohorts/target_surgery.sql
    #       OMOP SQL template that identifies the PAD surgery target cohort
    #       (index event = PAD-related lower-extremity vascular surgery).
    #       Uses SqlRender parameterisation for schema/table substitution.
    #
    #   cohorts/outcome_ssi.sql
    #       OMOP SQL template that identifies the SSI outcome cohort (surgical
    #       site infection diagnosed within the prediction window after the index
    #       procedure date).
    # -------------------------------------------------------------------------
    Write-Host "[Step 9] Syncing R source files ..." -ForegroundColor Cyan

    # Helper: copy one file from the main project into the bundle.
    # $src and $dst are paths relative to $repoRoot.
    function Copy-BundleFile($src, $dst) {
        $srcPath = Join-Path $repoRoot $src
        $dstPath = Join-Path $repoRoot $dst
        if (!(Test-Path $srcPath)) { Write-Warning "Not found, skipping: $src"; return }
        $dstDir = Split-Path -Parent $dstPath
        if (!(Test-Path $dstDir)) { New-Item -ItemType Directory -Path $dstDir | Out-Null }
        Copy-Item -Path $srcPath -Destination $dstPath -Force
        Write-Host "  $src -> $dst"
    }

    # --- Shared R analysis modules ---
    Copy-BundleFile "R\risk_score_pipeline.R"        "portable\prcc_bundle\R\risk_score_pipeline.R"
    Copy-BundleFile "R\cohorts.R"                    "portable\prcc_bundle\R\cohorts.R"
    Copy-BundleFile "R\cohort_demographics.R"        "portable\prcc_bundle\R\cohort_demographics.R"
    # report_extended.R is the developer-workstation filename; the bundle
    # always loads it as report.R (see run_analysis.R: source("R/report.R")).
    Copy-BundleFile "R\report_extended.R"            "portable\prcc_bundle\R\report.R"

    # --- Integer risk score reference data ---
    Copy-BundleFile "risk_score\components.csv"          "portable\prcc_bundle\risk_score\components.csv"
    Copy-BundleFile "risk_score\component_concepts.csv"  "portable\prcc_bundle\risk_score\component_concepts.csv"
    Copy-BundleFile "risk_score\risk_lookup.csv"         "portable\prcc_bundle\risk_score\risk_lookup.csv"

    # --- OMOP cohort SQL templates ---
    Copy-BundleFile "cohorts\target_surgery.sql"     "portable\prcc_bundle\cohorts\target_surgery.sql"
    Copy-BundleFile "cohorts\outcome_ssi.sql"        "portable\prcc_bundle\cohorts\outcome_ssi.sql"

    # -------------------------------------------------------------------------
    # Step 2 - Sync MSSQL JDBC JAR into bundle/drivers/
    #
    # WHY: Connecting to the Duke SQL Server from a Linux/PRCC R session requires
    # the Microsoft MSSQL JDBC driver.  This is the *standard* JDBC JAR from
    # Microsoft (mssql-jdbc-*.jre11.jar).  It is separate from the Duke SOM-HPC
    # custom wrapper JAR (prcc-jdbc-mssql-1.0-SNAPSHOT.jar), which is NOT
    # included in this bundle for the following reasons:
    #
    #   1. It is provided directly by Duke DHTS/SOM-HPC and is not ours to
    #      redistribute in a shared zip.
    #   2. Its location on each user's PRCC home directory may vary; config.R
    #      resolves it dynamically from ~/drivers/ at runtime.
    #
    # The standard MSSQL JDBC JAR is committed into drivers/jdbc-runtime/ in
    # this repository and IS included in the bundle because:
    #   - It is publicly available from Microsoft under the MIT licence.
    #   - Including it means the bundle is self-contained for the standard
    #     driver — users only need to obtain the Duke-specific wrapper separately.
    #
    # The JAR is found by glob (mssql-jdbc-*.jre11.jar) so that a version bump
    # in the filename does not require editing this script.  Only the first
    # match is copied; there should never be more than one version present.
    #
    # IMPORTANT: drivers/jaas.conf is NOT copied here.  That file is generated
    # at runtime by connection.R (write_jaas_conf()) because its content depends
    # on the user's live Kerberos ticket cache path (KRB5CCNAME), which is only
    # known on PRCC at the moment R is launched.
    # -------------------------------------------------------------------------
    Write-Host "[Step 9] Syncing JDBC JAR ..." -ForegroundColor Cyan

    $jdbcSrc = Get-ChildItem -Path (Join-Path $repoRoot "drivers\jdbc-runtime") `
                             -Filter "mssql-jdbc-*.jre11.jar" `
                             -ErrorAction SilentlyContinue | Select-Object -First 1

    if ($null -eq $jdbcSrc) {
        # Non-fatal: the JAR may have already been placed in the bundle manually.
        # The script warns but continues so the zip can still be built.
        Write-Warning "JDBC JAR not found in drivers\jdbc-runtime\ - skipping."
    } else {
        $jdbcDst = Join-Path $bundle "drivers\$($jdbcSrc.Name)"
        Copy-Item -Path $jdbcSrc.FullName -Destination $jdbcDst -Force
        Write-Host "  $($jdbcSrc.Name) -> portable\prcc_bundle\drivers\"
    }

    # -------------------------------------------------------------------------
    # Step 3 - Build dated zip (previous zips are kept)
    #
    # WHY A DATED FILENAME:
    #   Each build receives a date-stamped name (pad_oler_ssi_val_prcc_YYYYMMDD.zip)
    #   so that multiple versions can coexist in dist/.  This matters because:
    #     - A zip may already be in transit to or deployed on PRCC when a new
    #       build is made.  The dated name lets us identify which version is
    #       running on PRCC at any given time.
    #     - If a regression is introduced and PRCC results change unexpectedly,
    #       an earlier zip can be retrieved and re-deployed without a git checkout.
    #     - The date provides an audit trail linking PRCC results to a specific
    #       snapshot of the analysis code.
    #
    # WHY PREVIOUS ZIPS ARE NOT DELETED:
    #   Old zips are intentionally retained.  Every build produces a unique
    #   filename so no zip is ever overwritten.  dist/ is in .gitignore so
    #   the zip files do not bloat the repository; they are local build
    #   artefacts only.
    #
    # FILENAME SCHEME — multiple builds on the same day:
    #   First build of the day  : pad_oler_ssi_val_prcc_YYYYMMDD.zip
    #   Second build of the day : pad_oler_ssi_val_prcc_YYYYMMDD_1.zip
    #   Third build of the day  : pad_oler_ssi_val_prcc_YYYYMMDD_2.zip
    #   ...and so on.
    #   The counter is found by scanning dist/ for existing files that match
    #   the date prefix and taking the next available number.
    #
    # WHAT IS INCLUDED IN THE ZIP:
    #   Everything under portable/prcc_bundle/* is zipped EXCEPT output/.
    #   The output/ directory is excluded because:
    #     - It is created at runtime by run_integer_risk_score_pipeline().
    #     - Including a pre-existing directory in the zip causes it to be
    #       extracted with the permissions stored in the zip (often read-only
    #       on Linux), making it unwritable when the pipeline tries to save CSVs.
    #   Included items:
    #     - R/            shared analysis modules (just synced in Step 1)
    #     - risk_score/   integer score reference CSVs
    #     - cohorts/      OMOP SQL templates
    #     - drivers/      mssql-jdbc-*.jre11.jar (just synced in Step 2)
    #     - config.R             PRCC-specific config with CHANGE_ME placeholders
    #     - run_analysis.R       PRCC entry-point script
    #     - connection.R         PRCC Kerberos/JVM setup (inside R/)
    #     - install_packages.R   R package installer (called by install_r_packages.sh)
    #     - setup_prcc_env.sh    Step 1: conda env creation + Kerberos ticket
    #     - install_r_packages.sh  Step 2: activates env + runs install_packages.R
    #
    # WHAT IS *NOT* IN THE ZIP:
    #     - prcc-jdbc-mssql-1.0-SNAPSHOT.jar  (Duke SOM-HPC JAR, not ours to ship)
    #     - jaas.conf                           (generated at runtime from env vars)
    #     - Any files under dist/, workflow/, or the main project R/ directly
    # -------------------------------------------------------------------------
    Write-Host "[Step 9] Building zip ..." -ForegroundColor Cyan

    $stamp    = Get-Date -Format "yyyyMMdd"
    $base     = "pad_oler_ssi_val_prcc_$stamp"

    # Find the next available filename for today.
    # Existing files that match today's date are counted so the new zip always
    # gets a unique name:
    #   pad_oler_ssi_val_prcc_YYYYMMDD.zip      (no suffix — first of the day)
    #   pad_oler_ssi_val_prcc_YYYYMMDD_1.zip    (second build)
    #   pad_oler_ssi_val_prcc_YYYYMMDD_2.zip    (third build)  ...
    $existing = @(Get-ChildItem -Path $dist -Filter "${base}*.zip" -ErrorAction SilentlyContinue)
    if ($existing.Count -eq 0) {
        $zipName = "${base}.zip"
    } else {
        $zipName = "${base}_$($existing.Count).zip"
    }

    $zipPath = Join-Path $dist $zipName

    # Exclude output/ — it is created at runtime by run_integer_risk_score_pipeline().
    # Including it causes Linux to extract it with read-only permissions, which
    # prevents the pipeline from writing result CSVs.
    $zipItems = Get-ChildItem -Path $bundle |
                Where-Object { $_.Name -ne "output" } |
                ForEach-Object { $_.FullName }
    Compress-Archive -Path $zipItems -DestinationPath $zipPath

    $sizeMB = [math]::Round((Get-Item $zipPath).Length / 1MB, 1)
    Write-Host ""
    Write-Host "Step 9 complete: $zipName ($sizeMB MB)" -ForegroundColor Green
    Write-Host "Location: $zipPath" -ForegroundColor Green

} finally {
    Pop-Location
}
