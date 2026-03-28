#!/usr/bin/env Rscript
# Optional preflight checks before running the canonical workflow.

# -----------------------------------------------------------------------------
# Chunk 1: Determine script location and normalize working directory.
# Purpose:
# - Make this script robust whether invoked as `Rscript workflow/...` or sourced
#   interactively from a different current directory.
# - Ensure all subsequent relative paths (e.g., `config.R`, `cohorts/...`) are
#   resolved from the project root, not the caller's shell directory.
# Outcome:
# - If the script path can be inferred, `setwd()` points to repo root.
# -----------------------------------------------------------------------------

resolve_script_path <- function() {
  # Rscript invocation often includes a --file=... argument; prefer that.
  file_arg <- grep("^--file=", commandArgs(trailingOnly = FALSE), value = TRUE)
  if (length(file_arg) > 0) {
    return(normalizePath(sub("^--file=", "", file_arg[1]), winslash = "/", mustWork = FALSE))
  }

  # Fallback for some sourced execution contexts where `ofile` is available.
  if (!is.null(sys.frames()[[1]]$ofile)) {
    return(normalizePath(sys.frames()[[1]]$ofile, winslash = "/", mustWork = FALSE))
  }

  # If neither mechanism works, keep current working directory as-is.
  NA_character_
}

script_path <- resolve_script_path()
if (!is.na(script_path)) {
  setwd(normalizePath(file.path(dirname(script_path), ".."), winslash = "/", mustWork = FALSE))
}

# -----------------------------------------------------------------------------
# Chunk 2: Activate project environment and source core helpers.
# Purpose:
# - Load the project-local `renv` library (if present) so package versions are
#   consistent with the repository lockfile.
# - Load configuration and shared helper functions used by this preflight.
# Outcome:
# - Runtime environment and helper functions are available for checks below.
# -----------------------------------------------------------------------------

if (file.exists("renv/activate.R")) source("renv/activate.R")

source("config.R")
source("R/drivers.R")
source("R/connection.R")

# -----------------------------------------------------------------------------
# Chunk 3: Verify required R packages are installed.
# Purpose:
# - Detect missing dependencies early (before long workflow steps fail later).
# - Keep this check non-fatal so first-time setup can still proceed with an
#   actionable note to run Step 1 installation.
# Outcome:
# - Emits an informational message listing missing packages, if any.
# -----------------------------------------------------------------------------

required_packages <- c("DatabaseConnector", "SqlRender", "jsonlite", "data.table")
missing_packages <- required_packages[!vapply(required_packages, requireNamespace, logical(1), quietly = TRUE)]
if (length(missing_packages) > 0) {
  message("Preflight note: missing packages (run Step 1 to install): ", paste(missing_packages, collapse = ", "))
}

# -----------------------------------------------------------------------------
# Chunk 4: Validate required repository artifacts exist.
# Purpose:
# - Ensure critical SQL/cohort/risk-score/module files are present in the repo.
# - Fail fast with a concrete missing-file list if the checkout is incomplete.
# Outcome:
# - Hard stop (`stop`) when required files are missing.
# -----------------------------------------------------------------------------

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

# -----------------------------------------------------------------------------
# Chunk 5: Check expected Synthea CSV inputs are present.
# Purpose:
# - Verify that the minimal CSV set needed for ETL exists at the configured
#   input directory (override via `WORKFLOW_CSV_INPUT_DIR`).
# - Keep non-fatal to allow users to run setup steps before ETL execution.
# Outcome:
# - Emits path + missing-file notes when CSV inputs are incomplete.
# -----------------------------------------------------------------------------

csv_dir <- Sys.getenv("WORKFLOW_CSV_INPUT_DIR", unset = "C:/Users/rapiduser/source/repos/synthea/output/csv")
required_csv <- c("patients.csv", "encounters.csv", "procedures.csv", "conditions.csv")
missing_csv <- required_csv[!file.exists(file.path(csv_dir, required_csv))]

if (length(missing_csv) > 0) {
  message("Preflight note: CSV input directory is missing one or more files: ", paste(missing_csv, collapse = ", "))
  message("CSV directory checked: ", csv_dir)
}

# -----------------------------------------------------------------------------
# Chunk 6: Perform a lightweight database connectivity probe.
# Purpose:
# - Confirm JDBC + credentials + DB reachability before the workflow runs.
# - Only run when DB packages are available; otherwise provide a skip note.
# Outcome:
# - Executes `SELECT 1` against the configured DB and errors on empty result.
# -----------------------------------------------------------------------------

config <- get_validation_config()
can_ping_db <- all(c("DatabaseConnector", "SqlRender") %in% required_packages[!(required_packages %in% missing_packages)])
if (isTRUE(can_ping_db)) {
  # Ensure Java/JDBC runtime env vars are set consistently for DB calls.
  configure_java(config)

  # Open a connection and guarantee cleanup on any exit path.
  conn <- DatabaseConnector::connect(build_connection_details(config))
  on.exit(DatabaseConnector::disconnect(conn), add = TRUE)

  # Small translated query to validate DB connectivity in a dialect-safe way.
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

# -----------------------------------------------------------------------------
# Chunk 7: Final summary message.
# Purpose:
# - Provide a single success line describing scope of checks performed.
# -----------------------------------------------------------------------------

cat("Preflight complete: configuration and required artifacts verified; database connectivity checked when DB packages are available.\n")