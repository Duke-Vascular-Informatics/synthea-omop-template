#!/usr/bin/env Rscript
# Step 7: Install packages and verify analysis environment for external validation.

source("setup_renv.R")
source("install_packages.R")

required <- c(
  "PatientLevelPrediction",
  "DatabaseConnector",
  "SqlRender",
  "dplyr",
  "ggplot2",
  "readr",
  "officer",
  "flextable"
)
missing <- required[!vapply(required, requireNamespace, logical(1), quietly = TRUE)]
if (length(missing) > 0) {
  stop("Missing required analysis packages: ", paste(missing, collapse = ", "))
}

cat("Step 7 complete: analysis environment verified for integer risk score external validation.\n")
