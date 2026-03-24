#!/usr/bin/env Rscript
# Step 1: Install packages and initialize environment for Synthea generation, ETL, and data checks.

source("setup_renv.R")
source("install_packages.R")

required <- c("DatabaseConnector", "SqlRender", "jsonlite", "data.table")
missing <- required[!vapply(required, requireNamespace, logical(1), quietly = TRUE)]
if (length(missing) > 0) {
  stop("Missing required packages after setup: ", paste(missing, collapse = ", "))
}

cat("Step 1 complete: environment and packages are ready for Synthea/ETL/data-check workflow.\n")
