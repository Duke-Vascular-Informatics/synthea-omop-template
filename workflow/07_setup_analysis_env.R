#!/usr/bin/env Rscript
# =============================================================================
# workflow/07_setup_analysis_env.R
#
# Step 7: Verify the analysis environment before running Step 8.
#
# PURPOSE
# -------
# Confirms that every R package required by Step 8 is installed and that the
# SQL Server JDBC driver bundle is present in the project-local drivers/
# folder.  Step 7 does NOT install Synthea, ETL, or ML-training packages —
# those belong to earlier workflow steps.
#
# PREREQUISITES
# -------------
#   - renv has been initialised (setup/setup_renv.R run once).
#   - Project packages have been installed (setup/install_packages.R run once).
#   - Java >= 11 is installed and JAVA_HOME is configured in config.R.
#
# EXECUTION
# ---------
#   Rscript workflow/07_setup_analysis_env.R
#   (Run from the project root, or source interactively from RStudio.)
# =============================================================================


# -----------------------------------------------------------------------------
# 1. Locate and source the workflow bootstrap
# -----------------------------------------------------------------------------
# Resolves the project root from the --file= argument when called via Rscript,
# and falls back to the conventional relative path when sourced interactively.
bootstrap_path <- local({
  file_arg <- grep("^--file=", commandArgs(trailingOnly = FALSE), value = TRUE)
  if (length(file_arg) > 0) {
    normalizePath(
      file.path(dirname(sub("^--file=", "", file_arg[1])), "workflow_bootstrap.R"),
      winslash = "/",
      mustWork = FALSE
    )
  } else {
    "workflow/workflow_bootstrap.R"
  }
})
source(bootstrap_path)
set_workflow_root()


# -----------------------------------------------------------------------------
# 2. Activate renv
# -----------------------------------------------------------------------------
# Pins every package to the version recorded in renv.lock, ensuring the same
# library state as when the project was last snapshotted.  Safe to call on
# every run — renv is a no-op if already active.
if (file.exists("renv/activate.R")) source("renv/activate.R")


# -----------------------------------------------------------------------------
# 3. Verify all packages required by Step 8
# -----------------------------------------------------------------------------
# This is the exact set of packages loaded or called (via ::) across the four
# R source files that Step 8 executes:
#
#   workflow/08_run_analysis_and_manuscript_report.R
#     library(DatabaseConnector)
#     library(PatientLevelPrediction)
#
#   R/risk_score_pipeline.R
#     SqlRender::render / ::translate
#     DatabaseConnector::querySql / ::connect / ::disconnect
#     dplyr (data manipulation)
#     readr::write_csv
#     pROC::roc / ::auc
#     PRROC::pr.curve
#
#   R/report_extended.R
#     library(officer)
#     library(flextable)
#     library(ggplot2)
#     library(pROC)
#     SqlRender::render / ::translate
#   Note: writexl was removed when Excel export was dropped from Step 8.
#
#   R/cohorts.R / R/cohort_demographics.R
#     SqlRender::render / ::translate
#     DatabaseConnector::querySql
required <- c(
  "DatabaseConnector",      # JDBC database connectivity (>= 6.0)
  "SqlRender",              # SQL dialect translation and parameterisation
  "PatientLevelPrediction", # cohort-building helpers used by R/cohorts.R
  "dplyr",                  # data manipulation in score pipeline
  "ggplot2",                # calibration and ROC plots
  "readr",                  # CSV I/O for score output files
  "officer",                # Word document assembly
  "flextable",              # Table formatting inside Word report
  "pROC",                   # AUROC computation
  "PRROC"                   # AUPRC computation
)

missing_pkgs <- required[
  !vapply(required, requireNamespace, logical(1L), quietly = TRUE)
]

if (length(missing_pkgs) > 0) {
  stop(
    "The following packages required by Step 8 are not installed:\n",
    paste0("  - ", missing_pkgs, collapse = "\n"),
    "\n\nRun setup/install_packages.R in a fresh R session to install them,",
    "\nthen re-run Step 7."
  )
}

message("Package check passed. All ", length(required),
        " required packages are installed:")
for (pkg in required) {
  ver <- tryCatch(
    as.character(utils::packageVersion(pkg)),
    error = function(e) "?"
  )
  message(sprintf("  %-30s %s", pkg, ver))
}


# -----------------------------------------------------------------------------
# 4. Verify the JDBC driver bundle
# -----------------------------------------------------------------------------
# ensure_jdbc_bundle() (R/drivers.R) checks whether the mssql-jdbc runtime jar
# exists in drivers/jdbc-runtime/.  If it does not, it downloads and extracts
# the official Microsoft JDBC zip (once) — subsequent calls are instant.
# This step must succeed before Step 8 can open any database connection.
source("config.R")
source("R/drivers.R")
config <- get_validation_config()
ensure_jdbc_bundle(config)
message("JDBC driver verified: ",
        file.path(config$jdbc_runtime_dir,
                  paste0("mssql-jdbc-", config$sql_server_jdbc_version,
                         ".jre11.jar")))


# -----------------------------------------------------------------------------
# 5. Done
# -----------------------------------------------------------------------------
message("\nStep 7 complete: analysis environment is ready for Step 8.")
message("Next: Rscript workflow/08_run_analysis_and_manuscript_report.R")
