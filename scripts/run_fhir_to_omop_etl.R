# =============================================================================
# scripts/run_fhir_to_omop_etl.R
# Draft FHIR -> OMOP ETL runner for SQL Server.
#
# Purpose:
# - Build a deterministic run name from sample size, module version, and date
# - Emit metadata JSON for traceability
# - Stage FHIR NDJSON resources into SQL Server
# - Execute a draft SQL transform into OMOP tables
#
# Usage example:
# source("renv/activate.R")
# source("scripts/run_fhir_to_omop_etl.R")
# run_fhir_to_omop_etl(
#   fhir_input_dir = "C:/path/to/synthea/output/fhir",
#   sample_size = 5000L,
#   module_version = "v03",
#   run_date = Sys.Date()
# )
# =============================================================================

if (!requireNamespace("DatabaseConnector", quietly = TRUE)) {
  stop("Package 'DatabaseConnector' is required. Install with renv::install('DatabaseConnector').")
}
if (!requireNamespace("SqlRender", quietly = TRUE)) {
  stop("Package 'SqlRender' is required. Install with renv::install('SqlRender').")
}
if (!requireNamespace("jsonlite", quietly = TRUE)) {
  stop("Package 'jsonlite' is required. Install with renv::install('jsonlite').")
}

source("config.R")
source("R/drivers.R")
source("R/connection.R")

sanitize_token <- function(x) {
  x <- tolower(trimws(as.character(x)))
  x <- gsub("[^a-z0-9]+", "-", x)
  x <- gsub("^-+|-+$", "", x)
  x
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

build_run_name <- function(sample_size, module_version, run_date) {
  date_part <- format(as.Date(run_date), "%Y%m%d")
  sprintf(
    "padssi-n%s-mod%s-%s",
    as.integer(sample_size),
    sanitize_token(module_version),
    date_part
  )
}

empty_stage_df <- function() {
  data.frame(
    run_name = character(),
    source_file = character(),
    resource_type = character(),
    resource_id = character(),
    payload_json = character(),
    stringsAsFactors = FALSE
  )
}

resource_to_stage_df <- function(resource_list, run_name, source_file) {
  if (length(resource_list) == 0) {
    return(empty_stage_df())
  }

  payload_json <- vapply(
    resource_list,
    function(resource) jsonlite::toJSON(resource, auto_unbox = TRUE, null = "null"),
    character(1)
  )
  resource_type <- vapply(
    resource_list,
    function(resource) {
      if (is.null(resource$resourceType)) NA_character_ else as.character(resource$resourceType)
    },
    character(1)
  )
  resource_id <- vapply(
    resource_list,
    function(resource) {
      if (is.null(resource$id)) NA_character_ else as.character(resource$id)
    },
    character(1)
  )

  data.frame(
    run_name = rep(run_name, length(resource_list)),
    source_file = rep(source_file, length(resource_list)),
    resource_type = resource_type,
    resource_id = resource_id,
    payload_json = payload_json,
    stringsAsFactors = FALSE
  )
}

read_ndjson_as_stage <- function(file_path, run_name) {
  file_ext <- tolower(tools::file_ext(file_path))

  if (identical(file_ext, "json")) {
    document <- tryCatch(
      jsonlite::fromJSON(file_path, simplifyVector = FALSE),
      error = function(e) {
        stop("Failed to parse JSON file ", basename(file_path), ": ", e$message, call. = FALSE)
      }
    )

    if (identical(document$resourceType, "Bundle") && !is.null(document$entry)) {
      resource_list <- lapply(document$entry, function(entry) entry$resource)
      resource_list <- Filter(Negate(is.null), resource_list)
      return(resource_to_stage_df(resource_list, run_name, basename(file_path)))
    }

    if (!is.null(document$resourceType)) {
      return(resource_to_stage_df(list(document), run_name, basename(file_path)))
    }

    stop("Unsupported JSON structure in file: ", basename(file_path), call. = FALSE)
  }

  lines <- readLines(file_path, warn = FALSE, encoding = "UTF-8")
  lines <- lines[nzchar(trimws(lines))]
  if (length(lines) == 0) {
    return(empty_stage_df())
  }

  resource_list <- lapply(lines, function(line) {
    tryCatch(jsonlite::fromJSON(line, simplifyVector = FALSE), error = function(e) NULL)
  })
  valid_idx <- vapply(resource_list, function(resource) !is.null(resource), logical(1))
  if (!any(valid_idx)) {
    return(empty_stage_df())
  }

  resource_to_stage_df(resource_list[valid_idx], run_name, basename(file_path))
}

write_metadata <- function(metadata, output_dir) {
  if (!dir.exists(output_dir)) {
    dir.create(output_dir, recursive = TRUE, showWarnings = FALSE)
  }
  out_file <- file.path(output_dir, "metadata.json")
  jsonlite::write_json(metadata, path = out_file, auto_unbox = TRUE, pretty = TRUE)
  out_file
}

# Split a rendered+translated SQL string into named blocks by
# '-- [BLOCK: name]' comment markers.  Returns a named list of SQL chunks.
split_sql_blocks <- function(sql) {
  lines      <- strsplit(sql, "\n", fixed = TRUE)[[1]]
  marker_re  <- "^\\s*--\\s*\\[BLOCK:\\s*([^\\]]+)\\]"
  marker_idx <- grep(marker_re, lines)
  if (length(marker_idx) == 0L) {
    return(list(default = sql))
  }
  bnames <- trimws(sub(marker_re, "\\1", lines[marker_idx]))
  blocks <- vector("list", length(marker_idx))
  for (k in seq_along(marker_idx)) {
    from      <- marker_idx[k] + 1L
    to        <- if (k < length(marker_idx)) marker_idx[k + 1L] - 1L else length(lines)
    blocks[[k]] <- paste(lines[seq(from, to)], collapse = "\n")
  }
  setNames(blocks, bnames)
}

run_fhir_to_omop_etl <- function(
    fhir_input_dir,
    sample_size,
    module_version,
    run_date = Sys.Date(),
    staging_schema = "fhir_stage",
  staging_batch_files = 100L,
    cdm_schema = NULL,
    transform_sql_file = file.path("scripts", "sql", "fhir_to_omop_transform_draft.sql"),
    metadata_output_root = file.path("output", "etl_runs")) {

  config <- get_validation_config()
  if (is.null(cdm_schema) || !nzchar(cdm_schema)) {
    cdm_schema <- config$cdm_schema
  }

  if (!dir.exists(fhir_input_dir)) {
    stop("FHIR input directory does not exist: ", fhir_input_dir)
  }
  if (!file.exists(transform_sql_file)) {
    stop("Transform SQL file not found: ", transform_sql_file)
  }
  if (!is.numeric(staging_batch_files) || staging_batch_files < 1) {
    stop("staging_batch_files must be a positive integer")
  }
  staging_batch_files <- as.integer(staging_batch_files)

  ndjson_files <- list.files(fhir_input_dir, pattern = "\\.(ndjson|json)$", full.names = TRUE)
  if (length(ndjson_files) == 0) {
    stop("No .ndjson or .json files found in: ", fhir_input_dir)
  }

  run_name <- build_run_name(sample_size = sample_size, module_version = module_version, run_date = run_date)

  metadata <- list(
    run_name = run_name,
    sample_size = as.integer(sample_size),
    module_version = as.character(module_version),
    run_date = as.character(as.Date(run_date)),
    generated_at_utc = format(Sys.time(), tz = "UTC", usetz = TRUE),
    fhir_input_dir = normalizePath(fhir_input_dir, winslash = "/", mustWork = TRUE),
    ndjson_file_count = length(ndjson_files),
    ndjson_files = basename(ndjson_files),
    target_dbms = config$dbms,
    target_server = config$server,
    target_database = config$database,
    target_cdm_schema = cdm_schema,
    staging_schema = staging_schema,
    transform_sql_file = transform_sql_file
  )

  metadata_file <- write_metadata(
    metadata = metadata,
    output_dir = file.path(metadata_output_root, run_name)
  )

  connection_details <- build_connection_details(config)
  conn <- DatabaseConnector::connect(connection_details)
  on.exit(DatabaseConnector::disconnect(conn), add = TRUE)

  create_stage_sql <- SqlRender::translate(SqlRender::render(
    "
    IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = '@staging_schema')
      EXEC('CREATE SCHEMA @staging_schema');

    IF OBJECT_ID('@staging_schema.fhir_raw_resource', 'U') IS NULL
    BEGIN
      CREATE TABLE @staging_schema.fhir_raw_resource (
        run_name      VARCHAR(200) NOT NULL,
        source_file   VARCHAR(260) NOT NULL,
        resource_type VARCHAR(100) NULL,
        resource_id   VARCHAR(100) NULL,
        payload_json  NVARCHAR(MAX) NOT NULL,
        inserted_at   DATETIME2 NOT NULL DEFAULT SYSUTCDATETIME()
      );

      CREATE INDEX IX_fhir_raw_resource_run ON @staging_schema.fhir_raw_resource(run_name);
      CREATE INDEX IX_fhir_raw_resource_type ON @staging_schema.fhir_raw_resource(resource_type);
    END
    ",
    staging_schema = staging_schema
  ), targetDialect = config$dbms)

  DatabaseConnector::executeSql(conn, create_stage_sql)

  total_files <- length(ndjson_files)
  message(sprintf("\n=== Phase 1/2: STAGING (%d files) ===", total_files))
  stage_start_time <- Sys.time()
  progress_bar <- utils::txtProgressBar(min = 0, max = total_files, style = 3)
  on.exit(close(progress_bar), add = TRUE)

  batch_list <- list()
  batch_files <- 0L
  batch_rows <- 0L
  batch_start_idx <- NA_integer_

  flush_stage_batch <- function(batch_end_idx) {
    if (batch_files == 0L) {
      return(invisible(NULL))
    }

    batch_df <- do.call(rbind, batch_list)
    message(
      "Staging batch files ", batch_start_idx, "-", batch_end_idx,
      " (", batch_files, " files, ", nrow(batch_df), " rows)"
    )

    tryCatch({
      DatabaseConnector::insertTable(
        connection = conn,
        tableName = paste0(staging_schema, ".fhir_raw_resource"),
        data = batch_df,
        dropTableIfExists = FALSE,
        createTable = FALSE,
        tempTable = FALSE
      )
    }, error = function(e) {
      stop(
        "Failed while staging batch ", batch_start_idx, "-", batch_end_idx,
        ": ", e$message,
        call. = FALSE
      )
    })

    batch_list <<- list()
    batch_files <<- 0L
    batch_rows <<- 0L
    batch_start_idx <<- NA_integer_
    invisible(NULL)
  }

  for (i in seq_along(ndjson_files)) {
    file_path <- ndjson_files[[i]]
    if (i %% 250 == 0 || i == 1 || i == total_files) {
      message("Staging file ", i, "/", total_files, ": ", basename(file_path))
    }

    stage_df <- read_ndjson_as_stage(file_path, run_name)
    if (nrow(stage_df) == 0) {
      next
    }

    if (is.na(batch_start_idx)) {
      batch_start_idx <- i
    }
    batch_files <- batch_files + 1L
    batch_rows <- batch_rows + nrow(stage_df)
    batch_list[[batch_files]] <- stage_df

    if (batch_files >= staging_batch_files) {
      flush_stage_batch(i)
    }

    utils::setTxtProgressBar(progress_bar, i)
    if (i %% 25 == 0 || i == total_files) {
      elapsed_secs <- as.numeric(difftime(Sys.time(), stage_start_time, units = "secs"))
      files_per_sec <- if (elapsed_secs > 0) i / elapsed_secs else NA_real_
      eta_secs <- if (is.finite(files_per_sec) && files_per_sec > 0) {
        (total_files - i) / files_per_sec
      } else {
        NA_real_
      }
      message(
        sprintf(
          "Progress: %d/%d files (%.1f%%) | elapsed %s | ETA %s",
          i,
          total_files,
          100 * i / total_files,
          format_duration(elapsed_secs),
          format_duration(eta_secs)
        )
      )
    }
  }

  close(progress_bar)

  if (batch_files > 0L && batch_rows > 0L) {
    flush_stage_batch(total_files)
  }

  staging_elapsed <- as.numeric(difftime(Sys.time(), stage_start_time, units = "secs"))
  message(sprintf("=== Staging complete: %d files in %s ===",
                  total_files, format_duration(staging_elapsed)))

  message(sprintf("\n=== Phase 2/2: TRANSFORM (%s) ===", transform_sql_file))
  transform_start_time <- Sys.time()

  # Split on the raw template BEFORE render/translate so that
  # '-- [BLOCK: name]' markers survive (SqlRender strips comments).
  transform_template <- paste(readLines(transform_sql_file, warn = FALSE), collapse = "\n")
  template_blocks    <- split_sql_blocks(transform_template)

  # Render + translate each block independently.
  sql_blocks <- lapply(template_blocks, function(tmpl) {
    SqlRender::translate(
      SqlRender::render(
        tmpl,
        run_name       = run_name,
        staging_schema = staging_schema,
        cdm_schema     = cdm_schema
      ),
      targetDialect = config$dbms
    )
  })

  block_labels <- c(
    cleanup   = "[1/5] Pre-transform cleanup",
    person    = "[2/5] Patient -> PERSON",
    visit     = "[3/5] Encounter -> VISIT_OCCURRENCE",
    procedure = "[4/5] Procedure -> PROCEDURE_OCCURRENCE",
    condition = "[5/5] Condition -> CONDITION_OCCURRENCE"
  )

  for (bname in names(sql_blocks)) {
    sql_chunk <- trimws(sql_blocks[[bname]])
    if (!nzchar(sql_chunk)) next
    label <- if (bname %in% names(block_labels)) block_labels[[bname]] else bname
    message(label, " ...")
    block_t0 <- Sys.time()
    tryCatch(
      DatabaseConnector::executeSql(conn, sql_chunk),
      error = function(e) {
        message("ERROR in transform block '", bname, "':")
        message(e$message)
        stop(e)
      }
    )
    message(label, " done (",
            format_duration(as.numeric(difftime(Sys.time(), block_t0, units = "secs"))), ")")
  }

  transform_elapsed <- as.numeric(difftime(Sys.time(), transform_start_time, units = "secs"))
  total_elapsed     <- as.numeric(difftime(Sys.time(), stage_start_time,     units = "secs"))

  message("\n=== ETL Complete ===")
  message("Run name     : ", run_name)
  message("Metadata JSON: ", metadata_file)
  message(sprintf("Transform: %s | Total: %s",
                  format_duration(transform_elapsed), format_duration(total_elapsed)))

  invisible(list(
    run_name = run_name,
    metadata_file = metadata_file,
    ndjson_files = ndjson_files
  ))
}
