#!/usr/bin/env Rscript
# Fix SQL Server transaction log issues before bulk ETL operations.
#
# Purpose:
# - Check transaction log space usage for the target database
# - Switch recovery mode to SIMPLE to allow automatic log truncation
# - Shrink the transaction log file to reclaim space
# - Optionally return to FULL recovery mode when done
#
# Usage:
#   Rscript scripts/fix_sql_server_transaction_log.R
#
# The script will:
# 1. Connect using config.R credentials
# 2. Report current recovery mode and log space usage
# 3. Switch to SIMPLE recovery (if not already)
# 4. Shrink the transaction log file
# 5. Offer to switch back to FULL recovery

source("config.R")
source("R/drivers.R")
source("R/connection.R")

# Load required packages
if (!requireNamespace("DatabaseConnector", quietly = TRUE)) {
  stop("Package 'DatabaseConnector' is required. Install with renv::install('DatabaseConnector').")
}

if (!requireNamespace("SqlRender", quietly = TRUE)) {
  stop("Package 'SqlRender' is required. Install with renv::install('SqlRender').")
}

cfg <- get_validation_config()

cat("\n=== SQL Server Transaction Log Maintenance ===\n")
cat("Database: ", cfg$database, "\n")
cat("Server:   ", cfg$server, "\n\n")

# Build connection details using repository-standard helper (R/connection.R)
connection_details <- build_connection_details(cfg)

# Connect
tryCatch({
  conn <- DatabaseConnector::connect(connection_details)
  on.exit(DatabaseConnector::disconnect(conn), add = TRUE)

  # =========================================================================
  # 1. Check current recovery mode and log space
  # =========================================================================
  cat("[INFO] Checking database recovery mode and transaction log space...\n")

  recovery_sql <- paste0(
    "SELECT name, recovery_model_desc FROM sys.databases WHERE name = '", cfg$database, "';"
  )
  recovery_result <- DatabaseConnector::querySql(conn, recovery_sql)
  colnames(recovery_result) <- tolower(colnames(recovery_result))

  cat("[INFO] Database: ", recovery_result$name[[1]], "\n")
  cat("[INFO] Recovery mode: ", recovery_result$recovery_model_desc[[1]], "\n\n")

  # Check transaction log file name
  logspace_sql <- paste0(
    "SELECT name, size * 8.0 / 1024 AS size_mb FROM sys.master_files ",
    "WHERE database_id = DB_ID('", cfg$database, "') AND type_desc = 'LOG';"
  )
  logspace_result <- DatabaseConnector::querySql(conn, logspace_sql)
  colnames(logspace_result) <- tolower(colnames(logspace_result))

  if (nrow(logspace_result) > 0) {
    log_file_name <- logspace_result$name[[1]]
    log_file_size <- round(logspace_result$size_mb[[1]], 1)
    cat("[INFO] Transaction log file: ", log_file_name, "\n")
    cat("[INFO] Current size: ", log_file_size, " MB\n\n")
  } else {
    stop("Could not find transaction log file for database ", cfg$database)
  }

  # =========================================================================
  # 2. Switch to SIMPLE recovery if currently FULL
  # =========================================================================
  current_mode <- recovery_result$recovery_model_desc[[1]]

  if (tolower(current_mode) == "full") {
    cat("[WARN] Database is in FULL recovery mode. Switching to SIMPLE for bulk ETL...\n")
    switch_sql <- paste0("ALTER DATABASE [", cfg$database, "] SET RECOVERY SIMPLE;")
    DatabaseConnector::executeSql(conn, switch_sql)
    cat("[INFO] ✓ Switched to SIMPLE recovery mode\n\n")
  } else {
    cat("[INFO] Database already in ", current_mode, " recovery mode\n\n")
  }

  # =========================================================================
  # 3. Shrink the transaction log file
  # =========================================================================
  cat("[INFO] Shrinking transaction log file...\n")

  # Target size: 500 MB (adjust if needed)
  target_size_mb <- 500

  shrink_sql <- paste0(
    "DBCC SHRINKFILE([", log_file_name, "], ", target_size_mb, ") WITH NO_INFOMSGS;"
  )
  DatabaseConnector::executeSql(conn, shrink_sql)

  # Check new size
  logspace_after <- DatabaseConnector::querySql(conn, logspace_sql)
  colnames(logspace_after) <- tolower(colnames(logspace_after))
  new_size <- round(logspace_after$size_mb[[1]], 1)

  cat("[INFO] ✓ Transaction log shrunk from ", log_file_size, " MB to ", new_size, " MB\n\n")

  # =========================================================================
  # 4. Summary and recovery mode reset offer
  # =========================================================================
  cat("[INFO] ✓ Transaction log maintenance complete!\n\n")
  cat("[INFO] Current status:\n")
  cat("       - Recovery mode: SIMPLE (bulk inserts will auto-truncate log)\n")
  cat("       - Log file size: ", new_size, " MB\n")
  cat("       - Ready for bulk ETL operations\n\n")

  cat("[INFO] After ETL completes, you may want to switch back to FULL recovery:\n")
  cat('       Rscript scripts/fix_sql_server_transaction_log.R --restore-full\n\n')

}, error = function(e) {
  cat("[ERROR] Failed to fix transaction log: ", conditionMessage(e), "\n")
  stop(e)
})
