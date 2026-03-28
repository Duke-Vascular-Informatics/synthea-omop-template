#!/usr/bin/env Rscript
# Step 2: Define cohort, outcome, and covariates by OMOP concepts.
# This step validates required definition artifacts, loads the definition
# variables used downstream, and prints a compact manifest.

# -----------------------------------------------------------------------------
# Chunk 1 - Workflow bootstrap
# Purpose:
# 1) Resolve the path to workflow_bootstrap.R whether this file is launched from
#    the repo root or from any other working directory.
# 2) Set the working directory to the project root so all relative paths in
#    this script resolve consistently.
# Why this matters:
# Later workflow steps and helper scripts rely on project-relative paths.
# -----------------------------------------------------------------------------
bootstrap_path <- local({
  file_arg <- grep("^--file=", commandArgs(trailingOnly = FALSE), value = TRUE)
  if (length(file_arg) > 0) {
    normalizePath(
      file.path(dirname(sub("^--file=", "", file_arg[1])), "workflow_bootstrap.R"),
      winslash = "/",
      mustWork = FALSE
    )
  } else {
    "workflow/workflow_bootstrap.R"
  }
})
source(bootstrap_path)
set_workflow_root()

# -----------------------------------------------------------------------------
# Chunk 2 - Declare source artifact paths
# Purpose:
# Define canonical file locations for target cohort SQL, outcome SQL, and
# covariate definition CSVs. These variables are the concrete definitions that
# describe the study phenotype inputs for subsequent steps.
# -----------------------------------------------------------------------------
target_cohort_sql_path <- "cohorts/target_surgery.sql"
outcome_cohort_sql_path <- "cohorts/outcome_ssi.sql"
covariate_components_csv_path <- "risk_score/components.csv"
covariate_concepts_csv_path <- "risk_score/component_concepts.csv"

artifacts <- c(
  target_cohort_sql_path,
  outcome_cohort_sql_path,
  covariate_components_csv_path,
  covariate_concepts_csv_path
)

# -----------------------------------------------------------------------------
# Chunk 3 - File existence validation
# Purpose:
# Fail fast if any required phenotype artifact is missing. Without all four
# artifacts, the workflow cannot define target/outcome cohorts and covariates
# reproducibly.
# -----------------------------------------------------------------------------
missing <- artifacts[!file.exists(artifacts)]
if (length(missing) > 0) {
  stop("Missing required definition files: ", paste(missing, collapse = ", "))
}

# -----------------------------------------------------------------------------
# Chunk 4 - Load cohort SQL definitions into variables
# Purpose:
# Read SQL text now so this step explicitly sets the variables that define the
# target and outcome cohorts. This confirms files are readable and non-empty.
# -----------------------------------------------------------------------------
target_cohort_sql <- paste(readLines(target_cohort_sql_path, warn = FALSE), collapse = "\n")
outcome_cohort_sql <- paste(readLines(outcome_cohort_sql_path, warn = FALSE), collapse = "\n")

if (nchar(trimws(target_cohort_sql)) == 0) {
  stop("Target cohort SQL file is empty: ", target_cohort_sql_path)
}
if (nchar(trimws(outcome_cohort_sql)) == 0) {
  stop("Outcome cohort SQL file is empty: ", outcome_cohort_sql_path)
}

# -----------------------------------------------------------------------------
# Chunk 5 - Load covariate component and concept mapping definitions
# Purpose:
# Read the two risk-score definition tables that establish covariate logic:
# - components.csv defines covariate windows, minimum counts, and point values
# - component_concepts.csv defines OMOP concepts attached to each component
# -----------------------------------------------------------------------------
components <- read.csv(covariate_components_csv_path, stringsAsFactors = FALSE, comment.char = "")
concepts <- read.csv(covariate_concepts_csv_path, stringsAsFactors = FALSE, comment.char = "#")

# -----------------------------------------------------------------------------
# Chunk 6 - Structural validation of covariate definition tables
# Purpose:
# Ensure expected columns exist and verify concept mappings reference known
# component IDs. This catches malformed files before any model or cohort run.
# -----------------------------------------------------------------------------
required_component_cols <- c(
  "component_id", "component_name", "domain",
  "lookback_start_day", "lookback_end_day", "min_count", "points"
)
required_concept_cols <- c("component_id", "concept_id", "include_descendants")

missing_component_cols <- setdiff(required_component_cols, names(components))
missing_concept_cols <- setdiff(required_concept_cols, names(concepts))

if (length(missing_component_cols) > 0) {
  stop("components.csv is missing required columns: ", paste(missing_component_cols, collapse = ", "))
}
if (length(missing_concept_cols) > 0) {
  stop("component_concepts.csv is missing required columns: ", paste(missing_concept_cols, collapse = ", "))
}

unknown_component_ids <- setdiff(unique(concepts$component_id), unique(components$component_id))
if (length(unknown_component_ids) > 0) {
  stop(
    "component_concepts.csv contains component_id values not present in components.csv: ",
    paste(unknown_component_ids, collapse = ", ")
  )
}

placeholder_concepts <- sum(concepts$concept_id %in% c(0, "0"), na.rm = TRUE)
if (placeholder_concepts > 0) {
  warning(
    "component_concepts.csv contains ", placeholder_concepts,
    " placeholder concept_id value(s) equal to 0. Replace with validated standard OMOP concept IDs before final analysis."
  )
}

# -----------------------------------------------------------------------------
# Chunk 7 - Manifest output
# Purpose:
# Print a concise operational summary so users can confirm what was loaded and
# validated in this step.
# -----------------------------------------------------------------------------
cat("Step 2 complete: OMOP phenotype artifacts verified.\n")
cat("Target cohort SQL path : ", target_cohort_sql_path, "\n", sep = "")
cat("Outcome cohort SQL path: ", outcome_cohort_sql_path, "\n", sep = "")
cat("Target cohort SQL chars : ", nchar(target_cohort_sql), "\n", sep = "")
cat("Outcome cohort SQL chars: ", nchar(outcome_cohort_sql), "\n", sep = "")
cat("Covariates defined in components.csv: ", nrow(components), "\n", sep = "")
cat("Concept mappings in component_concepts.csv: ", nrow(concepts), "\n", sep = "")
