if (file.exists("renv/activate.R")) source("renv/activate.R")
source("config.R")
source("R/drivers.R")
source("R/connection.R")
cfg <- get_validation_config()
ensure_jdbc_bundle(cfg)
configure_java(cfg)
connDetails <- build_connection_details(cfg)
out <- ETLSyntheaBuilder::CreateVisitRollupTables(
  connectionDetails = connDetails,
  cdmSchema = cfg$cdm_schema,
  syntheaSchema = "synthea",
  cdmVersion = "5.4",
  sqlOnly = TRUE
)
cat("TYPE=", class(out), "\n", sep="")
if (is.character(out)) {
  cat(substr(out, 1, 1200))
}
