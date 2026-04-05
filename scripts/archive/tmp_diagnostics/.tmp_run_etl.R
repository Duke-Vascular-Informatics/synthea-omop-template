setwd("c:/Users/rapiduser/pad-oler-ssi-val")
source("renv/activate.R")
if (requireNamespace("renv", quietly = TRUE)) renv::load(project = getwd())
source("config.R")
source("R/drivers.R")
source("R/connection.R")
source("scripts/etl/run_synthea_full_csv_builder_etl.R")

run_synthea_full_csv_builder_etl(
  csv_input_dir = "C:/Users/rapiduser/synthea-data/output/csv",
  run_name = paste0("padssi-csv-", format(Sys.time(), "%Y%m%d-%H%M%S")),
  reset_before_etl = TRUE,
  synthea_bulk_load = TRUE,
  create_extra_indices = TRUE
)
