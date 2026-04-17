# =============================================================================
# config.R
# Central configuration for your OMOP validation / analysis study.
# All database connection, schema, cohort, file path, and study settings
# live here. This is the single source of truth for Steps 2–9.
#
# TEMPLATE SETUP — Complete all TODO items before running any workflow step.
# Search for "TODO [CONFIG]:" to find every placeholder that needs your input.
# Infrastructure settings (JDBC, Java, SQL Server connection) are pre-wired
# for the dev container and typically do not need changes.
# =============================================================================

get_validation_config <- function() {

  # ---------------------------------------------------------------------------
  # JDBC / Java setup — self-contained under this project's drivers/ folder.
  # On first run, R/drivers.R downloads and extracts the JDBC bundle here.
  # java_home is read from the JAVA_HOME env var (set in the dev container);
  # falls back to the Windows path for legacy Windows runs outside the container.
  # ---------------------------------------------------------------------------
  java_home        <- Sys.getenv("JAVA_HOME",
                        unset = "C:/Program Files/Eclipse Adoptium/jdk-17.0.18.8-hotspot")
  sql_server_jdbc_version <- "13.2.1"
  path_to_driver   <- file.path(getwd(), "drivers")
  jdbc_home        <- file.path(path_to_driver, "sqljdbc_13.2", "enu")
  jdbc_runtime_dir <- file.path(path_to_driver, "jdbc-runtime")

  list(

    # -------------------------------------------------------------------------
    # Java / JDBC
    # -------------------------------------------------------------------------
    java_home               = java_home,
    java_bin                = file.path(java_home, "bin"),
    sql_server_jdbc_version = sql_server_jdbc_version,
    jdbc_zip_url            = "https://go.microsoft.com/fwlink/?linkid=2338346&clcid=0x409",
    path_to_driver          = path_to_driver,
    jdbc_home               = jdbc_home,
    jdbc_jar_folder         = file.path(jdbc_home, "jars"),
    jdbc_runtime_dir        = jdbc_runtime_dir,
    jdbc_auth_dir           = file.path(jdbc_home, "auth", "x64"),

    # -------------------------------------------------------------------------
    # SQL Server connection
    # MSSQL_HOST defaults to localhost (macOS/Windows direct); set to mssql_dev
    # inside the dev container via the MSSQL_HOST environment variable.
    # -------------------------------------------------------------------------
    dbms             = "sql server",
    server           = Sys.getenv("MSSQL_HOST", unset = "localhost"),
    user             = "SA",
    password         = Sys.getenv("MSSQL_SA_PASSWORD", unset = "P@ssw0rd!"),
    database         = "omop_synth",
    sql_server_port  = 1433L,

    # Shared vocabulary schema — loaded once via scripts/setup_omop_vocab_schema.R.
    vocab_schema     = "omop_vocab",

    # -------------------------------------------------------------------------
    # TODO [CONFIG]: CDM schema name.
    # Schema containing the OMOP CDM tables populated by Step 5 (ETL).
    # Example: "cdm_my_study_01"
    # -------------------------------------------------------------------------
    cdm_schema   = "cdm_my_study",    # <-- REPLACE with your CDM schema name
    cdm_version  = 5L,

    # -------------------------------------------------------------------------
    # TODO [CONFIG]: Results / work schema.
    # Created automatically if absent. Use a study-specific name.
    # Example: "my_study_results"
    # -------------------------------------------------------------------------
    results_schema = "my_study_results",    # <-- REPLACE with your results schema name

    # -------------------------------------------------------------------------
    # TODO [CONFIG]: Cohort table name.
    # Holds target, comparator (if any), and outcome cohort rows.
    # Use a study-specific name to avoid conflicts on shared servers.
    # Example: "my_study_cohort"
    # -------------------------------------------------------------------------
    cohort_table = "my_study_cohort",    # <-- REPLACE with your cohort table name

    # -------------------------------------------------------------------------
    # Cohort IDs — integer identifiers for each cohort population.
    # These are used as cohort_definition_id in the cohort table.
    #
    # TODO [CONFIG]: Add or remove cohort IDs to match your study design.
    #   • Cohort characterization: only target_cohort_id needed.
    #   • Prognostic modelling:    target_cohort_id + outcome_cohort_id.
    #   • Causal inference:        all three (set comparator_cohort_id).
    # -------------------------------------------------------------------------
    target_cohort_id     = 1L,
    comparator_cohort_id = NA_integer_,    # <-- SET to an integer (e.g. 2L) for causal inference;
                                           #     leave NA for cohort characterization / prognostic
    outcome_cohort_id    = 2L,

    # -------------------------------------------------------------------------
    # Cohort SQL file paths.
    # build_cohorts() (R/cohorts.R) reads these to instantiate cohorts.
    #
    # TODO [CONFIG]: Update each path to match your renamed SQL files.
    # Set comparator_cohort_sql to NULL if no comparator cohort is needed.
    # The SQL files themselves are templated in cohorts/ — edit them first.
    # -------------------------------------------------------------------------
    target_cohort_sql     = file.path("cohorts", "target_surgery.sql"),   # <-- RENAME to match your file
    comparator_cohort_sql = NULL,                                          # <-- SET path or leave NULL
    outcome_cohort_sql    = file.path("cohorts", "outcome_ssi.sql"),       # <-- RENAME to match your file

    # -------------------------------------------------------------------------
    # Existing ATLAS cohorts (optional).
    # If use_atlas_cohorts = TRUE the target cohort is copied from ATLAS rather
    # than being instantiated from the local SQL file.
    # -------------------------------------------------------------------------
    use_atlas_cohorts       = FALSE,
    atlas_cohort_schema     = "results",
    atlas_cohort_table      = "cohort",
    atlas_target_cohort_id  = NA_integer_,
    atlas_outcome_cohort_id = NA_integer_,

    # -------------------------------------------------------------------------
    # TODO [CONFIG]: Study name / identifier.
    # Used for output file naming and report metadata.
    # Lowercase letters, numbers, underscores only. No spaces.
    # Example: "hip_replace_vte", "colectomy_ssi_30day"
    # -------------------------------------------------------------------------
    study_name = "my_study",    # <-- REPLACE with your study identifier

    # -------------------------------------------------------------------------
    # Covariate / feature definition files.
    # Used by R/risk_score_pipeline.R or custom covariate extraction code.
    # Set to NULL if using FeatureExtraction settings objects instead of CSVs.
    # -------------------------------------------------------------------------
    covariate_components_file = file.path("risk_score", "components.csv"),
    covariate_concepts_file   = file.path("risk_score", "component_concepts.csv"),
    covariate_lookup_file     = file.path("risk_score", "risk_lookup.csv"),

    # -------------------------------------------------------------------------
    # TODO [CONFIG]: Prediction / follow-up window (days).
    # Number of days after the index date during which the outcome is counted.
    # Examples: 30, 90, 365.
    # -------------------------------------------------------------------------
    prediction_window_days = 90L,    # <-- REPLACE with your follow-up window

    # -------------------------------------------------------------------------
    # TODO [CONFIG]: Study date window.
    # Index events outside this window are excluded from all cohorts.
    # -------------------------------------------------------------------------
    study_start_date = "2017-01-01",    # <-- REPLACE with your study start date
    study_end_date   = "2025-12-31",    # <-- REPLACE with your study end date

    # -------------------------------------------------------------------------
    # TODO [CONFIG]: Output folder.
    # All analysis outputs (CSVs, plots, reports) are written here.
    # Relative paths resolve from the project root (getwd()).
    # -------------------------------------------------------------------------
    output_folder = file.path(getwd(), "output", "my_study"),    # <-- REPLACE folder name

    # -------------------------------------------------------------------------
    # TODO [CONFIG]: Database metadata strings.
    # Used in output report metadata and PLP result objects.
    # -------------------------------------------------------------------------
    cdm_database_id          = "my_cdm_v5.4",                  # <-- REPLACE
    cdm_database_name        = "My Study Database",             # <-- REPLACE
    cdm_database_description = paste0(                          # <-- REPLACE
      "Brief description of the patient population and database used in this study."
    )
  )
}
