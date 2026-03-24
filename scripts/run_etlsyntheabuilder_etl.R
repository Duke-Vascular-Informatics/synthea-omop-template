# =============================================================================
# scripts/run_etlsyntheabuilder_etl.R
# Package-first runner for Synthea CSV -> OMOP ETL via EtlSyntheaBuilder.
# =============================================================================

source("config.R")
source("R/drivers.R")
source("R/connection.R")

`%||%` <- function(x, y) {
  if (is.null(x) || (is.character(x) && !nzchar(x))) y else x
}

resolve_etlsyntheabuilder_namespace <- function() {
  candidates <- c("EtlSyntheaBuilder", "etlSyntheaBuilder", "ETLSyntheaBuilder")
  for (pkg in candidates) {
    if (requireNamespace(pkg, quietly = TRUE)) {
      return(pkg)
    }
  }
  stop(
    "EtlSyntheaBuilder package is not installed in this renv environment. ",
    "Install it with renv::install(<package source>) and retry.",
    call. = FALSE
  )
}

resolve_etl_entrypoint <- function(pkg_name) {
  exports <- getNamespaceExports(pkg_name)
  preferred <- c(
    "executeSyntheaToOmopEtl",
    "executeEtl",
    "runSyntheaToOmopEtl",
    "runEtl"
  )
  hit <- preferred[preferred %in% exports]
  if (length(hit) > 0L) {
    return(hit[[1]])
  }
  stop(
    "Could not find a known ETL entrypoint in package ", pkg_name,
    ". Exported functions: ", paste(exports, collapse = ", "),
    call. = FALSE
  )
}

run_etlsyntheabuilder_etl <- function(
    csv_input_dir = "C:/Users/rapiduser/synthea-data/output/csv",
    cdm_schema = NULL,
    vocabulary_schema = NULL,
    run_name = paste0("padssi-csv-", format(Sys.time(), "%Y%m%d-%H%M%S"))) {

  if (!dir.exists(csv_input_dir)) {
    stop("CSV input directory does not exist: ", csv_input_dir, call. = FALSE)
  }

  get_validation_config_fn <- get("get_validation_config", mode = "function")
  build_connection_details_fn <- get("build_connection_details", mode = "function")

  config <- get_validation_config_fn()
  cdm_schema <- cdm_schema %||% config$cdm_schema
  vocabulary_schema <- vocabulary_schema %||% config$cdm_schema

  pkg <- resolve_etlsyntheabuilder_namespace()
  entrypoint_name <- resolve_etl_entrypoint(pkg)
  entrypoint <- getExportedValue(pkg, entrypoint_name)

  connection_details <- build_connection_details_fn(config)

  # Provide a broad set of commonly-used argument names and only pass those
  # accepted by the discovered entrypoint.
  candidate_args <- list(
    connectionDetails = connection_details,
    cdmDatabaseSchema = cdm_schema,
    cdmSchema = cdm_schema,
    vocabularyDatabaseSchema = vocabulary_schema,
    vocabDatabaseSchema = vocabulary_schema,
    syntheaPath = csv_input_dir,
    syntheaCsvPath = csv_input_dir,
    syntheaCsvFolder = csv_input_dir,
    csvPath = csv_input_dir,
    csvFolder = csv_input_dir,
    runName = run_name,
    run_name = run_name
  )

  accepted <- names(formals(entrypoint))
  args <- candidate_args[names(candidate_args) %in% accepted]

  # Many ETLSyntheaBuilder entry points require at least connection + CDM schema.
  required_basics <- c("connectionDetails", "cdmDatabaseSchema")
  missing_basics <- required_basics[!required_basics %in% accepted]
  if (length(missing_basics) == length(required_basics)) {
    message(
      "Entrypoint '", entrypoint_name,
      "' has non-standard arguments; passing matched args only: ",
      paste(names(args), collapse = ", ")
    )
  }

  message("Running ETL via package ", pkg, "::", entrypoint_name)
  message("CSV source: ", normalizePath(csv_input_dir, winslash = "/", mustWork = TRUE))
  message("CDM schema: ", cdm_schema)

  do.call(entrypoint, args)

  invisible(list(
    package = pkg,
    entrypoint = entrypoint_name,
    run_name = run_name,
    csv_input_dir = csv_input_dir,
    cdm_schema = cdm_schema
  ))
}
