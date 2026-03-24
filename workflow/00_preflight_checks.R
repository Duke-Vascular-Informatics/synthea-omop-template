#!/usr/bin/env Rscript
# Optional preflight checks before running the canonical workflow.

resolve_script_path <- function() {
  file_arg <- grep("^--file=", commandArgs(trailingOnly = FALSE), value = TRUE)
  if (length(file_arg) > 0) {
    return(normalizePath(sub("^--file=", "", file_arg[1]), winslash = "/", mustWork = FALSE))
  }

  if (!is.null(sys.frames()[[1]]$ofile)) {
    return(normalizePath(sys.frames()[[1]]$ofile, winslash = "/", mustWork = FALSE))
  }

  NA_character_
}

script_path <- resolve_script_path()
if (!is.na(script_path)) {
  setwd(normalizePath(file.path(dirname(script_path), ".."), winslash = "/", mustWork = FALSE))
}

if (file.exists("renv/activate.R")) source("renv/activate.R")

source("config.R")
source("R/drivers.R")
source("R/connection.R")

required_packages <- c("DatabaseConnector", "SqlRender", "jsonlite", "data.table")
missing_packages <- required_packages[!vapply(required_packages, requireNamespace, logical(1), quietly = TRUE)]
if (length(missing_packages) > 0) {
  message("Preflight note: missing packages (run Step 1 to install): ", paste(missing_packages, collapse = ", "))
}

required_files <- c(
  "config.R",
  "cohorts/target_surgery.sql",
  "cohorts/outcome_ssi.sql",
  "risk_score/components.csv",
  "risk_score/component_concepts.csv",
  "risk_score/risk_lookup.csv",
  "synthea/modules/pad_ssi.json",
  "scripts/sql/synthea_csv_to_omop_transform.sql"
)

missing_files <- required_files[!file.exists(required_files)]
if (length(missing_files) > 0) {
  stop("Missing required files: ", paste(missing_files, collapse = ", "))
}

csv_dir <- Sys.getenv("WORKFLOW_CSV_INPUT_DIR", unset = "C:/Users/rapiduser/source/repos/synthea/output/csv")
required_csv <- c("patients.csv", "encounters.csv", "procedures.csv", "conditions.csv")
missing_csv <- required_csv[!file.exists(file.path(csv_dir, required_csv))]

if (length(missing_csv) > 0) {
  message("Preflight note: CSV input directory is missing one or more files: ", paste(missing_csv, collapse = ", "))
  message("CSV directory checked: ", csv_dir)
}

config <- get_validation_config()
can_ping_db <- all(c("DatabaseConnector", "SqlRender") %in% required_packages[!(required_packages %in% missing_packages)])
if (isTRUE(can_ping_db)) {
  configure_java(config)

  conn <- DatabaseConnector::connect(build_connection_details(config))
  on.exit(DatabaseConnector::disconnect(conn), add = TRUE)

  ping_sql <- SqlRender::translate(
    SqlRender::render("SELECT 1 AS ok;"),
    targetDialect = config$dbms
  )
  ping <- DatabaseConnector::querySql(conn, ping_sql)
  if (nrow(ping) == 0) {
    stop("Database preflight query returned no rows.")
  }
} else {
  message("Preflight note: skipped DB connectivity check because DatabaseConnector/SqlRender is not installed yet.")
}

cat("Preflight complete: configuration and required artifacts verified; database connectivity checked when DB packages are available.\n")