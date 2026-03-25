#!/usr/bin/env Rscript
# Step 5: ETL Synthea output to OMOP.
#
# Modes:
# - csv_builder (default): full-domain CSV -> OMOP ETL via ETLSyntheaBuilder
# - csv_legacy: legacy CSV -> OMOP ETL (patients/encounters/procedures/conditions)

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

csv_input_dir <- "C:/Users/rapiduser/synthea-data/output/csv"
run_name <- paste0("padssi-csv-", format(Sys.time(), "%Y%m%d-%H%M%S"))
reset_before_etl <- TRUE
etl_mode <- "csv_builder"
force_reload_vocab <- FALSE
synthea_bulk_load <- TRUE
synthea_schema <- "synthea"
synthea_version <- "3.3.0"
cdm_version_builder <- "5.4"
vocab_file_loc <- "C:/Users/rapiduser/omop-vocab"

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
      if (identical(key, "etl_mode")) etl_mode <- tolower(trimws(val))
      if (identical(key, "force_reload_vocab")) force_reload_vocab <- parse_bool(val)
      if (identical(key, "synthea_bulk_load")) synthea_bulk_load <- parse_bool(val)
      if (identical(key, "synthea_schema")) synthea_schema <- val
      if (identical(key, "synthea_version")) synthea_version <- val
      if (identical(key, "cdm_version_builder")) cdm_version_builder <- val
      if (identical(key, "vocab_file_loc")) vocab_file_loc <- val
    }
  } else {
    positional <- c(positional, arg)
  }
}

if (length(positional) >= 1 && nzchar(positional[[1]])) csv_input_dir <- positional[[1]]
if (length(positional) >= 2 && nzchar(positional[[2]])) run_name <- positional[[2]]

source("renv/activate.R")
if (requireNamespace("renv", quietly = TRUE)) {
  renv::load(project = getwd())
}

source("config.R")
cfg <- get_validation_config()
if (!is.null(cfg$java_home) && nzchar(cfg$java_home) && dir.exists(cfg$java_home)) {
  java_bin <- file.path(cfg$java_home, "bin")
  Sys.setenv(JAVA_HOME = cfg$java_home)
  Sys.setenv(PATH = paste(normalizePath(java_bin, winslash = "/", mustWork = FALSE), Sys.getenv("PATH"), sep = .Platform$path.sep))
  options(java.parameters = paste0("-Djava.home=", normalizePath(cfg$java_home, winslash = "/", mustWork = FALSE)))
}

required_pkgs <- c("DatabaseConnector", "SqlRender", "data.table")
missing_pkgs <- required_pkgs[!vapply(required_pkgs, requireNamespace, logical(1), quietly = TRUE)]
if (length(missing_pkgs) > 0) {
  options(repos = c(CRAN = "https://archive.linux.duke.edu/cran/"))
  message("Installing missing Step 5 packages via renv: ", paste(missing_pkgs, collapse = ", "))
  for (pkg in missing_pkgs) {
    renv::install(pkg)
  }
  if (requireNamespace("renv", quietly = TRUE)) {
    renv::load(project = getwd())
  }
}

missing_pkgs_after_install <- required_pkgs[!vapply(required_pkgs, requireNamespace, logical(1), quietly = TRUE)]
if (length(missing_pkgs_after_install) > 0) {
  stop("Step 5 cannot continue; missing packages after install attempt: ",
       paste(missing_pkgs_after_install, collapse = ", "))
}

source("scripts/etl/run_synthea_csv_to_omop_etl.R")
source("scripts/etl/run_synthea_full_csv_builder_etl.R")

if (!etl_mode %in% c("csv_builder", "csv_legacy")) {
  stop("Unsupported --etl_mode. Expected 'csv_builder' or 'csv_legacy', got: ", etl_mode)
}
if (identical(etl_mode, "csv_builder")) {
  run_synthea_full_csv_builder_etl(
    csv_input_dir = csv_input_dir,
    run_name = run_name,
    synthea_schema = synthea_schema,
    synthea_version = synthea_version,
    cdm_version = cdm_version_builder,
    vocab_file_loc = vocab_file_loc,
    reset_before_etl = reset_before_etl,
    force_reload_vocab = force_reload_vocab,
    synthea_bulk_load = synthea_bulk_load,
    create_extra_indices = TRUE
  )

  cat(
    "Step 5 complete: full-domain CSV builder ETL loaded to OMOP. run_name=",
    run_name,
    ", reset_before_etl=",
    ifelse(reset_before_etl, "true", "false"),
    ", force_reload_vocab=",
    ifelse(force_reload_vocab, "true", "false"),
    ", synthea_bulk_load=",
    ifelse(synthea_bulk_load, "true", "false"),
    "\n",
    sep = ""
  )
} else {
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
}
