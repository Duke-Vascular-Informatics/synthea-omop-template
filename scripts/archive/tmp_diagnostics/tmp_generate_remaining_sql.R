if (file.exists("renv/activate.R")) source("renv/activate.R")
source("config.R")
source("R/drivers.R")
source("R/connection.R")
cfg <- get_validation_config()
ensure_jdbc_bundle(cfg)
configure_java(cfg)
connDetails <- build_connection_details(cfg)
ETLSyntheaBuilder::CreateMapAndRollupTables(
  connectionDetails = connDetails,
  cdmSchema = cfg$cdm_schema,
  syntheaSchema = "synthea",
  cdmVersion = "5.4",
  syntheaVersion = "3.3.0",
  sqlOnly = TRUE
)
ETLSyntheaBuilder::LoadEventTables(
  connectionDetails = connDetails,
  cdmSchema = cfg$cdm_schema,
  syntheaSchema = "synthea",
  cdmVersion = "5.4",
  syntheaVersion = "3.3.0",
  createIndices = FALSE,
  sqlOnly = TRUE
)
cat("SQL_ONLY_GENERATED\n")
