if (file.exists("renv/activate.R")) source("renv/activate.R")
source("config.R")
source("R/drivers.R")
source("R/connection.R")
cfg <- get_validation_config()
ensure_jdbc_bundle(cfg)
configure_java(cfg)
connDetails <- build_connection_details(cfg)
conn <- DatabaseConnector::connect(connDetails)
on.exit(DatabaseConnector::disconnect(conn), add = TRUE)

run_sql_file <- function(path) {
  sql <- paste(readLines(path, warn = FALSE), collapse = "\n")
  DatabaseConnector::executeSql(conn, sql)
}

run_sql_file("output/AllVisitTable.sql")
run_sql_file("output/AAVITable.sql")

final_sql <- "
if object_id('cdm_synthea.FINAL_VISIT_IDS', 'U') is not null drop table cdm_synthea.FINAL_VISIT_IDS;

SELECT encounter_id, VISIT_OCCURRENCE_ID_NEW
INTO cdm_synthea.FINAL_VISIT_IDS
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
      FROM cdm_synthea.ASSIGN_ALL_VISIT_IDS
  ) T1
) RankedVisits
WHERE RN = 1;
"
DatabaseConnector::executeSql(conn, final_sql)

ETLSyntheaBuilder::CreateMapAndRollupTables(
  connectionDetails = connDetails,
  cdmSchema = cfg$cdm_schema,
  syntheaSchema = "synthea",
  cdmVersion = "5.4",
  syntheaVersion = "3.3.0"
)
ETLSyntheaBuilder::LoadEventTables(
  connectionDetails = connDetails,
  cdmSchema = cfg$cdm_schema,
  syntheaSchema = "synthea",
  cdmVersion = "5.4",
  syntheaVersion = "3.3.0",
  createIndices = FALSE,
  sqlOnly = FALSE
)
suppressWarnings(try(
  ETLSyntheaBuilder::CreateExtraIndices(
    connectionDetails = connDetails,
    cdmSchema = cfg$cdm_schema,
    cdmVersion = "5.4"
  ),
  silent = TRUE
))
cat("STEP5_RESUME_DONE\n")
