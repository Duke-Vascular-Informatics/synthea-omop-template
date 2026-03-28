#!/usr/bin/env Rscript
# Step 1: Install packages and initialize environment for Synthea generation, ETL, and data checks.

source("workflow/workflow_bootstrap.R")
set_workflow_root()

source("setup/setup_renv.R")
source("setup/install_packages.R")

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

cat("Step 1 complete: environment and packages are ready for Synthea/ETL/data-check workflow.\n")
