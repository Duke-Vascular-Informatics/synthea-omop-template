#!/usr/bin/env Rscript
# =============================================================================
# scripts/new_study.R
# Initialize a fresh study_params.yaml for a new study.
#
# Usage (from project root):
#   Rscript scripts/new_study.R <study_name>
#
# Creates study_params.yaml pre-filled with the study name, or prints the
# command to copy the template if study_params.yaml already exists.
# =============================================================================

args <- commandArgs(trailingOnly = TRUE)
if (length(args) < 1L) {
  cat("Usage: Rscript scripts/new_study.R <study_name>\n")
  cat("  study_name: lowercase, underscores only (e.g. hip_replace_vte)\n")
  quit(status = 1L)
}

study_name <- args[1L]
if (!grepl("^[a-z][a-z0-9_]*$", study_name)) {
  stop("study_name must be lowercase letters, numbers, and underscores only (e.g. hip_replace_vte)")
}

dest <- file.path(getwd(), "study_params.yaml")
if (file.exists(dest)) {
  stop(
    "study_params.yaml already exists.\n",
    "  To start over: delete it and re-run this script.\n",
    "  To keep the current study: edit study_params.yaml directly."
  )
}

template <- file.path(getwd(), "study_params.yaml.example")
if (!file.exists(template)) {
  stop("study_params.yaml.example not found. Run from the project root directory.")
}

lines <- readLines(template, warn = FALSE)

# Pre-fill study_name and output_folder with the supplied value.
lines <- gsub('"my_study"',    paste0('"', study_name, '"'), lines, fixed = TRUE)
lines <- gsub('"output/my_study"', paste0('"output/', study_name, '"'), lines, fixed = TRUE)

writeLines(lines, dest)

message("Created study_params.yaml for study: ", study_name)
message("")
message("Next steps:")
message("  1. Edit study_params.yaml — fill in every TODO item")
message("  2. Rscript scripts/find_todos.R            — check remaining placeholders")
message("  3. Rscript workflow/02_define_omop_cohort_outcome_covariates.R  — validate")
message("  4. Edit covariates/covariates.csv and covariates/covariate_concepts.csv")
message("  5. Rscript workflow/08_run_analysis_and_manuscript_report.R")
