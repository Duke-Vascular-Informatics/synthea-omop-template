#!/usr/bin/env Rscript
# =============================================================================
# workflow/07_setup_analysis_env.R
#
# Step 7: Verify that all R packages required by Step 8 are installed.
#
# PURPOSE
# -------
# Checks that every package your Step 8 analysis needs is present in the renv
# library. Fails fast with an actionable message if anything is missing, so
# you discover installation gaps before running the full analysis.
#
# This step does NOT install packages. Run setup/install_packages.R first.
#
# PREREQUISITES
# -------------
#   - renv has been initialised (setup/setup_renv.R run once).
#   - Project packages have been installed (setup/install_packages.R run once).
#   - Java >= 11 is installed and JAVA_HOME is set (required for
#     DatabaseConnector regardless of analysis type).
#
# EXECUTION
# ---------
#   Rscript workflow/07_setup_analysis_env.R
# =============================================================================


# -----------------------------------------------------------------------------
# 1. Workflow bootstrap
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
# 2. Activate renv
# -----------------------------------------------------------------------------
if (file.exists("renv/activate.R")) source("renv/activate.R")


# -----------------------------------------------------------------------------
# 3. Package list
# -----------------------------------------------------------------------------
# TODO [PACKAGES]: List every R package that Step 8 loads or calls.
#
# DatabaseConnector and SqlRender are almost always required for OMOP studies
# and are included by default. Add your analysis-specific packages below.
#
# DEPENDENCY CHAIN — why certain packages must be listed together:
#
#   PatientLevelPrediction REQUIRES FeatureExtraction.
#     PLP does not extract covariates itself — it delegates to FeatureExtraction
#     to build the feature matrix from the OMOP CDM. Both must be installed and
#     listed here even if you never call FeatureExtraction functions directly.
#
#   CohortMethod REQUIRES FeatureExtraction.
#     CohortMethod uses FeatureExtraction internally to build the covariate
#     table for propensity score estimation. Same rule applies.
#
#   DatabaseConnector loads before PatientLevelPrediction / CohortMethod.
#     These HADES packages open their own database connections internally using
#     DatabaseConnector — they do not accept raw SQL Server connections. Always
#     load DatabaseConnector first and ensure JAVA_HOME is set before any call
#     to these packages (see the Java guard in Section 2 of Step 8).
#
# Reference lists by study design:
#
#   Cohort characterization
#   ────────────────────────
#   "FeatureExtraction"   — extracts standardised patient features (demographics,
#                           conditions, drugs, procedures) from the OMOP CDM;
#                           used to describe the target cohort
#   "CohortDiagnostics"   — validates cohort phenotypes: incidence, attrition,
#                           time distributions, concept prevalence
#   "Eunomia"             — lightweight synthetic OMOP CDM for local testing
#                           (optional; remove before running against real data)
#
#   Prognostic modelling
#   ────────────────────
#   "PatientLevelPrediction"  — end-to-end supervised learning pipeline for OMOP:
#                               data extraction, model training, evaluation, and
#                               output (AUROC, calibration, feature importance)
#   "FeatureExtraction"       — REQUIRED by PatientLevelPrediction; builds the
#                               patient-feature matrix from the CDM
#   "pROC"                    — computes AUROC and confidence intervals for model
#                               discrimination (used in external validation)
#   "PRROC"                   — computes area under precision-recall curve (AUPRC);
#                               more informative than AUROC when outcome is rare
#   "ggplot2"                 — calibration plots, ROC curves, feature importance
#   "officer"                 — creates Word (.docx) reports programmatically
#   "flextable"               — formats tables for Word / HTML output
#
#   Causal inference
#   ────────────────
#   "CohortMethod"             — active comparator new-user cohort design;
#                                propensity score estimation, matching/weighting,
#                                and outcome modelling (HR, RR, OR)
#   "SelfControlledCaseSeries" — SCCS design; each patient is their own control;
#                                useful when confounding by indication is high
#   "EvidenceSynthesis"        — meta-analysis across multiple databases or sites
#   "FeatureExtraction"        — REQUIRED by CohortMethod; builds covariates for
#                                propensity score model
#   "EmpiricalCalibration"     — calibrates p-values and CIs using negative
#                                controls to correct for residual confounding
#
#   General utilities (add as needed)
#   ──────────────────────────────────
#   "dplyr"     — data frame manipulation (filter, mutate, join, summarise)
#   "readr"     — fast CSV reading / writing
#   "tidyr"     — data reshaping (pivot_longer, pivot_wider, unnest)
#   "ggplot2"   — grammar-of-graphics plotting
#   "officer"   — Word document generation
#   "flextable" — formatted tables in Word / HTML
#   "openxlsx"  — Excel (.xlsx) output with formatting
#   "knitr"     — R Markdown report rendering

required <- c(
  # --- Always required for OMOP database access ---
  "DatabaseConnector",   # JDBC connectivity to OMOP CDM
  "SqlRender",           # SQL dialect translation and parameterisation

  # --- TODO [PACKAGES]: Add your analysis packages below ---
  # "PatientLevelPrediction",
  # "FeatureExtraction",
  # "CohortMethod",
  # "CohortDiagnostics",
  # "dplyr",
  # "ggplot2",
  # "officer",
  # "flextable",
  # "pROC",
  # "PRROC",
  NULL  # trailing NULL so every line above can end with a comma safely
)

# Remove any NULLs (from the trailing NULL above).
required <- required[!vapply(required, is.null, logical(1L))]


# -----------------------------------------------------------------------------
# 4. Check packages
# -----------------------------------------------------------------------------
missing_pkgs <- required[
  !vapply(required, requireNamespace, logical(1L), quietly = TRUE)
]

if (length(missing_pkgs) > 0) {
  stop(
    "The following packages required by Step 8 are not installed:\n",
    paste0("  - ", missing_pkgs, collapse = "\n"),
    "\n\nAdd them to setup/install_packages.R and re-run that script,",
    "\nthen re-run Step 7."
  )
}

message("Package check passed. ", length(required), " package(s) verified:")
for (pkg in required) {
  ver <- tryCatch(as.character(utils::packageVersion(pkg)), error = function(e) "?")
  message(sprintf("  %-35s %s", pkg, ver))
}


# -----------------------------------------------------------------------------
# 5. Verify JDBC driver bundle
# -----------------------------------------------------------------------------
# DatabaseConnector requires a JDBC driver regardless of analysis type.
# ensure_jdbc_bundle() downloads it once if not already present.
source("config.R")
source("R/drivers.R")
config <- get_validation_config()
ensure_jdbc_bundle(config)
message("JDBC driver verified: ",
        file.path(config$jdbc_runtime_dir,
                  paste0("mssql-jdbc-", config$sql_server_jdbc_version, ".jre11.jar")))


# -----------------------------------------------------------------------------
# 6. Done
# -----------------------------------------------------------------------------
message("\nStep 7 complete: analysis environment is ready for Step 8.")
message("Next: Rscript workflow/08_run_analysis_and_manuscript_report.R")
