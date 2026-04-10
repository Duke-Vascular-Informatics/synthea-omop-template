# =============================================================================
# R/cohorts.R
# Create the results schema / cohort table and instantiate the target (surgery)
# and outcome (SSI) cohorts using parameterised OHDSI SQL executed via
# SqlRender and DatabaseConnector.
#
# CROSS-DATABASE SUPPORT:
# When results_database in config differs from database (the CDM database),
# the cohort table is referenced with a three-part name:
#   [results_database].[results_schema].[cohort_table]
# SQL Server supports cross-database references as long as the connecting
# user has SELECT/INSERT/CREATE TABLE permission in results_database.
#
# SCHEMA NAMES WITH SPECIAL CHARACTERS:
# Schema names containing backslashes (e.g. "dhe\apj20") must be
# bracket-quoted in SQL Server: [dhe\apj20].  bracket_quote() handles this
# automatically so config$results_schema can be stored without brackets.
# =============================================================================

# Helper: bracket-quotes a SQL Server identifier when it contains characters
# that require quoting (backslash, space, hyphen, dot, etc.).
# e.g. "dhe\\apj20" -> "[dhe\\apj20]",  "dbo" -> "dbo"
bracket_quote <- function(name) {
  needs_quoting <- grepl("[\\\\\\s\\-\\.]", name, perl = TRUE)
  already_quoted <- grepl("^\\[", name)
  if (needs_quoting && !already_quoted) {
    paste0("[", name, "]")
  } else {
    name
  }
}

# Helper: returns the fully-qualified schema prefix for the results table,
# bracket-quoting any part that contains special characters.
# If results_database is set and differs from the CDM database, returns
# "[results_database].[results_schema]" (three-part name), otherwise just
# "[results_schema]" (two-part name).
results_schema_prefix <- function(config) {
  schema <- bracket_quote(config$results_schema)
  rdb    <- config$results_database
  if (!is.null(rdb) && !is.na(rdb) &&
      nchar(trimws(rdb)) > 0 && trimws(rdb) != "CHANGE_ME" &&
      trimws(rdb) != trimws(config$database)) {
    paste0(bracket_quote(trimws(rdb)), ".", schema)
  } else {
    schema
  }
}

# Ensure the results schema and the cohort table both exist.
ensure_results_schema <- function(connection, config) {
  prefix <- results_schema_prefix(config)

  # When results_database differs from the CDM database, switch context to
  # the results database for schema existence check and table creation.
  rdb <- config$results_database
  use_cross_db <- !is.null(rdb) && !is.na(rdb) &&
                  nchar(trimws(rdb)) > 0 && trimws(rdb) != "CHANGE_ME" &&
                  trimws(rdb) != trimws(config$database)

  if (use_cross_db) {
    message("Results database: ", trimws(rdb),
            " (separate from CDM database: ", config$database, ")")
    DatabaseConnector::executeSql(
      connection,
      paste0("USE [", trimws(rdb), "]"),
      reportOverallTime = FALSE
    )
  }

  # Check whether the schema exists (sys.schemas is database-scoped).
  schema_exists_sql <- SqlRender::render(
    sql            = "SELECT COUNT(*) AS n FROM sys.schemas WHERE name = '@results_schema'",
    results_schema = config$results_schema
  )
  schema_exists <- DatabaseConnector::querySql(
    connection,
    SqlRender::translate(schema_exists_sql, targetDialect = "sql server")
  )$N[1] > 0

  if (schema_exists) {
    message("Results schema '", config$results_schema, "' already exists — skipping creation.")
  } else {
    message("Results schema '", config$results_schema, "' not found — attempting to create ...")
    tryCatch(
      DatabaseConnector::executeSql(
        connection,
        paste0("EXEC('CREATE SCHEMA [", config$results_schema, "]')"),
        reportOverallTime = FALSE
      ),
      error = function(e) {
        stop(
          "Could not create results schema '", config$results_schema, "'.\n",
          "Your account may not have CREATE SCHEMA permission.\n",
          "Ask DHTS to create the schema and grant INSERT/SELECT/DROP.\n\n",
          "Original error: ", conditionMessage(e)
        )
      }
    )
  }

  # Switch back to CDM database so subsequent CDM queries work.
  if (use_cross_db) {
    DatabaseConnector::executeSql(
      connection,
      paste0("USE [", config$database, "]"),
      reportOverallTime = FALSE
    )
  }

  # Create cohort table if absent — use fully-qualified prefix so it resolves
  # correctly regardless of current database context.
  cohort_table_sql <- paste0(
    "IF OBJECT_ID('", prefix, ".", config$cohort_table, "', 'U') IS NULL\n",
    "BEGIN\n",
    "  CREATE TABLE ", prefix, ".", config$cohort_table, " (\n",
    "    cohort_definition_id  BIGINT  NOT NULL,\n",
    "    subject_id            BIGINT  NOT NULL,\n",
    "    cohort_start_date     DATE    NOT NULL,\n",
    "    cohort_end_date       DATE    NOT NULL\n",
    "  )\n",
    "END"
  )
  DatabaseConnector::executeSql(connection, cohort_table_sql, reportOverallTime = FALSE)

  message("Results table ready: ", prefix, ".", config$cohort_table)
  invisible(NULL)
}

# Read a cohort SQL file, render parameters, translate to SQL Server dialect,
# and execute it.
instantiate_cohort <- function(connection, sql_file, render_params, label) {
  raw_sql <- readLines(sql_file, warn = FALSE)
  raw_sql <- paste(raw_sql, collapse = "\n")

  rendered  <- do.call(SqlRender::render,  c(list(sql = raw_sql), render_params))
  translated <- SqlRender::translate(rendered, targetDialect = "sql server")

  message("Instantiating cohort: ", label, " ...")
  DatabaseConnector::executeSql(connection, translated, reportOverallTime = FALSE)
  message("Done: ", label)
}

# Copy an already-instantiated cohort from an ATLAS/WebAPI cohort table into
# the local PLP cohort table, remapping the cohort_definition_id.
copy_atlas_cohort <- function(connection,
                              config,
                              source_cohort_id,
                              destination_cohort_id,
                              label) {
  source_check_sql <- SqlRender::render(
    sql = "IF OBJECT_ID('@atlas_schema.@atlas_table', 'U') IS NULL
           RAISERROR('ATLAS cohort table @atlas_schema.@atlas_table was not found.', 16, 1);",
    atlas_schema = config$atlas_cohort_schema,
    atlas_table  = config$atlas_cohort_table
  )
  DatabaseConnector::executeSql(
    connection,
    SqlRender::translate(source_check_sql, targetDialect = "sql server"),
    reportOverallTime = FALSE
  )

  prefix <- results_schema_prefix(config)

  clear_sql <- paste0(
    "DELETE FROM ", prefix, ".", config$cohort_table,
    " WHERE cohort_definition_id = ", destination_cohort_id, ";"
  )
  DatabaseConnector::executeSql(connection, clear_sql, reportOverallTime = FALSE)

  copy_sql <- SqlRender::render(
    sql = paste0(
      "INSERT INTO ", prefix, ".@cohort_table (",
      "  cohort_definition_id, subject_id, cohort_start_date, cohort_end_date",
      ") SELECT @destination_cohort_id, c.subject_id, c.cohort_start_date,",
      "  c.cohort_end_date",
      " FROM @atlas_schema.@atlas_table c",
      " WHERE c.cohort_definition_id = @source_cohort_id",
      "   AND c.cohort_start_date >= CAST('@study_start_date' AS DATE)",
      "   AND c.cohort_start_date <= CAST('@study_end_date'   AS DATE);"
    ),
    cohort_table          = config$cohort_table,
    atlas_schema          = config$atlas_cohort_schema,
    atlas_table           = config$atlas_cohort_table,
    source_cohort_id      = source_cohort_id,
    destination_cohort_id = destination_cohort_id,
    study_start_date      = config$study_start_date,
    study_end_date        = config$study_end_date
  )

  message("Copying cohort from ATLAS table: ", label, " ...")
  DatabaseConnector::executeSql(
    connection,
    SqlRender::translate(copy_sql, targetDialect = "sql server"),
    reportOverallTime = FALSE
  )
  message("Done: ", label)
}

# Count the rows in a cohort to give quick feedback.
count_cohort <- function(connection, config, cohort_id, label) {
  prefix    <- results_schema_prefix(config)
  count_sql <- paste0(
    "SELECT COUNT(*) AS N FROM ", prefix, ".", config$cohort_table,
    " WHERE cohort_definition_id = ", cohort_id
  )
  n <- DatabaseConnector::querySql(connection, count_sql)$N
  message(sprintf("  %-30s  n = %d", label, n))
  n
}

# Main entry point: create schema + table, instantiate both cohorts, print
# counts.
build_cohorts <- function(connection, config) {
  ensure_results_schema(connection, config)

  common_params <- list(
    cdm_database_schema    = config$cdm_schema,
    target_database_schema = results_schema_prefix(config),
    target_cohort_table    = config$cohort_table,
    study_start_date       = config$study_start_date,
    study_end_date         = config$study_end_date
  )

  if (isTRUE(config$use_atlas_cohorts)) {
    copy_atlas_cohort(
      connection            = connection,
      config                = config,
      source_cohort_id      = config$atlas_target_cohort_id,
      destination_cohort_id = config$target_cohort_id,
      label                 = paste0(
        "Target – ATLAS cohort ",
        config$atlas_target_cohort_id,
        " -> destination id ",
        config$target_cohort_id
      )
    )
  } else {
    instantiate_cohort(
      connection    = connection,
      sql_file      = file.path("cohorts", "target_surgery.sql"),
      render_params = c(common_params,
                        list(target_cohort_id = config$target_cohort_id)),
      label         = "Target – Inpatient surgical procedure"
    )
  }

  if (isTRUE(config$use_atlas_cohorts) && !is.na(config$atlas_outcome_cohort_id)) {
    copy_atlas_cohort(
      connection            = connection,
      config                = config,
      source_cohort_id      = config$atlas_outcome_cohort_id,
      destination_cohort_id = config$outcome_cohort_id,
      label                 = paste0(
        "Outcome – ATLAS cohort ",
        config$atlas_outcome_cohort_id,
        " -> destination id ",
        config$outcome_cohort_id
      )
    )
  } else {
    instantiate_cohort(
      connection    = connection,
      sql_file      = file.path("cohorts", "outcome_ssi.sql"),
      render_params = c(common_params,
                        list(outcome_cohort_id = config$outcome_cohort_id)),
      label         = "Outcome – Surgical site infection"
    )
  }

  target_n  <- count_cohort(connection, config, config$target_cohort_id,
                             "Surgery target cohort")
  outcome_n <- count_cohort(connection, config, config$outcome_cohort_id,
                             "SSI outcome cohort")

  if (target_n == 0) {
    warning("Target cohort is EMPTY.  Check that cdm_schema is correct and ",
            "that visit_occurrence / procedure_occurrence are populated.")
  }
  if (outcome_n == 0) {
    warning("Outcome cohort is EMPTY.  Check SSI concept IDs in ",
            "cohorts/outcome_ssi.sql against your cdm_synthea.concept table.")
  }

  invisible(list(target_n = target_n, outcome_n = outcome_n))
}
