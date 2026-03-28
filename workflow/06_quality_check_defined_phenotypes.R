#!/usr/bin/env Rscript
# Step 6: Data quality check against defined cohort, outcome, and covariates.

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
