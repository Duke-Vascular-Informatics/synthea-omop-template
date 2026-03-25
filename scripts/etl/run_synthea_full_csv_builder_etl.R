# =============================================================================
# scripts/etl/run_synthea_full_csv_builder_etl.R
# Full-domain Synthea CSV -> OMOP ETL using ETLSyntheaBuilder.
# =============================================================================

source("config.R")
source("R/drivers.R")
source("R/connection.R")

run_synthea_full_csv_builder_etl <- function(
    csv_input_dir,
    run_name = paste0("padssi-csv-full-", format(Sys.time(), "%Y%m%d-%H%M%S")),
    synthea_schema = "synthea",
  synthea_version = "3.3.0",
    cdm_version = "5.4",
    vocab_file_loc = "C:/Users/rapiduser/omop-vocab",
    reset_before_etl = TRUE,
    force_reload_vocab = FALSE,
    create_extra_indices = TRUE) {

  config <- get_validation_config()
  ensure_jdbc_bundle(config)
  configure_java(config)

  if (!dir.exists(csv_input_dir)) {
    stop("CSV input directory does not exist: ", csv_input_dir)
  }

  csv_files <- list.files(csv_input_dir, pattern = "\\.csv$", full.names = TRUE)
  if (length(csv_files) == 0) {
    stop("No CSV files found in: ", csv_input_dir)
  }

  if (!dir.exists(vocab_file_loc)) {
    stop("Vocabulary directory does not exist: ", vocab_file_loc)
  }

  if (!requireNamespace("ETLSyntheaBuilder", quietly = TRUE)) {
    stop(
      "Package 'ETLSyntheaBuilder' is required for full-domain CSV ETL. ",
      "Install it in this renv before running Step 5 in csv_builder mode."
    )
  }

  if (!requireNamespace("SqlRender", quietly = TRUE)) {
    stop("Package 'SqlRender' is required. Install with renv::install('SqlRender').")
  }

  connection_details <- build_connection_details(config)

  render_sql <- function(sql, ...) {
    SqlRender::translate(
      SqlRender::render(sql, ...),
      targetDialect = config$dbms
    )
  }

  table_exists <- function(connection, schema_name, table_name) {
    sql <- render_sql(
      "SELECT COUNT(*) AS n FROM INFORMATION_SCHEMA.TABLES
       WHERE TABLE_SCHEMA = '@schema_name'
         AND TABLE_NAME = '@table_name';",
      schema_name = schema_name,
      table_name = table_name
    )
    res <- DatabaseConnector::querySql(connection, sql)
    as.numeric(res$n[1]) > 0
  }

  table_has_rows <- function(connection, schema_name, table_name) {
    if (!table_exists(connection, schema_name, table_name)) {
      return(FALSE)
    }

    sql <- render_sql(
      "SELECT CASE
          WHEN EXISTS (SELECT 1 FROM @schema_name.@table_name)
          THEN 1 ELSE 0
        END AS has_rows;",
      schema_name = schema_name,
      table_name = table_name
    )
    res <- DatabaseConnector::querySql(connection, sql)
    identical(as.integer(res$has_rows[1]), 1L)
  }

  vocab_is_loaded <- function(connection, cdm_schema) {
    required_vocab_tables <- c("concept", "concept_ancestor", "concept_relationship")
    all(vapply(
      required_vocab_tables,
      function(table_name) table_has_rows(connection, cdm_schema, table_name),
      logical(1)
    ))
  }

  clear_schema_tables <- function(connection, schema_name) {
    sql <- render_sql(
      "SELECT t.name AS table_name
       FROM sys.tables t
       JOIN sys.schemas s ON t.schema_id = s.schema_id
       WHERE s.name = '@schema_name';",
      schema_name = schema_name
    )
    tbl <- DatabaseConnector::querySql(connection, sql)
    if (nrow(tbl) == 0) {
      return(invisible(NULL))
    }

    for (nm in tbl$table_name) {
      DatabaseConnector::executeSql(connection, paste0("DROP TABLE [", schema_name, "].[", nm, "];"))
    }
    invisible(NULL)
  }

  message("=== Step 5 CSV builder ETL ===")
  message("run_name: ", run_name)
  message("csv_input_dir: ", normalizePath(csv_input_dir, winslash = "/", mustWork = TRUE))
  message("vocab_file_loc: ", normalizePath(vocab_file_loc, winslash = "/", mustWork = TRUE))
  message("synthea_schema: ", synthea_schema)
  message("synthea_version: ", synthea_version)
  message("cdm_schema: ", config$cdm_schema)

  conn_check <- DatabaseConnector::connect(connection_details)

  if (!table_exists(conn_check, config$cdm_schema, "person")) {
    ETLSyntheaBuilder::CreateCDMTables(
      connectionDetails = connection_details,
      cdmSchema = config$cdm_schema,
      cdmVersion = cdm_version
    )
  } else {
    message("CDM tables already exist in ", config$cdm_schema, "; skipping CreateCDMTables.")
  }

  DatabaseConnector::executeSql(
    conn_check,
    paste0("IF SCHEMA_ID('", synthea_schema, "') IS NULL EXEC('CREATE SCHEMA ", synthea_schema, "');")
  )

  DatabaseConnector::disconnect(conn_check)

  if (isTRUE(reset_before_etl)) {
    message("Reset requested: dropping event + synthea staging tables before reload ...")
    suppressWarnings(try(ETLSyntheaBuilder::DropEventTables(
      connectionDetails = connection_details,
      cdmSchema = config$cdm_schema,
      cdmVersion = cdm_version,
      syntheaVersion = synthea_version
    ), silent = TRUE))
    suppressWarnings(try(ETLSyntheaBuilder::DropSyntheaTables(
      connectionDetails = connection_details,
      syntheaSchema = synthea_schema,
      syntheaVersion = synthea_version
    ), silent = TRUE))

    # Defensive cleanup to handle schema-version mismatches in DropSyntheaTables.
    conn_reset <- DatabaseConnector::connect(connection_details)
    clear_schema_tables(conn_reset, synthea_schema)
    DatabaseConnector::disconnect(conn_reset)
  }

  ETLSyntheaBuilder::CreateSyntheaTables(
    connectionDetails = connection_details,
    syntheaSchema = synthea_schema,
    syntheaVersion = synthea_version
  )

  ETLSyntheaBuilder::LoadSyntheaTables(
    connectionDetails = connection_details,
    syntheaSchema = synthea_schema,
    syntheaFileLoc = csv_input_dir,
    bulkLoad = FALSE
  )

  conn_vocab <- DatabaseConnector::connect(connection_details)
  on.exit(DatabaseConnector::disconnect(conn_vocab), add = TRUE)
  vocab_loaded <- vocab_is_loaded(conn_vocab, config$cdm_schema)
  if (isTRUE(force_reload_vocab)) {
    message("force_reload_vocab=true: truncating vocabulary tables before reload ...")
    suppressWarnings(try(ETLSyntheaBuilder::TruncateVocabTables(
      connectionDetails = connection_details,
      cdmSchema = config$cdm_schema,
      cdmVersion = cdm_version
    ), silent = TRUE))
    vocab_loaded <- FALSE
  }

  if (isTRUE(vocab_loaded)) {
    message(
      "Vocabulary tables already populated in ",
      config$cdm_schema,
      "; skipping LoadVocabFromCsv()."
    )
  } else {
    ETLSyntheaBuilder::LoadVocabFromCsv(
      connectionDetails = connection_details,
      cdmSchema = config$cdm_schema,
      vocabFileLoc = vocab_file_loc,
      bulkLoad = TRUE
    )
  }
  DatabaseConnector::disconnect(conn_vocab)

  ETLSyntheaBuilder::CreateVocabMapTables(
    connectionDetails = connection_details,
    cdmSchema = config$cdm_schema,
    cdmVersion = cdm_version
  )

  ETLSyntheaBuilder::CreateVisitRollupTables(
    connectionDetails = connection_details,
    cdmSchema = config$cdm_schema,
    cdmVersion = cdm_version
  )

  ETLSyntheaBuilder::CreateMapAndRollupTables(
    connectionDetails = connection_details,
    cdmSchema = config$cdm_schema,
    syntheaSchema = synthea_schema,
    cdmVersion = cdm_version,
    syntheaVersion = synthea_version
  )

  ETLSyntheaBuilder::LoadEventTables(
    connectionDetails = connection_details,
    cdmSchema = config$cdm_schema,
    syntheaSchema = synthea_schema,
    cdmVersion = cdm_version,
    syntheaVersion = synthea_version,
    createIndices = FALSE,
    sqlOnly = FALSE
  )

  if (isTRUE(create_extra_indices)) {
    suppressWarnings(try(ETLSyntheaBuilder::CreateExtraIndices(
      connectionDetails = connection_details,
      cdmSchema = config$cdm_schema,
      cdmVersion = cdm_version
    ), silent = TRUE))
  }

  # Ensure concept_ancestor indexes are present for risk score descendant-expansion queries.
  conn <- DatabaseConnector::connect(connection_details)
  on.exit(DatabaseConnector::disconnect(conn), add = TRUE)

  index_sql <- SqlRender::translate(
    SqlRender::render(
      "IF OBJECT_ID('@cdm_schema.concept_ancestor', 'U') IS NOT NULL
       BEGIN
         IF NOT EXISTS (
           SELECT 1 FROM sys.indexes
           WHERE object_id = OBJECT_ID('@cdm_schema.concept_ancestor')
             AND name = 'IX_concept_ancestor_ancestor'
         )
         BEGIN
           CREATE INDEX IX_concept_ancestor_ancestor
             ON @cdm_schema.concept_ancestor (ancestor_concept_id)
             INCLUDE (descendant_concept_id, min_levels_of_separation, max_levels_of_separation);
         END;

         IF NOT EXISTS (
           SELECT 1 FROM sys.indexes
           WHERE object_id = OBJECT_ID('@cdm_schema.concept_ancestor')
             AND name = 'IX_concept_ancestor_descendant'
         )
         BEGIN
           CREATE INDEX IX_concept_ancestor_descendant
             ON @cdm_schema.concept_ancestor (descendant_concept_id)
             INCLUDE (ancestor_concept_id);
         END;
       END;",
      cdm_schema = config$cdm_schema
    ),
    targetDialect = config$dbms
  )
  DatabaseConnector::executeSql(conn, index_sql)

  invisible(list(run_name = run_name, mode = "csv_builder"))
}
