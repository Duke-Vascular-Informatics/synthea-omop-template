setwd("C:/Users/rapiduser/pad-oler-ssi-val")
source("renv/activate.R")
source("config.R")
cfg <- get_validation_config()
source("R/drivers.R")
source("R/connection.R")
configure_java(cfg)
cd <- build_connection_details(cfg)
conn <- DatabaseConnector::connect(cd)

cat("Creating index on ancestor_concept_id...\n")
t0 <- proc.time()
DatabaseConnector::executeSql(conn, "
  CREATE INDEX IX_concept_ancestor_ancestor
  ON cdm_synthea.concept_ancestor (ancestor_concept_id)
  INCLUDE (descendant_concept_id, min_levels_of_separation, max_levels_of_separation)
")
cat("Done in", (proc.time() - t0)["elapsed"], "sec\n")

cat("Creating index on descendant_concept_id...\n")
t0 <- proc.time()
DatabaseConnector::executeSql(conn, "
  CREATE INDEX IX_concept_ancestor_descendant
  ON cdm_synthea.concept_ancestor (descendant_concept_id)
  INCLUDE (ancestor_concept_id)
")
cat("Done in", (proc.time() - t0)["elapsed"], "sec\n")

DatabaseConnector::disconnect(conn)
cat("Indexes created successfully.\n")
