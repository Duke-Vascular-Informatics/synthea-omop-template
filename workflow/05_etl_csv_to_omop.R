#!/usr/bin/env Rscript
# Step 5: ETL Synthea CSV output to OMOP.

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

parse_bool <- function(x) {
  tolower(trimws(as.character(x))) %in% c("1", "true", "t", "yes", "y")
}

csv_input_dir <- "C:/Users/rapiduser/source/repos/synthea/output/csv"
run_name <- paste0("padssi-csv-", format(Sys.time(), "%Y%m%d-%H%M%S"))
reset_before_etl <- FALSE

positional <- character()
for (arg in args) {
  if (grepl("^--", arg)) {
    m <- regmatches(arg, regexec("^--([^=]+)=(.*)$", arg))[[1]]
    if (length(m) == 3) {
      key <- m[2]
      val <- m[3]
      if (identical(key, "csv_input_dir")) csv_input_dir <- val
      if (identical(key, "run_name")) run_name <- val
      if (identical(key, "reset_before_etl")) reset_before_etl <- parse_bool(val)
    }
  } else {
    positional <- c(positional, arg)
  }
}

if (length(positional) >= 1 && nzchar(positional[[1]])) csv_input_dir <- positional[[1]]
if (length(positional) >= 2 && nzchar(positional[[2]])) run_name <- positional[[2]]

source("renv/activate.R")
source("scripts/etl/run_synthea_csv_to_omop_etl.R")

if (isTRUE(reset_before_etl)) {
  source("scripts/etl/reset_omop_and_staging.R")
}

run_synthea_csv_to_omop_etl(
  csv_input_dir = csv_input_dir,
  run_name = run_name
)

cat(
  "Step 5 complete: CSV ETL loaded to OMOP. run_name=",
  run_name,
  ", reset_before_etl=",
  ifelse(reset_before_etl, "true", "false"),
  "\n",
  sep = ""
)
