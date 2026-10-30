#!/usr/bin/env Rscript
################################################################################
# scripts/module_vocab_check.R
#
# PURPOSE
#   Look up every coded state in a Synthea module against the omop_vocab schema
#   and report codes that have no concept, or no standard concept to map to.
#   Such codes ETL to concept_id 0 with no error and show up later as an
#   unexplained zero (workspace CLAUDE.md Rule 1).
#
# USAGE
#   Rscript scripts/module_vocab_check.R <module.json> [--strict]
#   Called by workflow/03 (MODULE_VOCAB_CHECK=off|warn|strict, default warn).
#
# EXIT CODES
#   0  all looked-up codes resolve, or the check was skipped (no database)
#   2  --strict and at least one code did not resolve
#   3  could not connect (reported as a SKIP by the caller, never fatal unless strict)
#
# SYSTEMS CHECKED: SNOMED-CT, LOINC, RxNorm, CVX. Others (NUBC, DICOM, ...) are not
#   vocabulary concepts in this CDM and are ignored.
################################################################################
args <- commandArgs(trailingOnly = TRUE)
module_path <- args[1]; strict <- "--strict" %in% args
if (is.na(module_path) || !file.exists(module_path)) stop("Usage: module_vocab_check.R <module.json> [--strict]")
if (file.exists("renv/activate.R")) source("renv/activate.R")
if (!requireNamespace("DatabaseConnector", quietly = TRUE) || !requireNamespace("jsonlite", quietly = TRUE)) {
  cat("[SKIP] module vocab check: DatabaseConnector/jsonlite not installed.\n"); quit(status = 0)
}
source("config.R"); source("R/drivers.R"); source("R/connection.R")

module <- jsonlite::fromJSON(module_path, simplifyVector = FALSE)
sys_map <- c(`SNOMED-CT` = "SNOMED", LOINC = "LOINC", RxNorm = "RxNorm", CVX = "CVX")
codes <- do.call(rbind, lapply(names(module$states), function(n) {
  st <- module$states[[n]]; cds <- c(st$codes, if (!is.null(st$value_code)) list(st$value_code))
  if (!length(cds)) return(NULL)
  do.call(rbind, lapply(cds, function(cd) if (!is.null(cd$system) && !is.null(cd$code) && cd$system %in% names(sys_map))
    data.frame(state = n, vocab = sys_map[[cd$system]], code = as.character(cd$code), stringsAsFactors = FALSE)))
}))
codes <- unique(codes[codes$code != "REPLACE_ME", ])

cfg <- get_validation_config()
conn_err <- NULL
conn <- tryCatch(DatabaseConnector::connect(build_connection_details(cfg)), error = function(e) { conn_err <<- conditionMessage(e); NULL })
if (is.null(conn)) { cat("[SKIP] module vocab check: no database connection:", substr(conn_err, 1, 300), "\n"); quit(status = if (strict) 3 else 0) }
on.exit(DatabaseConnector::disconnect(conn), add = TRUE)

vs <- if (!is.null(cfg$vocabulary_schema)) cfg$vocabulary_schema else "omop_vocab"
bad <- list()
for (v in unique(codes$vocab)) {
  cv <- unique(codes$code[codes$vocab == v])
  lit <- paste0("'", gsub("'", "''", cv), "'", collapse = ",")
  # A code resolves if the concept exists AND is standard, or has a 'Maps to' standard target.
  res <- DatabaseConnector::querySql(conn, sprintf(
    "SELECT c.concept_code, MAX(CASE WHEN c.standard_concept = 'S' OR cr.concept_id_2 IS NOT NULL THEN 1 ELSE 0 END) AS ok
       FROM %1$s.concept c
       LEFT JOIN %1$s.concept_relationship cr ON cr.concept_id_1 = c.concept_id
            AND cr.relationship_id = 'Maps to' AND cr.invalid_reason IS NULL
      WHERE c.vocabulary_id = '%2$s' AND c.concept_code IN (%3$s) GROUP BY c.concept_code", vs, v, lit))
  names(res) <- tolower(names(res))
  ok <- res$concept_code[res$ok == 1]
  miss <- setdiff(cv, ok)
  if (length(miss)) bad[[v]] <- miss
}
if (length(bad) == 0L) {
  cat(sprintf("Vocabulary check PASSED: %d coded values resolve in %s.\n", nrow(codes), vs)); quit(status = 0)
}
for (v in names(bad)) for (cd in bad[[v]]) {
  st <- codes$state[codes$vocab == v & codes$code == cd]
  cat(sprintf("[VOCAB] %s code %s has no standard concept in %s (state(s): %s)\n", v, cd, vs, paste(st, collapse = ", ")))
}
cat("These ETL to concept_id 0. Verify with: Rscript scripts/concept_lookup.R \"<term>\" <Domain>\n")
quit(status = if (strict) 2 else 0)
