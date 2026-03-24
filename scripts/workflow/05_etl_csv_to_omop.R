#!/usr/bin/env Rscript
# Step 5: ETL Synthea CSV output to OMOP.

args <- commandArgs(trailingOnly = TRUE)
csv_input_dir <- if (length(args) >= 1 && nzchar(args[[1]])) args[[1]] else "C:/Users/rapiduser/source/repos/synthea/output/csv"
run_name <- if (length(args) >= 2 && nzchar(args[[2]])) args[[2]] else paste0("padssi-csv-", format(Sys.time(), "%Y%m%d-%H%M%S"))

source("renv/activate.R")
source("scripts/run_synthea_csv_to_omop_etl.R")

run_synthea_csv_to_omop_etl(
  csv_input_dir = csv_input_dir,
  run_name = run_name
)

cat("Step 5 complete: CSV ETL loaded to OMOP. run_name=", run_name, "\n", sep = "")
