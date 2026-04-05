if (file.exists("renv/activate.R")) source("renv/activate.R")
source("config.R")
source("R/drivers.R")
source("R/connection.R")
cfg <- get_validation_config()
ensure_jdbc_bundle(cfg)
configure_java(cfg)
conn <- DatabaseConnector::connect(build_connection_details(cfg))
on.exit(DatabaseConnector::disconnect(conn), add = TRUE)

run_sql_file <- function(path) {
  message("Running file: ", path)
  sql <- paste(readLines(path, warn = FALSE), collapse = "\n")
  DatabaseConnector::executeSql(conn, sql)
}

# Rebuild map tables (idempotent in generated scripts)
run_sql_file("output/create_source_to_standard_vocab_map.sql")
run_sql_file("output/create_source_to_source_vocab_map.sql")
run_sql_file("output/create_states_map.sql")

# Visit rollup SQL (SQL Server compatible)
run_sql_file("output/AllVisitTable.sql")
run_sql_file("output/AAVITable.sql")
DatabaseConnector::executeSql(conn, "
if object_id('cdm_synthea.FINAL_VISIT_IDS', 'U') is not null drop table cdm_synthea.FINAL_VISIT_IDS;
SELECT encounter_id, VISIT_OCCURRENCE_ID_NEW
INTO cdm_synthea.FINAL_VISIT_IDS
FROM (
  SELECT *, ROW_NUMBER() OVER (PARTITION BY encounter_id ORDER BY PRIORITY) AS RN
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
    FROM cdm_synthea.ASSIGN_ALL_VISIT_IDS
  ) T1
) RankedVisits
WHERE RN = 1;
")

# Event load SQL scripts
event_files <- c(
  "output/insert_location.sql",
  "output/insert_care_site.sql",
  "output/insert_person.sql",
  "output/insert_observation_period.sql",
  "output/insert_provider.sql",
  "output/insert_visit_occurrence.sql",
  "output/insert_visit_detail.sql",
  "output/insert_condition_occurrence.sql",
  "output/insert_observation.sql",
  "output/insert_measurement.sql",
  "output/insert_procedure_occurrence.sql",
  "output/insert_drug_exposure.sql",
  "output/insert_condition_era.sql",
  "output/insert_drug_era.sql",
  "output/insert_cdm_source.sql",
  "output/insert_device_exposure.sql",
  "output/insert_death.sql",
  "output/insert_payer_plan_period.sql",
  "output/insert_cost_v300.sql"
)
for (f in event_files) run_sql_file(f)

suppressWarnings(try(
  ETLSyntheaBuilder::CreateExtraIndices(
    connectionDetails = build_connection_details(cfg),
    cdmSchema = cfg$cdm_schema,
    cdmVersion = "5.4"
  ),
  silent = TRUE
))

cat("STEP5_MANUAL_RESUME_DONE\n")
