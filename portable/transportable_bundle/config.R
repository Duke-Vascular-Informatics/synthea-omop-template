# =============================================================================
# config.R — Portable Bundle Configuration
#
# Institution-specific connection values are read from environment variables.
# Set them in a .env file at the bundle root or export them in your shell
# before launching R.  See .env.example for the full list.
#
# Authentication: Kerberos (NetID). Run setup_env.sh first to obtain
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
  # Institution-provided JDBC wrapper JAR — required for Kerberos authentication.
  # Set OMOP_HPC_JAR in .env to the absolute path of this file.
  # If your institution does not require a custom wrapper, set OMOP_HPC_JAR=""
  # and update configure_java_hpc() in R/connection.R accordingly.
  # ---------------------------------------------------------------------------
  hpc_jar_default <- file.path(
    dirname(normalizePath(getwd(), mustWork = FALSE)),
    "drivers",
    "hpc-jdbc-wrapper.jar"
  )
  hpc_jar <- Sys.getenv("OMOP_HPC_JAR", unset = hpc_jar_default)

  # ---------------------------------------------------------------------------
  # SQL Server connection — FILL IN THESE VALUES
  # ---------------------------------------------------------------------------
  list(
    # Java
    java_home        = java_home,
    jdbc_runtime_dir = jdbc_runtime_dir,
    hpc_jar         = hpc_jar,

    # ---- CONNECTION (read from environment variables — set in .env) ---------
    # SQL Server hostname. Omit the port when using the default (1433).
    # Only include ":port" if the instance uses a non-standard port.
    server           = Sys.getenv("OMOP_SERVER",   unset = "YOUR_SERVER.example.com"),

    # Database containing the OMOP CDM (read-only access is sufficient).
    database         = Sys.getenv("OMOP_DATABASE", unset = "YOUR_DATABASE"),

    # Kerberos SPN host — the hostname portion only (no port, no MSSQLSvc/ prefix).
    # When a non-default port is used the SPN format is MSSQLSvc/<host>:<port>
    # — connection.R appends the port automatically from config$server.
    # Contact your HPC support team if unsure of the correct SPN hostname.
    spn_host         = Sys.getenv("OMOP_SPN_HOST", unset = "YOUR_SPN_HOST"),

    # Schema holding shared OMOP vocabulary tables
    # (concept, concept_ancestor, concept_relationship, etc.)
    vocab_schema     = Sys.getenv("OMOP_VOCAB_SCHEMA", unset = "omop_vocab"),

    # CDM schema (person, visit_occurrence, condition_occurrence, etc.)
    cdm_schema       = Sys.getenv("OMOP_CDM_SCHEMA",   unset = "omop_cdm"),

    # Results database — the database where cohort tables will be written.
    # This may differ from the CDM database if you only have read access to
    # the CDM but write access to a separate scratch/results database.
    # Leave as NA to use the same database as the CDM.
    results_database = NA,

    # Results schema within the results database (your personal write schema).
    results_schema   = Sys.getenv("OMOP_RESULTS_SCHEMA", unset = "your_results_schema"),
    # ---- END CONNECTION -----------------------------------------------------

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
    model_name                 = "my_study",   # TODO: set to your study identifier
    risk_score_lookup_file     = file.path(getwd(), "risk_score", "risk_lookup.csv"),
    risk_score_output_folder   = file.path(getwd(), "output", "risk_score_eval"),

    # Keys used internally by risk_score_pipeline.R — point to the covariate
    # definition CSVs copied into risk_score/ by workflow/09.
    covariate_definitions_file = file.path(getwd(), "risk_score", "covariates.csv"),
    covariate_concepts_file    = file.path(getwd(), "risk_score", "covariate_concepts.csv"),
    output_folder              = file.path(getwd(), "output", "risk_score_eval"),

    # SSI attribution window in days after the index procedure date.
    # 90 days matches the HPC cluster validation study design.
    prediction_window_days     = 90L,

    # Study date window — adjust to match your CDM coverage.
    study_start_date = "2010-01-01",
    study_end_date   = "2023-12-31",

    # Database identifier metadata (written into output files)
    cdm_database_id          = Sys.getenv("OMOP_CDM_DATABASE_ID",          unset = "your_cdm_v5.4"),
    cdm_database_name        = Sys.getenv("OMOP_CDM_DATABASE_NAME",        unset = "Your Institution OMOP CDM"),
    cdm_database_description = Sys.getenv("OMOP_CDM_DATABASE_DESCRIPTION", unset = "Brief description of the patient population and database.")
  )
}
