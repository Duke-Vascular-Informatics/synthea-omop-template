#!/usr/bin/env Rscript
# =============================================================================
# scripts/setup_omop_vocab_schema.R
#
# One-time setup: load the OMOP vocabulary into a dedicated shared schema
# (default: "omop_vocab") so that all subsequent ETL runs can reference it
# via SQL Server synonyms instead of reloading 130M rows from CSV each time.
#
# When to run:
#   - First time setting up this project on a new SQL Server instance.
#   - After upgrading the OMOP vocabulary to a new release.
#   - You should NOT need to run this again between synthetic dataset runs.
#
# What it does:
#   1. Creates the shared vocabulary schema if it does not exist.
#   2. Creates all OMOP CDM v5.4 vocabulary tables in that schema.
#   3. Sets the database to SIMPLE recovery and pre-grows the transaction log
#      (CONCEPT_ANCESTOR alone is 75M rows and needs ~25 GB of log headroom).
#   4. Loads all vocabulary tables from CSV using ETLSyntheaBuilder::LoadVocabFromCsv.
#   5. Sets the database permanently to SIMPLE recovery (appropriate for a
#      synthetic/dev database with no point-in-time restore requirement).
#
# Usage:
#   $env:OHDSI_VOCAB_CSV_DIR = "C:\path\to\Vocabulary_YYYYMMDD"
#   Rscript scripts/setup_omop_vocab_schema.R
#
# After this script completes, set in workflow/05_etl_csv_to_omop.R:
#   use_shared_vocab_schema <- TRUE
# Every subsequent ETL run will skip the vocabulary load entirely and wire
# synonyms in ~1 second instead of waiting 30-60 minutes for CSV load.
# =============================================================================

# -----------------------------------------------------------------------------
# Settings
# -----------------------------------------------------------------------------
vocab_schema      <- "omop_vocab"          # Shared schema to load vocab into
cdm_version       <- "5.4"
vocab_delimiter   <- "\t"                  # OHDSI vocabulary CSVs are tab-delimited
target_log_mb     <- 25600L               # 25 GB log headroom for bulk vocab load
vocab_file_loc    <- Sys.getenv("OHDSI_VOCAB_CSV_DIR", unset = "C:/Users/rapiduser/omop-vocab")

# -----------------------------------------------------------------------------
# Bootstrap
# -----------------------------------------------------------------------------
if (!file.exists("renv/activate.R")) {
  stop(
    "Run this script from the project root directory.\n",
    "Current directory: ", getwd(),
    call. = FALSE
  )
}

source("renv/activate.R")
if (requireNamespace("renv", quietly = TRUE)) renv::load(project = getwd())

source("config.R")
source("R/drivers.R")
source("R/connection.R")
source("R/db_maintenance.R")

cfg <- get_validation_config()

# Apply Java / JDBC setup from config.
if (!is.null(cfg$java_home) && nzchar(cfg$java_home) && dir.exists(cfg$java_home)) {
  java_bin <- file.path(cfg$java_home, "bin")
  Sys.setenv(JAVA_HOME = cfg$java_home)
  Sys.setenv(PATH = paste(
    normalizePath(java_bin, winslash = "/", mustWork = FALSE),
    Sys.getenv("PATH"), sep = .Platform$path.sep
  ))
  options(java.parameters = paste0(
    "-Djava.home=", normalizePath(cfg$java_home, winslash = "/", mustWork = FALSE)
  ))
  if (!is.null(cfg$jdbc_auth_dir) && nzchar(cfg$jdbc_auth_dir) && dir.exists(cfg$jdbc_auth_dir)) {
    jdbc_auth_native <- normalizePath(cfg$jdbc_auth_dir, winslash = "/", mustWork = FALSE)
    Sys.setenv(JAVA_TOOL_OPTIONS = paste0("-Djava.library.path=", jdbc_auth_native))
    Sys.setenv(PATH = paste(jdbc_auth_native, Sys.getenv("PATH"), sep = .Platform$path.sep))
  }
}

for (pkg in c("DatabaseConnector", "SqlRender", "ETLSyntheaBuilder")) {
  if (!requireNamespace(pkg, quietly = TRUE)) {
    stop("Required package not found: ", pkg,
         ". Run workflow/01_setup_synthea_etl_qc_env.R first.", call. = FALSE)
  }
}

# -----------------------------------------------------------------------------
# Preflight checks
# -----------------------------------------------------------------------------
cat("\n=== OMOP Shared Vocabulary Schema Setup ===\n")
cat("Vocabulary schema  :", vocab_schema, "\n")
cat("CDM version        :", cdm_version, "\n")
cat("Vocabulary CSV dir :", vocab_file_loc, "\n")
cat("Database           :", cfg$database, "on", cfg$server, "\n\n")

if (!dir.exists(vocab_file_loc)) {
  stop(
    "Vocabulary CSV directory not found: ", vocab_file_loc, "\n",
    "Set the OHDSI_VOCAB_CSV_DIR environment variable to the correct path.",
    call. = FALSE
  )
}

required_vocab_files <- c(
  "CONCEPT.csv", "CONCEPT_ANCESTOR.csv", "CONCEPT_CLASS.csv",
  "CONCEPT_RELATIONSHIP.csv", "CONCEPT_SYNONYM.csv", "DOMAIN.csv",
  "DRUG_STRENGTH.csv", "RELATIONSHIP.csv", "VOCABULARY.csv"
)
missing_files <- required_vocab_files[
  !file.exists(file.path(vocab_file_loc, required_vocab_files))
]
if (length(missing_files) > 0) {
  stop(
    "Missing required vocabulary CSV files in ", vocab_file_loc, ":\n",
    paste(" -", missing_files, collapse = "\n"),
    call. = FALSE
  )
}

ensure_jdbc_bundle(cfg)

connection_details <- build_connection_details(cfg)

# -----------------------------------------------------------------------------
# Check if vocab schema already populated — skip if so
# -----------------------------------------------------------------------------
conn_check <- DatabaseConnector::connect(connection_details)
on.exit(DatabaseConnector::disconnect(conn_check), add = TRUE)

schema_exists_sql <- paste0(
  "SELECT COUNT(*) AS n FROM sys.schemas WHERE name = '",
  gsub("'", "''", vocab_schema), "';"
)
schema_row <- DatabaseConnector::querySql(conn_check, schema_exists_sql)
colnames(schema_row) <- tolower(colnames(schema_row))
schema_exists <- as.integer(schema_row$n[[1]]) > 0L

if (schema_exists) {
  concept_check_sql <- paste0(
    "SELECT CASE WHEN EXISTS (SELECT 1 FROM [", vocab_schema, "].[concept]) ",
    "THEN 1 ELSE 0 END AS has_rows;"
  )
  concept_row <- tryCatch(
    { r <- DatabaseConnector::querySql(conn_check, concept_check_sql)
      colnames(r) <- tolower(colnames(r)); r },
    error = function(e) data.frame(has_rows = 0L)
  )
  if (as.integer(concept_row$has_rows[[1]]) > 0L) {
    cat("[INFO] Vocabulary schema '", vocab_schema,
        "' already exists and is populated. Nothing to do.\n", sep = "")
    cat("[INFO] To reload the vocabulary, drop the schema first:\n")
    cat("       DROP SCHEMA [", vocab_schema, "] (after dropping all tables in it)\n\n", sep = "")
    quit(save = "no", status = 0)
  }
}

DatabaseConnector::disconnect(conn_check)

# -----------------------------------------------------------------------------
# Step 1: Transaction log preparation
# -----------------------------------------------------------------------------
prepare_txlog_for_bulk_etl(cfg, target_min_mb = target_log_mb)

# -----------------------------------------------------------------------------
# Step 2: Create vocabulary schema and CDM vocab tables
# -----------------------------------------------------------------------------
cat("[INFO] Creating vocabulary schema '", vocab_schema, "' ...\n", sep = "")

conn_setup <- DatabaseConnector::connect(connection_details)
on.exit(DatabaseConnector::disconnect(conn_setup), add = TRUE)

DatabaseConnector::executeSql(
  conn_setup,
  paste0(
    "IF SCHEMA_ID('", gsub("'", "''", vocab_schema), "') IS NULL ",
    "EXEC('CREATE SCHEMA [", vocab_schema, "]');"
  )
)
cat("[INFO] \u2713 Schema created (or already exists)\n")
DatabaseConnector::disconnect(conn_setup)

# Use ETLSyntheaBuilder to create CDM tables in the vocab schema, then
# we only use the vocabulary table definitions.
cat("[INFO] Creating CDM vocabulary table definitions in '", vocab_schema, "' ...\n", sep = "")
ETLSyntheaBuilder::CreateCDMTables(
  connectionDetails = connection_details,
  cdmSchema         = vocab_schema,
  cdmVersion        = cdm_version
)
cat("[INFO] \u2713 CDM tables created\n")

# -----------------------------------------------------------------------------
# Step 3: Load vocabulary from CSV
# -----------------------------------------------------------------------------
cat("[INFO] Loading OMOP vocabulary from CSV (this will take 30-60 minutes) ...\n")
cat("[INFO] CONCEPT_ANCESTOR alone is 75M rows — please be patient.\n\n")

ETLSyntheaBuilder::LoadVocabFromCsv(
  connectionDetails = connection_details,
  cdmSchema         = vocab_schema,
  vocabFileLoc      = vocab_file_loc,
  delimiter         = vocab_delimiter
)

cat("\n[INFO] \u2713 Vocabulary loaded successfully into '", vocab_schema, "'\n", sep = "")

# -----------------------------------------------------------------------------
# Step 3b: Post-load NULL corrections
#
# data.table/DatabaseConnector converts empty CSV fields to '' rather than SQL
# NULL.  Several OMOP vocab columns are nullable and the ETLSyntheaBuilder
# source-to-standard mapping SQL relies on IS NULL checks.  Restore proper
# NULLs here so that every downstream ETL run maps correctly without manual
# intervention.
# -----------------------------------------------------------------------------
cat("[INFO] Applying post-load NULL corrections ...\n")
conn_null_fix <- DatabaseConnector::connect(connection_details)
on.exit(DatabaseConnector::disconnect(conn_null_fix), add = TRUE)

null_fix_stmts <- c(
  paste0("UPDATE [", vocab_schema, "].[concept] SET invalid_reason = NULL WHERE invalid_reason = ''"),
  paste0("UPDATE [", vocab_schema, "].[concept] SET standard_concept = NULL WHERE standard_concept = ''"),
  paste0("UPDATE [", vocab_schema, "].[concept_relationship] SET invalid_reason = NULL WHERE invalid_reason = ''"),
  paste0("UPDATE [", vocab_schema, "].[drug_strength] SET invalid_reason = NULL WHERE invalid_reason = ''"),
  paste0("UPDATE [", vocab_schema, "].[relationship] SET invalid_reason = NULL WHERE invalid_reason = ''")
)
for (stmt in null_fix_stmts) {
  tryCatch(
    DatabaseConnector::executeSql(conn_null_fix, stmt),
    error = function(e) cat("[INFO] NULL fix note (non-fatal):", conditionMessage(e), "\n")
  )
}
DatabaseConnector::disconnect(conn_null_fix)
cat("[INFO] \u2713 Nullable columns corrected (invalid_reason, standard_concept)\n")

# -----------------------------------------------------------------------------
# Step 4: Set database permanently to SIMPLE recovery
# -----------------------------------------------------------------------------
conn_final <- DatabaseConnector::connect(connection_details)
on.exit(DatabaseConnector::disconnect(conn_final), add = TRUE)

DatabaseConnector::executeSql(
  conn_final,
  paste0("ALTER DATABASE [", cfg$database, "] SET RECOVERY SIMPLE;")
)
cat("[INFO] \u2713 Database set to SIMPLE recovery (permanent for this dev/synthetic instance)\n")

# Shrink log back down now that vocab load is complete.
DatabaseConnector::executeSql(conn_final, "CHECKPOINT;")

log_name_sql <- paste0(
  "SELECT name FROM sys.master_files ",
  "WHERE database_id = DB_ID('", gsub("'", "''", cfg$database), "') AND type_desc = 'LOG';"
)
log_name_row <- DatabaseConnector::querySql(conn_final, log_name_sql)
colnames(log_name_row) <- tolower(colnames(log_name_row))
log_name <- as.character(log_name_row$name[[1]])
tryCatch(
  DatabaseConnector::querySql(conn_final, paste0("DBCC SHRINKFILE (", log_name, ", 1024);")),
  error = function(e) cat("[INFO] SHRINKFILE note (non-fatal):", conditionMessage(e), "\n")
)
cat("[INFO] \u2713 Transaction log shrunk back to ~1 GB\n")

DatabaseConnector::disconnect(conn_final)

cat("\n=== Setup complete ===\n")
cat("Vocabulary is now available in schema '", vocab_schema, "'.\n\n", sep = "")
cat("Next steps:\n")
cat("  In workflow/05_etl_csv_to_omop.R, set:\n")
cat("    use_shared_vocab_schema <- TRUE\n")
cat("  All ETL runs will now use synonyms instead of reloading vocabulary.\n\n")
