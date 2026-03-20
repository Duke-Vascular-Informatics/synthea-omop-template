# =============================================================================
# scripts/run_fhir_to_omop_etl.R
# Draft FHIR -> OMOP ETL runner for SQL Server.
#
# Purpose:
# - Build a deterministic run name from sample size, module version, and date
# - Emit metadata JSON for traceability
# - Stage FHIR NDJSON resources into SQL Server
# - Execute a draft SQL transform into OMOP tables
#
# Usage example:
# source("renv/activate.R")
# source("scripts/run_fhir_to_omop_etl.R")
# run_fhir_to_omop_etl(
#   fhir_input_dir = "C:/path/to/synthea/output/fhir",
#   sample_size = 5000L,
#   module_version = "v03",
#   run_date = Sys.Date()
# )
# =============================================================================

if (!requireNamespace("DatabaseConnector", quietly = TRUE)) {
  stop("Package 'DatabaseConnector' is required. Install with renv::install('DatabaseConnector').")
}
if (!requireNamespace("SqlRender", quietly = TRUE)) {
  stop("Package 'SqlRender' is required. Install with renv::install('SqlRender').")
}
if (!requireNamespace("jsonlite", quietly = TRUE)) {
  stop("Package 'jsonlite' is required. Install with renv::install('jsonlite').")
}

source("config.R")
source("R/drivers.R")
source("R/connection.R")

sanitize_token <- function(x) {
  x <- tolower(trimws(as.character(x)))
  x <- gsub("[^a-z0-9]+", "-", x)
  x <- gsub("^-+|-+$", "", x)
  x
}

build_run_name <- function(sample_size, module_version, run_date) {
  date_part <- format(as.Date(run_date), "%Y%m%d")
  sprintf(
    "padssi-n%s-mod%s-%s",
    as.integer(sample_size),
    sanitize_token(module_version),
    date_part
  )
}

extract_resource_id <- function(payload_json) {
  val <- tryCatch(jsonlite::fromJSON(payload_json, simplifyVector = TRUE), error = function(e) NULL)
  if (is.null(val) || is.null(val$id)) {
    return(NA_character_)
  }
  as.character(val$id)
}

extract_resource_type <- function(payload_json) {
  val <- tryCatch(jsonlite::fromJSON(payload_json, simplifyVector = TRUE), error = function(e) NULL)
  if (is.null(val) || is.null(val$resourceType)) {
    return(NA_character_)
  }
  as.character(val$resourceType)
}

read_ndjson_as_stage <- function(file_path, run_name) {
  lines <- readLines(file_path, warn = FALSE, encoding = "UTF-8")
  lines <- lines[nzchar(trimws(lines))]
  if (length(lines) == 0) {
    return(data.frame(
      run_name = character(),
      source_file = character(),
      resource_type = character(),
      resource_id = character(),
      payload_json = character(),
      stringsAsFactors = FALSE
    ))
  }

  resource_type <- vapply(lines, extract_resource_type, character(1))
  resource_id <- vapply(lines, extract_resource_id, character(1))

  data.frame(
    run_name = rep(run_name, length(lines)),
    source_file = rep(basename(file_path), length(lines)),
    resource_type = resource_type,
    resource_id = resource_id,
    payload_json = lines,
    stringsAsFactors = FALSE
  )
}

write_metadata <- function(metadata, output_dir) {
  if (!dir.exists(output_dir)) {
    dir.create(output_dir, recursive = TRUE, showWarnings = FALSE)
  }
  out_file <- file.path(output_dir, "metadata.json")
  jsonlite::write_json(metadata, path = out_file, auto_unbox = TRUE, pretty = TRUE)
  out_file
}

run_fhir_to_omop_etl <- function(
    fhir_input_dir,
    sample_size,
    module_version,
    run_date = Sys.Date(),
    staging_schema = "fhir_stage",
    cdm_schema = NULL,
    transform_sql_file = file.path("scripts", "sql", "fhir_to_omop_transform_draft.sql"),
    metadata_output_root = file.path("output", "etl_runs")) {

  config <- get_validation_config()
  if (is.null(cdm_schema) || !nzchar(cdm_schema)) {
    cdm_schema <- config$cdm_schema
  }

  if (!dir.exists(fhir_input_dir)) {
    stop("FHIR input directory does not exist: ", fhir_input_dir)
  }
  if (!file.exists(transform_sql_file)) {
    stop("Transform SQL file not found: ", transform_sql_file)
  }

  ndjson_files <- list.files(fhir_input_dir, pattern = "\\.ndjson$", full.names = TRUE)
  if (length(ndjson_files) == 0) {
    stop("No .ndjson files found in: ", fhir_input_dir)
  }

  run_name <- build_run_name(sample_size = sample_size, module_version = module_version, run_date = run_date)

  metadata <- list(
    run_name = run_name,
    sample_size = as.integer(sample_size),
    module_version = as.character(module_version),
    run_date = as.character(as.Date(run_date)),
    generated_at_utc = format(Sys.time(), tz = "UTC", usetz = TRUE),
    fhir_input_dir = normalizePath(fhir_input_dir, winslash = "/", mustWork = TRUE),
    ndjson_file_count = length(ndjson_files),
    ndjson_files = basename(ndjson_files),
    target_dbms = config$dbms,
    target_server = config$server,
    target_database = config$database,
    target_cdm_schema = cdm_schema,
    staging_schema = staging_schema,
    transform_sql_file = transform_sql_file
  )

  metadata_file <- write_metadata(
    metadata = metadata,
    output_dir = file.path(metadata_output_root, run_name)
  )

  connection_details <- build_connection_details(config)
  conn <- DatabaseConnector::connect(connection_details)
  on.exit(DatabaseConnector::disconnect(conn), add = TRUE)

  create_stage_sql <- SqlRender::translate(SqlRender::render(
    "
    IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = '@staging_schema')
      EXEC('CREATE SCHEMA @staging_schema');

    IF OBJECT_ID('@staging_schema.fhir_raw_resource', 'U') IS NULL
    BEGIN
      CREATE TABLE @staging_schema.fhir_raw_resource (
        run_name      VARCHAR(200) NOT NULL,
        source_file   VARCHAR(260) NOT NULL,
        resource_type VARCHAR(100) NULL,
        resource_id   VARCHAR(100) NULL,
        payload_json  NVARCHAR(MAX) NOT NULL,
        inserted_at   DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME()
      );

      CREATE INDEX IX_fhir_raw_resource_run ON @staging_schema.fhir_raw_resource(run_name);
      CREATE INDEX IX_fhir_raw_resource_type ON @staging_schema.fhir_raw_resource(resource_type);
    END
    ",
    staging_schema = staging_schema
  ), targetDialect = config$dbms)

  DatabaseConnector::executeSql(conn, create_stage_sql)

  for (file_path in ndjson_files) {
    stage_df <- read_ndjson_as_stage(file_path, run_name)
    if (nrow(stage_df) == 0) {
      next
    }

    DatabaseConnector::insertTable(
      connection = conn,
      tableName = "fhir_raw_resource",
      data = stage_df,
      schema = staging_schema,
      dropTableIfExists = FALSE,
      createTable = FALSE,
      tempTable = FALSE
    )
  }

  transform_template <- paste(readLines(transform_sql_file, warn = FALSE), collapse = "\n")
  transform_sql <- SqlRender::translate(SqlRender::render(
    transform_template,
    run_name = run_name,
    staging_schema = staging_schema,
    cdm_schema = cdm_schema
  ), targetDialect = config$dbms)

  DatabaseConnector::executeSql(conn, transform_sql)

  message("FHIR -> OMOP draft ETL completed.")
  message("Run name     : ", run_name)
  message("Metadata JSON: ", metadata_file)

  invisible(list(
    run_name = run_name,
    metadata_file = metadata_file,
    ndjson_files = ndjson_files
  ))
}
