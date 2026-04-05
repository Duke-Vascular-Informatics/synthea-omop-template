if (file.exists("renv/activate.R")) source("renv/activate.R")
source("config.R")
source("R/drivers.R")
source("R/connection.R")
cfg <- get_validation_config()
ensure_jdbc_bundle(cfg)
configure_java(cfg)
connDetails <- build_connection_details(cfg)
ETLSyntheaBuilder::DropEventTables(
  connectionDetails = connDetails,
  cdmSchema = cfg$cdm_schema
)
cat("DROP_EVENT_TABLES_DONE\n")
