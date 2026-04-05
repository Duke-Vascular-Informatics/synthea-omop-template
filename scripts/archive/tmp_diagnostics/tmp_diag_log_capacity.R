source("config.R")
source("R/drivers.R")
source("R/connection.R")

cfg <- get_validation_config()
cd <- build_connection_details(cfg)
con <- connect_with_retry(cd, max_attempts = 2L)
on.exit(DatabaseConnector::disconnect(con), add = TRUE)

q1 <- "
SELECT
  DB_NAME(mf.database_id) AS db_name,
  mf.name AS logical_name,
  mf.physical_name,
  CAST(mf.size * 8.0 / 1024 AS DECIMAL(18,2)) AS size_mb,
  CASE mf.max_size
    WHEN -1 THEN 'UNLIMITED'
    ELSE CAST(CAST(mf.max_size * 8.0 / 1024 AS DECIMAL(18,2)) AS VARCHAR(50))
  END AS max_size_mb,
  CASE mf.is_percent_growth
    WHEN 1 THEN CONCAT(CAST(mf.growth AS VARCHAR(20)), '%')
    ELSE CONCAT(CAST(CAST(mf.growth * 8.0 / 1024 AS DECIMAL(18,2)) AS VARCHAR(50)), ' MB')
  END AS growth_setting,
  mf.state_desc
FROM sys.master_files mf
WHERE mf.database_id = DB_ID('omop_synth')
  AND mf.type_desc = 'LOG';
"

q2 <- "DBCC SQLPERF(LOGSPACE);"

q3 <- "
SELECT
  r.session_id,
  r.command,
  r.status,
  r.percent_complete,
  r.wait_type,
  r.wait_time,
  r.total_elapsed_time,
  r.cpu_time,
  s.login_name,
  s.host_name,
  s.program_name
FROM sys.dm_exec_requests r
JOIN sys.dm_exec_sessions s ON r.session_id = s.session_id
WHERE r.database_id = DB_ID('omop_synth')
ORDER BY r.total_elapsed_time DESC;
"

cat('=== LOG FILE DEFINITION ===\n')
print(DatabaseConnector::querySql(con, q1))
cat('\n=== LOG SPACE USAGE (ALL DBs) ===\n')
print(DatabaseConnector::querySql(con, q2))
cat('\n=== ACTIVE REQUESTS IN omop_synth ===\n')
print(DatabaseConnector::querySql(con, q3))
