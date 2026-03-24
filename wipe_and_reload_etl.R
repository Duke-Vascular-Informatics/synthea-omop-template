# =============================================================================
# wipe_and_reload_etl.R
#
# Truncates ALL rows from every patient-level OMOP CDM table (including any
# prior FHIR/CSV-imported data) and staging tables, then re-runs a fresh ETL
# load from the Synthea CSV output directory.
#
# Run from the project root:
#   Rscript wipe_and_reload_etl.R
# or interactively:
#   source("wipe_and_reload_etl.R")
# =============================================================================

# ---------------------------------------------------------------------------
# 1. Configure Java BEFORE rJava / DatabaseConnector is initialised.
#    options(java.parameters) must be set before the JVM is first started.
# ---------------------------------------------------------------------------
local({
  java_home     <- "C:/Program Files/Eclipse Adoptium/jdk-17.0.18.8-hotspot"
  jdbc_auth_dir <- file.path(getwd(), "drivers", "sqljdbc_13.2", "enu", "auth", "x64")
  jdbc_rt_dir   <- file.path(getwd(), "drivers", "jdbc-runtime")

  Sys.setenv(JAVA_HOME = java_home)
  Sys.setenv(PATH = paste(
    normalizePath(file.path(java_home, "bin"),   winslash = "\\", mustWork = FALSE),
    normalizePath(jdbc_auth_dir,                  winslash = "\\", mustWork = FALSE),
    Sys.getenv("PATH"),
    sep = .Platform$path.sep
  ))
  options(java.parameters = paste0(
    "-Djava.library.path=",
    normalizePath(jdbc_auth_dir, winslash = "/", mustWork = FALSE)
  ))
  Sys.setenv(DATABASECONNECTOR_JAR_FOLDER = jdbc_rt_dir)
})

# ---------------------------------------------------------------------------
# 2. Activate renv and load ETL helpers (defines run_etlsyntheabuilder_etl,
#    get_validation_config, build_connection_details, etc.)
# ---------------------------------------------------------------------------
source("renv/activate.R")
source("scripts/run_etlsyntheabuilder_etl.R")

# ---------------------------------------------------------------------------
# 3. Connect to SQL Server
# ---------------------------------------------------------------------------
config             <- get_validation_config()
connection_details <- build_connection_details(config)
conn               <- DatabaseConnector::connect(connection_details)
on.exit(DatabaseConnector::disconnect(conn), add = TRUE)

cdm    <- config$cdm_schema      # "cdm_synthea"
stage_fhir <- "fhir_stage"
stage_csv  <- "synthea_csv_stage"

# ---------------------------------------------------------------------------
# 4. TRUNCATE all patient-level CDM tables in FK-safe (leaf-to-root) order,
#    then truncate the FHIR staging table.
#    This clears CSV-imported rows, prior ETL loads, and anything else so the
#    load starts from a completely empty state.
# ---------------------------------------------------------------------------

# Delete all rows from a CDM table, skipping silently if the table doesn't exist.
truncate_cdm <- function(conn, schema, table) {
  message("=== WIPE: ", table, " ===")
  DatabaseConnector::executeSql(
    conn,
    paste0(
      "IF OBJECT_ID('", schema, ".", table, "', 'U') IS NOT NULL ",
      "DELETE FROM ", schema, ".", table, ";"
    )
  )
}

# Leaf clinical event tables first (no downstream FKs)
truncate_cdm(conn, cdm, "death")
truncate_cdm(conn, cdm, "observation")
truncate_cdm(conn, cdm, "measurement")
truncate_cdm(conn, cdm, "drug_exposure")
truncate_cdm(conn, cdm, "device_exposure")
truncate_cdm(conn, cdm, "specimen")
truncate_cdm(conn, cdm, "note")
truncate_cdm(conn, cdm, "note_nlp")
truncate_cdm(conn, cdm, "survey_conduct")
truncate_cdm(conn, cdm, "fact_relationship")
truncate_cdm(conn, cdm, "condition_occurrence")
truncate_cdm(conn, cdm, "procedure_occurrence")
# visit_detail references visit_occurrence, clear it before visit_occurrence
truncate_cdm(conn, cdm, "visit_detail")
truncate_cdm(conn, cdm, "visit_occurrence")
# person is the root; clear last
truncate_cdm(conn, cdm, "person")

message("=== WIPE: FHIR staging table ===")
DatabaseConnector::executeSql(
  conn,
  paste0(
    "IF OBJECT_ID('", stage_fhir, ".fhir_raw_resource', 'U') IS NOT NULL ",
    "TRUNCATE TABLE ", stage_fhir, ".fhir_raw_resource;"
  )
)

message("=== WIPE: CSV staging tables ===")
DatabaseConnector::executeSql(
  conn,
  paste0(
    "IF OBJECT_ID('", stage_csv, ".patients_stage', 'U') IS NOT NULL TRUNCATE TABLE ", stage_csv, ".patients_stage;",
    "IF OBJECT_ID('", stage_csv, ".encounters_stage', 'U') IS NOT NULL TRUNCATE TABLE ", stage_csv, ".encounters_stage;",
    "IF OBJECT_ID('", stage_csv, ".procedures_stage', 'U') IS NOT NULL TRUNCATE TABLE ", stage_csv, ".procedures_stage;",
    "IF OBJECT_ID('", stage_csv, ".conditions_stage', 'U') IS NOT NULL TRUNCATE TABLE ", stage_csv, ".conditions_stage;"
  )
)

message("Wipe complete. Disconnecting before ETL re-run...")
DatabaseConnector::disconnect(conn)
# Remove from on.exit so we don't double-disconnect
on.exit(NULL)

# ---------------------------------------------------------------------------
# 5. Re-run the ETL.  Adjust fhir_input_dir / sample_size / module_version
#    if needed.
# ---------------------------------------------------------------------------
message("=== Starting fresh ETL load ===")
run_etlsyntheabuilder_etl(
  csv_input_dir = "C:/Users/rapiduser/synthea-data/output/csv",
  run_name = paste0("padssi-csv-", format(Sys.time(), "%Y%m%d-%H%M%S"))
)

message("=== wipe_and_reload_etl.R complete ===")
