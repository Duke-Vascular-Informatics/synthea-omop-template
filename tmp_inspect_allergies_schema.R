source("config.R")
source("R/drivers.R")
source("R/connection.R")

cfg <- get_validation_config()
cd <- build_connection_details(cfg)
conn <- DatabaseConnector::connect(cd)
on.exit(DatabaseConnector::disconnect(conn), add = TRUE)

sql <- "
SELECT COLUMN_NAME, ORDINAL_POSITION, DATA_TYPE
FROM INFORMATION_SCHEMA.COLUMNS
WHERE TABLE_SCHEMA = 'synthea'
  AND TABLE_NAME = 'allergies'
ORDER BY ORDINAL_POSITION;
"

print(DatabaseConnector::querySql(conn, sql))
