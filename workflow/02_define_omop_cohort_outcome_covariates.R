#!/usr/bin/env Rscript
# Step 2: Define cohort, outcome, and covariates by OMOP concepts.
# This step validates required definition artifacts and prints a compact manifest.

resolve_script_path <- function() {
  file_arg <- grep("^--file=", commandArgs(trailingOnly = FALSE), value = TRUE)
  if (length(file_arg) > 0) {
    return(normalizePath(sub("^--file=", "", file_arg[1]), winslash = "/", mustWork = FALSE))
  }

  if (!is.null(sys.frames()[[1]]$ofile)) {
    return(normalizePath(sys.frames()[[1]]$ofile, winslash = "/", mustWork = FALSE))
  }

  NA_character_
}

script_path <- resolve_script_path()
if (!is.na(script_path)) {
  setwd(normalizePath(file.path(dirname(script_path), ".."), winslash = "/", mustWork = FALSE))
}

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
