# =============================================================================
# run_risk_score_pipeline.R
# Entry point for integer risk score evaluation on OMOP target/outcome cohorts.
# =============================================================================

# Run in a fresh R session.
loaded_java_ns <- intersect(
  c("rJava", "DatabaseConnector"),
  loadedNamespaces()
)
if (length(loaded_java_ns) > 0) {
  stop(
    "Run this script in a FRESH R session.\n",
    "Already loaded namespaces: ", paste(loaded_java_ns, collapse = ", ")
  )
}

if (file.exists("renv/activate.R")) source("renv/activate.R")

source("config.R")
source("R/drivers.R")
source("R/connection.R")
source("R/risk_score_pipeline.R")

library(DatabaseConnector)
library(SqlRender)
library(dplyr)
library(ggplot2)
library(pROC)
library(PRROC)
library(readr)

message("\n[RiskScore] Loading config ...")
config <- get_validation_config()

message("[RiskScore] Building DB connection details ...")
connection_details <- build_connection_details(config)

message("[RiskScore] Running integer risk score pipeline ...")
results <- run_integer_risk_score_pipeline(config, connection_details)

print(results$metrics)

message("\n[RiskScore] Done.")
message("Output folder: ", normalizePath(config$risk_score_output_folder, winslash = "/", mustWork = FALSE))
