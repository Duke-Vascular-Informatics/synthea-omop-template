source("config.R")
source("R/drivers.R")
source("R/connection.R")

cfg <- get_validation_config()
ensure_jdbc_bundle(cfg)

conn <- connect_with_retry(build_connection_details(cfg), max_attempts = 1L)
on.exit(DatabaseConnector::disconnect(conn), add = TRUE)

DatabaseConnector::executeSql(
  conn,
  "IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = 'omop_synth_pad_oler_ssi')\n   EXEC('CREATE SCHEMA [omop_synth_pad_oler_ssi]');"
)

cat("SCHEMA_READY\n")
