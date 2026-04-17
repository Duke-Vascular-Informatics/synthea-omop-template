#!/usr/bin/env Rscript
# =============================================================================
# workflow/02_define_omop_cohort_outcome_covariates.R
#
# Step 2: Declare and validate the phenotype artifacts for your study.
#
# PURPOSE
# -------
# This step is the single source of truth for WHAT the study measures:
#   • Which patients are in scope (target / exposure cohort)
#   • What is being compared to or against (comparator cohort, if any)
#   • What outcome is being tracked (outcome cohort, if any)
#   • Which covariates / features are extracted (covariate definitions, if any)
#
# It does NOT connect to a database. It reads files, validates their structure,
# and prints a manifest so you can confirm the artifacts before running Step 8.
#
# This step supports any OMOP-based study design:
#   • Cohort characterization  — target cohort only
#   • Prognostic modelling     — target cohort + outcome + covariates
#   • Causal inference         — target + comparator + outcome + covariates
#   • Descriptive comparison   — target + comparator (no formal outcome)
#
# =============================================================================
# TEMPLATE — COMPLETE THE THREE SECTIONS BELOW BEFORE RUNNING THIS STEP
# =============================================================================


# =============================================================================
# SECTION A — STUDY DESIGN
# =============================================================================
# TODO [STUDY DESIGN]: Set study_design to match your analysis.
#
# Options:
#   "cohort_characterization" — Describe a single cohort. No outcome or
#                               comparator required. Step 8 will typically
#                               call FeatureExtraction or CohortDiagnostics.
#
#   "prognostic_model"        — Predict an outcome in a single cohort.
#                               Requires: target cohort + outcome cohort +
#                               covariate definitions.
#                               Step 8 will typically call
#                               PatientLevelPrediction::runPlp().
#
#   "causal_inference"        — Estimate a treatment effect.
#                               Requires: target (treated) + comparator
#                               (control) + outcome + covariate definitions.
#                               Step 8 will typically call
#                               CohortMethod::runCmAnalyses() or
#                               SelfControlledCaseSeries::runSccsAnalyses().
#
#   "descriptive"             — Compare two cohorts without a formal outcome.
#                               Requires: target + comparator.
#                               Step 8 will typically produce summary tables.
#
#   "custom"                  — Any other design. Validation is minimal.
#
study_design <- "prognostic_model"   # <-- REPLACE with your study design


# =============================================================================
# SECTION B — PHENOTYPE ARTIFACT PATHS
# =============================================================================
# TODO [PHENOTYPE PATHS]: Set the path to each SQL file and covariate
# definition file for your study. Paths are relative to the project root.
#
# Set a variable to NULL to mark it as unused for your design.
# Step 2 will skip validation for NULL entries and emit a reminder if a
# non-NULL file is missing.
#
# SQL FILE NAMING CONVENTION
# ─────────────────────────
# Name your files to reflect the study concept, not the template default.
# Examples:
#   Target cohort   : "cohorts/initiators_statin.sql"
#                     "cohorts/hip_replacement_index.sql"
#   Comparator      : "cohorts/initiators_fibrate.sql"
#                     "cohorts/knee_replacement_index.sql"
#   Outcome         : "cohorts/mi_outcome.sql"
#                     "cohorts/vte_90day.sql"
#
# The two template SQL files already in cohorts/ use generic names:
#   cohorts/target_surgery.sql  — target / exposure cohort template
#   cohorts/outcome_ssi.sql     — outcome cohort template
# Rename or copy them as needed for your study.

# --- Required for all designs ---
# NOTE: this path must also match config$target_cohort_sql in config.R so that
# build_cohorts() in Step 8 reads the same file you validated here.
target_cohort_sql_path <- "cohorts/target_surgery.sql"   # <-- RENAME / REPLACE path

# --- Required for: causal_inference | descriptive ---
# Set to NULL if study_design is "cohort_characterization" or "prognostic_model".
#
# IMPORTANT: when you set a comparator SQL path here, also set
#   comparator_cohort_id = <integer>L   in config.R
# so that build_cohorts() (R/cohorts.R) knows which cohort_definition_id to
# assign and Step 8 analysis code can reference config$comparator_cohort_id.
comparator_cohort_sql_path <- NULL    # <-- SET path (e.g. "cohorts/comparator_cohort.sql"),
                                      #     or leave NULL if not applicable

# --- Required for: prognostic_model | causal_inference ---
# Set to NULL if study_design is "cohort_characterization" or "descriptive".
# NOTE: must also match config$outcome_cohort_sql in config.R.
outcome_cohort_sql_path <- "cohorts/outcome_ssi.sql"     # <-- RENAME / REPLACE path

# --- Covariate / feature definitions ---
# How you define covariates depends on your analysis approach:
#
#   Option 1 — FeatureExtraction settings object (R object, not a file):
#     Define a FeatureExtraction::createCovariateSettings() call in Step 8.
#     Set both covariate_* paths to NULL here.
#
#   Option 2 — Custom CSV specification (as used by this template's pipeline):
#     Populate risk_score/components.csv and risk_score/component_concepts.csv.
#     Set paths below.
#
#   Option 3 — ATLAS concept sets or cohort features (JSON files):
#     Point the paths below to your JSON specification files.
#
#   Option 4 — No pre-specified covariates (e.g. cohort characterization only):
#     Set both to NULL.
#
covariate_components_path <- "risk_score/components.csv"          # <-- SET path, or NULL
covariate_concepts_path   <- "risk_score/component_concepts.csv"  # <-- SET path, or NULL


# =============================================================================
# SECTION C — STUDY PARAMETERS
# =============================================================================
# TODO [STUDY PARAMETERS]: Set the analysis parameters that are NOT in config.R.
# These are study-design–specific values referenced in Step 8.
#
# These variables are defined here (not in config.R) because they describe
# the analytic structure of the study, not the infrastructure.
# Add or remove parameters as your design requires.

# Prediction / follow-up window (days after index date for outcome attribution).
# Used by prognostic_model and causal_inference designs.
# Set to NULL if not applicable.
prediction_window_days <- 90L        # <-- REPLACE or set to NULL

# Minimum required days of prior observation before index date.
# Patients with fewer prior days are excluded from the cohort.
# Set to NULL to skip this restriction.
min_prior_observation_days <- 365L   # <-- REPLACE or set to NULL

# Covariate lookback window (days before index to extract covariates).
# Used when configuring FeatureExtraction or custom covariate queries.
# Set to NULL if using a fixed window defined in covariate files.
covariate_lookback_days <- 365L      # <-- REPLACE or set to NULL

# TODO [STUDY PARAMETERS]: Add any other study-specific parameters here.
# Examples:
#   washout_days           <- 365L    # Prior-event washout window
#   time_at_risk_start     <- 1L      # Days after index to start follow-up
#   time_at_risk_end       <- 365L    # Days after index to end follow-up
#   ps_model_covariates    <- TRUE    # Include propensity score covariates
#   negative_control_ids   <- c(...)  # Negative control outcome concept IDs


# =============================================================================
# — INFRASTRUCTURE BELOW — no changes needed unless extending validation —
# =============================================================================


# -----------------------------------------------------------------------------
# Chunk 1 - Workflow bootstrap
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
# Chunk 2 - Resolve required vs. optional artifact list for this design
# -----------------------------------------------------------------------------
required_artifacts  <- list()
optional_artifacts  <- list()

# Target cohort is always required.
required_artifacts[["target_cohort"]] <- target_cohort_sql_path

# Comparator, outcome, and covariate files depend on study design.
if (study_design %in% c("prognostic_model", "causal_inference", "descriptive")) {
  if (!is.null(comparator_cohort_sql_path)) {
    required_artifacts[["comparator_cohort"]] <- comparator_cohort_sql_path
  } else if (study_design %in% c("causal_inference", "descriptive")) {
    warning(
      "[Step 2] study_design = '", study_design, "' typically requires a comparator cohort.\n",
      "  TODO [PHENOTYPE PATHS]: Set comparator_cohort_sql_path or change study_design."
    )
  }
}

if (study_design %in% c("prognostic_model", "causal_inference")) {
  if (!is.null(outcome_cohort_sql_path)) {
    required_artifacts[["outcome_cohort"]] <- outcome_cohort_sql_path
  } else {
    warning(
      "[Step 2] study_design = '", study_design, "' requires an outcome cohort.\n",
      "  TODO [PHENOTYPE PATHS]: Set outcome_cohort_sql_path or change study_design."
    )
  }
}

if (!is.null(covariate_components_path))
  optional_artifacts[["covariate_components"]] <- covariate_components_path
if (!is.null(covariate_concepts_path))
  optional_artifacts[["covariate_concepts"]] <- covariate_concepts_path


# -----------------------------------------------------------------------------
# Chunk 3 - File existence validation
# -----------------------------------------------------------------------------
missing_required <- Filter(function(p) !file.exists(p), required_artifacts)
if (length(missing_required) > 0) {
  stop(
    "Missing required phenotype artifact(s):\n",
    paste0("  [", names(missing_required), "] ", unlist(missing_required), collapse = "\n"),
    "\nCreate the file(s) or update the paths in Section B above."
  )
}

missing_optional <- Filter(function(p) !file.exists(p), optional_artifacts)
if (length(missing_optional) > 0) {
  warning(
    "[Step 2] Optional covariate file(s) not found (set path to NULL to suppress):\n",
    paste0("  [", names(missing_optional), "] ", unlist(missing_optional), collapse = "\n")
  )
}


# -----------------------------------------------------------------------------
# Chunk 4 - Load and validate SQL artifacts
# -----------------------------------------------------------------------------
load_sql <- function(path, label) {
  sql <- paste(readLines(path, warn = FALSE), collapse = "\n")
  if (nchar(trimws(sql)) == 0)
    stop(label, " SQL file is empty: ", path)
  # Warn if placeholder concept_id = 0 values are still present.
  if (grepl("concept_id\\s*=\\s*0\\b|IN\\s*\\(\\s*0\\s*\\)", sql)) {
    warning(
      "[Step 2] ", label, " (", path, ") may contain placeholder concept_id = 0 values.\n",
      "  Replace all 0 placeholders with verified standard OMOP concept IDs before Step 8."
    )
  }
  sql
}

target_cohort_sql   <- load_sql(target_cohort_sql_path, "Target cohort")
comparator_cohort_sql <- if (!is.null(comparator_cohort_sql_path) && file.exists(comparator_cohort_sql_path))
  load_sql(comparator_cohort_sql_path, "Comparator cohort") else NULL
outcome_cohort_sql  <- if (!is.null(outcome_cohort_sql_path) && file.exists(outcome_cohort_sql_path))
  load_sql(outcome_cohort_sql_path, "Outcome cohort") else NULL


# -----------------------------------------------------------------------------
# Chunk 5 - Load and validate covariate definition files (if provided)
# -----------------------------------------------------------------------------
covariate_components <- NULL
covariate_concepts   <- NULL

if (!is.null(covariate_components_path) && file.exists(covariate_components_path)) {
  covariate_components <- read.csv(covariate_components_path,
                                   stringsAsFactors = FALSE, comment.char = "#")

  required_cols <- c("component_id", "component_name", "domain",
                     "lookback_start_day", "lookback_end_day", "min_count", "points")
  missing_cols  <- setdiff(required_cols, names(covariate_components))
  if (length(missing_cols) > 0)
    stop("Covariate components file is missing required columns: ",
         paste(missing_cols, collapse = ", "))

  # Warn on placeholder rows (component_id still matching template defaults).
  placeholder_ids <- grep("^covariate_[0-9]+$", covariate_components$component_id, value = TRUE)
  if (length(placeholder_ids) > 0)
    warning(
      "[Step 2] Covariate components file still contains ", length(placeholder_ids),
      " placeholder row(s): ", paste(placeholder_ids, collapse = ", "), ".\n",
      "  TODO [COVARIATES]: Replace template example rows with your study covariates."
    )
}

if (!is.null(covariate_concepts_path) && file.exists(covariate_concepts_path)) {
  covariate_concepts <- read.csv(covariate_concepts_path,
                                 stringsAsFactors = FALSE, comment.char = "#")

  required_cols <- c("component_id", "concept_id", "include_descendants")
  missing_cols  <- setdiff(required_cols, names(covariate_concepts))
  if (length(missing_cols) > 0)
    stop("Covariate concepts file is missing required columns: ",
         paste(missing_cols, collapse = ", "))

  # Cross-check: every concept row must reference a known component.
  if (!is.null(covariate_components)) {
    unknown_ids <- setdiff(unique(covariate_concepts$component_id),
                           unique(covariate_components$component_id))
    if (length(unknown_ids) > 0)
      stop("Covariate concepts file references unknown component_id values: ",
           paste(unknown_ids, collapse = ", "))
  }

  placeholder_concepts <- sum(covariate_concepts$concept_id %in% c(0, "0"), na.rm = TRUE)
  if (placeholder_concepts > 0)
    warning(
      "[Step 2] Covariate concepts file contains ", placeholder_concepts,
      " placeholder concept_id = 0 value(s).\n",
      "  TODO [COVARIATES]: Replace with verified standard OMOP concept IDs before Step 8."
    )
}


# -----------------------------------------------------------------------------
# Chunk 6 - Manifest output
# -----------------------------------------------------------------------------
cat("=================================================================\n")
cat("Step 2 complete: phenotype artifacts loaded and validated.\n")
cat("=================================================================\n")
cat("Study design     : ", study_design, "\n", sep = "")
cat("\nCohort artifacts:\n")
cat("  [target]     ", target_cohort_sql_path,
    "  (", nchar(target_cohort_sql), " chars)\n", sep = "")
if (!is.null(comparator_cohort_sql))
  cat("  [comparator] ", comparator_cohort_sql_path,
      "  (", nchar(comparator_cohort_sql), " chars)\n", sep = "")
if (!is.null(outcome_cohort_sql))
  cat("  [outcome]    ", outcome_cohort_sql_path,
      "  (", nchar(outcome_cohort_sql), " chars)\n", sep = "")
cat("\nCovariate definitions:\n")
if (!is.null(covariate_components)) {
  cat("  components   : ", covariate_components_path,
      "  (", nrow(covariate_components), " rows)\n", sep = "")
} else {
  cat("  components   : not provided",
      if (study_design %in% c("prognostic_model", "causal_inference"))
        " — define covariates in Step 8 using FeatureExtraction" else "", "\n")
}
if (!is.null(covariate_concepts)) {
  cat("  concepts     : ", covariate_concepts_path,
      "  (", nrow(covariate_concepts), " rows)\n", sep = "")
}
cat("\nStudy parameters:\n")
cat("  Prediction window  : ",
    if (!is.null(prediction_window_days)) paste0(prediction_window_days, " days") else "not set",
    "\n", sep = "")
cat("  Min prior obs days : ",
    if (!is.null(min_prior_observation_days)) paste0(min_prior_observation_days, " days") else "not set",
    "\n", sep = "")
cat("  Covariate lookback : ",
    if (!is.null(covariate_lookback_days)) paste0(covariate_lookback_days, " days") else "not set",
    "\n", sep = "")
cat("\nNext step: Rscript workflow/03_generate_synthea_module_artifacts.R\n")
cat("           (or skip to Step 7 if not using Synthea)\n")
