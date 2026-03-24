#!/usr/bin/env Rscript
# =============================================================================
# gen_validation_report.R
# Complete workflow: Run risk score pipeline + generate Word report
#
# This script executes the full validation workflow in one step:
# 1. Builds cohorts from OMOP CDM
# 2. Computes integer risk scores
# 3. Evaluates discrimination and calibration
# 4. Generates comprehensive Word document report
#
# Usage:
#   Rscript gen_validation_report.R
# Or from R:
#   source("gen_validation_report.R")
# =============================================================================

cat("\n=== PAD/OLER SSI Validation Report Generation ===\n\n")

# Check for fresh session (required by run_risk_score_pipeline.R)
loaded_java_ns <- intersect(
  c("rJava", "DatabaseConnector"),
  loadedNamespaces()
)
if (length(loaded_java_ns) > 0) {
  stop(
    "ERROR: Cannot run in a session with already-loaded Java/DatabaseConnector.\n",
    "Please run this script in a FRESH R session.\n",
    "Loaded: ", paste(loaded_java_ns, collapse = ", ")
  )
}

cat("[1/2] Running risk score pipeline...\n")

tryCatch({
  source("run_risk_score_pipeline.R")
  cat("✓ Risk score pipeline completed successfully.\n\n")
}, error = function(e) {
  cat("✗ Risk score pipeline failed:\n")
  cat("  ", e$message, "\n\n")
  stop("Cannot continue without risk score data.")
})

cat("[2/2] Generating Word validation report...\n")

tryCatch({
  source("run_report.R")
  cat("✓ Report generation completed successfully.\n\n")
}, error = function(e) {
  cat("✗ Report generation failed:\n")
  cat("  ", e$message, "\n\n")
  stop("Report generation failed.")
})

cat("=== Workflow Complete ===\n")
cat("Report available at: output/risk_score_eval/ssi_validation_report.docx\n\n")
