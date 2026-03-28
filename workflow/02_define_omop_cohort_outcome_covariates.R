#!/usr/bin/env Rscript
# Step 2: Define cohort, outcome, and covariates by OMOP concepts.
# This step validates required definition artifacts and prints a compact manifest.

source("workflow/workflow_bootstrap.R")
set_workflow_root()

artifacts <- c(
  "cohorts/target_surgery.sql",
  "cohorts/outcome_ssi.sql",
  "risk_score/components.csv",
  "risk_score/component_concepts.csv"
)

missing <- artifacts[!file.exists(artifacts)]
if (length(missing) > 0) {
  stop("Missing required definition files: ", paste(missing, collapse = ", "))
}

components <- read.csv("risk_score/components.csv", stringsAsFactors = FALSE)
concepts <- read.csv("risk_score/component_concepts.csv", stringsAsFactors = FALSE)

cat("Step 2 complete: OMOP phenotype artifacts verified.\n")
cat("Target cohort SQL : cohorts/target_surgery.sql\n")
cat("Outcome cohort SQL: cohorts/outcome_ssi.sql\n")
cat("Covariates defined in components.csv: ", nrow(components), "\n", sep = "")
cat("Concept mappings in component_concepts.csv: ", nrow(concepts), "\n", sep = "")
