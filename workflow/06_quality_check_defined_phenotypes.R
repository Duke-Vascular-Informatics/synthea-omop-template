#!/usr/bin/env Rscript
# Step 6: Data quality check against defined cohort, outcome, and covariates.

source("workflow/workflow_bootstrap.R")
set_workflow_root()

source("config.R")
cfg <- get_validation_config()
if (!is.null(cfg$java_home) && nzchar(cfg$java_home) && dir.exists(cfg$java_home)) {
  java_bin <- file.path(cfg$java_home, "bin")
  Sys.setenv(JAVA_HOME = cfg$java_home)
  Sys.setenv(PATH = paste(normalizePath(java_bin, winslash = "/", mustWork = FALSE), Sys.getenv("PATH"), sep = .Platform$path.sep))
  options(java.parameters = paste0("-Djava.home=", normalizePath(cfg$java_home, winslash = "/", mustWork = FALSE)))
}

args <- commandArgs(trailingOnly = TRUE)

cmd <- c("quality_check_etl.R")
if (length(args) > 0) {
  cmd <- c(cmd, args)
}

status <- system2(file.path(R.home("bin"), "Rscript.exe"), args = cmd)
if (!identical(status, 0L)) {
  stop("Quality check failed.")
}

cat("Step 6 complete: quality checks executed.\n")
