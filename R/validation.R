# =============================================================================
# R/validation.R
# Run external validation of a pre-trained PatientLevelPrediction (PLP v6)
# model on the Synthea OMOP database.
#
# The main exported function is run_external_validation(config,
# connectionDetails).  It:
#   1. Loads the plpResult saved by the original training study.
#   2. Builds PLP database-details and validation settings objects.
#   3. Calls PatientLevelPrediction::externalValidateDbPlp().
#   4. Saves results to config$output_folder and returns the result list.
# =============================================================================

# ---------------------------------------------------------------------------
# Load, and minimally validate, the pre-trained plpResult from disk.
# ---------------------------------------------------------------------------
load_plp_model <- function(model_path) {
  if (!dir.exists(model_path)) {
    stop(
      "Pre-trained model folder not found: ", model_path, "\n",
      "Set config$model_path in config.R to the plpResult output folder ",
      "produced by the original SSI development study."
    )
  }

  message("Loading pre-trained PLP result from: ", model_path)
  plp_result <- PatientLevelPrediction::loadPlpResult(dirPath = model_path)

  if (is.null(plp_result$model)) {
    stop("Loaded plpResult does not contain a model object.  ",
         "Ensure model_path points to a complete plpResult directory.")
  }

  message("Model loaded: ",
          plp_result$model$modelDesign$modelType %||% "(model type unknown)")
  plp_result
}

# Null-coalescing helper – avoids importing rlang just for `%||%`
`%||%` <- function(a, b) if (!is.null(a)) a else b

# ---------------------------------------------------------------------------
# Build the PLP database-details object describing the validation database.
# ---------------------------------------------------------------------------
build_database_details <- function(config, connection_details) {
  PatientLevelPrediction::createDatabaseDetails(
    connectionDetails      = connection_details,
    cdmDatabaseSchema      = config$cdm_schema,
    cdmDatabaseId          = config$cdm_database_id,
    cdmDatabaseName        = config$cdm_database_name,
    cdmDatabaseDescription = config$cdm_database_description,
    cohortDatabaseSchema   = config$results_schema,
    cohortTable            = config$cohort_table,
    outcomeDatabaseSchema  = config$results_schema,
    outcomeTable           = config$cohort_table,
    cdmVersion             = config$cdm_version
  )
}

# ---------------------------------------------------------------------------
# Build RestrictPlpDataSettings – constrains the patient-level data pull to
# the study window and applies standard population filters.
# ---------------------------------------------------------------------------
build_restrict_settings <- function(config) {
  PatientLevelPrediction::createRestrictPlpDataSettings(
    studyStartDate = config$study_start_date,
    studyEndDate   = config$study_end_date
  )
}

# ---------------------------------------------------------------------------
# Build ValidationSettings – controls optional recalibration applied to the
# model before performance metrics are computed.
# ---------------------------------------------------------------------------
build_validation_settings <- function() {
  PatientLevelPrediction::createValidationSettings(
    # Apply two recalibration strategies so performance is assessed both
    # with and without domain shift correction.
    recalibrate        = c("weakRecalibration", "RecalibrationinTheLarge"),
    runCovariateSummary = TRUE
  )
}

# ---------------------------------------------------------------------------
# Ensure the output folder exists.
# ---------------------------------------------------------------------------
prepare_output_folder <- function(config) {
  dir.create(config$output_folder, recursive = TRUE, showWarnings = FALSE)
  message("Output will be written to: ", normalizePath(config$output_folder,
                                                       winslash = "/",
                                                       mustWork = FALSE))
  invisible(config$output_folder)
}

# ---------------------------------------------------------------------------
# Main validation function.
# ---------------------------------------------------------------------------
run_external_validation <- function(config, connection_details) {

  # 1. Load the pre-trained model
  plp_result <- load_plp_model(config$model_path)

  # 2. Build PLP settings
  db_details       <- build_database_details(config, connection_details)
  restrict_settings <- build_restrict_settings(config)
  val_settings      <- build_validation_settings()
  output_folder     <- prepare_output_folder(config)

  log_settings <- PatientLevelPrediction::createLogSettings(
    verbosity = "INFO",
    logName   = "SSI External Validation"
  )

  # 3. Run external validation
  message("\n=== Running external validation ===")
  message("  Target cohort  : ", config$target_cohort_id)
  message("  Outcome cohort : ", config$outcome_cohort_id)
  message("  CDM schema     : ", config$cdm_schema)
  message("  Results schema : ", config$results_schema)
  message("  Output folder  : ", output_folder)

  validation_result <- PatientLevelPrediction::externalValidateDbPlp(
    plpResultList                      = list(plp_result),
    validationDatabaseDetails          = db_details,
    validationRestrictPlpDataSettings  = restrict_settings,
    settings                           = val_settings,
    logSettings                        = log_settings,
    outputFolder                       = output_folder
  )

  message("\n=== Validation complete ===")
  message("Results saved to: ", output_folder)

  invisible(validation_result)
}

# ---------------------------------------------------------------------------
# Summarise key performance metrics to the console.
# ---------------------------------------------------------------------------
print_performance_summary <- function(validation_result) {
  if (is.null(validation_result)) {
    message("No validation result available to summarise.")
    return(invisible(NULL))
  }

  # PLP v6 stores per-database performance under $validation[[1]]$performanceEvaluation
  tryCatch({
    perf <- validation_result[[1]]$performanceEvaluation$evaluationStatistics
    if (!is.null(perf)) {
      cat("\n--- Performance summary ---\n")
      key_metrics <- c("AUROC", "AUPRC", "brier score", "calibration in the large")
      print(perf[perf$metric %in% key_metrics, c("metric", "value", "evaluation")])
    }
  }, error = function(e) {
    message("Could not extract performance summary: ", conditionMessage(e))
  })

  invisible(validation_result)
}
