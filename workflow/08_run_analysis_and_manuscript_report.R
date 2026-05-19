#!/usr/bin/env Rscript
# =============================================================================
# workflow/08_run_analysis_and_manuscript_report.R
#
# Step 8: Run analysis and generate output.
#
# PURPOSE
# -------
# Executes the analysis blocks enabled in study_params.yaml (analyses: section)
# and writes outputs to config$output_folder.
#
# No editing of this script is needed for standard analyses.
# To enable an analysis, set its flag to true in study_params.yaml:
#
#   analyses:
#     cohort_characterization: true   # FeatureExtraction covariate summary
#     prognostic_model:         false  # PatientLevelPrediction LASSO
#     causal_inference:         false  # CohortMethod PS matching
#     integer_risk_score:       false  # custom integer score pipeline
#     word_report:              false  # Word report (run after a pipeline above)
#
# To customise a default analysis (e.g. swap the PLP model algorithm, change
# covariate settings) edit the relevant if-block in Section 7 below.
#
# PREREQUISITES
# -------------
#   - Steps 1–7 completed successfully.
#   - Step 5 (ETL) populated the CDM schema referenced in study_params.yaml.
#   - Step 7 confirmed all required packages are installed.
#
# EXECUTION
# ---------
#   Rscript workflow/08_run_analysis_and_manuscript_report.R
#   Must be run in a FRESH R session (see Java guard in Section 2).
# =============================================================================


# =============================================================================
# 1. Workflow bootstrap
# =============================================================================
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


# =============================================================================
# 2. Java / JDBC session guard
# =============================================================================
# DatabaseConnector uses rJava. The JVM can only be initialised once per R
# session. This guard stops execution immediately if Java-related namespaces
# are already loaded, prompting the analyst to open a fresh session rather
# than getting cryptic JVM errors downstream.
loaded_java_ns <- intersect(
  c("rJava", "DatabaseConnector", "PatientLevelPrediction",
    "CohortMethod", "FeatureExtraction"),
  loadedNamespaces()
)
if (length(loaded_java_ns) > 0) {
  stop(
    "Run this script in a FRESH R session. Already loaded: ",
    paste(loaded_java_ns, collapse = ", ")
  )
}


# =============================================================================
# 3. Activate renv, load config, and source helper modules
# =============================================================================
Sys.setenv(RENV_CONFIG_SYNCHRONIZED_CHECK = "FALSE") # suppress renv "not synchronized" warning during analysis runs
if (file.exists("renv/activate.R")) source("renv/activate.R")

source("config.R")       # get_validation_config()
source("R/drivers.R")    # configure_java(), ensure_jdbc_bundle()
source("R/connection.R") # build_connection_details()
source("R/cohorts.R")    # ensure_results_schema(), build_cohorts()

# Read config before Java initialisation (only YAML parsing; no JDBC yet).
config <- get_validation_config()

# Source analysis-specific helper modules for the analyses that are enabled.
# Load order matters: risk_score_pipeline before plp_validation_pipeline
# (both may export helpers used by report_extended), and report_extended last
# so it can reference any function defined by the earlier pipelines.
if (config$run_integer_risk_score)   source("R/risk_score_pipeline.R")
if (config$run_plp_model_validation) source("R/plp_validation_pipeline.R")
if (config$run_word_report)          source("R/report_extended.R")


# =============================================================================
# 4. Initialise Java and load packages
# =============================================================================
# configure_java() sets the JVM heap and JDBC class path; must run before any
# library() call that depends on rJava.
configure_java(config)

# Core database packages — always required.
library(DatabaseConnector)
library(SqlRender)

# Load analysis packages based on the flags in study_params.yaml.
# FeatureExtraction is a shared dependency for PLP, CohortMethod, and
# CohortDiagnostics and is loaded once when any of those are enabled.
if (config$run_cohort_characterization ||
    config$run_prognostic_model        ||
    config$run_causal_inference) {
  library(FeatureExtraction)
}
if (config$run_cohort_characterization) {
  library(CohortDiagnostics)
}
if (config$run_prognostic_model) {
  library(PatientLevelPrediction)
  library(pROC)    # AUROC with confidence intervals
  library(PRROC)   # area under precision-recall curve
}
if (config$run_causal_inference) {
  library(CohortMethod)
  library(EmpiricalCalibration)
}
if (config$run_integer_risk_score || config$run_word_report) {
  library(ggplot2)
  library(officer)
  library(flextable)
}
library(dplyr)   # data wrangling — broadly useful
library(readr)   # CSV I/O


# =============================================================================
# 5. Build database connection
# =============================================================================
# build_connection_details() returns a DatabaseConnector ConnectionDetails
# object (credentials only — no open connection yet) from the settings in
# config.R. All downstream HADES functions accept this object and manage their
# own connections internally.
message("[Step 8] Building connection details ...")
connection_details <- build_connection_details(config)


# =============================================================================
# 6. Prepare results schema and instantiate cohorts
# =============================================================================
# ensure_results_schema() creates the results schema and cohort table if they
# do not already exist (idempotent — safe to re-run).
#
# build_cohorts() renders and executes the SqlRender-parameterised cohort SQL
# files declared in study_params.yaml. Each SQL deletes existing rows before
# inserting, so re-runs produce a fresh, non-duplicated cohort.
# Comparator and outcome cohorts are skipped when their IDs are NA.
message("[Step 8] Preparing results schema and instantiating cohorts ...")
cohort_conn <- DatabaseConnector::connect(connection_details)
ensure_results_schema(cohort_conn, config)
build_cohorts(cohort_conn, config)
DatabaseConnector::disconnect(cohort_conn)
message("[Step 8] Cohorts instantiated.")


# =============================================================================
# 7. ANALYSIS
# =============================================================================
# Each block below runs only when its flag is true in study_params.yaml.
# Customise default settings (e.g. model algorithm, covariate settings) by
# editing the relevant block here.

dir.create(config$output_folder, recursive = TRUE, showWarnings = FALSE)

# -----------------------------------------------------------------------------
# Cohort characterization — FeatureExtraction default covariate summary
# -----------------------------------------------------------------------------
if (config$run_cohort_characterization) {
  message("[Step 8] Running cohort characterization ...")

  # createDefaultCovariateSettings() extracts demographics, conditions, drugs,
  # and procedures across standard OHDSI lookback windows. Swap for
  # createCovariateSettings() to specify individual domains and windows.
  covariate_settings <- FeatureExtraction::createDefaultCovariateSettings()

  covariate_data <- FeatureExtraction::getDbCovariateData(
    connectionDetails    = connection_details,
    cdmDatabaseSchema    = config$cdm_schema,
    cohortDatabaseSchema = config$results_schema,
    cohortTable          = config$cohort_table,
    cohortId             = config$target_cohort_id,
    rowIdField           = "subject_id",
    covariateSettings    = covariate_settings
  )

  FeatureExtraction::saveCovariateData(
    covariateData = covariate_data,
    file          = file.path(config$output_folder, "covariate_data")
  )
  message("[Step 8] Cohort characterization complete. ",
          "Saved to: ", file.path(config$output_folder, "covariate_data"))
}


# -----------------------------------------------------------------------------
# Prognostic model — PatientLevelPrediction (LASSO logistic regression default)
# To change the model algorithm replace setLassoLogisticRegression() with
# setRandomForest(), setGradientBoostingMachine(), etc.
# -----------------------------------------------------------------------------
if (config$run_prognostic_model) {
  message("[Step 8] Running prognostic model (PatientLevelPrediction) ...")

  covariate_settings <- FeatureExtraction::createDefaultCovariateSettings()

  # Study population settings — use study_params.yaml values for the key
  # time windows so this block requires no editing for most studies.
  population_settings <- PatientLevelPrediction::createStudyPopulationSettings(
    washoutPeriod                  = config$min_prior_observation_days,
    firstExposureOnly              = TRUE,
    removeSubjectsWithPriorOutcome = TRUE,
    priorOutcomeLookback           = config$min_prior_observation_days,
    riskWindowStart                = 1L,
    riskWindowEnd                  = config$prediction_window_days,
    startAnchor                    = "cohort start",
    endAnchor                      = "cohort start",
    minTimeAtRisk                  = 1L,
    requireTimeAtRisk              = TRUE
  )

  plp_data <- PatientLevelPrediction::getPlpData(
    databaseDetails = PatientLevelPrediction::createDatabaseDetails(
      connectionDetails    = connection_details,
      cdmDatabaseSchema    = config$cdm_schema,
      cohortDatabaseSchema = config$results_schema,
      cohortTable          = config$cohort_table,
      targetId             = config$target_cohort_id,
      outcomeIds           = config$outcome_cohort_id
    ),
    covariateSettings        = covariate_settings,
    restrictPlpDataToIPeriod = FALSE
  )

  results <- PatientLevelPrediction::runPlp(
    plpData            = plp_data,
    outcomeId          = config$outcome_cohort_id,
    analysisId         = config$study_name,
    analysisName       = config$cdm_database_name,
    populationSettings = population_settings,
    splitSettings      = PatientLevelPrediction::createDefaultSplitSetting(
                           testFraction = 0.25, nfold = 3L),
    sampleSettings            = PatientLevelPrediction::createSampleSettings(),
    featureEngineeringSettings = PatientLevelPrediction::createFeatureEngineeringSettings(),
    preprocessSettings        = PatientLevelPrediction::createPreprocessSettings(),
    modelSettings             = PatientLevelPrediction::setLassoLogisticRegression(),
    logSettings               = PatientLevelPrediction::createLogSettings(),
    executeSettings           = PatientLevelPrediction::createExecuteSettings(
                                  runSplitData          = TRUE,
                                  runSampleData         = TRUE,
                                  runfeatureEngineering = TRUE,
                                  runPreprocessData     = TRUE,
                                  runModelDevelopment   = TRUE,
                                  runCovariateSummary   = TRUE),
    saveDirectory      = config$output_folder
  )

  message("[Step 8] Prognostic model complete. ",
          "Results saved to: ", config$output_folder)
}


# -----------------------------------------------------------------------------
# Causal inference — CohortMethod (propensity score matching, Cox outcome model)
# Requires comparator.cohort_id set in study_params.yaml.
# -----------------------------------------------------------------------------
if (config$run_causal_inference) {
  if (is.na(config$comparator_cohort_id)) {
    warning("[Step 8] run_causal_inference = TRUE but comparator_cohort_id is NA. ",
            "Set comparator.cohort_id in study_params.yaml and re-run.")
  } else {
    message("[Step 8] Running causal inference (CohortMethod) ...")

    # Exclude the exposure concept IDs from the propensity score covariate set
    # to avoid conditioning on the treatment itself.
    covariate_settings <- FeatureExtraction::createDefaultCovariateSettings(
      excludedCovariateConceptIds = config$target_index_concept_ids,
      addDescendantsToExclude     = TRUE
    )

    cm_data <- CohortMethod::getDbCohortMethodData(
      connectionDetails      = connection_details,
      cdmDatabaseSchema      = config$cdm_schema,
      targetId               = config$target_cohort_id,
      comparatorId           = config$comparator_cohort_id,
      outcomeIds             = config$outcome_cohort_id,
      exposureDatabaseSchema = config$results_schema,
      exposureTable          = config$cohort_table,
      outcomeDatabaseSchema  = config$results_schema,
      outcomeTable           = config$cohort_table,
      covariateSettings      = covariate_settings
    )

    study_pop <- CohortMethod::createStudyPopulation(
      cohortMethodData = cm_data,
      outcomeId        = config$outcome_cohort_id,
      riskWindowStart  = 1L,
      startAnchor      = "cohort start",
      riskWindowEnd    = config$prediction_window_days,
      endAnchor        = "cohort start"
    )

    ps_model    <- CohortMethod::createPs(cm_data, study_pop)
    matched_pop <- CohortMethod::matchOnPs(
      ps_model,
      caliper      = 0.2,
      caliperScale = "standardized logit"
    )

    outcome_model <- CohortMethod::fitOutcomeModel(
      population = matched_pop,
      modelType  = "cox"
    )
    print(outcome_model)

    # Persist the data and model for downstream review / meta-analysis.
    CohortMethod::saveCohortMethodData(
      cm_data,
      file.path(config$output_folder, "cm_data")
    )
    saveRDS(outcome_model,
            file.path(config$output_folder, "outcome_model.rds"))

    message("[Step 8] Causal inference complete. ",
            "Results saved to: ", config$output_folder)
  }
}


# -----------------------------------------------------------------------------
# Integer risk score validation — custom pipeline
# Reads covariates/covariates.csv and covariates/covariate_concepts.csv.
# Those files must have a points column and verified concept IDs.
# Pass lookup_file= to supply a score → probability table from the derivation
# cohort; omit to use logistic recalibration only.
# -----------------------------------------------------------------------------
if (config$run_integer_risk_score) {
  message("[Step 8] Running integer risk score pipeline ...")
  lookup_path <- file.path("covariates", "risk_lookup.csv")
  run_integer_risk_score_pipeline(
    config,
    connection_details,
    lookup_file = if (file.exists(lookup_path)) lookup_path else NULL
  )
  message("[Step 8] Integer risk score pipeline complete.")
}


# -----------------------------------------------------------------------------
# Word report — requires a pipeline above to have written its outputs first.
# Reads person_level_scores.csv, covariate_summary.csv, and metrics.csv from
# config$output_folder.
# generate_manuscript_report() dispatches to the appropriate report format
# based on config flags; supply score_output_dir when a pipeline writes its
# CSVs to a subdirectory (e.g. "risk_score_eval/").
# -----------------------------------------------------------------------------
if (config$run_word_report) {
  message("[Step 8] Generating Word report ...")
  # score_output_dir must match where run_integer_risk_score_pipeline() wrote its
  # CSVs.  The pipeline defaults to config$output_folder/risk_score_eval/ — pass
  # the same path here so the report function can find person_level_scores.csv etc.
  generate_manuscript_report(
    output_dir          = config$output_folder,
    score_output_dir    = file.path(config$output_folder, "risk_score_eval"),
    cleanup_old_outputs = FALSE,  # preserve previous report versions (_2, _3, ...) so no work is lost on re-run
    connection_details  = connection_details,
    config              = config
  )
  message("[Step 8] Word report complete.")
}


# -----------------------------------------------------------------------------
# PLP prebuilt model external validation
# Runs an external validation pass for a prebuilt PatientLevelPrediction model
# (linear / LASSO / Ridge) whose coefficients are stored in a standardised spec
# file.  No Python dependency.  See R/plp_validation_pipeline.R for the model
# spec format and required files (model_spec.yaml, covariates/covariates.csv).
# Outputs are written to config$output_folder/plp_validation/.
# -----------------------------------------------------------------------------
if (config$run_plp_model_validation) {
  message("[Step 8] Running PLP model external validation ...")
  run_plp_validation_pipeline(
    config             = config,
    connection_details = connection_details
  )
  message("[Step 8] PLP model external validation complete.")
}


# =============================================================================
# 8. DONE
# =============================================================================
enabled <- Filter(isTRUE, list(
  cohort_characterization = config$run_cohort_characterization,
  prognostic_model        = config$run_prognostic_model,
  causal_inference        = config$run_causal_inference,
  integer_risk_score      = config$run_integer_risk_score,
  word_report             = config$run_word_report,
  plp_model_validation    = config$run_plp_model_validation
))
message("\n[Step 8] Complete. Analyses run: ",
        if (length(enabled) > 0) paste(names(enabled), collapse = ", ") else "none")
message("[Step 8] Output folder: ", config$output_folder)
