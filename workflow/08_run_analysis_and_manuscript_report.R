#!/usr/bin/env Rscript
# Step 8: Perform analysis and generate manuscript-format report.

source("workflow/workflow_bootstrap.R")
set_workflow_root()

loaded_java_ns <- intersect(
  c("rJava", "DatabaseConnector", "PatientLevelPrediction"),
  loadedNamespaces()
)
if (length(loaded_java_ns) > 0) {
  stop(
    "Run this script in a FRESH R session. Already loaded: ",
    paste(loaded_java_ns, collapse = ", ")
  )
}

if (file.exists("renv/activate.R")) source("renv/activate.R")

source("config.R")
source("R/drivers.R")
source("R/connection.R")
source("R/risk_score_pipeline.R")
source("R/cohorts.R")
source("R/report_extended.R")

configure_java(get_validation_config())

library(DatabaseConnector)
library(PatientLevelPrediction)

message("[Step 8] Loading config ...")
config <- get_validation_config()

message("[Step 8] Preparing cohorts ...")
connection_details <- build_connection_details(config)
cohort_conn <- DatabaseConnector::connect(connection_details)
ensure_results_schema(cohort_conn, config)
build_cohorts(cohort_conn, config)
DatabaseConnector::disconnect(cohort_conn)

message("[Step 8] Running integer risk score analysis ...")
results <- run_integer_risk_score_pipeline(config, connection_details)
print(results$metrics)

message("[Step 8] Generating manuscript report ...")
report_path <- generate_manuscript_report(
  output_dir = config$risk_score_output_folder,
  score_output_dir = config$risk_score_output_folder,
  cleanup_old_outputs = FALSE
)

message("[Step 8] Report written to: ", report_path)

cat("Step 8 complete: analysis executed and manuscript report generated.\n")
