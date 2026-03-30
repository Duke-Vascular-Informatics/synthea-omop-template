if (file.exists("renv/activate.R")) source("renv/activate.R")
source("config.R")
source("R/drivers.R")
source("R/connection.R")
cfg <- get_validation_config()
ensure_jdbc_bundle(cfg)
configure_java(cfg)
conn <- DatabaseConnector::connect(build_connection_details(cfg))
on.exit(DatabaseConnector::disconnect(conn), add = TRUE)

schema <- cfg$cdm_schema
tables <- c(
  "location","care_site","person","observation_period","provider",
  "visit_occurrence","visit_detail","condition_occurrence","observation",
  "measurement","procedure_occurrence","drug_exposure","condition_era",
  "drug_era","cdm_source","device_exposure","death","payer_plan_period",
  "cost","all_visits","assign_all_visit_ids","final_visit_ids"
)
for (t in tables) {
  sql <- paste0("IF OBJECT_ID('[", schema, "].[", t, "]','U') IS NOT NULL DROP TABLE [", schema, "].[", t, "];")
  DatabaseConnector::executeSql(conn, sql)
}
cat("MANUAL_EVENT_DROP_DONE\n")
