# =============================================================================
# run_validation.R
# PAD / OLER – Surgical Site Infection (SSI) External Validation Pipeline
#
# This is the single entry point for the entire validation study.  Run it in
# a fresh R session from the project root:
#
#   setwd("C:/Users/rapiduser/pad-oler-ssi-val")
#   source("run_validation.R")
#
# Prerequisites (run once, in order):
#   1. source("setup_renv.R")         # initialises renv
#   2. source("install_packages.R")   # installs PLP v6 and dependencies
#   3. Set config$model_path in config.R to your pre-trained plpResult folder.
#
# Pipeline steps executed here:
#   Step 1  Load configuration
#   Step 2  Build database connection details (JDBC / Integrated Security)
#   Step 3  Instantiate target (surgery) and outcome (SSI) cohorts in DB
#   Step 4  Run PatientLevelPrediction::externalValidateDbPlp()
#   Step 5  Print performance summary and launch the Shiny viewer
# =============================================================================

# Guard: must run in a fresh session to avoid rJava / JDBC class-loader issues.
loaded_java_ns <- intersect(
  c("rJava", "DatabaseConnector", "PatientLevelPrediction"),
  loadedNamespaces()
)
if (length(loaded_java_ns) > 0) {
  stop(
    "Run this script in a FRESH R session.\n",
    "The following namespaces are already loaded: ",
    paste(loaded_java_ns, collapse = ", ")
  )
}

# ---------------------------------------------------------------------------
# Bootstrap: activate renv and load helpers
# ---------------------------------------------------------------------------
if (file.exists("renv/activate.R")) source("renv/activate.R")

source("config.R")
source("R/drivers.R")
source("R/connection.R")
source("R/cohorts.R")
source("R/validation.R")

library(DatabaseConnector)
library(SqlRender)
library(PatientLevelPrediction)

# ---------------------------------------------------------------------------
# Step 1 – Configuration
# ---------------------------------------------------------------------------
message("\n[Step 1] Loading configuration ...")
config <- get_validation_config()

message("  Server         : ", config$server, ":", config$sql_server_port)
message("  Database       : ", config$database)
message("  CDM schema     : ", config$cdm_schema)
message("  Results schema : ", config$results_schema)
message("  Cohort table   : ", config$cohort_table)
message("  Model path     : ", config$model_path)
message("  Output folder  : ", config$output_folder)

# ---------------------------------------------------------------------------
# Step 2 – Database connection
# ---------------------------------------------------------------------------
message("\n[Step 2] Building connection details ...")
connection_details <- build_connection_details(config)

# Quick connectivity check
message("  Verifying connection ...")
conn <- DatabaseConnector::connect(connection_details)
DatabaseConnector::disconnect(conn)
message("  Connection OK.")

# ---------------------------------------------------------------------------
# Step 3 – Cohort instantiation
# ---------------------------------------------------------------------------
message("\n[Step 3] Instantiating cohorts ...")
conn <- DatabaseConnector::connect(connection_details)
tryCatch(
  {
    cohort_counts <- build_cohorts(conn, config)
  },
  finally = DatabaseConnector::disconnect(conn)
)

message(sprintf("  Target cohort  (id=%d): %d patients",
                config$target_cohort_id,  cohort_counts$target_n))
message(sprintf("  Outcome cohort (id=%d): %d patients",
                config$outcome_cohort_id, cohort_counts$outcome_n))

if (cohort_counts$target_n == 0) {
  stop("Target cohort is empty – cannot proceed with validation.")
}

# ---------------------------------------------------------------------------
# Step 4 – External validation
# ---------------------------------------------------------------------------
message("\n[Step 4] Running external validation ...")
validation_result <- run_external_validation(config, connection_details)

# ---------------------------------------------------------------------------
# Step 5 – Results summary and viewer
# ---------------------------------------------------------------------------
message("\n[Step 5] Results summary ...")
print_performance_summary(validation_result)

message("\nLaunching Shiny viewer (close the browser tab to exit) ...")
PatientLevelPrediction::viewPlp(validation_result[[1]])
