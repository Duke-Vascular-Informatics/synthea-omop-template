# =============================================================================
# scripts/etl/run_synthea_csv_to_omop_etl.R
# Synthea CSV -> OMOP ETL runner for SQL Server.
# =============================================================================

source("config.R")
source("R/drivers.R")
source("R/connection.R")

bootstrap_config <- get_validation_config()
configure_java(bootstrap_config)

if (!requireNamespace("DatabaseConnector", quietly = TRUE)) {
  stop("Package 'DatabaseConnector' is required. Install with renv::install('DatabaseConnector').")
}
if (!requireNamespace("SqlRender", quietly = TRUE)) {
  stop("Package 'SqlRender' is required. Install with renv::install('SqlRender').")
}
if (!requireNamespace("data.table", quietly = TRUE)) {
  stop("Package 'data.table' is required. Install with renv::install('data.table').")
}

format_duration <- function(seconds) {
  if (!is.finite(seconds) || is.na(seconds)) {
    return("n/a")
  }
  seconds <- max(0, as.integer(round(seconds)))
  hours <- seconds %/% 3600
  minutes <- (seconds %% 3600) %/% 60
  secs <- seconds %% 60
  if (hours > 0) {
    sprintf("%02dh:%02dm:%02ds", hours, minutes, secs)
  } else {
    sprintf("%02dm:%02ds", minutes, secs)
  }
}

split_sql_blocks <- function(sql) {
  lines <- strsplit(sql, "\n", fixed = TRUE)[[1]]
  marker_re <- "^\\s*--\\s*\\[BLOCK:\\s*([^\\]]+)\\]"
  marker_idx <- grep(marker_re, lines)
  if (length(marker_idx) == 0L) {
    return(list(default = sql))
  }
  bnames <- trimws(sub(marker_re, "\\1", lines[marker_idx]))
  blocks <- vector("list", length(marker_idx))
  for (k in seq_along(marker_idx)) {
    from <- marker_idx[k] + 1L
    to <- if (k < length(marker_idx)) marker_idx[k + 1L] - 1L else length(lines)
    blocks[[k]] <- paste(lines[seq(from, to)], collapse = "\n")
  }
  setNames(blocks, bnames)
}

read_required_csv <- function(csv_dir, file_name, select_cols) {
  file_path <- file.path(csv_dir, file_name)
  if (!file.exists(file_path)) {
    stop("Missing required CSV file: ", file_path)
  }
  data.table::fread(file_path, select = select_cols, na.strings = c("", "NULL"))
}

run_synthea_csv_to_omop_etl <- function(
    csv_input_dir,
    run_name = paste0("synthea-csv-", format(Sys.time(), "%Y%m%d-%H%M%S")),
    staging_schema = "synthea_csv_stage",
    cdm_schema = NULL,
    transform_sql_file = file.path("scripts", "sql", "synthea_csv_to_omop_transform.sql")) {

  config <- get_validation_config()
  if (is.null(cdm_schema) || !nzchar(cdm_schema)) {
    cdm_schema <- config$cdm_schema
  }

  if (!dir.exists(csv_input_dir)) {
    stop("CSV input directory does not exist: ", csv_input_dir)
  }
  if (!file.exists(transform_sql_file)) {
    stop("Transform SQL file not found: ", transform_sql_file)
  }

  conn <- DatabaseConnector::connect(build_connection_details(config))
  on.exit(DatabaseConnector::disconnect(conn), add = TRUE)

  vocab_ready_sql <- SqlRender::translate(
    SqlRender::render(
      "SELECT
         CASE WHEN EXISTS (SELECT 1 FROM @cdm_schema.concept) THEN 1 ELSE 0 END AS has_concept,
         CASE WHEN EXISTS (SELECT 1 FROM @cdm_schema.concept_relationship) THEN 1 ELSE 0 END AS has_concept_relationship,
         CASE WHEN EXISTS (SELECT 1 FROM @cdm_schema.concept_ancestor) THEN 1 ELSE 0 END AS has_concept_ancestor;",
      cdm_schema = cdm_schema
    ),
    targetDialect = config$dbms
  )
  vocab_ready <- DatabaseConnector::querySql(conn, vocab_ready_sql)
  if (
    as.integer(vocab_ready$has_concept[1]) != 1L ||
    as.integer(vocab_ready$has_concept_relationship[1]) != 1L ||
    as.integer(vocab_ready$has_concept_ancestor[1]) != 1L
  ) {
    stop(
      paste0(
        "Vocabulary precheck failed in ", cdm_schema, ". Required populated tables are: ",
        "concept, concept_relationship, and concept_ancestor. ",
        "This analysis repository no longer loads vocabularies during ETL. ",
        "Please run the separate 'vocab_omop_etl' process first."
      ),
      call. = FALSE
    )
  }

  message("=== Phase 1/2: STAGING CSV TABLES ===")
  stage_start <- Sys.time()

  create_stage_sql <- SqlRender::translate(
    SqlRender::render(
      "
      IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = '@staging_schema')
        EXEC('CREATE SCHEMA @staging_schema');

      IF OBJECT_ID('@staging_schema.patients_stage', 'U') IS NULL
      BEGIN
        CREATE TABLE @staging_schema.patients_stage (
          run_name      VARCHAR(200) NOT NULL,
          patient_id    VARCHAR(100) NOT NULL,
          birth_date    DATE NULL,
          gender        VARCHAR(20) NULL
        );
        CREATE INDEX IX_patients_stage_run ON @staging_schema.patients_stage(run_name);
      END;

      IF OBJECT_ID('@staging_schema.encounters_stage', 'U') IS NULL
      BEGIN
        CREATE TABLE @staging_schema.encounters_stage (
          run_name         VARCHAR(200) NOT NULL,
          encounter_id     VARCHAR(100) NOT NULL,
          patient_id       VARCHAR(100) NOT NULL,
          start_datetime   DATETIME2 NULL,
          end_datetime     DATETIME2 NULL,
          encounter_class  VARCHAR(50) NULL
        );
        CREATE INDEX IX_encounters_stage_run ON @staging_schema.encounters_stage(run_name);
      END;

      IF OBJECT_ID('@staging_schema.procedures_stage', 'U') IS NULL
      BEGIN
        CREATE TABLE @staging_schema.procedures_stage (
          run_name          VARCHAR(200) NOT NULL,
          patient_id        VARCHAR(100) NOT NULL,
          encounter_id      VARCHAR(100) NULL,
          procedure_date    DATETIME2 NULL,
          source_code       VARCHAR(50) NULL,
          source_display    VARCHAR(400) NULL
        );
        CREATE INDEX IX_procedures_stage_run ON @staging_schema.procedures_stage(run_name);
      END;

      IF OBJECT_ID('@staging_schema.conditions_stage', 'U') IS NULL
      BEGIN
        CREATE TABLE @staging_schema.conditions_stage (
          run_name            VARCHAR(200) NOT NULL,
          patient_id          VARCHAR(100) NOT NULL,
          encounter_id        VARCHAR(100) NULL,
          condition_start     DATETIME2 NULL,
          condition_end       DATETIME2 NULL,
          source_code         VARCHAR(50) NULL,
          source_display      VARCHAR(400) NULL
        );
        CREATE INDEX IX_conditions_stage_run ON @staging_schema.conditions_stage(run_name);
      END;
      ",
      staging_schema = staging_schema
    ),
    targetDialect = config$dbms
  )
  DatabaseConnector::executeSql(conn, create_stage_sql)

  clear_stage_sql <- SqlRender::translate(
    SqlRender::render(
      "
      DELETE FROM @staging_schema.patients_stage WHERE run_name = '@run_name';
      DELETE FROM @staging_schema.encounters_stage WHERE run_name = '@run_name';
      DELETE FROM @staging_schema.procedures_stage WHERE run_name = '@run_name';
      DELETE FROM @staging_schema.conditions_stage WHERE run_name = '@run_name';
      ",
      staging_schema = staging_schema,
      run_name = run_name
    ),
    targetDialect = config$dbms
  )
  DatabaseConnector::executeSql(conn, clear_stage_sql)

  message("Loading patients.csv ...")
  patients <- read_required_csv(csv_input_dir, "patients.csv", c("Id", "BIRTHDATE", "GENDER"))
  data.table::setnames(patients, c("Id", "BIRTHDATE", "GENDER"), c("patient_id", "birth_date", "gender"))
  patients[, birth_date := as.Date(as.character(birth_date))]
  patients[, run_name := run_name]
  patients <- as.data.frame(patients[, .(run_name, patient_id, birth_date, gender)])
  DatabaseConnector::insertTable(conn, databaseSchema = staging_schema, tableName = "patients_stage",
                                 data = patients, dropTableIfExists = FALSE, createTable = FALSE, tempTable = FALSE)
  message("patients.csv rows: ", nrow(patients))

  message("Loading encounters.csv ...")
  encounters <- read_required_csv(csv_input_dir, "encounters.csv", c("Id", "PATIENT", "START", "STOP", "ENCOUNTERCLASS"))
  data.table::setnames(encounters, c("Id", "PATIENT", "START", "STOP", "ENCOUNTERCLASS"),
           c("encounter_id", "patient_id", "start_datetime", "end_datetime", "encounter_class"))
  encounters[, start_datetime := as.POSIXct(as.character(start_datetime), tz = "UTC")]
  encounters[, end_datetime   := as.POSIXct(as.character(end_datetime),   tz = "UTC")]
  encounters[, run_name := run_name]
  encounters <- as.data.frame(encounters[, .(run_name, encounter_id, patient_id, start_datetime, end_datetime, encounter_class)])
  DatabaseConnector::insertTable(conn, databaseSchema = staging_schema, tableName = "encounters_stage",
                                 data = encounters, dropTableIfExists = FALSE, createTable = FALSE, tempTable = FALSE)
  message("encounters.csv rows: ", nrow(encounters))

  message("Loading procedures.csv ...")
  procedures <- read_required_csv(csv_input_dir, "procedures.csv", c("PATIENT", "ENCOUNTER", "START", "CODE", "DESCRIPTION"))
  data.table::setnames(procedures, c("PATIENT", "ENCOUNTER", "START", "CODE", "DESCRIPTION"),
           c("patient_id", "encounter_id", "procedure_date", "source_code", "source_display"))
  procedures[, procedure_date := as.POSIXct(as.character(procedure_date), tz = "UTC")]
  procedures[, run_name := run_name]
  procedures <- as.data.frame(procedures[, .(run_name, patient_id, encounter_id, procedure_date, source_code, source_display)])
  DatabaseConnector::insertTable(conn, databaseSchema = staging_schema, tableName = "procedures_stage",
                                 data = procedures, dropTableIfExists = FALSE, createTable = FALSE, tempTable = FALSE)
  message("procedures.csv rows: ", nrow(procedures))

  message("Loading conditions.csv ...")
  conditions <- read_required_csv(csv_input_dir, "conditions.csv", c("PATIENT", "ENCOUNTER", "START", "STOP", "CODE", "DESCRIPTION"))
  data.table::setnames(conditions, c("PATIENT", "ENCOUNTER", "START", "STOP", "CODE", "DESCRIPTION"),
           c("patient_id", "encounter_id", "condition_start", "condition_end", "source_code", "source_display"))
  conditions[, condition_start := as.POSIXct(as.character(condition_start), tz = "UTC")]
  conditions[, condition_end   := as.POSIXct(as.character(condition_end),   tz = "UTC")]
  conditions[, run_name := run_name]
  conditions <- as.data.frame(conditions[, .(run_name, patient_id, encounter_id, condition_start, condition_end, source_code, source_display)])
  DatabaseConnector::insertTable(conn, databaseSchema = staging_schema, tableName = "conditions_stage",
                                 data = conditions, dropTableIfExists = FALSE, createTable = FALSE, tempTable = FALSE)
  message("conditions.csv rows: ", nrow(conditions))

  message("=== Staging complete in ", format_duration(as.numeric(difftime(Sys.time(), stage_start, units = "secs"))), " ===")

  message("=== Phase 2/2: TRANSFORM CSV -> OMOP ===")
  transform_start <- Sys.time()

  template <- paste(readLines(transform_sql_file, warn = FALSE), collapse = "\n")
  template_blocks <- split_sql_blocks(template)

  block_labels <- c(
    cleanup = "[1/5] Cleanup existing CSV-derived rows",
    person = "[2/5] Patients -> PERSON",
    visit = "[3/5] Encounters -> VISIT_OCCURRENCE",
    procedure = "[4/5] Procedures -> PROCEDURE_OCCURRENCE",
    condition = "[5/5] Conditions -> CONDITION_OCCURRENCE"
  )

  for (bname in names(template_blocks)) {
    sql <- SqlRender::translate(
      SqlRender::render(
        template_blocks[[bname]],
        run_name = run_name,
        staging_schema = staging_schema,
        cdm_schema = cdm_schema
      ),
      targetDialect = config$dbms
    )

    label <- if (bname %in% names(block_labels)) block_labels[[bname]] else bname
    message(label, " ...")
    t0 <- Sys.time()
    DatabaseConnector::executeSql(conn, sql)
    message(label, " done (", format_duration(as.numeric(difftime(Sys.time(), t0, units = "secs"))), ")")
  }

  message("=== CSV ETL complete in ",
          format_duration(as.numeric(difftime(Sys.time(), transform_start, units = "secs"))),
          " (transform), ",
          format_duration(as.numeric(difftime(Sys.time(), stage_start, units = "secs"))),
          " (total) ===")

  invisible(list(run_name = run_name))
}
