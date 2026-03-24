# =============================================================================
# quality_check_etl.R
#
# Run post-load quality checks for a FHIR -> OMOP ETL run.
# =============================================================================

local({
  java_home <- "C:/Program Files/Eclipse Adoptium/jdk-17.0.18.8-hotspot"
  jdbc_auth_dir <- file.path(getwd(), "drivers", "sqljdbc_13.2", "enu", "auth", "x64")
  jdbc_rt_dir <- file.path(getwd(), "drivers", "jdbc-runtime")

  Sys.setenv(JAVA_HOME = java_home)
  Sys.setenv(PATH = paste(
    normalizePath(file.path(java_home, "bin"), winslash = "\\", mustWork = FALSE),
    normalizePath(jdbc_auth_dir, winslash = "\\", mustWork = FALSE),
    Sys.getenv("PATH"),
    sep = .Platform$path.sep
  ))
  options(java.parameters = paste0(
    "-Djava.library.path=",
    normalizePath(jdbc_auth_dir, winslash = "/", mustWork = FALSE)
  ))
  Sys.setenv(DATABASECONNECTOR_JAR_FOLDER = jdbc_rt_dir)
})

source("renv/activate.R")
source("config.R")
source("R/drivers.R")
source("R/connection.R")

args <- commandArgs(trailingOnly = TRUE)
run_name <- if (length(args) >= 1 && nzchar(args[[1]])) {
  args[[1]]
} else {
  "padssi-n1000-modv04-20260322"
}

config <- get_validation_config()
conn <- DatabaseConnector::connect(build_connection_details(config))
on.exit(DatabaseConnector::disconnect(conn), add = TRUE)

run_query <- function(sql) {
  DatabaseConnector::querySql(conn, sql, snakeCaseToCamelCase = TRUE)
}

cat("=== ETL QUALITY CHECK ===\n")
cat("Run name:", run_name, "\n\n")

resource_sql <- SqlRender::translate(SqlRender::render(
  "
  SELECT resource_type, COUNT(*) AS row_count
  FROM @staging_schema.fhir_raw_resource
  WHERE run_name = '@run_name'
  GROUP BY resource_type
  ORDER BY resource_type;
  ",
  staging_schema = "fhir_stage",
  run_name = run_name
), targetDialect = config$dbms)

resource_counts <- run_query(resource_sql)
cat("Staging resource counts\n")
print(resource_counts)
cat("\n")

summary_sql <- SqlRender::translate(SqlRender::render(
  "
  SELECT
    (SELECT COUNT(*) FROM @staging_schema.fhir_raw_resource WHERE run_name = '@run_name') AS staged_rows,
    (SELECT COUNT(DISTINCT source_file) FROM @staging_schema.fhir_raw_resource WHERE run_name = '@run_name') AS staged_files,
    (SELECT COUNT(*) FROM @cdm_schema.person WHERE person_source_value LIKE 'fhir:%') AS person_rows,
    (SELECT COUNT(*) FROM @cdm_schema.visit_occurrence WHERE visit_source_value LIKE 'fhir:%') AS visit_rows,
    (SELECT COUNT(*) FROM @cdm_schema.procedure_occurrence po WHERE po.person_id IN (
       SELECT p.person_id FROM @cdm_schema.person p WHERE p.person_source_value LIKE 'fhir:%'
     )) AS procedure_rows,
    (SELECT COUNT(*) FROM @cdm_schema.procedure_occurrence po WHERE po.person_id IN (
       SELECT p.person_id FROM @cdm_schema.person p WHERE p.person_source_value LIKE 'fhir:%'
     ) AND po.procedure_source_value = '232723009') AS open_revascularization_rows,
    (SELECT COUNT(*) FROM @cdm_schema.condition_occurrence co WHERE co.person_id IN (
       SELECT p.person_id FROM @cdm_schema.person p WHERE p.person_source_value LIKE 'fhir:%'
     )) AS condition_rows,
    (SELECT COUNT(*) FROM @cdm_schema.condition_occurrence co WHERE co.person_id IN (
       SELECT p.person_id FROM @cdm_schema.person p WHERE p.person_source_value LIKE 'fhir:%'
     ) AND co.condition_concept_id > 0) AS mapped_condition_rows,
    (SELECT COUNT(*) FROM @cdm_schema.condition_occurrence co WHERE co.person_id IN (
       SELECT p.person_id FROM @cdm_schema.person p WHERE p.person_source_value LIKE 'fhir:%'
     ) AND co.condition_source_value = '399957001') AS pad_condition_rows,
    (SELECT COUNT(*) FROM @cdm_schema.condition_occurrence co WHERE co.person_id IN (
       SELECT p.person_id FROM @cdm_schema.person p WHERE p.person_source_value LIKE 'fhir:%'
     ) AND co.condition_source_value = '76844004') AS ssi_condition_rows;
  ",
  staging_schema = "fhir_stage",
  cdm_schema = config$cdm_schema,
  run_name = run_name
), targetDialect = config$dbms)

summary_df <- run_query(summary_sql)
cat("OMOP summary\n")
print(summary_df)
cat("\n")

age_sql <- SqlRender::translate(SqlRender::render(
  "
  SELECT
    COUNT(*) AS n_people,
    SUM(CASE WHEN year_of_birth >= YEAR(GETDATE()) - 18 THEN 1 ELSE 0 END) AS age_under_18_count,
    MIN(year_of_birth) AS min_year_of_birth,
    MAX(year_of_birth) AS max_year_of_birth
  FROM @cdm_schema.person
  WHERE person_source_value LIKE 'fhir:%';
  ",
  cdm_schema = config$cdm_schema
), targetDialect = config$dbms)

age_df <- run_query(age_sql)
cat("Age distribution check\n")
print(age_df)
cat("\n")

ssi_person_sql <- SqlRender::translate(SqlRender::render(
  "
  SELECT
    COUNT(DISTINCT CASE WHEN po.procedure_source_value = '232723009' THEN p.person_id END) AS people_with_open_revascularization,
    COUNT(DISTINCT CASE WHEN co.condition_source_value = '399957001' THEN p.person_id END) AS people_with_pad,
    COUNT(DISTINCT CASE WHEN co.condition_source_value = '76844004' THEN p.person_id END) AS people_with_ssi
  FROM @cdm_schema.person p
  LEFT JOIN @cdm_schema.procedure_occurrence po
    ON po.person_id = p.person_id
  LEFT JOIN @cdm_schema.condition_occurrence co
    ON co.person_id = p.person_id
  WHERE p.person_source_value LIKE 'fhir:%'
    AND (
      po.procedure_source_value = '232723009'
      OR co.condition_source_value IN ('399957001', '76844004')
    );
  ",
  cdm_schema = config$cdm_schema
), targetDialect = config$dbms)

signal_df <- run_query(ssi_person_sql)
cat("Clinical signal check\n")
print(signal_df)
cat("\n")

cat("=== QUALITY CHECK COMPLETE ===\n")