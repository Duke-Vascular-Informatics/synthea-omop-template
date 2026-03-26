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
    synthea_bulk_load = TRUE,
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

  run_db_preflight(
    connection_details,
    required_successes = 3L,
    max_attempts = 10L,
    delay_seconds = 2
  )

  run_step_with_retry <- function(step_name, expr, max_attempts = 3L) {
    with_db_retry(
      expr,
      operation_name = step_name,
      max_attempts = max_attempts,
      initial_delay_seconds = 2
    )
  }

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
    res <- query_sql_with_retry(connection, sql)
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
    res <- query_sql_with_retry(connection, sql)
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
    tbl <- query_sql_with_retry(connection, sql)
    if (nrow(tbl) == 0) {
      return(invisible(NULL))
    }

    for (nm in tbl$table_name) {
      execute_sql_with_retry(connection, paste0("DROP TABLE [", schema_name, "].[", nm, "];"))
    }
    invisible(NULL)
  }

  ensure_cdm_tables_exist <- function() {
    conn_cdm <- connect_with_retry(connection_details)
    on.exit(DatabaseConnector::disconnect(conn_cdm), add = TRUE)

    required_cdm_tables <- c(
      "person", "location", "care_site", "provider",
      "observation_period", "visit_occurrence"
    )
    missing_tables <- required_cdm_tables[!vapply(
      required_cdm_tables,
      function(tb) table_exists(conn_cdm, config$cdm_schema, tb),
      logical(1)
    )]

    if (length(missing_tables) > 0) {
      message(
        "Missing CDM tables detected in ", config$cdm_schema,
        " (", paste(missing_tables, collapse = ", "), "); recreating CDM tables."
      )
      run_step_with_retry("ETLSyntheaBuilder::CreateCDMTables", ETLSyntheaBuilder::CreateCDMTables(
        connectionDetails = connection_details,
        cdmSchema = config$cdm_schema,
        cdmVersion = cdm_version
      ))
    }
  }

  drop_rollup_helper_tables <- function(connection, cdm_schema) {
    helper_tables <- c("all_visits", "assign_all_visit_ids", "final_visit_ids")
    for (table_name in helper_tables) {
      sql <- render_sql(
        "IF OBJECT_ID('@cdm_schema.@table_name', 'U') IS NOT NULL
           DROP TABLE @cdm_schema.@table_name;",
        cdm_schema = cdm_schema,
        table_name = table_name
      )
      execute_sql_with_retry(connection, sql)
    }
    invisible(NULL)
  }

  execute_sql_file <- function(connection, file_path) {
    sql <- paste(readLines(file_path, warn = FALSE), collapse = "\n")
    execute_sql_with_retry(connection, sql)
  }

  create_visit_rollup_tables_sql_server <- function() {
    run_step_with_retry("ETLSyntheaBuilder::CreateVisitRollupTables(sqlOnly)", ETLSyntheaBuilder::CreateVisitRollupTables(
      connectionDetails = connection_details,
      cdmSchema = config$cdm_schema,
      syntheaSchema = synthea_schema,
      cdmVersion = cdm_version,
      sqlOnly = TRUE
    ))

    conn_rollup <- connect_with_retry(connection_details)
    on.exit(DatabaseConnector::disconnect(conn_rollup), add = TRUE)

    execute_sql_file(conn_rollup, file.path("output", "AllVisitTable.sql"))
    execute_sql_file(conn_rollup, file.path("output", "AAVITable.sql"))

    final_visit_sql <- render_sql(
      "IF OBJECT_ID('@cdm_schema.FINAL_VISIT_IDS', 'U') IS NOT NULL
         DROP TABLE @cdm_schema.FINAL_VISIT_IDS;

       SELECT encounter_id, VISIT_OCCURRENCE_ID_NEW
       INTO @cdm_schema.FINAL_VISIT_IDS
       FROM (
         SELECT *,
             ROW_NUMBER() OVER (PARTITION BY encounter_id ORDER BY PRIORITY) AS RN
         FROM (
             SELECT *,
                 CASE
                     WHEN encounterclass IN ('emergency', 'urgent') THEN
                         CASE
                             WHEN VISIT_TYPE = 'inpatient' AND VISIT_OCCURRENCE_ID_NEW IS NOT NULL THEN 1
                             WHEN VISIT_TYPE IN ('emergency', 'urgent') AND VISIT_OCCURRENCE_ID_NEW IS NOT NULL THEN 2
                             ELSE 99
                         END
                     WHEN encounterclass IN ('ambulatory', 'wellness', 'outpatient') THEN
                         CASE
                             WHEN VISIT_TYPE = 'inpatient' AND VISIT_OCCURRENCE_ID_NEW IS NOT NULL THEN 1
                             WHEN VISIT_TYPE IN ('ambulatory', 'wellness', 'outpatient') AND VISIT_OCCURRENCE_ID_NEW IS NOT NULL THEN 2
                             ELSE 99
                         END
                     WHEN encounterclass = 'inpatient' AND VISIT_TYPE = 'inpatient' AND VISIT_OCCURRENCE_ID_NEW IS NOT NULL THEN 1
                     ELSE 99
                 END AS PRIORITY
             FROM @cdm_schema.ASSIGN_ALL_VISIT_IDS
         ) T1
       ) RankedVisits
       WHERE RN = 1;",
      cdm_schema = config$cdm_schema
    )
    execute_sql_with_retry(conn_rollup, final_visit_sql)
  }

  load_event_tables_sql_server <- function() {
    run_step_with_retry("ETLSyntheaBuilder::CreateMapAndRollupTables(sqlOnly)", ETLSyntheaBuilder::CreateMapAndRollupTables(
      connectionDetails = connection_details,
      cdmSchema = config$cdm_schema,
      syntheaSchema = synthea_schema,
      cdmVersion = cdm_version,
      syntheaVersion = synthea_version,
      sqlOnly = TRUE
    ))

    run_step_with_retry("ETLSyntheaBuilder::LoadEventTables(sqlOnly)", ETLSyntheaBuilder::LoadEventTables(
      connectionDetails = connection_details,
      cdmSchema = config$cdm_schema,
      syntheaSchema = synthea_schema,
      cdmVersion = cdm_version,
      syntheaVersion = synthea_version,
      createIndices = FALSE,
      sqlOnly = TRUE
    ))

    conn_events <- connect_with_retry(connection_details)
    on.exit(DatabaseConnector::disconnect(conn_events), add = TRUE)

    map_sql_files <- c(
      file.path("output", "create_source_to_standard_vocab_map.sql"),
      file.path("output", "create_source_to_source_vocab_map.sql"),
      file.path("output", "create_states_map.sql")
    )
    for (sql_file in map_sql_files) {
      execute_sql_file(conn_events, sql_file)
    }

    event_sql_files <- c(
      file.path("output", "insert_location.sql"),
      file.path("output", "insert_care_site.sql"),
      file.path("output", "insert_person.sql"),
      file.path("output", "insert_observation_period.sql"),
      file.path("output", "insert_provider.sql"),
      file.path("output", "insert_visit_occurrence.sql"),
      file.path("output", "insert_visit_detail.sql"),
      file.path("output", "insert_condition_occurrence.sql"),
      file.path("output", "insert_observation.sql"),
      file.path("output", "insert_measurement.sql"),
      file.path("output", "insert_procedure_occurrence.sql"),
      file.path("output", "insert_drug_exposure.sql"),
      file.path("output", "insert_condition_era.sql"),
      file.path("output", "insert_drug_era.sql"),
      file.path("output", "insert_cdm_source.sql"),
      file.path("output", "insert_device_exposure.sql"),
      file.path("output", "insert_death.sql"),
      file.path("output", "insert_payer_plan_period.sql"),
      file.path("output", "insert_cost_v300.sql")
    )
    for (sql_file in event_sql_files) {
      execute_sql_file(conn_events, sql_file)
    }
  }

  message("=== Step 5 CSV builder ETL ===")
  message("run_name: ", run_name)
  message("csv_input_dir: ", normalizePath(csv_input_dir, winslash = "/", mustWork = TRUE))
  message("vocab_file_loc: ", normalizePath(vocab_file_loc, winslash = "/", mustWork = TRUE))
  message("synthea_schema: ", synthea_schema)
  message("synthea_version: ", synthea_version)
  message("cdm_schema: ", config$cdm_schema)

  ensure_cdm_tables_exist()

  conn_check <- connect_with_retry(connection_details)
  message("CDM tables verified in ", config$cdm_schema, ".")

  execute_sql_with_retry(
    conn_check,
    paste0("IF SCHEMA_ID('", synthea_schema, "') IS NULL EXEC('CREATE SCHEMA ", synthea_schema, "');")
  )

  DatabaseConnector::disconnect(conn_check)

  if (isTRUE(reset_before_etl)) {
    message("Reset requested: dropping event + synthea staging tables before reload ...")
    suppressWarnings(try(run_step_with_retry("ETLSyntheaBuilder::DropEventTables", ETLSyntheaBuilder::DropEventTables(
      connectionDetails = connection_details,
      cdmSchema = config$cdm_schema
    )), silent = TRUE))
    suppressWarnings(try(run_step_with_retry("ETLSyntheaBuilder::DropSyntheaTables", ETLSyntheaBuilder::DropSyntheaTables(
      connectionDetails = connection_details,
      syntheaSchema = synthea_schema,
      syntheaVersion = synthea_version
    )), silent = TRUE))

    # Defensive cleanup to handle schema-version mismatches in DropSyntheaTables.
    conn_reset <- connect_with_retry(connection_details)
    drop_rollup_helper_tables(conn_reset, config$cdm_schema)
    clear_schema_tables(conn_reset, synthea_schema)
    DatabaseConnector::disconnect(conn_reset)

    # Some reset paths can remove non-vocabulary CDM tables; recreate if needed.
    ensure_cdm_tables_exist()
  }

  run_step_with_retry("ETLSyntheaBuilder::CreateSyntheaTables", ETLSyntheaBuilder::CreateSyntheaTables(
    connectionDetails = connection_details,
    syntheaSchema = synthea_schema,
    syntheaVersion = synthea_version
  ))

  if (isTRUE(synthea_bulk_load)) {
    message("Loading Synthea staging with bulkLoad=TRUE")
  } else {
    message("Loading Synthea staging with bulkLoad=FALSE")
  }

  load_synthea_tables <- function(use_bulk_load) {
    run_step_with_retry("ETLSyntheaBuilder::LoadSyntheaTables", ETLSyntheaBuilder::LoadSyntheaTables(
      connectionDetails = connection_details,
      syntheaSchema = synthea_schema,
      syntheaFileLoc = csv_input_dir,
      bulkLoad = use_bulk_load
    ))
  }

  if (isTRUE(synthea_bulk_load)) {
    loaded_with_bulk <- tryCatch({
      load_synthea_tables(TRUE)
      TRUE
    }, error = function(e) {
      warning(
        "Bulk Synthea staging load failed; retrying with bulkLoad=FALSE. Error: ",
        conditionMessage(e)
      )
      FALSE
    })

    if (!isTRUE(loaded_with_bulk)) {
      load_synthea_tables(FALSE)
    }
  } else {
    load_synthea_tables(FALSE)
  }

  conn_vocab <- connect_with_retry(connection_details)
  on.exit(DatabaseConnector::disconnect(conn_vocab), add = TRUE)
  vocab_loaded <- vocab_is_loaded(conn_vocab, config$cdm_schema)
  if (isTRUE(force_reload_vocab)) {
    message("force_reload_vocab=true: truncating vocabulary tables before reload ...")
    suppressWarnings(try(run_step_with_retry("ETLSyntheaBuilder::TruncateVocabTables", ETLSyntheaBuilder::TruncateVocabTables(
      connectionDetails = connection_details,
      cdmSchema = config$cdm_schema,
      cdmVersion = cdm_version
    )), silent = TRUE))
    vocab_loaded <- FALSE
  }

  if (isTRUE(vocab_loaded)) {
    message(
      "Vocabulary tables already populated in ",
      config$cdm_schema,
      "; skipping LoadVocabFromCsv()."
    )
  } else {
    run_step_with_retry("ETLSyntheaBuilder::LoadVocabFromCsv", ETLSyntheaBuilder::LoadVocabFromCsv(
      connectionDetails = connection_details,
      cdmSchema = config$cdm_schema,
      vocabFileLoc = vocab_file_loc,
      bulkLoad = TRUE
    ))
  }
  DatabaseConnector::disconnect(conn_vocab)

  create_visit_rollup_tables_sql_server()
  load_event_tables_sql_server()

  if (isTRUE(create_extra_indices)) {
    suppressWarnings(try(run_step_with_retry("ETLSyntheaBuilder::CreateExtraIndices", ETLSyntheaBuilder::CreateExtraIndices(
      connectionDetails = connection_details,
      cdmSchema = config$cdm_schema,
      cdmVersion = cdm_version
    )), silent = TRUE))
  }

  # Ensure concept_ancestor indexes are present for risk score descendant-expansion queries.
  conn <- connect_with_retry(connection_details)
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
  execute_sql_with_retry(conn, index_sql)

  invisible(list(run_name = run_name, mode = "csv_builder"))
}
