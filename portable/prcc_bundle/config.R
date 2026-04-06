# =============================================================================
# config.R — PAD/OLER SSI Validation Bundle — Duke PRCC Configuration
#
# Fill in the CHANGE_ME values for your PRCC environment before running.
# All other settings (risk score files, output folder, prediction window)
# can be left at their defaults.
#
# Authentication: Kerberos (NetID). Run setup_prcc_env.sh first to obtain
# a Kerberos ticket. Java is provided by the conda openjdk environment; this
# script resolves JAVA_HOME automatically from the active environment.
# =============================================================================

get_validation_config <- function() {

  # ---------------------------------------------------------------------------
  # Java — resolved automatically from the conda openjdk environment.
  # Run `conda activate openjdk` BEFORE starting R so that JAVA_HOME is set.
  # ---------------------------------------------------------------------------
  java_home <- Sys.getenv("JAVA_HOME")
  if (nchar(trimws(java_home)) == 0) {
    # Fallback: resolve from the running java binary on PATH
    java_bin_path <- trimws(system("which java 2>/dev/null", intern = TRUE))
    if (length(java_bin_path) > 0 && nchar(java_bin_path) > 0) {
      java_home <- normalizePath(file.path(dirname(java_bin_path), ".."),
                                 mustWork = FALSE)
    }
  }
  if (nchar(trimws(java_home)) == 0) {
    stop(
      "JAVA_HOME is not set and 'java' is not on PATH.\n",
      "Run: conda activate openjdk\n",
      "Then re-launch R from the same shell."
    )
  }

  # ---------------------------------------------------------------------------
  # JDBC driver — bundled JAR in drivers/ (no download needed)
  # ---------------------------------------------------------------------------
  jdbc_runtime_dir <- file.path(getwd(), "drivers")

  # ---------------------------------------------------------------------------
  # SQL Server connection — FILL IN THESE VALUES
  # ---------------------------------------------------------------------------
  list(
    # Java
    java_home        = java_home,
    jdbc_runtime_dir = jdbc_runtime_dir,

    # ---- UPDATE THESE -------------------------------------------------------
    # SQL Server hostname (e.g. "dbserver01.dhe.duke.edu")
    server           = "CHANGE_ME",

    # Database name containing your OMOP CDM
    database         = "CHANGE_ME",

    # Kerberos SPN host — usually the same as server.
    # Format: just the hostname, NOT the full "MSSQLSvc/..." prefix.
    # If unsure, open a ticket with DHTS/SOM-HPC.
    spn_host         = "CHANGE_ME",

    # Schema holding shared OMOP vocabulary tables
    # (concept, concept_ancestor, concept_relationship, etc.)
    vocab_schema     = "CHANGE_ME",

    # CDM schema (person, visit_occurrence, condition_occurrence, etc.)
    cdm_schema       = "CHANGE_ME",

    # Results schema — will be created if it does not exist.
    # Your NetID must have CREATE TABLE permission in this schema.
    results_schema   = "CHANGE_ME",
    # ---- END UPDATE ---------------------------------------------------------

    dbms             = "sql server",
    cohort_table     = "pad_ssi_val_cohort",

    # Cohort definition IDs written into the cohort table
    target_cohort_id  = 1L,
    outcome_cohort_id = 2L,

    # ---------------------------------------------------------------------------
    # Pre-existing ATLAS cohorts (optional).
    # Set use_atlas_cohorts = TRUE if target/outcome cohorts are already in your
    # results schema from ATLAS. Set the corresponding cohort IDs.
    # When FALSE, cohorts are built from the SQL templates in cohorts/.
    # ---------------------------------------------------------------------------
    use_atlas_cohorts       = FALSE,
    atlas_cohort_schema     = "results",
    atlas_cohort_table      = "cohort",
    atlas_target_cohort_id  = NA_integer_,   # e.g. 1796269L
    atlas_outcome_cohort_id = NA_integer_,   # e.g. 1796278L

    # ---------------------------------------------------------------------------
    # Risk score pipeline settings
    # ---------------------------------------------------------------------------
    risk_score_components_file = file.path(getwd(), "risk_score", "components.csv"),
    risk_score_concepts_file   = file.path(getwd(), "risk_score", "component_concepts.csv"),
    risk_score_lookup_file     = file.path(getwd(), "risk_score", "risk_lookup.csv"),
    risk_score_output_folder   = file.path(getwd(), "output", "risk_score_eval"),

    # SSI attribution window in days after the index procedure date.
    # 90 days matches the PRCC validation study design.
    prediction_window_days     = 90L,

    # Study date window — adjust to match your CDM coverage.
    study_start_date = "2010-01-01",
    study_end_date   = "2023-12-31",

    # Database identifier metadata (written into output files)
    cdm_database_id          = "CHANGE_ME",   # e.g. "duke_omop_v5.4"
    cdm_database_name        = "CHANGE_ME",   # e.g. "Duke SOM OMOP CDM"
    cdm_database_description = "CHANGE_ME"    # free-text description
  )
}
