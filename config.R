# =============================================================================
# config.R
# Central configuration for the PAD/OLER SSI Validation Study.
# All database connection, schema, cohort, and path settings live here.
# =============================================================================

get_validation_config <- function() {

  # ---------------------------------------------------------------------------
  # JDBC / Java setup – fully self-contained under this project's drivers/ folder.
  # On first run, R/drivers.R will download and extract the JDBC bundle here.
  # ---------------------------------------------------------------------------
  java_home        <- "C:/Program Files/Eclipse Adoptium/jdk-17.0.18.8-hotspot"
  sql_server_jdbc_version <- "13.2.1"
  path_to_driver   <- file.path(getwd(), "drivers")
  jdbc_home        <- file.path(path_to_driver, "sqljdbc_13.2", "enu")
  jdbc_runtime_dir <- file.path(path_to_driver, "jdbc-runtime")

  # ---------------------------------------------------------------------------
  # Database connection
  # ---------------------------------------------------------------------------
  list(
    # Java / JDBC
    java_home               = java_home,
    java_bin                = file.path(java_home, "bin"),
    sql_server_jdbc_version = sql_server_jdbc_version,
    # Official Microsoft JDBC 13.2.1 download (en-US, all platforms)
    jdbc_zip_url            = "https://go.microsoft.com/fwlink/?linkid=2338346&clcid=0x409",
    path_to_driver          = path_to_driver,
    jdbc_home               = jdbc_home,
    jdbc_jar_folder         = file.path(jdbc_home, "jars"),
    jdbc_runtime_dir        = jdbc_runtime_dir,
    jdbc_auth_dir           = file.path(jdbc_home, "auth", "x64"),

    # SQL Server connection
    dbms             = "sql server",
    server           = "localhost",
    database         = "omop_synth",
    sql_server_port  = 1434L,

    # CDM schema (created by this repository's Step 5 ETL workflow)
    cdm_schema       = "cdm_synthea",
    cdm_version      = 5L,

    # Results / work schema – will be created automatically if it does not exist
    results_schema   = "plp_results",

    # Cohort table that will hold target + outcome cohorts
    cohort_table     = "ssi_val_cohort",

    # Cohort IDs
    # 1 = Target  : patients who underwent an inpatient surgical procedure
    # 2 = Outcome : patients with a diagnosis of surgical site infection
    target_cohort_id  = 1L,
    outcome_cohort_id = 2L,

    # ---------------------------------------------------------------------------
    # Existing ATLAS cohorts (optional, recommended when cohorts are already
    # generated in the database).
    #
    # If use_atlas_cohorts = TRUE:
    # - target cohort will be copied from atlas_target_cohort_id
    # - outcome cohort will be copied from atlas_outcome_cohort_id IF provided
    #   (non-NA), otherwise outcome is generated from cohorts/outcome_ssi.sql
    # ---------------------------------------------------------------------------
    use_atlas_cohorts      = FALSE,
    atlas_cohort_schema    = "results",
    atlas_cohort_table     = "cohort",
    atlas_target_cohort_id = 1796269L,
    atlas_outcome_cohort_id = 1796278L,

    # ---------------------------------------------------------------------------
    # Integer risk score pipeline settings
    # ---------------------------------------------------------------------------
    risk_score_components_file = file.path(getwd(), "risk_score", "components.csv"),
    risk_score_concepts_file   = file.path(getwd(), "risk_score", "component_concepts.csv"),
    risk_score_lookup_file     = file.path(getwd(), "risk_score", "risk_lookup.csv"),
    risk_score_output_folder   = file.path(getwd(), "output", "risk_score_eval"),
    prediction_window_days     = 30L,

    # Study date window applied to both cohort instantiation and PLP data pull.
    # Adjust to match the date range of the original training study so that
    # temporal drift analysis is meaningful.
    study_start_date = "2010-01-01",
    study_end_date   = "2023-12-31",

    # ---------------------------------------------------------------------------
    # Pre-trained model path
    # Point this to the folder produced by PatientLevelPrediction::runPlp() in
    # the original SSI development study.  The folder must contain
    # runPlp_result.rds (or a model sub-directory with model.rds).
    # ---------------------------------------------------------------------------
    model_path = file.path("..", "ssi-model", "plpResult"),

    # ---------------------------------------------------------------------------
    # Output folder for validation results
    # ---------------------------------------------------------------------------
    output_folder = file.path(getwd(), "output", "ssi_validation"),

    # Database identifier strings used in PLP result metadata
    cdm_database_id          = "synthea_omop_v5.4",
    cdm_database_name        = "Synthea OMOP",
    cdm_database_description = paste0(
      "Synthetic patient population (Synthea 3.3.0) mapped to OMOP CDM 5.4 ",
      "on SQL Server 2019.  Used as an external validation database for the ",
      "PAD / OLER surgical site infection prediction model."
    )
  )
}
