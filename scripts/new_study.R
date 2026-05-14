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
# results_schema and cohort_table auto-derive from study_name in config.R when omitted.
lines <- gsub('"my_study"',        paste0('"', study_name, '"'),          lines, fixed = TRUE)
lines <- gsub('"output/my_study"', paste0('"output/', study_name, '"'),   lines, fixed = TRUE)

writeLines(lines, dest)

message("Created study_params.yaml for study: ", study_name)

# =============================================================================
# Step 2: Create synthea-pad branch and register as a submodule.
#
# Branch name uses kebab-case (underscores → hyphens) to match the study repo
# naming convention used across the OHDSI PAD analysis portfolio.
# =============================================================================

study_branch <- gsub("_", "-", study_name)
synthea_url  <- "https://github.com/adam-mdmph/synthea-pad.git"
synthea_dir  <- file.path(getwd(), "external", "synthea")
synthea_tmp  <- file.path(getwd(), "external", ".synthea_init_tmp")

message("")
message("Setting up synthea-pad submodule for branch: ", study_branch)

# Clone to a temp path so we can create and push the study branch from master
# before registering the submodule (git submodule add requires the branch to
# already exist on the remote).
message("  Cloning synthea-pad to create study branch ...")
if (dir.exists(synthea_tmp)) unlink(synthea_tmp, recursive = TRUE)

ret <- system2("git", c("clone", synthea_url, synthea_tmp), stdout = TRUE, stderr = TRUE)
if (!is.null(attr(ret, "status")) && attr(ret, "status") != 0) {
  stop("git clone failed:\n", paste(ret, collapse = "\n"))
}

ret <- system2("git", c("-C", synthea_tmp, "checkout", "-b", study_branch),
               stdout = TRUE, stderr = TRUE)
if (!is.null(attr(ret, "status")) && attr(ret, "status") != 0) {
  stop("git checkout -b '", study_branch, "' failed:\n", paste(ret, collapse = "\n"))
}

ret <- system2("git", c("-C", synthea_tmp, "push", "origin", study_branch),
               stdout = TRUE, stderr = TRUE)
if (!is.null(attr(ret, "status")) && attr(ret, "status") != 0) {
  stop("git push failed:\n", paste(ret, collapse = "\n"))
}

unlink(synthea_tmp, recursive = TRUE)
message("  Branch '", study_branch, "' pushed to synthea-pad.")

# Register external/synthea as a submodule pinned to the new branch
message("  Registering external/synthea as submodule ...")
ret <- system2("git", c("submodule", "add", "-b", study_branch, synthea_url, synthea_dir),
               stdout = TRUE, stderr = TRUE)
if (!is.null(attr(ret, "status")) && attr(ret, "status") != 0) {
  stop("git submodule add failed:\n", paste(ret, collapse = "\n"))
}

ret <- system2("git", c("submodule", "update", "--init", synthea_dir),
               stdout = TRUE, stderr = TRUE)
if (!is.null(attr(ret, "status")) && attr(ret, "status") != 0) {
  stop("git submodule update failed:\n", paste(ret, collapse = "\n"))
}

ret <- system2("git", c("add", ".gitmodules", "external/synthea"),
               stdout = TRUE, stderr = TRUE)
ret <- system2("git",
               c("commit", "-m",
                 paste0("chore: add synthea-pad submodule (", study_branch, " branch)")),
               stdout = TRUE, stderr = TRUE)

message("  Submodule registered and committed.")
message("")
message("Next steps:")
message("  1. Edit study_params.yaml — fill in every TODO item")
message("  2. Rscript scripts/find_todos.R            — check remaining placeholders")
message("  3. Add study-specific Synthea modules to:")
message("       external/synthea/src/main/resources/modules/")
message("     then commit and push:")
message("       cd external/synthea")
message("       git add . && git commit -m 'feat: add modules for ", study_name, "'")
message("       git push origin ", study_branch)
message("       cd ../..")
message("       git add external/synthea && git commit -m 'chore: update synthea-pad submodule'")
message("  4. Rscript workflow/02_define_omop_cohort_outcome_covariates.R  — validate")
message("  5. Edit covariates/covariates.csv and covariates/covariate_concepts.csv")
message("  6. Rscript workflow/08_run_analysis_and_manuscript_report.R")
