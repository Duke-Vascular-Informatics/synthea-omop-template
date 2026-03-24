#!/usr/bin/env Rscript
# Optional reset utility to clear CSV-derived OMOP rows and staging tables.

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
  setwd(normalizePath(file.path(dirname(script_path), "..", ".."), winslash = "/", mustWork = FALSE))
}

if (file.exists("renv/activate.R")) source("renv/activate.R")

source("config.R")
source("R/drivers.R")
source("R/connection.R")

config <- get_validation_config()
configure_java(config)

conn <- DatabaseConnector::connect(build_connection_details(config))
on.exit(DatabaseConnector::disconnect(conn), add = TRUE)

cdm_schema <- config$cdm_schema
stage_schema <- "synthea_csv_stage"

message("Resetting CSV-derived rows in OMOP and CSV staging tables ...")

reset_sql <- SqlRender::translate(
  SqlRender::render(
    "
    -- Delete all synthetic CSV-derived CDM rows.
    DELETE FROM @cdm_schema.condition_occurrence
    WHERE person_id IN (
      SELECT person_id FROM @cdm_schema.person WHERE person_source_value LIKE 'synthea_csv:%'
    );

    DELETE FROM @cdm_schema.procedure_occurrence
    WHERE person_id IN (
      SELECT person_id FROM @cdm_schema.person WHERE person_source_value LIKE 'synthea_csv:%'
    );

    DELETE FROM @cdm_schema.visit_occurrence
    WHERE person_id IN (
      SELECT person_id FROM @cdm_schema.person WHERE person_source_value LIKE 'synthea_csv:%'
    );

    DELETE FROM @cdm_schema.person
    WHERE person_source_value LIKE 'synthea_csv:%';

    -- Clear CSV staging tables.
    IF OBJECT_ID('@stage_schema.patients_stage', 'U') IS NOT NULL
      TRUNCATE TABLE @stage_schema.patients_stage;
    IF OBJECT_ID('@stage_schema.encounters_stage', 'U') IS NOT NULL
      TRUNCATE TABLE @stage_schema.encounters_stage;
    IF OBJECT_ID('@stage_schema.procedures_stage', 'U') IS NOT NULL
      TRUNCATE TABLE @stage_schema.procedures_stage;
    IF OBJECT_ID('@stage_schema.conditions_stage', 'U') IS NOT NULL
      TRUNCATE TABLE @stage_schema.conditions_stage;
    ",
    cdm_schema = cdm_schema,
    stage_schema = stage_schema
  ),
  targetDialect = config$dbms
)

DatabaseConnector::executeSql(conn, reset_sql)

cat("Reset complete: CSV-derived OMOP and staging rows removed.\n")