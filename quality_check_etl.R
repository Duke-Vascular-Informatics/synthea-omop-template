# =============================================================================
# quality_check_etl.R
#
# Run post-load quality checks after the Synthea CSV -> OMOP ETL.
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

parse_args <- function(args) {
  opts <- list(
    run_name = "",
    enforce_thresholds = FALSE,
    min_person_rows = 1,
    min_open_revascularization_rows = 1,
    min_ssi_condition_rows = 1,
    min_mapped_condition_pct = 0
  )

  parse_bool <- function(x) {
    tolower(trimws(as.character(x))) %in% c("1", "true", "t", "yes", "y")
  }

  for (arg in args) {
    if (grepl("^--", arg)) {
      m <- regmatches(arg, regexec("^--([^=]+)=(.*)$", arg))[[1]]
      if (length(m) == 3) {
        key <- m[2]
        val <- m[3]
        if (identical(key, "run_name")) opts$run_name <- val
        if (identical(key, "enforce_thresholds")) opts$enforce_thresholds <- parse_bool(val)
        if (identical(key, "min_person_rows")) opts$min_person_rows <- as.numeric(val)
        if (identical(key, "min_open_revascularization_rows")) opts$min_open_revascularization_rows <- as.numeric(val)
        if (identical(key, "min_ssi_condition_rows")) opts$min_ssi_condition_rows <- as.numeric(val)
        if (identical(key, "min_mapped_condition_pct")) opts$min_mapped_condition_pct <- as.numeric(val)
      }
    } else if (!nzchar(opts$run_name)) {
      opts$run_name <- arg
    }
  }

  if (!nzchar(opts$run_name)) {
    opts$run_name <- paste0("padssi-csv-", format(Sys.Date(), "%Y%m%d"))
  }

  opts
}

args <- commandArgs(trailingOnly = TRUE)
opts <- parse_args(args)
run_name <- opts$run_name

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
  SELECT source_schema, COUNT(*) AS row_count
  FROM (
    SELECT 'patients_stage'   AS source_schema FROM @staging_schema.patients_stage   WHERE run_name = '@run_name'
    UNION ALL
    SELECT 'encounters_stage'  AS source_schema FROM @staging_schema.encounters_stage  WHERE run_name = '@run_name'
    UNION ALL
    SELECT 'procedures_stage'  AS source_schema FROM @staging_schema.procedures_stage  WHERE run_name = '@run_name'
    UNION ALL
    SELECT 'conditions_stage'  AS source_schema FROM @staging_schema.conditions_stage  WHERE run_name = '@run_name'
  ) t
  GROUP BY source_schema
  ORDER BY source_schema;
  ",
  staging_schema = "synthea_csv_stage",
  run_name = run_name
), targetDialect = config$dbms)

resource_counts <- run_query(resource_sql)
cat("Staging table counts\n")
print(resource_counts)
cat("\n")

summary_sql <- SqlRender::translate(SqlRender::render(
  "
  SELECT
    (
      (SELECT COUNT(*) FROM @staging_schema.patients_stage   WHERE run_name = '@run_name') +
      (SELECT COUNT(*) FROM @staging_schema.encounters_stage WHERE run_name = '@run_name') +
      (SELECT COUNT(*) FROM @staging_schema.procedures_stage WHERE run_name = '@run_name') +
      (SELECT COUNT(*) FROM @staging_schema.conditions_stage WHERE run_name = '@run_name')
    ) AS staged_rows,
    (
      SELECT SUM(CASE WHEN row_count > 0 THEN 1 ELSE 0 END)
      FROM (
        SELECT COUNT(*) AS row_count FROM @staging_schema.patients_stage   WHERE run_name = '@run_name'
        UNION ALL
        SELECT COUNT(*) AS row_count FROM @staging_schema.encounters_stage WHERE run_name = '@run_name'
        UNION ALL
        SELECT COUNT(*) AS row_count FROM @staging_schema.procedures_stage WHERE run_name = '@run_name'
        UNION ALL
        SELECT COUNT(*) AS row_count FROM @staging_schema.conditions_stage WHERE run_name = '@run_name'
      ) stage_counts
    ) AS staged_tables_with_rows,
    (SELECT COUNT(*) FROM @cdm_schema.person WHERE person_source_value LIKE 'synthea_csv:%') AS person_rows,
    (SELECT COUNT(*) FROM @cdm_schema.visit_occurrence WHERE visit_source_value LIKE 'synthea_csv:%') AS visit_rows,
    (SELECT COUNT(*) FROM @cdm_schema.procedure_occurrence po WHERE po.person_id IN (
       SELECT p.person_id FROM @cdm_schema.person p WHERE p.person_source_value LIKE 'synthea_csv:%'
     )) AS procedure_rows,
    (SELECT COUNT(*) FROM @cdm_schema.procedure_occurrence po WHERE po.person_id IN (
       SELECT p.person_id FROM @cdm_schema.person p WHERE p.person_source_value LIKE 'synthea_csv:%'
     ) AND po.procedure_source_value = '232723009') AS open_revascularization_rows,
    (SELECT COUNT(*) FROM @cdm_schema.condition_occurrence co WHERE co.person_id IN (
       SELECT p.person_id FROM @cdm_schema.person p WHERE p.person_source_value LIKE 'synthea_csv:%'
     )) AS condition_rows,
    (SELECT COUNT(*) FROM @cdm_schema.condition_occurrence co WHERE co.person_id IN (
       SELECT p.person_id FROM @cdm_schema.person p WHERE p.person_source_value LIKE 'synthea_csv:%'
     ) AND co.condition_concept_id > 0) AS mapped_condition_rows,
    (SELECT COUNT(*) FROM @cdm_schema.condition_occurrence co WHERE co.person_id IN (
       SELECT p.person_id FROM @cdm_schema.person p WHERE p.person_source_value LIKE 'synthea_csv:%'
     ) AND co.condition_source_value = '399957001') AS pad_condition_rows,
    (SELECT COUNT(*) FROM @cdm_schema.condition_occurrence co WHERE co.person_id IN (
       SELECT p.person_id FROM @cdm_schema.person p WHERE p.person_source_value LIKE 'synthea_csv:%'
     ) AND co.condition_source_value = '76844004') AS ssi_condition_rows;
  ",
  staging_schema = "synthea_csv_stage",
  cdm_schema = config$cdm_schema,
  run_name = run_name
), targetDialect = config$dbms)

summary_df <- run_query(summary_sql)
cat("OMOP summary\n")
print(summary_df)
cat("\n")

value_from_summary <- function(df, candidates) {
  nm <- names(df)
  hit <- candidates[candidates %in% nm]
  if (length(hit) == 0) return(NA_real_)
  as.numeric(df[[hit[1]]][1])
}

person_rows <- value_from_summary(summary_df, c("personRows", "person_rows"))
open_revasc_rows <- value_from_summary(summary_df, c("openRevascularizationRows", "open_revascularization_rows"))
ssi_rows <- value_from_summary(summary_df, c("ssiConditionRows", "ssi_condition_rows"))
condition_rows <- value_from_summary(summary_df, c("conditionRows", "condition_rows"))
mapped_condition_rows <- value_from_summary(summary_df, c("mappedConditionRows", "mapped_condition_rows"))

mapped_pct <- if (!is.na(condition_rows) && condition_rows > 0) {
  100 * mapped_condition_rows / condition_rows
} else {
  NA_real_
}

cat("Mapping quality\n")
cat("Mapped condition percentage: ", round(mapped_pct, 2), "%\n\n", sep = "")

age_sql <- SqlRender::translate(SqlRender::render(
  "
  SELECT
    COUNT(*) AS n_people,
    SUM(CASE WHEN year_of_birth >= YEAR(GETDATE()) - 18 THEN 1 ELSE 0 END) AS age_under_18_count,
    MIN(year_of_birth) AS min_year_of_birth,
    MAX(year_of_birth) AS max_year_of_birth
  FROM @cdm_schema.person
  WHERE person_source_value LIKE 'synthea_csv:%';
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
  WHERE p.person_source_value LIKE 'synthea_csv:%'
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

if (isTRUE(opts$enforce_thresholds)) {
  failures <- character()

  if (is.na(person_rows) || person_rows < opts$min_person_rows) {
    failures <- c(failures, paste0("person_rows < min_person_rows (", person_rows, " < ", opts$min_person_rows, ")"))
  }
  if (is.na(open_revasc_rows) || open_revasc_rows < opts$min_open_revascularization_rows) {
    failures <- c(failures, paste0("open_revascularization_rows < min_open_revascularization_rows (", open_revasc_rows, " < ", opts$min_open_revascularization_rows, ")"))
  }
  if (is.na(ssi_rows) || ssi_rows < opts$min_ssi_condition_rows) {
    failures <- c(failures, paste0("ssi_condition_rows < min_ssi_condition_rows (", ssi_rows, " < ", opts$min_ssi_condition_rows, ")"))
  }
  if (is.na(mapped_pct) || mapped_pct < opts$min_mapped_condition_pct) {
    failures <- c(failures, paste0("mapped_condition_pct < min_mapped_condition_pct (", round(mapped_pct, 2), " < ", opts$min_mapped_condition_pct, ")"))
  }

  if (length(failures) > 0) {
    stop("Quality check threshold failures: ", paste(failures, collapse = "; "))
  }

  cat("Threshold gate\n")
  cat("All enforced thresholds passed.\n\n")
}

cat("=== QUALITY CHECK COMPLETE ===\n")
