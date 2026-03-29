# =============================================================================
# Portable risk score config template.
# Update values for your OMOP SQL Server environment before running.
# =============================================================================

get_validation_config <- function() {
  java_home <- "C:/Program Files/Eclipse Adoptium/jdk-17.0.18.8-hotspot" #### UPDATE IN PRCC
  sql_server_jdbc_version <- "13.2.1"
  path_to_driver <- file.path(getwd(), "drivers")
  jdbc_home <- file.path(path_to_driver, "sqljdbc_13.2", "enu")
  jdbc_runtime_dir <- file.path(path_to_driver, "jdbc-runtime")

  list(
    java_home = java_home,
    java_bin = file.path(java_home, "bin"),
    sql_server_jdbc_version = sql_server_jdbc_version,
    jdbc_zip_url = "https://go.microsoft.com/fwlink/?linkid=2338346&clcid=0x409",
    path_to_driver = path_to_driver, #### UPDATE IN PRCC
    jdbc_home = jdbc_home,
    jdbc_jar_folder = file.path(jdbc_home, "jars"),
    jdbc_runtime_dir = jdbc_runtime_dir,
    jdbc_auth_dir = file.path(jdbc_home, "auth", "x64"),

    # Update these for your environment
    dbms = "sql server",
    server = "localhost", #### UPDATE IN PRCC
    database = "omop_synth", #### UPDATE IN PRCC
    sql_server_port = 1434L, # UPDATE IN PRCC

    cdm_schema = "cdm_synthea", #### UPDATE IN PRCC
    results_schema = "plp_results", #### UPDATE IN PRCC
    cohort_table = "ssi_val_cohort",

    target_cohort_id = 1L,
    outcome_cohort_id = 2L,

    risk_score_components_file = file.path(getwd(), "risk_score", "components.csv"),
    risk_score_concepts_file = file.path(getwd(), "risk_score", "component_concepts.csv"),
    risk_score_lookup_file = file.path(getwd(), "risk_score", "risk_lookup.csv"),
    risk_score_output_folder = file.path(getwd(), "output", "risk_score_eval"),
    prediction_window_days = 30L
  )
}
