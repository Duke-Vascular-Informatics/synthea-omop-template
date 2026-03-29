# =============================================================================
# scripts/etl/run_synthea_full_csv_builder_etl.R
# Full-domain Synthea CSV -> OMOP ETL using ETLSyntheaBuilder.
#
# Overview of what this script does end-to-end:
#  1. Validates prerequisites (directories, packages, DB connectivity).
#  2. Ensures CDM tables exist in the target schema, creating them via
#     ETLSyntheaBuilder::CreateCDMTables if any are missing.
#  3. Loads the full OMOP vocabulary into the CDM schema, either from
#     CSV files (LoadVocabFromCsv) or by bootstrapping from a reference
#     schema via INSERT ... SELECT.
#  4. Optionally resets/drops existing Synthea staging and OMOP event
#     tables so each run starts from a clean slate.
#  5. Creates fresh Synthea staging tables using the versioned DDL
#     bundled inside ETLSyntheaBuilder.
#  6. Runs a proactive pre-flight alignment scan that reads every CSV,
#     compares column widths and types against the staging schema, and
#     issues ALTER TABLE statements to prevent loader type-clash and
#     truncation errors before any row is inserted.
#  7. Loads all Synthea CSV files into the staging schema (bulk or
#     row-by-row), with an automatic reactive fallback for any residual
#     type/truncation errors not caught by the pre-flight pass.
#  8. Generates OMOP visit rollup tables (ALL_VISITS, ASSIGN_ALL_VISIT_IDS,
#     FINAL_VISIT_IDS) using ETLSyntheaBuilder rollup SQL.
#  9. Builds concept_ancestor indexes in the CDM schema to accelerate the
#     drug_era INSERT (which joins across 75M concept_ancestor rows).
# 10. Executes the three vocabulary map SQL files (source-to-standard,
#     source-to-source, states map) followed by the 19 OMOP domain INSERT
#     SQL files produced by ETLSyntheaBuilder::LoadEventTables.
# 11. Creates extra CDM indexes via ETLSyntheaBuilder::CreateExtraIndices.
#
# Called by: workflow/05_etl_csv_to_omop.R
# =============================================================================

source("config.R")
source("R/drivers.R")
source("R/connection.R")

# run_synthea_full_csv_builder_etl()
# ---------------------------------------------------------------------------
# Main entry point.  All ETL logic lives inside this function so that its
# closures can share config, connection details, and helper functions without
# passing them through every call.
#
# Parameters:
#   csv_input_dir          Path to the folder produced by Synthea (Step 4).
#                          Must contain *.csv files such as patients.csv,
#                          encounters.csv, conditions.csv, etc.
#   run_name               Audit label stamped on log output.  Auto-generated
#                          from the current timestamp if not supplied.
#   synthea_schema         SQL Server schema to use for Synthea staging tables.
#                          Default: "synthea".
#   synthea_version        Synthea release version passed to ETLSyntheaBuilder
#                          to select the correct DDL/SQL bundle. Default: "3.3.0".
#   cdm_version            OMOP CDM version for DDL and insert SQL generation.
#                          Default: "5.4".
#   cdm_schema             Override the CDM schema from config.R.  Useful for
#                          isolated study schemas (e.g. omop_synth_pad_oler_ssi).
#   vocabulary_source_schema Schema to bootstrap vocabulary from when
#                          reload_vocab_from_csv is FALSE and the target schema
#                          has no vocab loaded.  Defaults to cdm_schema.
#   reload_vocab_from_csv  When TRUE, load vocabulary tables from CSV files in
#                          vocab_file_loc using ETLSyntheaBuilder::LoadVocabFromCsv.
#                          When FALSE, use bootstrap-from-schema instead.
#   vocab_file_loc         Directory containing OMOP vocabulary CSV files
#                          (CONCEPT.csv, CONCEPT_ANCESTOR.csv, …).
#                          Required when reload_vocab_from_csv = TRUE.
#   vocab_delimiter        Column delimiter used in the vocabulary CSVs.
#                          OHDSI distributions are tab-delimited ("\t").
#   reset_before_etl       Drop and recreate all Synthea staging tables and OMOP
#                          event tables before loading.  Set FALSE only for
#                          incremental / resumption runs.
#   synthea_bulk_load      Attempt high-speed JDBC bulk insert first.  Falls
#                          back automatically to row-by-row mode on failure.
#   verbose                Emit [INFO]/[WARN] log messages during execution.
run_synthea_full_csv_builder_etl <- function(
    csv_input_dir,
    run_name = paste0("padssi-csv-full-", format(Sys.time(), "%Y%m%d-%H%M%S")),
    synthea_schema = "synthea",
    synthea_version = "3.3.0",
    cdm_version = "5.4",
    cdm_schema = NULL,
    vocabulary_source_schema = NULL,
  reload_vocab_from_csv = FALSE,
  vocab_file_loc = NULL,
  vocab_delimiter = "\t",
    reset_before_etl = TRUE,
    synthea_bulk_load = TRUE,
    verbose = TRUE) {

  # ---------------------------------------------------------------------------
  # 1. Resolve runtime configuration
  # ---------------------------------------------------------------------------
  # Load central config and apply any schema override supplied by the caller.
  # active_vocab_source_schema is the fallback for bootstrapping vocabulary
  # when reload_vocab_from_csv is FALSE.
  config <- get_validation_config()
  if (!is.null(cdm_schema) && nzchar(cdm_schema)) {
    config$cdm_schema <- cdm_schema
  }

  active_vocab_source_schema <- if (
    !is.null(vocabulary_source_schema) && nzchar(vocabulary_source_schema)
  ) vocabulary_source_schema else config$cdm_schema

  active_vocab_file_loc <- if (!is.null(vocab_file_loc) && nzchar(vocab_file_loc)) {
    vocab_file_loc
  } else {
    NULL
  }

  # ---------------------------------------------------------------------------
  # 2. Logging and progress-bar helpers
  # ---------------------------------------------------------------------------
  # log_msg() respects the verbose flag and prefixes every message with a
  # severity level so callers can grep for [WARN] lines in captured logs.
  log_msg <- function(..., level = "INFO") {
    if (isTRUE(verbose)) {
      message("[", level, "] ", paste0(..., collapse = ""))
    }
  }

  # create_progress_tracker() returns a two-element list with tick(label) and
  # close().  tick() advances the text progress bar and emits a log line with
  # the step number so the operator can see exactly which phase is running.
  create_progress_tracker <- function(total_steps) {
    pb <- utils::txtProgressBar(min = 0, max = total_steps, style = 3)
    current <- 0L
    list(
      tick = function(label) {
        current <<- current + 1L
        utils::setTxtProgressBar(pb, current)
        log_msg("[", current, "/", total_steps, "] ", label)
      },
      close = function() {
        close(pb)
      }
    )
  }

  # ---------------------------------------------------------------------------
  # 3. Pre-conditions: JDBC driver, Java, CSV directory, required packages
  # ---------------------------------------------------------------------------
  # ensure_jdbc_bundle downloads the SQL Server JDBC driver jar if absent.
  # configure_java sets JAVA_HOME and java.library.path for rJava.
  ensure_jdbc_bundle(config)
  configure_java(config)

  if (!dir.exists(csv_input_dir)) {
    stop("CSV input directory does not exist: ", csv_input_dir)
  }

  csv_files <- list.files(csv_input_dir, pattern = "\\.csv$", full.names = TRUE)
  if (length(csv_files) == 0) {
    stop("No CSV files found in: ", csv_input_dir)
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

  # ---------------------------------------------------------------------------
  # 4. Database connection and preflight check
  # ---------------------------------------------------------------------------
  # build_connection_details() assembles a DatabaseConnector connectionDetails
  # object from config.R (server, port, database, JDBC driver path, integrated
  # security settings).  run_db_preflight() then makes 3 consecutive successful
  # connections before proceeding, guarding against transient SQL Server startup
  # delays in local/dev environments.
  connection_details <- build_connection_details(config)

  run_db_preflight(
    connection_details,
    required_successes = 3L,
    max_attempts = 10L,
    delay_seconds = 2
  )

  # run_step_with_retry() wraps a single ETLSyntheaBuilder call in the project's
  # standard retry decorator (with_db_retry) so transient JDBC errors are
  # retried up to max_attempts times with an exponential back-off.
  run_step_with_retry <- function(step_name, expr, max_attempts = 3L) {
    with_db_retry(
      expr,
      operation_name = step_name,
      max_attempts = max_attempts,
      initial_delay_seconds = 2
    )
  }

  # ---------------------------------------------------------------------------
  # 5. SQL helper utilities
  # ---------------------------------------------------------------------------
  # render_sql() renders SqlRender @parameters then translates the resulting
  # SQL to the target DBMS dialect (sql server for this project).  All dynamic
  # SQL throughout this script must go through this helper to prevent injection
  # and ensure portability.
  render_sql <- function(sql, ...) {
    SqlRender::translate(
      SqlRender::render(sql, ...),
      targetDialect = config$dbms
    )
  }

  # table_exists() returns TRUE if a table with the given name exists in the
  # given schema.  Uses INFORMATION_SCHEMA.TABLES for portability.
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

  # table_has_rows() returns TRUE if the table exists AND contains at least one
  # row.  Used for vocabulary precheck: an empty concept table is treated as
  # "not loaded" and triggers the bootstrap or CSV reload path.
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

  # vocab_is_loaded() confirms all three minimum vocabulary tables
  # (concept, concept_ancestor, concept_relationship) are populated.
  # These are necessary for the ETL source-to-standard mapping queries.
  vocab_is_loaded <- function(connection, cdm_schema) {
    required_vocab_tables <- c("concept", "concept_ancestor", "concept_relationship")
    all(vapply(
      required_vocab_tables,
      function(table_name) table_has_rows(connection, cdm_schema, table_name),
      logical(1)
    ))
  }

  # assert_vocab_loaded_for_etl() is a hard guard called after all vocabulary
  # load paths have been attempted.  If vocabulary is still absent it stops
  # with a clear message pointing to the correct remediation step.
  assert_vocab_loaded_for_etl <- function(connection, cdm_schema) {
    if (isTRUE(vocab_is_loaded(connection, cdm_schema))) {
      return(invisible(TRUE))
    }

    stop(
      paste0(
        "Vocabulary precheck failed in ", cdm_schema, ". Required populated tables are: ",
        "concept, concept_relationship, and concept_ancestor. ",
        "This analysis repository no longer loads vocabularies during Step 5 ETL. ",
        "Please run the separate 'vocab_omop_etl' process to load vocabularies, then rerun workflow/05_etl_csv_to_omop.R."
      ),
      call. = FALSE
    )
  }

  # bootstrap_vocabulary_from_schema() is the fallback when reload_vocab_from_csv
  # is FALSE.  It copies all vocabulary tables row-by-row from a reference
  # schema (usually cdm_synthea) into the target schema via INSERT ... SELECT.
  # Only tables that exist in BOTH schemas are copied; missing tables are skipped.
  bootstrap_vocabulary_from_schema <- function(connection, target_schema, source_schema) {
    if (identical(target_schema, source_schema)) {
      return(invisible(FALSE))
    }

    if (!isTRUE(vocab_is_loaded(connection, source_schema))) {
      stop(
        "Cannot bootstrap vocabulary: source schema '", source_schema,
        "' does not contain populated concept/concept_relationship/concept_ancestor tables.",
        call. = FALSE
      )
    }

    vocab_tables <- c(
      "vocabulary", "concept_class", "domain", "relationship",
      "concept", "concept_relationship", "concept_synonym",
      "concept_ancestor", "drug_strength", "source_to_concept_map"
    )

    copied_any <- FALSE
    for (table_name in vocab_tables) {
      if (!isTRUE(table_exists(connection, source_schema, table_name))) {
        next
      }
      if (!isTRUE(table_exists(connection, target_schema, table_name))) {
        next
      }

      log_msg(
        "Bootstrapping vocabulary table ", target_schema, ".", table_name,
        " from ", source_schema, ".", table_name, " ..."
      )

      clear_sql <- render_sql(
        "DELETE FROM @target_schema.@table_name;",
        target_schema = target_schema,
        table_name = table_name
      )
      execute_sql_with_retry(connection, clear_sql)

      copy_sql <- render_sql(
        "INSERT INTO @target_schema.@table_name
         SELECT *
         FROM @source_schema.@table_name;",
        target_schema = target_schema,
        source_schema = source_schema,
        table_name = table_name
      )
      execute_sql_with_retry(connection, copy_sql)
      copied_any <- TRUE
    }

    copied_any
  }

  # clear_schema_tables() drops every user table in the named schema.  Called
  # during reset to surgically clear the synthea staging schema when the
  # ETLSyntheaBuilder::DropSyntheaTables call fails due to version mismatches.
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

  # ensure_cdm_tables_exist() checks all 19 required OMOP CDM v5.4 tables.
  # Two recovery paths are taken when tables are missing:
  #   a) If vocabulary tables are also absent → call CreateCDMTables (full DDL).
  #   b) If vocabulary is already present → generate DDL with sqlOnly=TRUE,
  #      then execute only the missing non-vocabulary table stanzas so existing
  #      vocabulary data is not disturbed.
  ensure_cdm_tables_exist <- function() {
    conn_cdm <- connect_with_retry(connection_details)
    on.exit(DatabaseConnector::disconnect(conn_cdm), add = TRUE)

    required_cdm_tables <- c(
      "person", "location", "care_site", "provider",
      "observation_period", "visit_occurrence",
      "visit_detail", "condition_occurrence", "observation",
      "measurement", "procedure_occurrence", "drug_exposure",
      "condition_era", "drug_era", "cdm_source",
      "device_exposure", "death", "payer_plan_period", "cost"
    )
    missing_tables <- required_cdm_tables[!vapply(
      required_cdm_tables,
      function(tb) table_exists(conn_cdm, config$cdm_schema, tb),
      logical(1)
    )]

    if (length(missing_tables) > 0) {
      vocab_tables <- c(
        "concept", "concept_ancestor", "concept_class", "concept_relationship",
        "concept_synonym", "domain", "drug_strength", "relationship",
        "vocabulary", "source_to_concept_map"
      )
      vocab_present <- all(vapply(
        vocab_tables,
        function(tb) table_exists(conn_cdm, config$cdm_schema, tb),
        logical(1)
      ))

      if (!vocab_present) {
        # Ensure CDM schema exists before calling CreateCDMTables
        execute_sql_with_retry(
          conn_cdm,
          paste0("IF SCHEMA_ID('", config$cdm_schema, "') IS NULL EXEC('CREATE SCHEMA ", config$cdm_schema, "');")
        )

        message(
          "Missing CDM tables detected in ", config$cdm_schema,
          " (", paste(missing_tables, collapse = ", "), "); recreating CDM tables."
        )
        run_step_with_retry("ETLSyntheaBuilder::CreateCDMTables", ETLSyntheaBuilder::CreateCDMTables(
          connectionDetails = connection_details,
          cdmSchema = config$cdm_schema,
          cdmVersion = cdm_version
        ))
        return(invisible(NULL))
      }

      # Vocabulary-only reset path: create only missing non-vocabulary tables from DDL.
      message(
        "Missing non-vocabulary CDM tables detected in ", config$cdm_schema,
        " (", paste(missing_tables, collapse = ", "), "); creating missing tables from DDL."
      )

      ddl_dir <- file.path("output", "cdm_sql")
      full_ddl_path <- file.path(ddl_dir, paste0("OMOPCDM_sql_server_", cdm_version, "_ddl.sql"))
      if (!file.exists(full_ddl_path)) {
        run_step_with_retry("ETLSyntheaBuilder::CreateCDMTables(sqlOnly)", ETLSyntheaBuilder::CreateCDMTables(
          connectionDetails = connection_details,
          cdmSchema = config$cdm_schema,
          cdmVersion = cdm_version,
          outputFolder = file.path(getwd(), ddl_dir),
          sqlOnly = TRUE
        ))
      }

      if (!file.exists(full_ddl_path)) {
        stop("Missing full CDM DDL file not found: ", full_ddl_path)
      }

      ddl_lines <- readLines(full_ddl_path, warn = FALSE)
      create_line_idx <- grep("^\\s*CREATE\\s+TABLE\\s+", ddl_lines, ignore.case = TRUE)
      if (length(create_line_idx) == 0L) {
        stop("No CREATE TABLE statements found in: ", full_ddl_path)
      }

      for (k in seq_along(create_line_idx)) {
        start_idx <- create_line_idx[[k]]
        end_idx <- if (k < length(create_line_idx)) create_line_idx[[k + 1L]] - 1L else length(ddl_lines)
        create_line <- ddl_lines[[start_idx]]

        m <- regexec(
          "(?i)^\\s*CREATE\\s+TABLE\\s+([A-Za-z0-9_]+)\\.([A-Za-z0-9_]+)",
          create_line,
          perl = TRUE
        )
        parts <- regmatches(create_line, m)[[1]]
        if (length(parts) < 3L) {
          next
        }

        table_name <- tolower(parts[[3]])
        if (!(table_name %in% missing_tables) || (table_name %in% vocab_tables)) {
          next
        }

        stmt <- paste(ddl_lines[start_idx:end_idx], collapse = "\n")
        stmt <- sub(
          "(?i)^\\s*CREATE\\s+TABLE\\s+[A-Za-z0-9_]+\\.",
          paste0("CREATE TABLE ", config$cdm_schema, "."),
          stmt,
          perl = TRUE
        )

        create_sql <- paste0(
          "IF OBJECT_ID('", config$cdm_schema, ".", table_name, "','U') IS NULL\n",
          "BEGIN\n",
          stmt,
          "\nEND;"
        )
        execute_sql_with_retry(conn_cdm, create_sql)
      }

      still_missing <- required_cdm_tables[!vapply(
        required_cdm_tables,
        function(tb) table_exists(conn_cdm, config$cdm_schema, tb),
        logical(1)
      )]
      if (length(still_missing) > 0) {
        stop(
          "Failed to create required CDM tables: ",
          paste(still_missing, collapse = ", ")
        )
      }
    }
  }

  # drop_rollup_helper_tables() removes the three intermediate visit rollup
  # tables (ALL_VISITS, ASSIGN_ALL_VISIT_IDS, FINAL_VISIT_IDS) that are
  # created during the visit assignment step.  Called during reset so they are
  # regenerated cleanly on the next run even if the previous run partially
  # completed the visit rollup phase.
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

  # execute_sql_file() reads a SQL file, applies two SQL Server-specific patches
  # for known ETLSyntheaBuilder syntax issues, then executes via
  # execute_sql_with_retry().  Two files receive special treatment:
  #
  #   insert_person.sql  — ETLSyntheaBuilder emits the non-standard
  #     "INSERT ... WITH CTE ... SELECT" form which SQL Server rejects.
  #     The regex below reorders it to the valid "WITH CTE ... INSERT ... SELECT".
  #
  #   insert_drug_era.sql — The generated query joins drug_exposure directly
  #     against concept_ancestor (75M rows), causing CXSYNC_PORT parallelism
  #     stalls that never complete on this instance.  This patch pre-materialises
  #     the drug→ingredient mapping into a temp table (#drug_ingredient_map)
  #     so the join operates on ~300 rows instead of 75M, and adds MAXDOP 1
  #     to suppress the parallel query plan.
  execute_sql_file <- function(connection, file_path) {
    sql <- paste(readLines(file_path, warn = FALSE), collapse = "\n")

    # ETLSyntheaBuilder can emit INSERT ... WITH CTE ... SELECT for person load,
    # which is invalid in SQL Server. Rewrite to WITH CTE ... INSERT ... SELECT.
    if (tolower(basename(file_path)) == "insert_person.sql") {
      schema_esc <- gsub("\\.", "\\\\.", config$cdm_schema)
      pat <- paste0(
        "(?is)^\\s*(insert\\s+into\\s+", schema_esc, "\\.person\\s*\\([^)]*\\)\\s*)",
        "with\\s+mapped_states\\s+as\\s*\\((.*?)\\)\\s*select(.*)$"
      )
      m <- regexec(pat, sql, perl = TRUE)
      parts <- regmatches(sql, m)[[1]]
      if (length(parts) == 4) {
        insert_stmt <- parts[2]
        cte_body <- parts[3]
        select_tail <- parts[4]
        sql <- paste0(
          "with mapped_states as (", cte_body, ")\n",
          insert_stmt,
          "select",
          select_tail
        )
      }
    }

    # insert_drug_era.sql joins drug_exposure directly against concept_ancestor
    # (75M rows), causing CXSYNC_PORT parallelism stalls that never complete.
    # Fix: pre-materialize the ~300-row drug→ingredient mapping into a temp table,
    # then rewrite ctePreDrugTarget to join that instead.
    if (tolower(basename(file_path)) == "insert_drug_era.sql") {
      schema <- config$cdm_schema
      schema_esc <- gsub("\\.", "\\\\.", schema)

      # Replace c.concept_id alias in ctePreDrugTarget SELECT list
      sql <- gsub(
        "c\\.concept_id\\s+AS\\s+ingredient_concept_id",
        "dim.ingredient_concept_id",
        sql, ignore.case = TRUE
      )

      # Replace the expensive 3-table JOIN+WHERE block with a join to the pre-computed map.
      # The (?si) flags make . match newlines and the pattern case-insensitive.
      # We consume through "AND c.concept_class_id = 'Ingredient'..." and replace
      # with the map join + "WHERE 1=1" so the remaining AND clauses stay valid.
      sql <- gsub(
        paste0("(?si)JOIN\\s+", schema_esc, "\\.concept_ancestor\\s+ca",
               ".*?AND\\s+c\\.concept_class_id\\s*=\\s*'Ingredient'[^\n]*"),
        paste0("JOIN #drug_ingredient_map dim ON dim.drug_concept_id = d.drug_concept_id\n",
               "\t\tWHERE 1=1"),
        sql, perl = TRUE
      )

      # Add OPTION(MAXDOP 1) to the final SELECT INTO to prevent parallel stalls
      # on the window functions over the (now small) intermediate dataset.
      sql <- sub(
        "GROUP BY person_id, drug_concept_id, drug_era_end_date;",
        "GROUP BY person_id, drug_concept_id, drug_era_end_date\nOPTION (MAXDOP 1);",
        sql, ignore.case = TRUE
      )

      # Prepend temp table pre-computation (runs in seconds: 257 distinct concepts)
      prep <- paste0(
        "IF OBJECT_ID('tempdb..#drug_ingredient_map', 'U') IS NOT NULL\n",
        "  DROP TABLE #drug_ingredient_map;\n\n",
        "SELECT DISTINCT d.drug_concept_id, c.concept_id AS ingredient_concept_id\n",
        "INTO #drug_ingredient_map\n",
        "FROM ", schema, ".drug_exposure d\n",
        "  JOIN ", schema, ".concept_ancestor ca\n",
        "    ON ca.descendant_concept_id = d.drug_concept_id\n",
        "  JOIN ", schema, ".concept c\n",
        "    ON ca.ancestor_concept_id = c.concept_id\n",
        "WHERE c.vocabulary_id = 'RxNorm'\n",
        "  AND c.concept_class_id = 'Ingredient'\n",
        "  AND d.drug_concept_id != 0\n",
        "OPTION (MAXDOP 1);\n\n",
        "CREATE INDEX IX_dim_dc ON #drug_ingredient_map (drug_concept_id);\n\n"
      )
      sql <- paste0(prep, sql)
    }

    # Date column VARCHAR→DATETIME2 conversion patch: staging date fields may
    # arrive in one of three forms depending on JDBC coercion behavior:
    #   1) ISO timestamp string (yyyy-mm-ddThh:mm:ss[.fff][Z])
    #   2) ISO date string      (yyyy-mm-dd)
    #   3) Integer day offset from 1970-01-01 (for example: -10010)
    # To prevent hard conversion failures, map all known date tokens to a
    # tolerant COALESCE(TRY_CONVERT..., DATEADD(day, int, '1970-01-01')).
    date_expr <- paste0(
      "COALESCE(",
      "TRY_CONVERT(DATETIME2, \\1.\\2, 126), ",
      "TRY_CONVERT(DATETIME2, \\1.\\2, 23), ",
      "CASE WHEN TRY_CONVERT(INT, \\1.\\2) IS NOT NULL ",
      "THEN DATEADD(DAY, TRY_CONVERT(INT, \\1.\\2), CONVERT(DATETIME2, '1970-01-01', 23)) END",
      ")"
    )
    sql <- gsub(
      "\\b([a-z]+)\\.\\b(birthdate|startdate|stopdate|START_DATE|STOP_DATE|BIRTHDATE)\\b",
      date_expr,
      sql, ignore.case = TRUE, perl = TRUE
    )

    execute_sql_with_retry(connection, sql)
  }

  # create_visit_rollup_tables_sql_server() generates and executes the three
  # visit assignment SQL scripts produced by ETLSyntheaBuilder:
  #   AllVisitTable.sql          — flattens all encounter rows into ALL_VISITS
  #   AAVITable.sql              — assigns visit_occurrence IDs (ASSIGN_ALL_VISIT_IDS)
  #   FINAL_VISIT_IDS (inline)   — deduplicates to one visit ID per encounter
  #                                using a priority-ranked window function
  # The final FINAL_VISIT_IDS step is re-implemented inline rather than from
  # a generated file to allow safe re-execution (IF OBJECT_ID ... DROP) and
  # to avoid hardcoded schema names in the generated output SQL.
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

  # load_event_tables_sql_server() drives the full domain INSERT workload:
  #   Phase A — Map SQL (3 files):
  #     create_source_to_standard_vocab_map.sql  — maps source codes (SNOMED,
  #       LOINC, RxNorm, CPT4) to their standard OMOP concept IDs.
  #     create_source_to_source_vocab_map.sql    — preserves source concept IDs
  #       for observation_source_concept_id and similar columns.
  #     create_states_map.sql                    — maps US state names to
  #       OMOP location concept IDs.
  #   Phase B — Domain INSERT SQL (19 files, one per OMOP CDM table):
  #     insert_location, insert_care_site, insert_person,
  #     insert_observation_period, insert_provider,
  #     insert_visit_occurrence, insert_visit_detail,
  #     insert_condition_occurrence, insert_observation, insert_measurement,
  #     insert_procedure_occurrence, insert_drug_exposure,
  #     insert_condition_era, insert_drug_era, insert_cdm_source,
  #     insert_device_exposure, insert_death, insert_payer_plan_period,
  #     insert_cost_v300.
  #
  # Every file is executed via execute_sql_file(), which applies the
  # SQL Server-specific patches for insert_person and insert_drug_era.
  # Each file ticks the progress bar so the operator can track domain progress.
  load_event_tables_sql_server <- function(progress_tracker = NULL) {
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
      if (!is.null(progress_tracker)) {
        progress_tracker$tick(paste0("Loaded map SQL: ", basename(sql_file)))
      }
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
      if (!is.null(progress_tracker)) {
        progress_tracker$tick(paste0("Loaded event SQL: ", basename(sql_file)))
      }
    }
  }

  # ---------------------------------------------------------------------------
  # 6. Execution begins — emit run-identifying header to logs
  # ---------------------------------------------------------------------------
  log_msg("=== Step 5 CSV builder ETL ===")
  log_msg("run_name: ", run_name)
  log_msg("csv_input_dir: ", normalizePath(csv_input_dir, winslash = "/", mustWork = TRUE))
  log_msg("synthea_schema: ", synthea_schema)
  log_msg("synthea_version: ", synthea_version)
  log_msg("cdm_schema: ", config$cdm_schema)
  log_msg("vocabulary_source_schema: ", active_vocab_source_schema)
  log_msg("reload_vocab_from_csv: ", ifelse(isTRUE(reload_vocab_from_csv), "true", "false"))
  if (isTRUE(reload_vocab_from_csv)) {
    log_msg("vocab_file_loc: ", ifelse(is.null(active_vocab_file_loc), "<unset>", active_vocab_file_loc))
  }

  map_table_count <- 3L
  event_table_count <- 19L
  progress_total_steps <- 9L + map_table_count + event_table_count
  if (isTRUE(reload_vocab_from_csv)) {
    progress_total_steps <- progress_total_steps + 1L
  }
  progress <- create_progress_tracker(progress_total_steps)
  on.exit(progress$close(), add = TRUE)

  # ---------------------------------------------------------------------------
  # 7. CDM table structure and staging schema setup
  # ---------------------------------------------------------------------------
  # Verify (or create) all OMOP CDM tables in the target schema.  This step
  # is idempotent — it only issues DDL for genuinely missing tables.
  ensure_cdm_tables_exist()
  progress$tick("CDM table structure verified")

  # Ensure the synthea staging schema exists.  CREATE SCHEMA is wrapped in an
  # IF SCHEMA_ID guard so it is safe to call on every run.
  conn_check <- connect_with_retry(connection_details)
  log_msg("CDM tables verified in ", config$cdm_schema, ".")

  execute_sql_with_retry(
    conn_check,
    paste0("IF SCHEMA_ID('", synthea_schema, "') IS NULL EXEC('CREATE SCHEMA ", synthea_schema, "');")
  )
  progress$tick("Synthea staging schema verified")

  # ---------------------------------------------------------------------------
  # 8. Vocabulary load
  # ---------------------------------------------------------------------------
  # Preferred path (reload_vocab_from_csv = TRUE):
  #   Call ETLSyntheaBuilder::LoadVocabFromCsv with the OHDSI vocabulary CSV
  #   directory.  This loads ~130M rows across 9 vocabulary tables.
  #
  # Fallback path (reload_vocab_from_csv = FALSE):
  #   If the target schema has no vocabulary, bootstrap it from the reference
  #   schema (vocabulary_source_schema) via INSERT ... SELECT.
  #
  # Hard guard: regardless of path taken, assert_vocab_loaded_for_etl() will
  # stop execution if concept/concept_ancestor/concept_relationship are empty.
  if (isTRUE(reload_vocab_from_csv)) {
    if (is.null(active_vocab_file_loc) || !dir.exists(active_vocab_file_loc)) {
      stop(
        "reload_vocab_from_csv=TRUE but vocab_file_loc is not set to an existing directory: ",
        ifelse(is.null(active_vocab_file_loc), "<NULL>", active_vocab_file_loc),
        call. = FALSE
      )
    }

    # Pre-flight: ensure the transaction log is large enough for the vocab
    # bulk load.  CONCEPT_ANCESTOR alone is 75 M rows; JDBC batch inserts are
    # fully logged even in SIMPLE recovery, so we need ≥ 25 GB of log space
    # before we start.  ALTER DATABASE MODIFY FILE is async, so we must WAIT
    # and verify the log actually grew on disk before proceeding.
    log_msg("Pre-flight: expanding transaction log for bulk vocabulary load ...")
    tryCatch({
      conn_log <- connect_with_retry(connection_details)
      on.exit(DatabaseConnector::disconnect(conn_log), add = TRUE)

      log_meta_sql <- render_sql(
        "SELECT f.name AS log_name, f.size * 8.0 / 1024 AS size_mb
         FROM sys.master_files f
         JOIN sys.databases d ON f.database_id = d.database_id
         WHERE d.name = '@database' AND f.type_desc = 'LOG';",
        database = config$database
      )
      log_meta <- query_sql_with_retry(conn_log, log_meta_sql)
      names(log_meta) <- tolower(names(log_meta))

      if (nrow(log_meta) > 0L) {
        log_file_name <- as.character(log_meta$log_name[[1]])
        log_size_mb   <- as.numeric(log_meta$size_mb[[1]])
        target_mb     <- 25600L   # 25 GB

        # Switch to SIMPLE recovery so ETL checkpoints can truncate the log
        execute_sql_with_retry(conn_log,
          paste0("ALTER DATABASE [", config$database, "] SET RECOVERY SIMPLE;")
        )

        if (log_size_mb < target_mb) {
          log_msg(
            "Growing transaction log from ", round(log_size_mb, 0),
            " MB to ", target_mb, " MB ...", level = "WARN"
          )
          execute_sql_with_retry(conn_log, paste0(
            "ALTER DATABASE [", config$database, "] MODIFY FILE ",
            "(NAME = N'", log_file_name, "', ",
            "SIZE = ", target_mb, "MB, FILEGROWTH = 2048MB);"
          ))

          # ALTER DATABASE MODIFY FILE is async; SQL Server returns immediately
          # but allocates the space on disk in a background task.  We must poll
          # until the log size reaches the target, otherwise the bulk insert will
          # start before the log has actually grown and immediately hit "log full".
          log_msg("Waiting for transaction log to be allocated on disk (this may take 30-60s) ...")
          max_wait_attempts <- 120L
          wait_interval <- 3L
          for (wait_attempt in seq_len(max_wait_attempts)) {
            Sys.sleep(wait_interval)
            current_log_sql <- render_sql(
              "SELECT f.size * 8.0 / 1024 AS size_mb
               FROM sys.master_files f
               WHERE f.database_id = DB_ID('@database') AND f.type_desc = 'LOG' AND f.name = '@log_name';",
              database = config$database,
              log_name = log_file_name
            )
            current_log <- query_sql_with_retry(conn_log, current_log_sql, max_attempts = 1L)
            current_size_mb <- as.numeric(current_log$size_mb[[1]])

            if (current_size_mb >= target_mb * 0.95) {
              log_msg(
                "Transaction log allocated: ", round(current_size_mb, 0),
                " MB (>= 95% of target). Ready for bulk vocab load."
              )
              break
            }

            if (wait_attempt %% 10L == 0L) {
              log_msg(
                "Still waiting... current log size: ", round(current_size_mb, 0),
                " MB (target: ", target_mb, " MB)"
              )
            }
          }

          if (wait_attempt >= max_wait_attempts) {
            log_msg(
              "Log pre-growth did not complete within timeout; proceeding anyway. ",
              "Monitor for 'log full' errors and re-run if needed.",
              level = "WARN"
            )
          }
        } else {
          # Already large enough; just set generous autogrowth
          execute_sql_with_retry(conn_log, paste0(
            "ALTER DATABASE [", config$database, "] MODIFY FILE ",
            "(NAME = N'", log_file_name, "', FILEGROWTH = 2048MB);"
          ))
          log_msg("Log is already ", round(log_size_mb, 0),
                  " MB (>= target); autogrowth set to 2 GB.")
        }
      }
    }, error = function(e) {
      log_msg(
        "Could not pre-grow transaction log (non-fatal): ", conditionMessage(e),
        level = "WARN"
      )
    })

    log_msg(
      "Reloading vocabulary from CSV via ETLSyntheaBuilder::LoadVocabFromCsv (README-style) ..."
    )
    run_step_with_retry("ETLSyntheaBuilder::LoadVocabFromCsv", ETLSyntheaBuilder::LoadVocabFromCsv(
      connectionDetails = connection_details,
      cdmSchema = config$cdm_schema,
      vocabFileLoc = active_vocab_file_loc,
      delimiter = vocab_delimiter
    ))
    progress$tick("Vocabulary loaded from CSV")
  } else if (!isTRUE(vocab_is_loaded(conn_check, config$cdm_schema))) {
    log_msg(
      "Vocabulary precheck failed in target schema ", config$cdm_schema,
      "; attempting bootstrap from source schema ", active_vocab_source_schema, " ...",
      level = "WARN"
    )

    copied_vocab <- bootstrap_vocabulary_from_schema(
      connection = conn_check,
      target_schema = config$cdm_schema,
      source_schema = active_vocab_source_schema
    )

    if (isTRUE(copied_vocab)) {
      log_msg(
        "Vocabulary bootstrap complete for target schema ", config$cdm_schema,
        " using source schema ", active_vocab_source_schema, "."
      )
    }
  }

  assert_vocab_loaded_for_etl(conn_check, config$cdm_schema)
  log_msg("Vocabulary precheck passed in ", config$cdm_schema, ".")
  progress$tick("Vocabulary precheck passed")

  DatabaseConnector::disconnect(conn_check)

  # ---------------------------------------------------------------------------
  # 9. Optional reset — drop existing staging and event tables
  # ---------------------------------------------------------------------------
  # When reset_before_etl = TRUE, all Synthea staging rows and all OMOP event
  # table rows are removed so the load begins from a clean state.  This is the
  # recommended mode for study validation runs.  Three layers of cleanup are
  # applied in order of specificity to handle situations where earlier rounds
  # of the same run left partial state:
  #   a) ETLSyntheaBuilder::DropEventTables   — drops OMOP event rows
  #   b) ETLSyntheaBuilder::DropSyntheaTables — drops synthea staging rows
  #   c) drop_rollup_helper_tables + clear_schema_tables — defensive fallback
  #      for version mismatches or partial prior runs
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
  progress$tick("Reset and cleanup completed")

  # ---------------------------------------------------------------------------
  # 10. Create Synthea staging tables
  # ---------------------------------------------------------------------------
  # ETLSyntheaBuilder::CreateSyntheaTables executes the versioned CREATE TABLE
  # DDL bundled inside the package for the specified synthea_version.
  # These staging tables mirror the Synthea CSV column layout precisely — they
  # are the insertion target for the raw Synthea CSV data before the OMOP
  # mapping transforms are applied.
  run_step_with_retry("ETLSyntheaBuilder::CreateSyntheaTables", ETLSyntheaBuilder::CreateSyntheaTables(
    connectionDetails = connection_details,
    syntheaSchema = synthea_schema,
    syntheaVersion = synthea_version
  ))
  progress$tick("Synthea staging tables created")

  # ---------------------------------------------------------------------------
  # Pre-flight: scan all Synthea CSVs against staging schema and correct every
  # date-type mismatch and varchar-too-narrow column before the load is even
  # attempted.  This runs once and prevents the reactive retry loop from having
  # to discover problems one CSV/column at a time.
  # ---------------------------------------------------------------------------
  align_synthea_staging_schema_to_csvs <- function() {
    log_msg("Pre-flight: aligning synthea staging schema to CSV column widths and types ...")

    # Fetch all staging column metadata in one query.
    conn_align <- connect_with_retry(connection_details)
    on.exit(DatabaseConnector::disconnect(conn_align), add = TRUE)

    schema_sql <- render_sql(
      "SELECT c.TABLE_NAME, c.COLUMN_NAME, c.DATA_TYPE,
              c.CHARACTER_MAXIMUM_LENGTH, c.ORDINAL_POSITION
       FROM INFORMATION_SCHEMA.COLUMNS c
       JOIN INFORMATION_SCHEMA.TABLES t
         ON c.TABLE_SCHEMA = t.TABLE_SCHEMA
        AND c.TABLE_NAME = t.TABLE_NAME
       WHERE c.TABLE_SCHEMA = '@synthea_schema'
         AND t.TABLE_TYPE = 'BASE TABLE'
       ORDER BY c.TABLE_NAME, c.ORDINAL_POSITION;",
      synthea_schema = synthea_schema
    )
    schema_df <- query_sql_with_retry(conn_align, schema_sql)
    if (nrow(schema_df) == 0L) {
      log_msg("Pre-flight: no staging tables found — skipping alignment.", level = "WARN")
      return(invisible(NULL))
    }

    # Normalise column names returned by DatabaseConnector (may be camelCase).
    names(schema_df) <- tolower(names(schema_df))

    date_type_set <- c("date", "datetime", "datetime2", "smalldatetime")
    fixes_applied <- 0L

    # Group by table.
    staging_tables <- unique(as.character(schema_df$table_name))

    for (tbl in staging_tables) {
      csv_path <- file.path(csv_input_dir, paste0(tolower(tbl), ".csv"))
      if (!file.exists(csv_path)) {
        next
      }

      tbl_schema <- schema_df[tolower(as.character(schema_df$table_name)) == tolower(tbl), ]

      # Read entire CSV once for this table (suppressing progress bar noise).
      csv_data <- tryCatch(
        data.table::fread(csv_path, showProgress = FALSE, na.strings = c("", "NULL")),
        error = function(e) NULL
      )
      if (is.null(csv_data) || nrow(csv_data) == 0L) {
        next
      }

      csv_col_names_lower <- tolower(names(csv_data))

      alters <- character(0L)

      for (k in seq_len(nrow(tbl_schema))) {
        col_name   <- tolower(as.character(tbl_schema$column_name[[k]]))
        data_type  <- tolower(as.character(tbl_schema$data_type[[k]]))
        staged_len <- suppressWarnings(as.integer(tbl_schema$character_maximum_length[[k]]))
        if (is.na(staged_len)) staged_len <- -1L

        col_idx <- match(col_name, csv_col_names_lower)
        if (is.na(col_idx)) next

        # -- Date/datetime columns: convert to varchar(32) so the loader can
        #    send a string representation without type-binding mismatches.
        if (data_type %in% date_type_set) {
          alters <- c(alters, paste0(
            "ALTER TABLE [", synthea_schema, "].[", tbl,
            "] ALTER COLUMN [", col_name, "] VARCHAR(32) NULL;"
          ))
          next
        }

        # -- Varchar columns: widen if any CSV value exceeds the staged width.
        if (data_type %in% c("varchar", "nvarchar", "char", "nchar") && staged_len > 0L) {
          col_values <- as.character(csv_data[[col_idx]])
          observed_max <- suppressWarnings(max(nchar(col_values, type = "chars", allowNA = TRUE, keepNA = FALSE), na.rm = TRUE))
          if (!is.finite(observed_max)) observed_max <- 0L
          if (observed_max > staged_len) {
            # Round up to next power of 2 (minimum 64) to avoid repeated widening.
            target_len <- max(64L, 2L ^ ceiling(log2(observed_max + 1L)))
            alters <- c(alters, paste0(
              "ALTER TABLE [", synthea_schema, "].[", tbl,
              "] ALTER COLUMN [", col_name, "] VARCHAR(", target_len, ") NULL;"
            ))
          }
        }
      }

      if (length(alters) > 0L) {
        log_msg(
          "Pre-flight: fixing ", length(alters), " column(s) in synthea.", tbl,
          " (date→varchar or too-narrow varchar).",
          level = "WARN"
        )
        for (alt_sql in alters) {
          execute_sql_with_retry(conn_align, alt_sql)
          fixes_applied <- fixes_applied + 1L
        }
      }
    }

    if (fixes_applied > 0L) {
      log_msg("Pre-flight alignment complete: ", fixes_applied, " staging column(s) corrected.", level = "WARN")
    } else {
      log_msg("Pre-flight alignment complete: all staging columns are compatible with CSVs.")
    }
    invisible(NULL)
  }

  # Run the pre-flight alignment immediately after staging tables are created.
  align_synthea_staging_schema_to_csvs()

  # ---------------------------------------------------------------------------
  # 11. Reactive load-error detection helpers
  # ---------------------------------------------------------------------------
  # These functions are the second line of defence after the pre-flight pass.
  # They parse SQL Server error messages and return structured information so
  # load_synthea_tables_with_mitigations() can apply targeted fixes and retry.

  # is_int_date_type_clash_error() detects the SQL Server JDBC binding error
  # that occurs when the JDBC driver tries to send a string value into a DATE
  # column using integer type codes.  This happens because Synthea emits dates
  # as ISO-8601 strings but ETLSyntheaBuilder's batchedInsert uses int binding.
  is_int_date_type_clash_error <- function(err) {
    msg <- tolower(conditionMessage(err))
    grepl("operand type clash", msg, fixed = TRUE) &&
      grepl("int is incompatible with date", msg, fixed = TRUE)
  }

  # parse_truncation_error() extracts the table and column name from a
  # "String or binary data would be truncated" error message.  Returns a
  # named list(table_name, column_name) or NULL if the pattern does not match.
  parse_truncation_error <- function(err) {
    msg <- conditionMessage(err)
    m <- regexec("(?i)table '([^']+)',\\s*column '([^']+)'", msg, perl = TRUE)
    parts <- regmatches(msg, m)[[1]]
    if (length(parts) < 3L) {
      return(NULL)
    }

    table_ref <- parts[[2]]
    table_parts <- strsplit(table_ref, "\\.", perl = TRUE)[[1]]
    table_name <- table_parts[[length(table_parts)]]
    column_name <- parts[[3]]

    list(
      table_name = tolower(table_name),
      column_name = tolower(column_name)
    )
  }

  # widen_synthea_column_from_csv() reads the CSV for the affected table,
  # computes the maximum character length of the named column, and issues an
  # ALTER TABLE ... ALTER COLUMN VARCHAR(n) to accommodate it.  The target
  # width is rounded up to the next power of 2, clamped to a minimum of 64,
  # to reduce the likelihood of having to repeat the same fix on a future run.
  widen_synthea_column_from_csv <- function(table_name, column_name, min_length = 64L) {
    conn_widen <- connect_with_retry(connection_details)
    on.exit(DatabaseConnector::disconnect(conn_widen), add = TRUE)

    col_sql <- render_sql(
      "SELECT DATA_TYPE, CHARACTER_MAXIMUM_LENGTH
       FROM INFORMATION_SCHEMA.COLUMNS
       WHERE TABLE_SCHEMA = '@synthea_schema'
         AND TABLE_NAME = '@table_name'
         AND COLUMN_NAME = '@column_name';",
      synthea_schema = synthea_schema,
      table_name = table_name,
      column_name = column_name
    )
    col_meta <- query_sql_with_retry(conn_widen, col_sql)
    if (nrow(col_meta) == 0L) {
      stop(
        "Cannot auto-widen staging column; column not found: ",
        synthea_schema, ".", table_name, ".", column_name,
        call. = FALSE
      )
    }

    current_len <- suppressWarnings(as.integer(col_meta$CHARACTER_MAXIMUM_LENGTH[[1]]))
    if (is.na(current_len) || current_len < 1L) {
      current_len <- 0L
    }

    csv_path <- file.path(csv_input_dir, paste0(table_name, ".csv"))
    if (!file.exists(csv_path)) {
      stop(
        "Cannot auto-widen staging column; CSV file not found for table '",
        table_name, "': ", csv_path,
        call. = FALSE
      )
    }

    csv_headers <- names(data.table::fread(
      csv_path,
      nrows = 0L,
      showProgress = FALSE
    ))
    matching_cols <- csv_headers[tolower(csv_headers) == tolower(column_name)]
    if (length(matching_cols) == 0L) {
      stop(
        "Cannot auto-widen staging column; CSV column not found: ",
        table_name, ".", column_name,
        call. = FALSE
      )
    }

    csv_col <- matching_cols[[1]]
    csv_col_data <- data.table::fread(
      csv_path,
      select = csv_col,
      showProgress = FALSE,
      na.strings = c("", "NULL")
    )

    value_len <- nchar(as.character(csv_col_data[[1]]), type = "chars", allowNA = TRUE, keepNA = FALSE)
    observed_max <- suppressWarnings(max(value_len, na.rm = TRUE))
    if (!is.finite(observed_max) || observed_max < 1) {
      observed_max <- min_length
    }

    target_len <- as.integer(max(current_len, observed_max, min_length))
    if (target_len <= current_len) {
      target_len <- as.integer(max(current_len, min_length))
    }

    alter_sql <- paste0(
      "ALTER TABLE [", synthea_schema, "].[", table_name,
      "] ALTER COLUMN [", column_name, "] VARCHAR(", target_len, ") NULL;"
    )
    execute_sql_with_retry(conn_widen, alter_sql)

    log_msg(
      "Widened staging column ", synthea_schema, ".", table_name, ".", column_name,
      " to VARCHAR(", target_len, ") based on CSV max length ", observed_max, ".",
      level = "WARN"
    )

    invisible(TRUE)
  }

  # relax_synthea_date_columns_for_loader() converts every date/datetime column
  # in the synthea staging schema to VARCHAR(32).  This is the reactive
  # complement to the pre-flight date-type conversion in
  # align_synthea_staging_schema_to_csvs().  It is called when an int/date
  # type-clash error is detected after the load has already started (e.g. when
  # the pre-flight ran before the staging tables were recreated in a different
  # connection).
  relax_synthea_date_columns_for_loader <- function() {
    log_msg(
      "Applying SQL Server staging mitigation: converting synthea date/datetime columns to varchar(32) for loader compatibility ...",
      level = "WARN"
    )

    conn_relax <- connect_with_retry(connection_details)
    on.exit(DatabaseConnector::disconnect(conn_relax), add = TRUE)

    discover_sql <- render_sql(
      "SELECT c.TABLE_NAME, c.COLUMN_NAME
       FROM INFORMATION_SCHEMA.COLUMNS c
       JOIN INFORMATION_SCHEMA.TABLES t
         ON c.TABLE_SCHEMA = t.TABLE_SCHEMA
        AND c.TABLE_NAME = t.TABLE_NAME
       WHERE c.TABLE_SCHEMA = '@synthea_schema'
         AND t.TABLE_TYPE = 'BASE TABLE'
         AND c.DATA_TYPE IN ('date', 'datetime', 'datetime2', 'smalldatetime');",
      synthea_schema = synthea_schema
    )
    date_cols <- query_sql_with_retry(conn_relax, discover_sql)
    if (nrow(date_cols) == 0L) {
      return(invisible(FALSE))
    }

    for (k in seq_len(nrow(date_cols))) {
      table_name <- as.character(date_cols$TABLE_NAME[[k]])
      column_name <- as.character(date_cols$COLUMN_NAME[[k]])
      alter_sql <- render_sql(
        "ALTER TABLE @synthea_schema.@table_name
         ALTER COLUMN @column_name VARCHAR(32) NULL;",
        synthea_schema = synthea_schema,
        table_name = table_name,
        column_name = column_name
      )
      execute_sql_with_retry(conn_relax, alter_sql)
    }

    log_msg(
      "Mitigation complete: widened ", nrow(date_cols),
      " synthea date/datetime staging columns to varchar(32).",
      level = "WARN"
    )
    invisible(TRUE)
  }

  # ---------------------------------------------------------------------------
  # 12. Synthea CSV staging load
  # ---------------------------------------------------------------------------
  # load_synthea_tables() calls ETLSyntheaBuilder::LoadSyntheaTables which
  # iterates over every Synthea CSV file in csv_input_dir and inserts each
  # into its corresponding staging table in synthea_schema.
  #
  # bulkLoad=TRUE uses JDBC batched insert for speed (~10x faster).
  # bulkLoad=FALSE uses single-row inserts as a fallback for environments
  # where bulk operations are restricted.
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

  # load_synthea_tables_with_mitigations() is the retry orchestrator for the
  # staging load phase.  It calls load_synthea_tables() in a repeat loop and
  # applies targeted fixes when known SQL Server error classes are returned:
  #   - int/date type clash → relax_synthea_date_columns_for_loader() once.
  #   - varchar truncation  → widen_synthea_column_from_csv() for the exact
  #                           table+column reported.  Up to max_fix_attempts
  #                           fixes are applied before giving up.
  # Any other error is re-thrown immediately to avoid masking unexpected issues.
  load_synthea_tables_with_mitigations <- function(use_bulk_load, max_fix_attempts = 8L) {
    fix_attempts <- 0L
    int_date_fix_applied <- FALSE

    repeat {
      load_result <- tryCatch({
        load_synthea_tables(use_bulk_load)
        NULL
      }, error = function(e) {
        e
      })

      if (is.null(load_result)) {
        return(invisible(TRUE))
      }

      if (is_int_date_type_clash_error(load_result) && !isTRUE(int_date_fix_applied)) {
        warning(
          "Detected SQL Server int/date type clash during staging load. ",
          "Applying staging column mitigation and retrying with bulkLoad=FALSE."
        )
        relax_synthea_date_columns_for_loader()
        int_date_fix_applied <- TRUE
        fix_attempts <- fix_attempts + 1L
        next
      }

      trunc_info <- parse_truncation_error(load_result)
      if (!is.null(trunc_info) && fix_attempts < max_fix_attempts) {
        warning(
          "Detected SQL Server truncation in staging load at ",
          trunc_info$table_name, ".", trunc_info$column_name,
          ". Auto-widening column and retrying."
        )
        widen_synthea_column_from_csv(
          table_name = trunc_info$table_name,
          column_name = trunc_info$column_name
        )
        fix_attempts <- fix_attempts + 1L
        next
      }

      stop(load_result)
    }
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
      load_synthea_tables_with_mitigations(FALSE)
    }
  } else {
    load_synthea_tables_with_mitigations(FALSE)
  }
  progress$tick("Synthea CSV staging loaded")

  create_visit_rollup_tables_sql_server()
  progress$tick("Visit rollup tables materialized")
  
  # Create concept_ancestor indexes BEFORE load_event_tables_sql_server to support drug_era query optimization
  message("[PERF] Creating concept_ancestor indexes for drug_era query optimization...")
  conn_indices_pre <- connect_with_retry(connection_details)
  on.exit(DatabaseConnector::disconnect(conn_indices_pre), add = TRUE)
  
  index_sql_pre <- SqlRender::translate(
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
  execute_sql_with_retry(conn_indices_pre, index_sql_pre)
  message("[PERF] concept_ancestor indexes ready for drug_era.")
  progress$tick("concept_ancestor indexes verified")
  
  load_event_tables_sql_server(progress)

  suppressWarnings(try(run_step_with_retry("ETLSyntheaBuilder::CreateExtraIndices", ETLSyntheaBuilder::CreateExtraIndices(
    connectionDetails = connection_details,
    cdmSchema = config$cdm_schema,
    cdmVersion = cdm_version
  )), silent = TRUE))
  progress$tick("Extra CDM indices created")

  invisible(list(run_name = run_name, mode = "csv_builder"))
}
