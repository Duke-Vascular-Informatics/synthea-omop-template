#!/usr/bin/env Rscript
# Step 6: Data quality check against defined cohort, outcome, and covariates.

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
