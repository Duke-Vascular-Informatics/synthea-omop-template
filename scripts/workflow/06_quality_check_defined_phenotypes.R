#!/usr/bin/env Rscript
# Step 6: Data quality check against defined cohort, outcome, and covariates.

args <- commandArgs(trailingOnly = TRUE)
run_name <- if (length(args) >= 1 && nzchar(args[[1]])) args[[1]] else ""

cmd <- c("quality_check_etl.R")
if (nzchar(run_name)) {
  cmd <- c(cmd, run_name)
}

status <- system2(file.path(R.home("bin"), "Rscript.exe"), args = cmd)
if (!identical(status, 0L)) {
  stop("Quality check failed.")
}

cat("Step 6 complete: quality checks executed.\n")
