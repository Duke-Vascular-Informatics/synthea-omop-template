#!/usr/bin/env Rscript
# =============================================================================
# workflow/08_run_analysis_and_manuscript_report.R
#
# Step 8 of the PAD / OLER SSI external validation workflow.
#
# PURPOSE
# -------
# This script ties together three sequential tasks:
#   1. Cohort instantiation  — builds the target (surgery) and outcome (SSI)
#      cohorts in the results schema from the OMOP CDM data loaded in Step 5.
#   2. Risk score analysis   — calculates the PAD SSI integer risk score for
#      every patient in the target cohort and evaluates discrimination and
#      calibration against the 30-day SSI outcome.
#   3. Report generation     — compiles all results into a manuscript-format
#      Word document (.docx) including Table 1 (cohort characteristics),
#      Table 2 (predictor activation), calibration plots, and summary metrics.
#
# PREREQUISITES
# -------------
#   - Step 5 (ETL) must have completed successfully and the OMOP CDM tables
#     must be populated in the active CDM schema.
#   - Step 7 (analysis environment setup) should have been run to verify the
#     results schema and cohort table exist.
#   - All R package dependencies must be installed (managed via renv).
#
# OUTPUTS
# -------
#   output/risk_score_eval/person_level_scores.csv   — one row per patient
#   output/risk_score_eval/component_summary.csv     — prevalence per component
#   output/risk_score_eval/metrics.csv               — discrimination/calibration
#   output/risk_score_eval/calibration_*.png/.csv    — calibration plots/tables
#   output/risk_score_eval/pad-oler-ssi-val_report_<date>.docx — full report
#
# EXECUTION
# ---------
#   Rscript workflow/08_run_analysis_and_manuscript_report.R
#   (Must be run from the project root directory in a FRESH R session.)
# =============================================================================


# -----------------------------------------------------------------------------
# 1. Locate and source the workflow bootstrap
# -----------------------------------------------------------------------------
# workflow_bootstrap.R sets the R working directory to the project root and
# provides set_workflow_root(), which is needed before any relative paths are
# used.  The bootstrap path is resolved from the --file= argument when the
# script is invoked via Rscript (so it works regardless of the shell's working
# directory), and falls back to the conventional relative path when sourced
# interactively from within RStudio or a running R session.
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
# 2. Java / JDBC session guard
# -----------------------------------------------------------------------------
# DatabaseConnector uses rJava under the hood.  The JVM can only be initialised
# once per R session, and certain JDBC driver state is not safely reusable if
# these packages were already loaded by an earlier script in the same session.
# This guard stops execution immediately with a clear message so the analyst
# knows to open a fresh R session rather than silently getting incorrect results
# or cryptic JVM errors.
loaded_java_ns <- intersect(
  c("rJava", "DatabaseConnector", "PatientLevelPrediction"),
  loadedNamespaces()
)
if (length(loaded_java_ns) > 0) {
  stop(
    "Run this script in a FRESH R session. Already loaded: ",
    paste(loaded_java_ns, collapse = ", ")
  )
}


# -----------------------------------------------------------------------------
# 3. Activate renv and load project dependencies
# -----------------------------------------------------------------------------
# renv/activate.R pins every package to the version recorded in renv.lock,
# ensuring reproducible results across machines and R installations.
# Source it before loading any libraries so renv's library paths take effect.
if (file.exists("renv/activate.R")) source("renv/activate.R")


# -----------------------------------------------------------------------------
# 4. Source project R modules
# -----------------------------------------------------------------------------
# Each file contributes a focused set of functions:
#   config.R              — get_validation_config() returns the master config
#                           list (database credentials, schema names, cohort
#                           IDs, prediction window, file paths, etc.)
#   R/drivers.R           — configure_java() sets the JDBC driver path and JVM
#                           heap size before DatabaseConnector is loaded.
#   R/connection.R        — build_connection_details() wraps DatabaseConnector's
#                           createConnectionDetails() with project defaults.
#   R/risk_score_pipeline.R — run_integer_risk_score_pipeline() queries the CDM
#                           for each score component, assigns points per patient,
#                           and evaluates discrimination and calibration.
#   R/cohorts.R           — ensure_results_schema() and build_cohorts()
#                           instantiate the target and outcome cohort SQL
#                           templates against the live CDM.
#   R/report_extended.R   — generate_manuscript_report() assembles all results
#                           into a Word document via officer and flextable.
source("config.R")
source("R/drivers.R")
source("R/connection.R")
source("R/risk_score_pipeline.R")
source("R/cohorts.R")
source("R/report_extended.R")


# -----------------------------------------------------------------------------
# 5. Initialise the JVM and load heavy packages
# -----------------------------------------------------------------------------
# configure_java() must be called before library(DatabaseConnector) to ensure
# the JVM is started with the correct heap size (-Xmx argument) and the JDBC
# driver JAR is on the class path.  Loading DatabaseConnector after this point
# picks up the pre-configured JVM rather than starting it with defaults.
# PatientLevelPrediction is loaded here because the pipeline uses its
# covariate-extraction helpers internally.
configure_java(get_validation_config())

library(DatabaseConnector)
library(PatientLevelPrediction)


# -----------------------------------------------------------------------------
# 6. Load configuration
# -----------------------------------------------------------------------------
# get_validation_config() reads config.R and returns a named list with all
# study parameters, including:
#   $server / $dbms / $port   — SQL Server connection details
#   $cdm_schema               — CDM schema name (may be overridden below)
#   $results_schema           — results/cohort schema (e.g. plp_results)
#   $cohort_table             — cohort table name (e.g. ssi_val_cohort)
#   $target_cohort_id         — cohort_definition_id for the surgery cohort (1)
#   $outcome_cohort_id        — cohort_definition_id for the SSI cohort (2)
#   $prediction_window_days   — follow-up window for outcome attribution (30)
#   $risk_score_output_folder — output directory for CSV and DOCX artefacts
message("[Step 8] Loading config ...")
config <- get_validation_config()


# -----------------------------------------------------------------------------
# 7. Resolve the active CDM schema
# -----------------------------------------------------------------------------
# Step 5 (ETL) auto-increments the CDM schema name on each run to avoid
# overwriting previous data (e.g. omop_synth_pad_oler_ssi_01,
# omop_synth_pad_oler_ssi_02, ...).  config.R may therefore point to a schema
# that is either out of date or does not yet exist on the current server.
#
# resolve_active_cdm_schema() queries sys.schemas for all schemas matching the
# project naming pattern, then probes each one for the three tables that must
# be present for a valid CDM (person, visit_occurrence, condition_occurrence).
# Among all valid candidates it selects the one with the highest person count,
# which corresponds to the most recently completed ETL run.  The fallback_schema
# argument is returned unchanged if no qualifying schema is found (e.g. on a
# fresh server before any ETL has been run).
resolve_active_cdm_schema <- function(connection_details, fallback_schema) {
  conn <- DatabaseConnector::connect(connection_details)
  on.exit(DatabaseConnector::disconnect(conn), add = TRUE)

  # Query all schemas whose name is exactly 'omop_synth_pad_oler_ssi' or
  # starts with that prefix followed by an underscore and a numeric suffix.
  # The bracket-escaped LIKE pattern [_] matches a literal underscore rather
  # than the SQL wildcard single-character match.
  candidate_sql <- "
    SELECT name
    FROM sys.schemas
    WHERE name = 'omop_synth_pad_oler_ssi'
       OR name LIKE 'omop_synth_pad_oler_ssi[_]%';"
  candidates <- DatabaseConnector::querySql(conn, candidate_sql, snakeCaseToCamelCase = TRUE)

  schema_names <- if (nrow(candidates) > 0) as.character(candidates$name) else character(0)
  if (length(schema_names) == 0L) {
    return(fallback_schema)
  }

  best_schema <- NA_character_
  best_n <- -1

  for (schema_name in schema_names) {
    # Escape any single quotes in the schema name to prevent SQL injection
    # (defensive — schema names from sys.schemas are system-controlled).
    safe_schema <- gsub("'", "''", schema_name, fixed = TRUE)

    # OBJECT_ID() returns NULL if the table does not exist in that schema,
    # so CASE WHEN ... IS NULL THEN 0 ELSE 1 END gives a simple presence flag.
    # The person row count (person_n) is used as the tiebreaker / recency proxy.
    probe_sql <- paste0(
      "SELECT ",
      "CASE WHEN OBJECT_ID('[", safe_schema, "].[person]', 'U') IS NULL THEN 0 ELSE 1 END AS has_person, ",
      "CASE WHEN OBJECT_ID('[", safe_schema, "].[visit_occurrence]', 'U') IS NULL THEN 0 ELSE 1 END AS has_visit_occurrence, ",
      "CASE WHEN OBJECT_ID('[", safe_schema, "].[condition_occurrence]', 'U') IS NULL THEN 0 ELSE 1 END AS has_condition_occurrence, ",
      "CASE WHEN OBJECT_ID('[", safe_schema, "].[person]', 'U') IS NULL THEN 0 ELSE (SELECT COUNT_BIG(*) FROM [", safe_schema, "].[person]) END AS person_n;"
    )

    # suppressWarnings + try: if the schema exists in sys.schemas but the probe
    # query fails for any reason (e.g. permissions), skip it gracefully.
    probe <- suppressWarnings(try(
      DatabaseConnector::querySql(conn, probe_sql, snakeCaseToCamelCase = TRUE),
      silent = TRUE
    ))
    if (inherits(probe, "try-error") || nrow(probe) == 0L) {
      next
    }

    # All three required tables must be present for the schema to qualify.
    has_required <- as.integer(probe$hasPerson[[1]])          == 1L &&
                    as.integer(probe$hasVisitOccurrence[[1]]) == 1L &&
                    as.integer(probe$hasConditionOccurrence[[1]]) == 1L
    if (!has_required) {
      next
    }

    # Pick the schema with the most persons (most complete / most recent ETL).
    n <- as.numeric(probe$personN[[1]])
    if (is.finite(n) && n > best_n) {
      best_n   <- n
      best_schema <- schema_name
    }
  }

  if (!is.na(best_schema)) best_schema else fallback_schema
}


# -----------------------------------------------------------------------------
# 8. Verify standard OMOP concept IDs
# -----------------------------------------------------------------------------
# Every concept ID hardcoded in this project — cohort SQL templates, risk score
# component queries, Table 1 indication/procedure rollup queries — is declared
# below and checked against the omop_vocab.concept table at runtime.
#
# For each concept the check confirms:
#   (a) the concept_id exists in the connected vocabulary
#   (b) standard_concept = 'S' (standard) or 'C' (classification, acceptable
#       for ATC drug ancestors used in drug rollup queries)
#   (c) invalid_reason IS NULL (concept is not deprecated or updated)
#
# If any concept fails the check the script emits a WARNING (not a stop) so
# that runs on vocabularies with minor version differences still complete,
# but the analyst is alerted to review the flagged concept before publishing.
#
# Concept IDs are organised by their role in the pipeline:
#   Cohort definitions  — used in cohorts/target_surgery.sql and
#                         cohorts/outcome_ssi.sql
#   Table 1 rollup      — used in the fetch_demographics_from_omop() SQL in
#                         R/report_extended.R
#   Risk score          — used in R/risk_score_pipeline.R component queries,
#                         sourced from risk_score/component_concepts.csv

verify_omop_concepts <- function(connection_details) {
  message("[Step 8] Verifying standard OMOP concept IDs ...")

  # Master concept registry: concept_id, role, acceptable standard_concept values.
  # 'S'  = Standard concept     — preferred for conditions, procedures, measurements.
  # 'C'  = Classification       — acceptable for ATC drug class ancestors.
  concepts <- data.frame(
    concept_id = c(
      # ---- Cohort definitions -------------------------------------------------
      4236706L,   # Arterial bypass of lower limb artery (SNOMED)
                  #   → target cohort bypass inclusion ancestor (target_surgery.sql)
      4225375L,   # Endarterectomy of lower limb artery (SNOMED)
                  #   → target cohort endarterectomy inclusion ancestor (target_surgery.sql)
                  #   → replaces 4159960 (Procedure on blood vessel of lower extremity)
                  #     which was too broad: included imaging studies and venous procedures
      4334801L,   # Surgical site infection (SNOMED 433202001)
                  #   → SSI washout exclusion (target_surgery.sql)
                  #   → outcome cohort ancestor (outcome_ssi.sql)

      # ---- Table 1: indication rollup (report_extended.R) ---------------------
      442774L,    # Intermittent claudication (SNOMED 63491006)
                  #   → claudication indication subgroup
      4325344L,   # Peripheral vascular disease with rest pain (SNOMED 428171009)
                  #   → rest pain indication subgroup
      4029926L,   # Ischemic ulcer (SNOMED 13954005)
                  #   → tissue loss indication subgroup

      # ---- Table 1: procedure type rollup (report_extended.R) -----------------
      4231680L,   # Aorto-femoral arterial bypass (SNOMED 405482000)
      4040974L,   # Femoral endarterectomy (SNOMED 16589005)
      4012936L,   # Femoral-popliteal artery bypass graft (SNOMED 112828007)
      4166196L,   # Femorotibial vascular bypass (SNOMED 47575002)

      # ---- Risk score components (component_concepts.csv) ---------------------
      8532L,      # FEMALE — person.gender_concept_id (Gender domain)
      # BMI — direct measurement (bmi_direct role, preferred):
      3038553L,   # Body mass index (BMI) [Ratio]          — LOINC 39156-5
      36304833L,  # Body mass index (BMI) [Ratio] Estimated — LOINC 59574-4
      # BMI — weight concepts (weight role, fallback):
      3025315L,   # Body weight                            — LOINC 29463-7
      3013762L,   # Body weight Measured                   — LOINC 3141-9
      3011054L,   # Body weight Measured --without clothes — LOINC 8335-2
      3026600L,   # Body weight Estimated                  — LOINC 8335-2 alt
      # BMI — height concepts (height role, fallback):
      3036277L,   # Body height                            — LOINC 8302-2
      3023540L,   # Body height Measured                   — LOINC 3137-7
      3015514L,   # Body height --standing                 — LOINC 8308-9
      4158569L,   # Emergency procedure — urgent case flag
      4250892L,   # Emergency operation — urgent case flag (alternate)
      40489833L,  # Ankle brachial pressure index — SNOMED 446841001
      46237026L,  # Ankle-brachial index — LOINC 77194-9 (alternate ABI)
      21603553L,  # Antibiotics — ATC class S01AA (prolonged antibiotic ancestor)
      4086506L,   # Frailty — SNOMED 248279007 (mFI functional status)
      4159704L,   # Functional independence measure — SNOMED 273469003 (mFI)
      4167605L,   # Barthel index — SNOMED 273302005 (mFI)
      4306934L,   # Impaired mobility — SNOMED 82971005 (mFI)
      42529379L,  # Transferring - functional ability — LOINC 83185-9 (Barthel)
      42529380L,  # Ambulation - functional ability — LOINC 83186-7 (Barthel)
      1616510L,   # Stairs - functional ability — LOINC 96758-8 (Barthel)
      201820L,    # Diabetes mellitus — SNOMED 73211009 (mFI comorbidity)
      255573L,    # Chronic obstructive pulmonary disease — SNOMED 13645005 (mFI)
      316139L,    # Heart failure — SNOMED 84114007 (mFI comorbidity)
      316866L,    # Hypertensive disorder — SNOMED 38341003 (mFI comorbidity)
      442774L     # Intermittent claudication — indicationClaudication score component
    ),
    acceptable_std = c(
      "S", "S", "S",            # cohort definitions (4236706, 4225375, 4334801)
      "S", "S", "S",            # indication rollup
      "S", "S", "S", "S",       # procedure rollup
      "S",                      # gender
      "S", "S",                 # BMI direct (3038553, 36304833)
      "S", "S", "S", "S",       # BMI weight variants (3025315, 3013762, 3011054, 3026600)
      "S", "S", "S",            # BMI height variants (3036277, 3023540, 3015514)
      "S", "S",                 # urgent case
      "S", "S",                 # ABI
      "C",                      # ATC antibiotic class (Classification, not Standard)
      "S", "S", "S", "S",       # mFI functional status
      "S", "S", "S",            # Barthel items
      "S", "S", "S", "S",       # mFI comorbidities
      "S"                       # claudication score component
    ),
    stringsAsFactors = FALSE
  )

  # De-duplicate so each concept_id is checked once.
  concepts <- concepts[!duplicated(concepts$concept_id), ]

  # Query vocab.
  conn <- tryCatch(DatabaseConnector::connect(connection_details), error = function(e) NULL)
  if (is.null(conn)) {
    warning("[Step 8] Could not connect to verify concept IDs — skipping check.")
    return(invisible(NULL))
  }
  on.exit(DatabaseConnector::disconnect(conn), add = TRUE)

  id_csv <- paste(concepts$concept_id, collapse = ", ")
  sql <- paste0(
    "SELECT concept_id, concept_name, vocabulary_id, domain_id, ",
    "       standard_concept, invalid_reason ",
    "FROM omop_vocab.concept ",
    "WHERE concept_id IN (", id_csv, ")"
  )
  vocab <- tryCatch(
    DatabaseConnector::querySql(conn, sql, snakeCaseToCamelCase = TRUE),
    error = function(e) NULL
  )

  if (is.null(vocab) || nrow(vocab) == 0) {
    warning("[Step 8] omop_vocab.concept query returned no rows — concept check skipped.")
    return(invisible(NULL))
  }

  # Merge registry with vocab result.
  # querySql() with snakeCaseToCamelCase = TRUE returns camelCase column names
  # (conceptId, conceptName, vocabularyId, standardConcept, invalidReason).
  result <- merge(concepts, vocab, by.x = "concept_id", by.y = "conceptId", all.x = TRUE)

  # Determine pass/fail for each concept.
  result$status <- mapply(function(std_actual, invalid, acceptable) {
    if (is.na(std_actual))  return("MISSING")
    if (!is.na(invalid))    return("DEPRECATED")
    if (std_actual == acceptable || (acceptable == "S" && std_actual == "C")) return("OK")
    return("NOT_STANDARD")
  }, result$standardConcept, result$invalidReason, result$acceptable_std)

  # Print formatted table.
  message("\n  OMOP Concept Verification\n  ", strrep("-", 90))
  for (i in seq_len(nrow(result))) {
    r   <- result[i, ]
    tag <- if (r$status == "OK") "  OK " else paste0(" !!! ", r$status)
    message(sprintf("  [%s] %7d  %-14s  %-8s  %s",
      tag,
      r$concept_id,
      ifelse(is.na(r$vocabularyId),    "NOT FOUND", r$vocabularyId),
      ifelse(is.na(r$standardConcept), "?",         r$standardConcept),
      ifelse(is.na(r$conceptName),     "(no match in vocab)", r$conceptName)
    ))
  }
  message("  ", strrep("-", 90))

  # Warn and summarise any failures.
  failures <- result[result$status != "OK", ]
  if (nrow(failures) > 0) {
    warning(
      "[Step 8] ", nrow(failures), " concept(s) failed the standard concept check:\n",
      paste0(
        sprintf("    concept_id %d (%s): %s",
          failures$concept_id, failures$status,
          ifelse(is.na(failures$conceptName), "NOT FOUND IN VOCAB", failures$conceptName)
        ),
        collapse = "\n"
      ),
      "\nReview these concept IDs before publishing results."
    )
  } else {
    message("  All ", nrow(result), " concept IDs verified as standard and active.\n")
  }

  invisible(result)
}


# -----------------------------------------------------------------------------
# 9. Establish database connection, verify concepts, and instantiate cohorts
# -----------------------------------------------------------------------------
# build_connection_details() returns a DatabaseConnector ConnectionDetails
# object (not yet an open connection) constructed from the credentials in config.
#
# resolve_active_cdm_schema() is then called to pin config$cdm_schema to the
# schema that was actually populated by the most recent ETL run.  All downstream
# queries — cohort SQL, covariate queries, demographic queries — use
# config$cdm_schema, so overriding it here ensures they all target the same data.
#
# ensure_results_schema() creates the results schema (e.g. plp_results) and
# the cohort table (e.g. ssi_val_cohort) if they do not already exist.  It is
# idempotent — safe to call on every run.
#
# build_cohorts() executes the two SqlRender-parameterised cohort SQL templates:
#   cohorts/target_surgery.sql  — adults with qualifying inpatient open lower-
#                                  extremity revascularisation (concepts 4236706, 4225375)
#   cohorts/outcome_ssi.sql     — first SSI diagnosis within the study window
#                                  (concept 4334801 and descendants)
# Both cohort definitions DELETE their rows from the cohort table before
# inserting, so re-running this step always produces a fresh, non-duplicated
# cohort.  The connection is explicitly disconnected after cohort build to
# release the JDBC connection slot before the pipeline opens its own connection.
message("[Step 8] Preparing cohorts ...")
connection_details <- build_connection_details(config)
config$cdm_schema  <- resolve_active_cdm_schema(connection_details, config$cdm_schema)
message("[Step 8] Using CDM schema: ", config$cdm_schema)

# Verify all standard OMOP concept IDs before any cohort or analysis work.
# This confirms every concept used in cohort SQL, score queries, and Table 1
# rollup queries is present, standard, and not deprecated in the connected
# vocabulary.  A WARNING (not a stop) is emitted for any failing concept.
verify_omop_concepts(connection_details)

cohort_conn <- DatabaseConnector::connect(connection_details)
ensure_results_schema(cohort_conn, config)
build_cohorts(cohort_conn, config)
DatabaseConnector::disconnect(cohort_conn)


# -----------------------------------------------------------------------------
# 10. Run the integer risk score pipeline
# -----------------------------------------------------------------------------
# run_integer_risk_score_pipeline() (R/risk_score_pipeline.R) performs five
# sub-steps and returns a named list with elements $person_level,
# $component_summary, and $metrics:
#
#   a) Read spec files — loads risk_score/components.csv (component definitions:
#      ID, domain, lookback window, point value) and
#      risk_score/component_concepts.csv (OMOP concept IDs for each component).
#
#   b) Calculate scores — for each of the 10 components, queries the CDM to
#      count qualifying events per patient within the specified lookback window,
#      then assigns points according to components.csv.  Results are stored in
#      a wide person-level matrix (one column per component score).
#      The total integer score is the row sum of all component columns.
#
#   c) Map to predicted risk — applies the lookup table (risk_score/
#      risk_lookup.csv) to convert each integer score to a predicted probability,
#      and fits a recalibrated logistic regression on the integer score as a
#      single predictor.
#
#   d) Evaluate discrimination — computes AUROC and AUPRC for both the lookup
#      and recalibrated models.
#
#   e) Evaluate calibration — computes Brier score, estimated calibration error
#      (ECE, 10 equal-frequency bins), calibration intercept, and calibration
#      slope.  Generates calibration plots and saves them to the output folder.
#
#   f) Write outputs — saves person_level_scores.csv, component_summary.csv,
#      metrics.csv, calibration_table_lookup.csv, and calibration PNG files to
#      config$risk_score_output_folder.
#
# The metrics data frame is printed to the console immediately after the
# pipeline returns so the analyst can review key numbers before the report is
# compiled.
message("[Step 8] Running integer risk score analysis ...")
results <- run_integer_risk_score_pipeline(config, connection_details)
print(results$metrics)


# -----------------------------------------------------------------------------
# 11. Generate the manuscript report
# -----------------------------------------------------------------------------
# generate_manuscript_report() (R/report_extended.R) reads the CSV outputs
# written in step 9 and compiles them into a Word document using the officer
# and flextable packages.  The report contains:
#
#   Table 1 — Cohort characteristics
#     Queries the CDM directly (using connection_details and config) to populate
#     demographic rows (age median/IQR, sex, race, ethnicity) and clinical rows
#     (indication subgroups via concept_ancestor rollup, procedure type subgroups
#     via concept_ancestor rollup at the index visit, 30-day SSI outcome count).
#     All demographic queries use a dedup_person CTE to handle any duplicate
#     person rows from repeated ETL runs.
#
#   Table 2 — Predictor activation
#     Lists each of the 10 risk score components with its point value, lookback
#     window, OMOP CDM derivation method, and the observed activation count and
#     rate in the validation cohort.
#
#   Table 3 — Summary metrics
#     Reads metrics.csv and presents AUROC, AUPRC, Brier score, ECE,
#     calibration intercept, and calibration slope for both the published lookup
#     model and the recalibrated logistic model.
#
#   Calibration plots — lookup model and recalibrated model calibration curves
#     (mean predicted vs. mean observed risk per decile of predicted risk).
#
#   ROC curve — receiver operating characteristic curve for the lookup model.
#
#   Manuscript text — Methods and Results sections with inline values drawn
#     from the data (cohort N, event rate, AUROC, etc.).
#
# connection_details and config are passed explicitly so that the demographic
# database queries inside the function use the same connection parameters and
# resolved CDM schema as the rest of this script.  Without these arguments the
# function would have no database access and Table 1 would be empty.
#
# cleanup_old_outputs = FALSE preserves all previous report versions in the
# output folder (they are auto-numbered _2, _3, etc.) so no work is lost if
# the script is re-run.
message("[Step 8] Generating manuscript report ...")
report_path <- generate_manuscript_report(
  output_dir          = config$risk_score_output_folder,
  score_output_dir    = config$risk_score_output_folder,
  cleanup_old_outputs = FALSE,
  connection_details  = connection_details,
  config              = config
)

message("[Step 8] Report written to: ", report_path)

cat("Step 8 complete: analysis executed and manuscript report generated.\n")
