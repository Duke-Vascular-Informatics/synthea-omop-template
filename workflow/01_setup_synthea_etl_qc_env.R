#!/usr/bin/env Rscript
# Step 1: Install packages and initialize environment for Synthea generation, ETL, and data checks.

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

source("setup/setup_renv.R")
source("setup/install_packages.R")
source("config.R")
source("R/drivers.R")
source("R/connection.R")

if (!requireNamespace("DatabaseConnector", quietly = TRUE)) {
  if (!requireNamespace("renv", quietly = TRUE)) {
    stop("DatabaseConnector is missing and renv is unavailable to install it.")
  }
  options(repos = c(CRAN = "https://archive.linux.duke.edu/cran/"))
  message("DatabaseConnector not found after setup; installing via renv::install('DatabaseConnector') ...")
  renv::install("DatabaseConnector")
}

required <- c("DatabaseConnector", "SqlRender", "jsonlite", "data.table")
missing <- required[!vapply(required, requireNamespace, logical(1), quietly = TRUE)]
if (length(missing) > 0) {
  stop("Missing required packages after setup: ", paste(missing, collapse = ", "))
}

config <- get_validation_config()
connection_details <- build_connection_details(config)
run_db_preflight(
  connection_details = connection_details,
  required_successes = 3L,
  max_attempts = 10L,
  delay_seconds = 2
)

cat("Step 1 complete: environment and packages are ready, and database connectivity preflight passed.\n")
