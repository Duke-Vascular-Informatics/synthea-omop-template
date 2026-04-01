# =============================================================================
# R/db_maintenance.R
# SQL Server database maintenance helpers for bulk ETL operations.
# =============================================================================

# -----------------------------------------------------------------------------
# prepare_txlog_for_bulk_etl
#
# Purpose:
#   Run a pre-flight transaction log check and preparation before a large bulk
#   ETL (e.g., vocabulary CSV load). Called automatically by Step 5 before
#   invoking run_synthea_full_csv_builder_etl().
#
# What it does:
#   1. Connects using the same JDBC credentials as the rest of Step 5.
#   2. Checks recovery mode — switches to SIMPLE if currently FULL, so that
#      SQL Server can checkpoint-truncate the log between bulk insert batches.
#   3. Issues CHECKPOINT + DBCC SHRINKFILE to reclaim space from prior runs.
#   4. Pre-grows the log to target_min_mb (default 25 GB) with generous
#      autogrowth increments so SQL Server never stalls mid-insert.
#   5. Prints a clear summary of before/after sizes.
#
# Arguments:
#   cfg            List returned by get_validation_config().
#   target_min_mb  Minimum log size in MB to ensure before ETL (default 25600).
#   autogrowth_mb  Autogrowth increment in MB to set (default 2048).
#   shrink_to_mb   Target size in MB for DBCC SHRINKFILE before pre-growing
#                  (default 1024). Frees space consumed by previous failed runs.
#
# Returns: invisibly TRUE on success; stops with an informative message on
#          any failure so Step 5 aborts cleanly before touching OMOP tables.
# -----------------------------------------------------------------------------
prepare_txlog_for_bulk_etl <- function(cfg,
                                       target_min_mb = 25600L,
                                       autogrowth_mb = 2048L,
                                       shrink_to_mb  = 1024L) {

  cat("\n[txlog] ── Transaction log pre-flight check ──────────────────────────\n")
  cat("[txlog] Database:", cfg$database, "on", cfg$server, "\n")

  # ---------------------------------------------------------------------------
  # Build connection details (same pattern used throughout Step 5).
  # ---------------------------------------------------------------------------
  connection_details <- DatabaseConnector::createConnectionDetails(
    dbms     = cfg$dbms,
    server   = cfg$server,
    user     = "",
    password = "",
    pathToDriver = cfg$jdbc_runtime_dir,
    extraSettings = paste0(
      "database=", cfg$database,
      ";integratedSecurity=true",
      ";authenticationScheme=NativeAuthentication",
      ";trustServerCertificate=true",
      ";portNumber=", cfg$sql_server_port
    )
  )

  conn <- tryCatch(
    DatabaseConnector::connect(connection_details),
    error = function(e) {
      stop("[txlog] Could not connect to SQL Server: ", conditionMessage(e), call. = FALSE)
    }
  )
  on.exit(DatabaseConnector::disconnect(conn), add = TRUE)

  # ---------------------------------------------------------------------------
  # 1. Check and set recovery mode.
  # ---------------------------------------------------------------------------
  recovery_sql <- paste0(
    "SELECT recovery_model_desc FROM sys.databases WHERE name = '",
    gsub("'", "''", cfg$database), "';"
  )
  recovery_row <- DatabaseConnector::querySql(conn, recovery_sql)
  colnames(recovery_row) <- tolower(colnames(recovery_row))
  current_mode <- recovery_row$recovery_model_desc[[1]]

  if (tolower(current_mode) != "simple") {
    cat("[txlog] Recovery mode is", current_mode, "— switching to SIMPLE for bulk ETL\n")
    DatabaseConnector::executeSql(
      conn,
      paste0("ALTER DATABASE [", cfg$database, "] SET RECOVERY SIMPLE;")
    )
    cat("[txlog] \u2713 Recovery mode set to SIMPLE\n")
  } else {
    cat("[txlog] \u2713 Recovery mode already SIMPLE\n")
  }

  # ---------------------------------------------------------------------------
  # 2. Look up the log file logical name and current size.
  # ---------------------------------------------------------------------------
  logfile_sql <- paste0(
    "SELECT name, size * 8.0 / 1024 AS size_mb ",
    "FROM sys.master_files ",
    "WHERE database_id = DB_ID('", gsub("'", "''", cfg$database), "') ",
    "  AND type_desc = 'LOG';"
  )
  log_row <- DatabaseConnector::querySql(conn, logfile_sql)
  colnames(log_row) <- tolower(colnames(log_row))

  if (nrow(log_row) == 0L) {
    stop("[txlog] Could not locate transaction log file for database '",
         cfg$database, "'.", call. = FALSE)
  }

  log_name    <- log_row$name[[1]]
  size_before <- round(log_row$size_mb[[1]], 1)
  cat("[txlog] Log file: '", log_name, "' — current size: ", size_before, " MB\n", sep = "")

  # ---------------------------------------------------------------------------
  # 3. CHECKPOINT + DBCC SHRINKFILE to reclaim space from prior runs.
  # ---------------------------------------------------------------------------
  # Note: DBCC SHRINKFILE returns a result set, so querySql() must be used
  # instead of executeSql() to avoid a "result set generated for update" error.
  cat("[txlog] Running CHECKPOINT + DBCC SHRINKFILE to reclaim prior-run space ...\n")
  DatabaseConnector::executeSql(conn, "CHECKPOINT;")
  tryCatch(
    DatabaseConnector::querySql(
      conn,
      paste0("DBCC SHRINKFILE (", log_name, ", ", as.integer(shrink_to_mb), ");")
    ),
    error = function(e) {
      cat("[txlog] SHRINKFILE note (non-fatal):", conditionMessage(e), "\n")
    }
  )

  log_after_shrink <- DatabaseConnector::querySql(conn, logfile_sql)
  colnames(log_after_shrink) <- tolower(colnames(log_after_shrink))
  size_after_shrink <- round(log_after_shrink$size_mb[[1]], 1)
  cat("[txlog] \u2713 After shrink: ", size_after_shrink, " MB\n", sep = "")

  # ---------------------------------------------------------------------------
  # 4. Pre-grow log to target_min_mb if still below it, and set autogrowth.
  # ---------------------------------------------------------------------------
  if (size_after_shrink < target_min_mb) {
    cat("[txlog] Pre-growing log from ", size_after_shrink, " MB to ",
        target_min_mb, " MB ...\n", sep = "")
    DatabaseConnector::executeSql(
      conn,
      paste0(
        "ALTER DATABASE [", cfg$database, "] MODIFY FILE (",
        "NAME = N'", log_name, "', ",
        "SIZE = ", as.integer(target_min_mb), "MB, ",
        "FILEGROWTH = ", as.integer(autogrowth_mb), "MB);"
      )
    )
  } else {
    cat("[txlog] Log already >= ", target_min_mb, " MB — updating autogrowth only\n", sep = "")
    DatabaseConnector::executeSql(
      conn,
      paste0(
        "ALTER DATABASE [", cfg$database, "] MODIFY FILE (",
        "NAME = N'", log_name, "', ",
        "FILEGROWTH = ", as.integer(autogrowth_mb), "MB);"
      )
    )
  }

  # ---------------------------------------------------------------------------
  # 5. Final size report.
  # ---------------------------------------------------------------------------
  log_final <- DatabaseConnector::querySql(conn, logfile_sql)
  colnames(log_final) <- tolower(colnames(log_final))
  size_final <- round(log_final$size_mb[[1]], 1)

  cat("[txlog] \u2713 Final log size : ", size_final, " MB\n", sep = "")
  cat("[txlog] \u2713 Autogrowth     : ", autogrowth_mb, " MB per increment\n", sep = "")
  cat("[txlog] \u2713 Ready for bulk ETL\n")
  cat("[txlog] ──────────────────────────────────────────────────────────────\n\n")

  invisible(TRUE)
}


# -----------------------------------------------------------------------------
# create_vocab_synonyms
#
# Purpose:
#   Create SQL Server SYNONYM objects in a target CDM schema that point to
#   all 10 OMOP vocabulary tables in a shared vocabulary schema.  Synonyms
#   are transparent to all downstream SQL — queries against
#   target_schema.concept resolve through to shared_vocab_schema.concept
#   without any data being copied.
#
#   This eliminates the need to copy ~10 GB of vocabulary into every CDM
#   schema, and avoids the 25 GB transaction log hit of LoadVocabFromCsv on
#   each ETL run.
#
# Arguments:
#   cfg                List returned by get_validation_config().
#   target_schema      CDM schema to create synonyms in (e.g. "omop_synth_pad_oler_ssi_02").
#   shared_vocab_schema Schema containing the real vocabulary tables (default "omop_vocab").
#
# Returns: invisibly TRUE on success; stops with a message if shared vocab
#          schema is missing or unpopulated.
# -----------------------------------------------------------------------------
create_vocab_synonyms <- function(cfg, target_schema, shared_vocab_schema = "omop_vocab") {

  vocab_tables <- c(
    "vocabulary", "concept_class", "domain", "relationship",
    "concept", "concept_relationship", "concept_synonym",
    "concept_ancestor", "drug_strength", "source_to_concept_map"
  )

  cat("\n[vocab] ── Creating vocabulary synonyms ─────────────────────────────\n")
  cat("[vocab] Source schema :", shared_vocab_schema, "\n")
  cat("[vocab] Target schema :", target_schema, "\n")

  connection_details <- DatabaseConnector::createConnectionDetails(
    dbms     = cfg$dbms,
    server   = cfg$server,
    user     = "",
    password = "",
    pathToDriver = cfg$jdbc_runtime_dir,
    extraSettings = paste0(
      "database=", cfg$database,
      ";integratedSecurity=true",
      ";authenticationScheme=NativeAuthentication",
      ";trustServerCertificate=true",
      ";portNumber=", cfg$sql_server_port
    )
  )

  conn <- tryCatch(
    DatabaseConnector::connect(connection_details),
    error = function(e) {
      stop("[vocab] Could not connect to SQL Server: ", conditionMessage(e), call. = FALSE)
    }
  )
  on.exit(DatabaseConnector::disconnect(conn), add = TRUE)

  # Verify the shared vocabulary schema exists and is populated.
  check_sql <- paste0(
    "SELECT COUNT(*) AS n FROM sys.schemas WHERE name = '",
    gsub("'", "''", shared_vocab_schema), "';"
  )
  schema_check <- DatabaseConnector::querySql(conn, check_sql)
  colnames(schema_check) <- tolower(colnames(schema_check))
  if (as.integer(schema_check$n[[1]]) == 0L) {
    stop(
      "[vocab] Shared vocabulary schema '", shared_vocab_schema, "' does not exist. ",
      "Run scripts/setup_omop_vocab_schema.R first to load vocabulary.",
      call. = FALSE
    )
  }

  # Verify concept table is populated in the shared schema.
  concept_check_sql <- paste0(
    "SELECT CASE WHEN EXISTS (SELECT 1 FROM [", shared_vocab_schema, "].[concept]) ",
    "THEN 1 ELSE 0 END AS has_rows;"
  )
  concept_check <- tryCatch(
    DatabaseConnector::querySql(conn, concept_check_sql),
    error = function(e) stop(
      "[vocab] Could not query shared vocab schema '", shared_vocab_schema,
      "': ", conditionMessage(e), call. = FALSE
    )
  )
  colnames(concept_check) <- tolower(colnames(concept_check))
  if (as.integer(concept_check$has_rows[[1]]) == 0L) {
    stop(
      "[vocab] Shared vocabulary schema '", shared_vocab_schema,
      "' exists but concept table is empty. ",
      "Run scripts/setup_omop_vocab_schema.R to load vocabulary.",
      call. = FALSE
    )
  }

  # Ensure target schema exists.
  DatabaseConnector::executeSql(
    conn,
    paste0(
      "IF SCHEMA_ID('", gsub("'", "''", target_schema), "') IS NULL ",
      "EXEC('CREATE SCHEMA [", target_schema, "]');"
    )
  )

  # Create synonyms for each vocabulary table (skip if already exists).
  created <- 0L
  skipped <- 0L
  for (tbl in vocab_tables) {
    exists_sql <- paste0(
      "SELECT COUNT(*) AS n FROM sys.synonyms s ",
      "JOIN sys.schemas sc ON s.schema_id = sc.schema_id ",
      "WHERE sc.name = '", gsub("'", "''", target_schema), "' ",
      "  AND s.name  = '", gsub("'", "''", tbl), "';"
    )
    exists_res <- DatabaseConnector::querySql(conn, exists_sql)
    colnames(exists_res) <- tolower(colnames(exists_res))

    if (as.integer(exists_res$n[[1]]) > 0L) {
      skipped <- skipped + 1L
      next
    }

    DatabaseConnector::executeSql(
      conn,
      paste0(
        "CREATE SYNONYM [", target_schema, "].[", tbl, "] ",
        "FOR [", shared_vocab_schema, "].[", tbl, "];"
      )
    )
    created <- created + 1L
  }

  cat("[vocab] \u2713 Synonyms created :", created, "\n")
  cat("[vocab] \u2713 Already existed  :", skipped, "\n")
  cat("[vocab] \u2713 All", length(vocab_tables),
      "vocabulary tables wired to", shared_vocab_schema, "\n")
  cat("[vocab] ──────────────────────────────────────────────────────────────\n\n")

  invisible(TRUE)
}
