setwd("C:/Users/rapiduser/pad-oler-ssi-val")
source("renv/activate.R")
source("config.R")
cfg <- get_validation_config()
source("R/drivers.R")
source("R/connection.R")
configure_java(cfg)
cd <- build_connection_details(cfg)
conn <- DatabaseConnector::connect(cd)

# concept_ancestor lives in the shared vocabulary schema (omop_vocab), not in
# the per-study CDM schema.  The CDM schema exposes it via a SQL Server synonym,
# so OBJECT_ID('cdm_schema.concept_ancestor', 'U') always returns NULL and any
# index DDL targeting the synonym silently no-ops.  Indexes must be created
# directly on the physical table in omop_vocab.
vocab_schema <- cfg$vocab_schema  # "omop_vocab"

cat("Creating index on descendant_concept_id (", vocab_schema, ".concept_ancestor)...\n", sep = "")
t0 <- proc.time()
DatabaseConnector::executeSql(conn, paste0("
  IF NOT EXISTS (
    SELECT 1 FROM sys.indexes
    WHERE object_id = OBJECT_ID(N'", vocab_schema, ".concept_ancestor')
      AND name = 'IX_concept_ancestor_descendant'
  )
  BEGIN
    CREATE INDEX IX_concept_ancestor_descendant
    ON ", vocab_schema, ".concept_ancestor (descendant_concept_id)
    INCLUDE (ancestor_concept_id)
  END;
"))
cat("Done in", (proc.time() - t0)["elapsed"], "sec\n")

cat("Creating index on ancestor_concept_id (", vocab_schema, ".concept_ancestor)...\n", sep = "")
t0 <- proc.time()
DatabaseConnector::executeSql(conn, paste0("
  IF NOT EXISTS (
    SELECT 1 FROM sys.indexes
    WHERE object_id = OBJECT_ID(N'", vocab_schema, ".concept_ancestor')
      AND name = 'IX_concept_ancestor_ancestor'
  )
  BEGIN
    CREATE INDEX IX_concept_ancestor_ancestor
    ON ", vocab_schema, ".concept_ancestor (ancestor_concept_id)
    INCLUDE (descendant_concept_id, min_levels_of_separation, max_levels_of_separation)
  END;
"))
cat("Done in", (proc.time() - t0)["elapsed"], "sec\n")

DatabaseConnector::disconnect(conn)
cat("Indexes created successfully on", vocab_schema, ".concept_ancestor\n")
