#!/usr/bin/env Rscript
# Step 7: Install packages and verify analysis environment for external validation.

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
