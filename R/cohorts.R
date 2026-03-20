# =============================================================================
# R/cohorts.R
# Create the results schema / cohort table and instantiate the target (surgery)
# and outcome (SSI) cohorts using parameterised OHDSI SQL executed via
# SqlRender and DatabaseConnector.
# =============================================================================

# Ensure the results schema and the cohort table both exist.
ensure_results_schema <- function(connection, config) {
  # Create schema if absent (SQL Server CREATE SCHEMA must run in its own batch)
  schema_sql <- SqlRender::render(
    sql = "IF NOT EXISTS (
      SELECT 1 FROM sys.schemas WHERE name = '@results_schema'
    )
    BEGIN
      EXEC('CREATE SCHEMA [@results_schema]')
    END",
    results_schema = config$results_schema
  )
  DatabaseConnector::executeSql(connection,
                                SqlRender::translate(schema_sql, targetDialect = "sql server"),
                                reportOverallTime = FALSE)

  # Create cohort table if absent
  cohort_table_sql <- SqlRender::render(
    sql = "IF OBJECT_ID('@results_schema.@cohort_table', 'U') IS NULL
    BEGIN
      CREATE TABLE @results_schema.@cohort_table (
        cohort_definition_id  BIGINT       NOT NULL,
        subject_id            BIGINT       NOT NULL,
        cohort_start_date     DATE         NOT NULL,
        cohort_end_date       DATE         NOT NULL
      )
    END",
    results_schema = config$results_schema,
    cohort_table   = config$cohort_table
  )
  DatabaseConnector::executeSql(connection,
                                SqlRender::translate(cohort_table_sql, targetDialect = "sql server"),
                                reportOverallTime = FALSE)

  message("Results schema and cohort table are ready: ",
          config$results_schema, ".", config$cohort_table)
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

# Count the rows in a cohort to give quick feedback.
count_cohort <- function(connection, config, cohort_id, label) {
  count_sql <- SqlRender::render(
    sql = "SELECT COUNT(*) AS n
           FROM @results_schema.@cohort_table
           WHERE cohort_definition_id = @cohort_id",
    results_schema = config$results_schema,
    cohort_table   = config$cohort_table,
    cohort_id      = cohort_id
  )
  n <- DatabaseConnector::querySql(
         connection,
         SqlRender::translate(count_sql, targetDialect = "sql server")
       )$N
  message(sprintf("  %-30s  n = %d", label, n))
  n
}

# Main entry point: create schema + table, instantiate both cohorts, print
# counts.
build_cohorts <- function(connection, config) {
  ensure_results_schema(connection, config)

  common_params <- list(
    cdm_database_schema    = config$cdm_schema,
    target_database_schema = config$results_schema,
    target_cohort_table    = config$cohort_table,
    study_start_date       = config$study_start_date,
    study_end_date         = config$study_end_date
  )

  instantiate_cohort(
    connection   = connection,
    sql_file     = file.path("cohorts", "target_surgery.sql"),
    render_params = c(common_params,
                      list(target_cohort_id = config$target_cohort_id)),
    label        = "Target – Inpatient surgical procedure"
  )

  instantiate_cohort(
    connection   = connection,
    sql_file     = file.path("cohorts", "outcome_ssi.sql"),
    render_params = c(common_params,
                      list(outcome_cohort_id = config$outcome_cohort_id)),
    label        = "Outcome – Surgical site infection"
  )

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
