#!/usr/bin/env Rscript
# =============================================================================
# workflow/08_run_analysis_and_manuscript_report.R
#
# Step 8: Run analysis and generate output.
#
# PURPOSE
# -------
# This script is your analysis entry point. The infrastructure sections (1–6)
# are pre-wired: they activate renv, load config, initialise the JDBC driver,
# open a database connection, and instantiate your cohorts.
#
# Sections 7–9 are blank scaffolds. Fill them in with your analysis code.
# The TODO comments indicate what belongs in each section and include starter
# patterns for the three most common OMOP study designs.
#
# STUDY DESIGN QUICK-START
# ─────────────────────────
#   Cohort characterization  → fill in Section 7 (FeatureExtraction / CohortDiagnostics)
#   Prognostic modelling     → fill in Section 7 (PatientLevelPrediction::runPlp)
#   Causal inference         → fill in Section 7 (CohortMethod / SCCS)
#   Custom analysis          → fill in Section 7 with any R analysis code
#
# PREREQUISITES
# -------------
#   - Steps 1–7 completed successfully.
#   - Step 5 (ETL) populated the CDM schema referenced in config.R.
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
# 3. Activate renv and load infrastructure modules
# =============================================================================
if (file.exists("renv/activate.R")) source("renv/activate.R")

source("config.R")       # get_validation_config()
source("R/drivers.R")    # configure_java(), ensure_jdbc_bundle()
source("R/connection.R") # build_connection_details()
source("R/cohorts.R")    # ensure_results_schema(), build_cohorts()

# TODO [MODULES]: Source any additional R helper modules your analysis needs.
# Examples:
#   source("R/risk_score_pipeline.R")   # custom scoring pipeline
#   source("R/report_extended.R")       # Word report generation
#   source("R/my_analysis_helpers.R")   # your own helper functions


# =============================================================================
# 4. Initialise Java and load database packages
# =============================================================================
# configure_java() must be called BEFORE library(DatabaseConnector) to ensure
# the JVM starts with the correct heap size and JDBC driver on the class path.
config <- get_validation_config()
configure_java(config)

library(DatabaseConnector)   # JDBC connectivity to SQL Server OMOP CDM

# TODO [PACKAGES]: Load your analysis-specific packages here.
# Load them AFTER configure_java() — the JVM must be running before any HADES
# package that uses rJava (PatientLevelPrediction, CohortMethod, FeatureExtraction).
#
# Uncomment the lines for your study design. See workflow/07 for the full
# reference list with one-sentence descriptions of each package's role.
#
# --- Core SQL utilities (uncomment if needed in Section 7) ---
# library(SqlRender)           # SQL parameterization and SQL Server dialect translation
#
# --- Cohort characterization ---
# library(FeatureExtraction)   # extracts patient features (demographics, Dx, Rx, Px)
#                              # from the OMOP CDM into an analysis-ready matrix
# library(CohortDiagnostics)   # validates cohort phenotypes before running analysis
#
# --- Prognostic modelling (note: FeatureExtraction is REQUIRED by PLP) ---
# library(FeatureExtraction)         # covariate extraction — must load before PLP
# library(PatientLevelPrediction)    # model training, evaluation, and validation
# library(pROC)                      # AUROC with CIs for model discrimination
# library(PRROC)                     # precision-recall AUC (better metric when outcome is rare)
#
# --- Causal inference (note: FeatureExtraction is REQUIRED by CohortMethod) ---
# library(FeatureExtraction)         # propensity score covariate extraction
# library(CohortMethod)              # new-user comparative cohort design (HR/RR/OR)
# library(EmpiricalCalibration)      # corrects for residual confounding via negative controls
# library(EvidenceSynthesis)         # meta-analysis when running across multiple sites
#
# --- Output and reporting ---
# library(dplyr)       # data manipulation (filter, join, summarise)
# library(ggplot2)     # plots (calibration curves, ROC, KM)
# library(officer)     # generate Word (.docx) reports programmatically
# library(flextable)   # formatted tables inside Word / HTML reports
# library(openxlsx)    # Excel (.xlsx) output


# =============================================================================
# 5. Build database connection
# =============================================================================
# build_connection_details() returns a DatabaseConnector ConnectionDetails
# object (credentials only — no open connection yet) from the settings in
# config.R. All downstream functions that need a database connection accept
# this object and open/close their own connections internally.
message("[Step 8] Building connection details ...")
connection_details <- build_connection_details(config)


# =============================================================================
# 6. Prepare results schema and instantiate cohorts
# =============================================================================
# ensure_results_schema() creates the results schema and cohort table if they
# do not already exist (idempotent — safe to run on every execution).
#
# build_cohorts() renders and executes the SqlRender-parameterised cohort SQL
# files whose paths are declared in config.R (target_cohort_sql,
# comparator_cohort_sql, outcome_cohort_sql). Each SQL DELETEs its existing
# rows before inserting, so re-runs produce a fresh, non-duplicated cohort.
# Comparator and outcome cohorts are skipped automatically when their config
# paths are NULL or their cohort IDs are NA.
message("[Step 8] Preparing results schema and instantiating cohorts ...")
cohort_conn <- DatabaseConnector::connect(connection_details)
ensure_results_schema(cohort_conn, config)
build_cohorts(cohort_conn, config)
DatabaseConnector::disconnect(cohort_conn)
message("[Step 8] Cohorts instantiated.")

# TODO [COHORTS]: If build_cohorts() does not yet support your comparator
# cohort or a custom cohort SQL, add the instantiation logic here.
# Example of executing additional SQL directly:
#
#   extra_conn <- DatabaseConnector::connect(connection_details)
#   sql <- SqlRender::render(
#     paste(readLines("cohorts/my_extra_cohort.sql"), collapse = "\n"),
#     cdm_database_schema    = config$cdm_schema,
#     target_database_schema = config$results_schema,
#     target_cohort_table    = config$cohort_table,
#     cohort_id              = 3L,
#     study_start_date       = config$study_start_date,
#     study_end_date         = config$study_end_date
#   )
#   DatabaseConnector::executeSql(extra_conn, SqlRender::translate(sql, "sql server"))
#   DatabaseConnector::disconnect(extra_conn)


# =============================================================================
# 7. YOUR ANALYSIS
# =============================================================================
# TODO [ANALYSIS]: Write your analysis code here.
#
# At this point you have:
#   config              — named list with all study settings (from config.R)
#   connection_details  — DatabaseConnector ConnectionDetails object
#   config$cdm_schema   — CDM schema name (populated by Step 5 ETL)
#   config$results_schema / config$cohort_table — cohort table with rows for:
#       cohort_definition_id = config$target_cohort_id    (target / exposed)
#       cohort_definition_id = config$outcome_cohort_id   (outcome)
#       (and comparator_cohort_id if you defined one)
#
# ─────────────────────────────────────────────────────────────────────────────
# STARTER PATTERN A — Cohort characterization (FeatureExtraction)
# ─────────────────────────────────────────────────────────────────────────────
# library(FeatureExtraction)
#
# covariate_settings <- FeatureExtraction::createDefaultCovariateSettings()
# # Adjust: createCovariateSettings(useDemographicsAge = TRUE,
# #   useConditionGroupEraLongTerm = TRUE, longTermStartDays = -365, ...)
#
# covariate_data <- FeatureExtraction::getDbCovariateData(
#   connectionDetails      = connection_details,
#   cdmDatabaseSchema      = config$cdm_schema,
#   cohortDatabaseSchema   = config$results_schema,
#   cohortTable            = config$cohort_table,
#   cohortId               = config$target_cohort_id,
#   rowIdField             = "subject_id",
#   covariateSettings      = covariate_settings
# )
# FeatureExtraction::saveCovariateData(covariate_data, config$output_folder)
# summary(covariate_data)
#
# ─────────────────────────────────────────────────────────────────────────────
# STARTER PATTERN B — Prognostic modelling (PatientLevelPrediction)
# ─────────────────────────────────────────────────────────────────────────────
# library(PatientLevelPrediction)
# library(FeatureExtraction)
#
# covariate_settings <- FeatureExtraction::createDefaultCovariateSettings()
#
# population_settings <- PatientLevelPrediction::createStudyPopulationSettings(
#   washoutPeriod            = 365L,
#   firstExposureOnly        = TRUE,
#   removeSubjectsWithPriorOutcome = TRUE,
#   priorOutcomeLookback     = 365L,
#   riskWindowStart          = 1L,
#   riskWindowEnd            = config$prediction_window_days,
#   startAnchor              = "cohort start",
#   endAnchor                = "cohort start",
#   minTimeAtRisk            = 1L,
#   requireTimeAtRisk        = TRUE
# )
#
# plp_data <- PatientLevelPrediction::getPlpData(
#   databaseDetails        = PatientLevelPrediction::createDatabaseDetails(
#     connectionDetails    = connection_details,
#     cdmDatabaseSchema    = config$cdm_schema,
#     cohortDatabaseSchema = config$results_schema,
#     cohortTable          = config$cohort_table,
#     targetId             = config$target_cohort_id,
#     outcomeIds           = config$outcome_cohort_id
#   ),
#   covariateSettings      = covariate_settings,
#   restrictPlpDataToIPeriod = FALSE
# )
#
# model_settings <- PatientLevelPrediction::setLassoLogisticRegression()
# # Alternatives: setRandomForest(), setGradientBoostingMachine(), setDeepLearning()
#
# results <- PatientLevelPrediction::runPlp(
#   plpData             = plp_data,
#   outcomeId           = config$outcome_cohort_id,
#   analysisId          = config$model_name,
#   analysisName        = config$model_name,
#   populationSettings  = population_settings,
#   splitSettings       = PatientLevelPrediction::createDefaultSplitSetting(
#                           testFraction = 0.25, nfold = 3L),
#   sampleSettings      = PatientLevelPrediction::createSampleSettings(),
#   featureEngineeringSettings = PatientLevelPrediction::createFeatureEngineeringSettings(),
#   preprocessSettings  = PatientLevelPrediction::createPreprocessSettings(),
#   modelSettings       = model_settings,
#   logSettings         = PatientLevelPrediction::createLogSettings(),
#   executeSettings     = PatientLevelPrediction::createExecuteSettings(
#                           runSplitData = TRUE, runSampleData = TRUE,
#                           runfeatureEngineering = TRUE, runPreprocessData = TRUE,
#                           runModelDevelopment = TRUE, runCovariateSummary = TRUE),
#   saveDirectory       = config$output_folder
# )
# PatientLevelPrediction::viewPlp(results)
#
# ─────────────────────────────────────────────────────────────────────────────
# STARTER PATTERN C — Causal inference (CohortMethod)
# ─────────────────────────────────────────────────────────────────────────────
# library(CohortMethod)
# library(FeatureExtraction)
#
# covariate_settings <- FeatureExtraction::createDefaultCovariateSettings(
#   excludedCovariateConceptIds = c(),  # add concept IDs to exclude (e.g. the exposure itself)
#   addDescendantsToExclude     = TRUE
# )
#
# cm_data <- CohortMethod::getDbCohortMethodData(
#   connectionDetails        = connection_details,
#   cdmDatabaseSchema        = config$cdm_schema,
#   targetId                 = config$target_cohort_id,
#   comparatorId             = config$comparator_cohort_id,  # set in config.R TODO [CONFIG]
#   outcomeIds               = config$outcome_cohort_id,
#   exposureDatabaseSchema   = config$results_schema,
#   exposureTable            = config$cohort_table,
#   outcomeDatabaseSchema    = config$results_schema,
#   outcomeTable             = config$cohort_table,
#   covariateSettings        = covariate_settings
# )
#
# study_pop <- CohortMethod::createStudyPopulation(
#   cohortMethodData         = cm_data,
#   outcomeId                = config$outcome_cohort_id,
#   riskWindowStart          = 1L,
#   startAnchor              = "cohort start",
#   riskWindowEnd            = config$prediction_window_days,
#   endAnchor                = "cohort start"
# )
#
# ps_model <- CohortMethod::createPs(cm_data, study_pop)
# matched_pop <- CohortMethod::matchOnPs(ps_model, caliper = 0.2, caliperScale = "standardized logit")
# balance <- CohortMethod::computeCovariateBalance(matched_pop, cm_data)
# CohortMethod::plotCovariateBalanceScatterPlot(balance)
#
# outcome_model <- CohortMethod::fitOutcomeModel(
#   population     = matched_pop,
#   modelType      = "cox"
# )
# print(outcome_model)
#
# ─────────────────────────────────────────────────────────────────────────────


# =============================================================================
# 8. YOUR OUTPUT
# =============================================================================
# TODO [OUTPUT]: Write your results to files.
#
# The output folder from config.R is available as config$output_folder.
# Create it first if it does not exist:
#   dir.create(config$output_folder, recursive = TRUE, showWarnings = FALSE)
#
# Common output patterns:
#
#   CSV results:
#     write.csv(my_results_df, file.path(config$output_folder, "results.csv"),
#               row.names = FALSE)
#
#   Word report (officer + flextable):
#     library(officer)
#     library(flextable)
#     doc <- officer::read_docx()
#     doc <- officer::body_add_par(doc, "Results", style = "heading 1")
#     doc <- flextable::body_add_flextable(doc, flextable::flextable(my_summary_table))
#     print(doc, target = file.path(config$output_folder,
#                                   paste0(config$model_name, "_report.docx")))
#
#   HTML / Shiny viewer (PatientLevelPrediction):
#     PatientLevelPrediction::viewPlp(results)
#
#   Plot files:
#     ggplot2::ggsave(file.path(config$output_folder, "my_plot.png"),
#                    plot = my_gg_object, width = 8, height = 6, dpi = 150)
#
#   Excel:
#     openxlsx::write.xlsx(my_results_df,
#                          file.path(config$output_folder, "results.xlsx"))


# =============================================================================
# 9. DONE
# =============================================================================
# TODO [DONE]: Replace the message below with a summary of what was produced.
message("[Step 8] Analysis complete.")
message("[Step 8] Output written to: ", config$output_folder)
cat("Step 8 complete.\n")
