# run_report.R
# Entry point: generates the Word-format validation report.
#
# This script generates a comprehensive Word document report including:
# - Table 1: Risk score components and OMOP mappings
# - Table 2: Component prevalence in the validation cohort
# - Table 3: Discrimination and calibration metrics
# - ROC curve
# - Calibration plots (lookup-based and recalibrated)
# - Expected calibration error (ECE) summary
#
# Prerequisites:
#   - run_risk_score_pipeline.R must have been run first to generate the
#     person-level scores, component summary, and metrics files
#
# Usage:
#   setwd("C:/path/to/pad-oler-ssi-val")
#   source("run_report.R")

# Load the extended report generation function
source("R/report_extended.R")

# Generate the Word report
# The function will automatically load pipeline outputs from output/risk_score_eval
output_path <- generate_word_report(
  output_dir = "output/risk_score_eval",
  score_output_dir = "output/risk_score_eval"
)

message("✓ Report generation complete!")
message("Output file: ", output_path)

# Optional: Open the report in the default Word application
# Uncomment the line below if you want to automatically open the document
# system(paste("start", shQuote(output_path)))
