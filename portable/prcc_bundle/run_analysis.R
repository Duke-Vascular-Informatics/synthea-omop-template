#!/usr/bin/env Rscript
# =============================================================================
# run_analysis.R
#
# Entry point for the PAD/OLER SSI integer risk score external validation on
# Duke PRCC against institutional OMOP CDM data.
#
# PREREQUISITES (run setup_prcc_env.sh first):
#   1. conda activate openjdk          — Java from conda-forge on PATH
#   2. export KRB5CCNAME=FILE:~/krb5cc_java && kinit   — Kerberos ticket
#   3. Edit config.R                   — fill in server, database, schemas
#
# EXECUTION:
#   Rscript run_analysis.R
#   (Run from the bundle directory in a FRESH R session.)
#
# OUTPUTS (written to output/risk_score_eval/):
#   person_level_scores.csv            — per-patient scores and outcomes
#   component_summary.csv              — component-level prevalence
#   metrics.csv                        — discrimination/calibration + 95% CIs
#   calibration_table_*.csv            — calibration decile tables
#   calibration_*.png                  — calibration plots
#   pad-oler-ssi-val_report_<date>.docx — manuscript Word report
#   pad_oler_ssi_fringe_<date>.xlsx    — fringe-case Excel (clinical QC)
# =============================================================================

# -----------------------------------------------------------------------------
# JVM guard — must run in a fresh R session
# -----------------------------------------------------------------------------
loaded_java_ns <- intersect(
  c("rJava", "DatabaseConnector", "PatientLevelPrediction"),
  loadedNamespaces()
)
if (length(loaded_java_ns) > 0) {
  stop(
    "Run this script in a FRESH R session.\n",
    "Already-loaded namespaces that conflict: ",
    paste(loaded_java_ns, collapse = ", ")
  )
}

# -----------------------------------------------------------------------------
# Working directory
# -----------------------------------------------------------------------------
# Resolve the bundle root from the --file= argument so the script works
# regardless of the shell's current directory.
local({
  file_arg <- grep("^--file=", commandArgs(trailingOnly = FALSE), value = TRUE)
  if (length(file_arg) > 0) {
    bundle_dir <- normalizePath(
      dirname(sub("^--file=", "", file_arg[[1]])),
      mustWork = FALSE
    )
    if (bundle_dir != getwd()) {
      setwd(bundle_dir)
      message("[run_analysis] Working directory set to: ", bundle_dir)
    }
  }
})

# -----------------------------------------------------------------------------
# Source project modules
# -----------------------------------------------------------------------------
source("config.R")
source("R/drivers.R")
source("R/connection.R")
source("R/cohorts.R")
source("R/risk_score_pipeline.R")

# Load report module only if officer is available (optional for pipeline-only runs)
has_officer <- requireNamespace("officer",   quietly = TRUE) &&
               requireNamespace("flextable", quietly = TRUE)
if (has_officer) {
  source("R/report.R")
} else {
  message("NOTE: officer/flextable not found — Word report will be skipped.",
          " Run install_packages.R to add report support.")
}

# -----------------------------------------------------------------------------
# Configure Java and initialise JVM BEFORE loading DatabaseConnector.
#
# configure_java_prcc() must run first because it:
#   1. Sets options(java.parameters) — only effective before the JVM starts.
#   2. Writes drivers/jaas.conf for Kerberos login module.
#   3. Calls rJava::.jinit() to start the JVM explicitly.
#   4. Adds both JDBC JARs to the classpath via rJava::.jaddClassPath().
#
# library(DatabaseConnector) is loaded afterwards so it inherits the running
# JVM with the correct classpath already in place.
# -----------------------------------------------------------------------------
message("\n[run_analysis] Loading config ...")
config <- get_validation_config()

message("[run_analysis] Configuring Java and initialising JVM ...")
configure_java_prcc(config)

# -----------------------------------------------------------------------------
# Load heavy packages (JVM already running — classpath already set)
# -----------------------------------------------------------------------------
library(DatabaseConnector)
library(SqlRender)
library(dplyr)
library(ggplot2)
library(pROC)
library(PRROC)
library(readr)

# Validate required CHANGE_ME fields
required_fields <- c("server", "database", "spn_host",
                      "vocab_schema", "cdm_schema", "results_schema")
unset <- required_fields[sapply(required_fields, function(f) {
  v <- config[[f]]
  is.null(v) || (is.character(v) && trimws(v) %in% c("", "CHANGE_ME"))
})]
if (length(unset) > 0) {
  stop(
    "Please fill in the following fields in config.R before running:\n",
    paste0("  ", unset, collapse = "\n")
  )
}

message("[run_analysis] Server  : ", config$server)
message("[run_analysis] Database: ", config$database)
message("[run_analysis] CDM     : ", config$cdm_schema)
message("[run_analysis] Results : ", config$results_schema)
message("[run_analysis] Window  : ", config$prediction_window_days, "-day SSI")

# -----------------------------------------------------------------------------
# Database connection
# -----------------------------------------------------------------------------
message("\n[run_analysis] Building connection details (Kerberos) ...")
connection_details <- build_connection_details(config)

# Quick connectivity test
message("[run_analysis] Testing database connection ...")
test_conn <- tryCatch(
  DatabaseConnector::connect(connection_details),
  error = function(e) {
    stop(
      "Database connection failed: ", conditionMessage(e), "\n\n",
      "Checklist:\n",
      "  1. Kerberos ticket valid?  Run: klist\n",
      "     If expired: export KRB5CCNAME=FILE:~/krb5cc_java && kinit\n",
      "  2. spn_host correct in config.R? (contact DHTS if unsure)\n",
      "  3. Server name correct? server = '", config$server, "'\n",
      "  4. Database name correct? database = '", config$database, "'"
    )
  }
)
DatabaseConnector::disconnect(test_conn)
message("[run_analysis] Connection OK.")

# -----------------------------------------------------------------------------
# Cohort instantiation
# -----------------------------------------------------------------------------
message("\n[run_analysis] Instantiating cohorts ...")
cohort_conn <- DatabaseConnector::connect(connection_details)
ensure_results_schema(cohort_conn, config)
build_cohorts(cohort_conn, config)
DatabaseConnector::disconnect(cohort_conn)

# -----------------------------------------------------------------------------
# Integer risk score pipeline
# -----------------------------------------------------------------------------
message("\n[run_analysis] Running integer risk score pipeline ...")
results <- run_integer_risk_score_pipeline(config, connection_details)
print(results$metrics)

# -----------------------------------------------------------------------------
# Manuscript report (optional — requires officer + flextable)
# -----------------------------------------------------------------------------
if (has_officer) {
  message("\n[run_analysis] Generating manuscript Word report ...")
  report_path <- generate_manuscript_report(
    output_dir          = config$risk_score_output_folder,
    score_output_dir    = config$risk_score_output_folder,
    cleanup_old_outputs = FALSE,
    connection_details  = connection_details,
    config              = config
  )
  message("[run_analysis] Report written to: ", report_path)
} else {
  message("\n[run_analysis] Skipping report generation (officer not installed).")
}

message("\n[run_analysis] All done.")
message("Output folder: ",
        normalizePath(config$risk_score_output_folder, mustWork = FALSE))
