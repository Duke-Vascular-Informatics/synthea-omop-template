setwd("C:/Users/rapiduser/pad-oler-ssi-val")
source("renv/activate.R")
source("config.R")
source("R/drivers.R")
source("R/connection.R")
configure_java(get_validation_config())
library(DatabaseConnector)
library(SqlRender)
config <- get_validation_config()
conn <- DatabaseConnector::connect(build_connection_details(config))
on.exit(DatabaseConnector::disconnect(conn))

cat("--- Visit concept IDs (top 10) ---\n")
print(DatabaseConnector::querySql(conn, SqlRender::translate(
  SqlRender::render(
    "SELECT TOP 10 visit_concept_id, COUNT(*) AS N FROM @cdm.visit_occurrence GROUP BY visit_concept_id ORDER BY N DESC",
    cdm = config$cdm_schema),
  targetDialect = "sql server")))

cat("\n--- Concept names for 9201, 262 ---\n")
print(DatabaseConnector::querySql(conn, SqlRender::translate(
  SqlRender::render(
    "SELECT concept_id, concept_name FROM @cdm.concept WHERE concept_id IN (9201, 262)",
    cdm = config$cdm_schema),
  targetDialect = "sql server")))

cat("\n--- Procedure count ---\n")
print(DatabaseConnector::querySql(conn, SqlRender::translate(
  SqlRender::render("SELECT COUNT(*) AS N FROM @cdm.procedure_occurrence", cdm = config$cdm_schema),
  targetDialect = "sql server")))

cat("\n--- Visit count in study window ---\n")
print(DatabaseConnector::querySql(conn, SqlRender::translate(
  SqlRender::render(
    "SELECT COUNT(*) AS N FROM @cdm.visit_occurrence WHERE visit_concept_id IN (9201, 262) AND visit_start_date >= '2010-01-01' AND visit_start_date <= '2023-12-31'",

    message("--- Visit date range ---")
    print(DatabaseConnector::querySql(conn, SqlRender::translate(
      SqlRender::render(
        "SELECT MIN(visit_start_date) AS min_date, MAX(visit_start_date) AS max_date FROM @cdm.visit_occurrence WHERE visit_concept_id IN (9201, 262)",
        cdm = config$cdm_schema),
      targetDialect = "sql server")))
    cdm = config$cdm_schema),
  targetDialect = "sql server")))
