#!/usr/bin/env Rscript
# Step 7: Install packages and verify analysis environment for external validation.

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
