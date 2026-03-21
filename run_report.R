# run_report.R
# Entry point: generates the Word-format validation report.
#
# Usage:
#   setwd("C:/path/to/pad-oler-ssi-val")
#   source("run_report.R")

source("R/report.R")

generate_word_report(output_dir = "output/risk_score_eval")
