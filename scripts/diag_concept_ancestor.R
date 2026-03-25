setwd("C:/Users/rapiduser/pad-oler-ssi-val")
source("renv/activate.R")
source("config.R")
cfg <- get_validation_config()
source("R/drivers.R")
source("R/connection.R")
configure_java(cfg)
cd <- build_connection_details(cfg)
conn <- DatabaseConnector::connect(cd)

cat("=== concept_ancestor row count ===\n")
n <- DatabaseConnector::querySql(conn, "SELECT COUNT(*) AS N FROM cdm_synthea.concept_ancestor")
cat("Rows:", n$N, "\n")

cat("\n=== concept_ancestor indexes ===\n")
idx <- DatabaseConnector::querySql(conn, "
  SELECT i.name, i.type_desc, ic.key_ordinal, c.name AS col_name
  FROM sys.indexes i
  JOIN sys.objects o ON i.object_id = o.object_id
  JOIN sys.schemas s ON o.schema_id = s.schema_id
  JOIN sys.index_columns ic ON ic.object_id = i.object_id AND ic.index_id = i.index_id
  JOIN sys.columns c ON c.object_id = o.object_id AND c.column_id = ic.column_id
  WHERE s.name = 'cdm_synthea' AND o.name = 'concept_ancestor'
  ORDER BY i.name, ic.key_ordinal
")
print(idx)

cat("\n=== sample query test (5 descendants of concept 4009551) ===\n")
t0 <- proc.time()
test <- DatabaseConnector::querySql(conn, "
  SELECT TOP 5 descendant_concept_id
  FROM cdm_synthea.concept_ancestor
  WHERE ancestor_concept_id = 4009551
")
elapsed <- proc.time() - t0
cat("Elapsed:", elapsed["elapsed"], "sec\n")
print(test)

DatabaseConnector::disconnect(conn)
cat("Done.\n")
