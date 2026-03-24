# run_report.R
# Entry point: generates the manuscript-style Word validation report.
#
# This script generates a Word document with manuscript-style Methods and Results,
# including titled tables and captioned figures.
#
# Prerequisites:
#   - run_risk_score_pipeline.R must have been run first to generate the
#     person-level scores, component summary, metrics, and calibration plots
#
# Usage:
#   setwd("C:/path/to/pad-oler-ssi-val")
#   source("run_report.R")
#
# Optional cleanup:
#   Set cleanup_old_outputs <- TRUE to remove legacy report/image artifacts
#   while preserving iterative reports named like:
#   <folder>_report_<YYYYMMDD>[_N].docx

# Load the extended report generation function
source("R/report_extended.R")

# Set TRUE to clean legacy artifacts before writing a new report.
cleanup_old_outputs <- FALSE

# Generate the manuscript-style Word report.
output_path <- generate_manuscript_report(
  output_dir = "output/risk_score_eval",
  score_output_dir = "output/risk_score_eval",
  cleanup_old_outputs = cleanup_old_outputs
)

message("✓ Manuscript-style report generation complete!")
message("Output file: ", output_path)

# Optional: Open the report in the default Word application
# Uncomment the line below if you want to automatically open the document
# system(paste("start", shQuote(output_path)))
