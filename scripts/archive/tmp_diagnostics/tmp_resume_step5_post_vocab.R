if (file.exists("renv/activate.R")) source("renv/activate.R")
source("config.R")
source("R/drivers.R")
source("R/connection.R")
cfg <- get_validation_config()
ensure_jdbc_bundle(cfg)
configure_java(cfg)
connDetails <- build_connection_details(cfg)
cdmSchema <- cfg$cdm_schema
syntheaSchema <- "synthea"
cdmVersion <- "5.4"
syntheaVersion <- "3.3.0"
ETLSyntheaBuilder::CreateVisitRollupTables(
  connectionDetails = connDetails,
  cdmSchema = cdmSchema,
  syntheaSchema = syntheaSchema,
  cdmVersion = cdmVersion
)
ETLSyntheaBuilder::CreateMapAndRollupTables(
  connectionDetails = connDetails,
  cdmSchema = cdmSchema,
  syntheaSchema = syntheaSchema,
  cdmVersion = cdmVersion,
  syntheaVersion = syntheaVersion
)
ETLSyntheaBuilder::LoadEventTables(
  connectionDetails = connDetails,
  cdmSchema = cdmSchema,
  syntheaSchema = syntheaSchema,
  cdmVersion = cdmVersion,
  syntheaVersion = syntheaVersion,
  createIndices = FALSE,
  sqlOnly = FALSE
)
suppressWarnings(try(
  ETLSyntheaBuilder::CreateExtraIndices(
    connectionDetails = connDetails,
    cdmSchema = cdmSchema,
    cdmVersion = cdmVersion
  ),
  silent = TRUE
))
cat("STEP5_RESUME_DONE\n")
