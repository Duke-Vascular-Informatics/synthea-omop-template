#!/usr/bin/env Rscript
# Step 8: Perform analysis and generate manuscript-format report.

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

# Resolve active CDM schema for analysis runs. Step 5 may load into
# auto-incremented schemas (for example omop_synth_pad_oler_ssi_02) while
# config.R may still point to cdm_synthea.
resolve_active_cdm_schema <- function(connection_details, fallback_schema) {
  conn <- DatabaseConnector::connect(connection_details)
  on.exit(DatabaseConnector::disconnect(conn), add = TRUE)

  candidate_sql <- "
    SELECT name
    FROM sys.schemas
    WHERE name = 'omop_synth_pad_oler_ssi'
       OR name LIKE 'omop_synth_pad_oler_ssi[_]%';"
  candidates <- DatabaseConnector::querySql(conn, candidate_sql, snakeCaseToCamelCase = TRUE)

  schema_names <- if (nrow(candidates) > 0) as.character(candidates$name) else character(0)
  if (length(schema_names) == 0L) {
    return(fallback_schema)
  }

  best_schema <- NA_character_
  best_n <- -1
  for (schema_name in schema_names) {
    safe_schema <- gsub("'", "''", schema_name, fixed = TRUE)
    probe_sql <- paste0(
      "SELECT ",
      "CASE WHEN OBJECT_ID('[", safe_schema, "].[person]', 'U') IS NULL THEN 0 ELSE 1 END AS has_person, ",
      "CASE WHEN OBJECT_ID('[", safe_schema, "].[visit_occurrence]', 'U') IS NULL THEN 0 ELSE 1 END AS has_visit_occurrence, ",
      "CASE WHEN OBJECT_ID('[", safe_schema, "].[condition_occurrence]', 'U') IS NULL THEN 0 ELSE 1 END AS has_condition_occurrence, ",
      "CASE WHEN OBJECT_ID('[", safe_schema, "].[person]', 'U') IS NULL THEN 0 ELSE (SELECT COUNT_BIG(*) FROM [", safe_schema, "].[person]) END AS person_n;"
    )

    probe <- suppressWarnings(try(DatabaseConnector::querySql(conn, probe_sql, snakeCaseToCamelCase = TRUE), silent = TRUE))
    if (inherits(probe, "try-error") || nrow(probe) == 0L) {
      next
    }

    has_required <- as.integer(probe$hasPerson[[1]]) == 1L &&
      as.integer(probe$hasVisitOccurrence[[1]]) == 1L &&
      as.integer(probe$hasConditionOccurrence[[1]]) == 1L
    if (!has_required) {
      next
    }

    n <- as.numeric(probe$personN[[1]])
    if (is.finite(n) && n > best_n) {
      best_n <- n
      best_schema <- schema_name
    }
  }

  if (!is.na(best_schema)) best_schema else fallback_schema
}

message("[Step 8] Preparing cohorts ...")
connection_details <- build_connection_details(config)
config$cdm_schema <- resolve_active_cdm_schema(connection_details, config$cdm_schema)
message("[Step 8] Using CDM schema: ", config$cdm_schema)
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
