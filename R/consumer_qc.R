# =============================================================================
# R/consumer_qc.R
#
# PURPOSE
#   Consumer-study QC: prove that the synthetic dataset this -synth repo
#   produces still contains the patients that each consuming Strategus study
#   needs, so regenerating or changing the dataset cannot silently break a
#   study that depends on it.
#
#   For every study listed in consumers.yaml this module:
#     1. reads that study's cohort manifest (inst/Cohorts.csv) and circe JSON,
#     2. renders SQL from the JSON exactly as Strategus does at run time
#        (Strategus never reads inst/sql/*.sql; CohortGenerator re-renders from
#        the JSON with CirceR), so the QC tests the logic the study will run,
#     3. instantiates every cohort against the synthetic CDM with HADES
#        CohortGenerator into a scratch cohort table,
#     4. counts subjects per cohort and, for outcomes, subjects who are also in
#        the target cohort,
#     5. compares each count with a per-role minimum and drops the scratch
#        tables.
#
#   In a Strategus study the COHORT ROLES are:
#     target     - the one target cohort (targetId in the spec script)
#     outcome    - outcome cohorts (outcomeIds in the spec script)
#     covariate  - every other cohort in inst/Cohorts.csv. Strategus treats the
#                  remaining cohorts as covariate cohorts, so checking cohorts,
#                  covariates and outcomes is one mechanism.
#
# INPUTS   consumers.yaml (this repo), each consumer's inst/Cohorts.csv,
#          inst/cohorts/<id>.json, and CreateStrategusAnalysisSpecification.R
# OUTPUT   data frame of per-cohort results (see evaluate_consumer_results())
#
# SIDE EFFECTS
#   Creates and drops scratch cohort tables (prefix qc_consumer_) in the
#   results schema. Never writes to the CDM schema.
#
# LIMITS (by design)
#   - Cohort membership is checked at the subject level. Time-at-risk windows
#     and covariate windows are not re-run; a pass means the cohorts are
#     populated, not that every downstream estimate will be estimable.
#   - A hand-authored (circe escape hatch) cohort is checked using the
#     placeholder JSON that Strategus will actually run, not its .sql; such
#     cohorts are flagged in the output.
# =============================================================================

`%||%` <- function(a, b) if (is.null(a)) b else a

# NOTE: SqlRender::render(sql, ...) partial-matches argument names, so a template
# parameter called `s` or `sq` binds to render()'s own `sql` argument instead.
# Always use descriptive parameter names (schema_name, table_name, ...).

# -----------------------------------------------------------------------------
# read_consumers
#
# Reads and validates consumers.yaml, applying defaults.
#
# @param path  Path to consumers.yaml.
# @return list(dataset_id = <chr|NA>, consumers = list of normalised entries).
#         Each entry has: study, repo_dir, cohorts_manifest, cohorts_json_dir,
#         spec_script, target_id, outcome_ids, min_target_subjects,
#         min_outcome_subjects, min_covariate_subjects.
# -----------------------------------------------------------------------------
read_consumers <- function(path = "consumers.yaml") {
  if (!file.exists(path)) stop("consumers file not found: ", path)
  y <- yaml::read_yaml(path)
  entries <- y$consumers %||% list()

  as_int <- function(x) if (is.null(x) || length(x) == 0 || all(is.na(x))) NULL else as.integer(unlist(x))

  consumers <- lapply(entries, function(co) {
    if (is.null(co$study) || !nzchar(co$study)) {
      stop("every consumers.yaml entry needs a `study` (the consumer repo's directory name)")
    }
    list(
      study                  = co$study,
      repo_dir               = co$repo_dir,
      cohorts_manifest       = co$cohorts_manifest %||% "inst/Cohorts.csv",
      cohorts_json_dir       = co$cohorts_json_dir %||% "inst/cohorts",
      spec_script            = co$spec_script %||% "CreateStrategusAnalysisSpecification.R",
      target_id              = as_int(co$target_id),
      outcome_ids            = as_int(co$outcome_ids),
      min_target_subjects    = as.numeric(co$min_target_subjects    %||% 100),
      min_outcome_subjects   = as.numeric(co$min_outcome_subjects   %||% 10),
      min_covariate_subjects = as.numeric(co$min_covariate_subjects %||% 1)
    )
  })

  studies <- vapply(consumers, function(co) co$study, character(1))
  if (anyDuplicated(studies)) {
    stop("duplicate consumer study in consumers.yaml: ",
         paste(unique(studies[duplicated(studies)]), collapse = ", "))
  }
  list(dataset_id = y$dataset_id %||% NA_character_, consumers = consumers)
}

# -----------------------------------------------------------------------------
# parse_spec_roles
#
# Reads the cohort roles out of a consumer's CreateStrategusAnalysisSpecification.R
# by pattern-matching the `targetId <-`, `outcomeIds <-` and `HAND_AUTHORED <-`
# assignments, which the strategus-study-template defines. Comments are
# stripped first. Anything it cannot parse comes back NULL / empty so the
# caller can ask for explicit target_id / outcome_ids in consumers.yaml.
#
# @return list(target_id = <int|NULL>, outcome_ids = <int>, hand_authored = <int>)
# -----------------------------------------------------------------------------
parse_spec_roles <- function(spec_path) {
  if (!file.exists(spec_path)) {
    return(list(target_id = NULL, outcome_ids = integer(0), hand_authored = integer(0)))
  }
  txt <- readLines(spec_path, warn = FALSE)
  txt <- sub("#.*$", "", txt)
  txt <- paste(txt, collapse = "\n")

  ints_after <- function(var, allow_vector) {
    pat <- paste0("(?<![A-Za-z0-9_.])", var, "\\s*(?:<-|=)\\s*(",
                  if (allow_vector) "c\\([^)]*\\)|integer\\(0\\)|" else "",
                  "[0-9]+L?)")
    m <- regmatches(txt, regexec(pat, txt, perl = TRUE))[[1]]
    if (length(m) < 2) return(NULL)
    ids <- regmatches(m[2], gregexpr("[0-9]+", m[2]))[[1]]
    if (identical(m[2], "integer(0)")) ids <- character(0)
    as.integer(ids)
  }

  target <- ints_after("targetId", allow_vector = FALSE)
  if (!is.null(target) && length(target) == 1 && target == 0L) target <- NULL  # template placeholder
  outcomes <- ints_after("outcomeIds", allow_vector = TRUE) %||% integer(0)
  outcomes <- outcomes[outcomes != 0L]                                          # template placeholder
  hand <- ints_after("HAND_AUTHORED", allow_vector = TRUE) %||% integer(0)

  list(target_id = target, outcome_ids = outcomes, hand_authored = hand)
}

# -----------------------------------------------------------------------------
# resolve_consumer_dir
#
# A consumer repo is a sibling of this repo in the workspace unless repo_dir
# says otherwise. Study identity is taken from the configured name, never from
# a file path (see strategus-study-template conventions, section 11.2).
# -----------------------------------------------------------------------------
resolve_consumer_dir <- function(consumer, repo_root) {
  if (!is.null(consumer$repo_dir) && nzchar(consumer$repo_dir)) {
    d <- consumer$repo_dir
    if (!grepl("^(/|[A-Za-z]:)", d)) d <- file.path(repo_root, d)
    return(normalizePath(d, winslash = "/", mustWork = FALSE))
  }
  normalizePath(file.path(repo_root, "..", consumer$study), winslash = "/", mustWork = FALSE)
}

# -----------------------------------------------------------------------------
# load_consumer_cohorts
#
# Builds the cohort definition set for one consumer: cohortId, cohortName,
# json, sql. SQL is rendered from the JSON with CirceR the way Strategus does
# (generateStats = FALSE: membership is identical and no inclusion-statistics
# tables are needed for QC). Manifest rows with cohort_id 0 are the template's
# example row and are skipped.
# -----------------------------------------------------------------------------
load_consumer_cohorts <- function(consumer_dir, consumer) {
  manifest_path <- file.path(consumer_dir, consumer$cohorts_manifest)
  if (!file.exists(manifest_path)) stop("cohort manifest not found: ", manifest_path)
  manifest <- read.csv(manifest_path, stringsAsFactors = FALSE)
  names(manifest) <- SqlRender::snakeCaseToCamelCase(names(manifest))
  if (!all(c("cohortId", "cohortName") %in% names(manifest))) {
    stop(manifest_path, " needs cohort_id and cohort_name columns")
  }
  manifest <- manifest[manifest$cohortId != 0, , drop = FALSE]
  if (nrow(manifest) == 0) stop(manifest_path, " lists no cohorts")
  if (anyDuplicated(manifest$cohortId)) stop("duplicate cohort_id in ", manifest_path)

  json_dir <- file.path(consumer_dir, consumer$cohorts_json_dir)
  rows <- lapply(seq_len(nrow(manifest)), function(i) {
    cid <- as.integer(manifest$cohortId[i])
    json_path <- file.path(json_dir, paste0(cid, ".json"))
    if (!file.exists(json_path)) {
      stop("missing cohort JSON for id ", cid, ": ", json_path,
           "\n  Strategus runs the JSON, so every manifest row needs one.")
    }
    json <- paste(readLines(json_path, warn = FALSE), collapse = "\n")
    sql <- CirceR::buildCohortQuery(
      CirceR::cohortExpressionFromJson(json),
      options = CirceR::createGenerateOptions(generateStats = FALSE)
    )
    data.frame(cohortId = cid, cohortName = manifest$cohortName[i],
               json = json, sql = sql, stringsAsFactors = FALSE)
  })
  do.call(rbind, rows)
}

# -----------------------------------------------------------------------------
# evaluate_consumer_results   (pure; no database)
#
# Turns subject counts into a PASS/FAIL table.
#
# @param consumer       normalised consumer entry (thresholds)
# @param cohort_names   named character vector: names = cohort ids
# @param roles          list(target_id, outcome_ids) -- all other ids are covariates
# @param subjects       named numeric: subjects per cohort id (missing = 0)
# @param overlap        named numeric: for outcome ids, subjects also in the target
# @param failed         named character: cohort id -> generation error message
# @param hand_authored  integer ids flagged as hand-authored in the spec script
# @return data.frame(consumer, cohort_id, cohort_name, role, subjects,
#         subjects_in_target, threshold, metric, status, note)
# -----------------------------------------------------------------------------
evaluate_consumer_results <- function(consumer, cohort_names, roles, subjects,
                                      overlap = numeric(0), failed = character(0),
                                      hand_authored = integer(0)) {
  ids <- as.integer(names(cohort_names))
  rows <- lapply(ids, function(id) {
    key <- as.character(id)
    role <- if (isTRUE(id == roles$target_id)) "target"
            else if (id %in% roles$outcome_ids) "outcome"
            else "covariate"
    n <- unname(subjects[key]); if (is.na(n)) n <- 0
    ov <- if (role == "outcome") { v <- unname(overlap[key]); if (is.na(v)) 0 else v } else NA_real_

    threshold <- switch(role, target = consumer$min_target_subjects,
                              outcome = consumer$min_outcome_subjects,
                              covariate = consumer$min_covariate_subjects)
    value  <- if (role == "outcome") ov else n
    metric <- if (role == "outcome") "subjects_in_target" else "subjects"

    note <- character(0)
    status <- if (value >= threshold) "PASS" else "FAIL"
    if (key %in% names(failed)) {
      status <- "FAIL"; note <- c(note, paste0("generation failed: ", failed[[key]]))
    }
    if (id %in% hand_authored) {
      note <- c(note, "hand-authored: checked on the placeholder JSON Strategus will run")
    }
    data.frame(consumer = consumer$study, cohort_id = id,
               cohort_name = unname(cohort_names[key]), role = role,
               subjects = n, subjects_in_target = ov, threshold = threshold,
               metric = metric, status = status,
               note = paste(note, collapse = "; "), stringsAsFactors = FALSE)
  })
  do.call(rbind, rows)
}

# -----------------------------------------------------------------------------
# check_registry_agreement   (pure apart from reading YAML)
#
# consumers.yaml is what drives the QC; the workspace registry's `used_by` is
# the shared record. They must agree, or one of them is out of date. Returns a
# character vector of problems (empty when they agree or nothing to compare).
# -----------------------------------------------------------------------------
check_registry_agreement <- function(dataset_id, studies, registry_path) {
  if (is.na(dataset_id) || !nzchar(dataset_id)) {
    return("consumers.yaml has no dataset_id, so it cannot be compared with synthetic_data/registry.yaml")
  }
  if (!file.exists(registry_path)) {
    return(paste0("registry not found at ", registry_path, "; agreement not checked"))
  }
  reg <- yaml::read_yaml(registry_path)
  hit <- Filter(function(d) identical(d$id, dataset_id), reg$datasets %||% list())
  if (length(hit) == 0) {
    return(paste0("dataset '", dataset_id, "' is not in ", registry_path))
  }
  used_by <- vapply(hit[[1]]$used_by %||% list(), function(u) u$study_id %||% "", character(1))
  problems <- character(0)
  for (s in setdiff(studies, used_by)) {
    problems <- c(problems, paste0("'", s, "' is in consumers.yaml but not in registry used_by for ", dataset_id))
  }
  for (s in setdiff(used_by, studies)) {
    problems <- c(problems, paste0("'", s, "' is in registry used_by for ", dataset_id, " but not in consumers.yaml (its cohorts are not being checked)"))
  }
  problems
}

# -----------------------------------------------------------------------------
# resolve_active_cdm_schema
#
# Mirrors resolve_cdm_schema() in scripts/quality_check_etl.R so both QC stages
# test the same schema: use `default_schema` if it holds person rows; otherwise
# the highest-numbered omop_synth_<study>_<n> schema that does (SQL Server).
# -----------------------------------------------------------------------------
resolve_active_cdm_schema <- function(connection, default_schema, study_name) {
  count_person <- function(schema) {
    tryCatch({
      sql <- SqlRender::translate(
        SqlRender::render("SELECT COUNT(*) AS n FROM @schema_name.person;", schema_name = schema),
        targetDialect = connection@dbms)
      as.numeric(DatabaseConnector::querySql(connection, sql, snakeCaseToCamelCase = TRUE)$n[[1]])
    }, error = function(e) 0)
  }
  if (count_person(default_schema) > 0) return(default_schema)

  base <- paste0("omop_synth_", study_name)
  rows <- DatabaseConnector::querySql(
    connection,
    paste0("SELECT name FROM sys.schemas WHERE name = '", gsub("'", "''", base),
           "' OR name LIKE '", gsub("'", "''", base), "[_]%';"),
    snakeCaseToCamelCase = TRUE)
  cands <- as.character(rows$name)
  suffix <- suppressWarnings(as.integer(sub(paste0("^", base, "_([0-9]+)$"), "\\1", cands)))
  for (cand in cands[order(ifelse(is.na(suffix), -1L, suffix), decreasing = TRUE)]) {
    if (count_person(cand) > 0) return(cand)
  }
  default_schema
}

# -----------------------------------------------------------------------------
# drop_scratch_tables
#
# Drops every table named in a CohortGenerator cohortTableNames list (cohort,
# inclusion/summary/censor stats, checksum, subset attrition). Failures are
# ignored: cleanup must never mask the QC result.
# -----------------------------------------------------------------------------
drop_scratch_tables <- function(connection, schema, table_names) {
  for (tbl in unique(unlist(table_names, use.names = FALSE))) {
    try(DatabaseConnector::executeSql(connection, SqlRender::translate(
      SqlRender::render("IF OBJECT_ID('@schema_name.@table_name', 'U') IS NOT NULL DROP TABLE @schema_name.@table_name;",
                        schema_name = schema, table_name = tbl),
      targetDialect = connection@dbms), progressBar = FALSE, reportOverallTime = FALSE),
      silent = TRUE)
  }
  invisible(NULL)
}

# -----------------------------------------------------------------------------
# run_consumer_cohort_qc
#
# Runs the QC for every consumer against one CDM schema.
#
# @param connection_details  DatabaseConnector connectionDetails
# @param cdm_schema          schema holding the synthetic CDM (read only)
# @param results_schema      schema for scratch cohort tables (must exist)
# @param consumers           the `consumers` list from read_consumers()
# @param repo_root           root of this -synth repo (siblings resolve from it)
# @return list(results = data.frame, problems = character): `problems` holds
#         consumers that could not be checked at all (repo missing, no usable
#         roles, JSON missing); each is a hard failure under --enforce_thresholds.
# -----------------------------------------------------------------------------
run_consumer_cohort_qc <- function(connection_details, cdm_schema, results_schema,
                                   consumers, repo_root = getwd()) {
  connection <- DatabaseConnector::connect(connection_details)
  on.exit(DatabaseConnector::disconnect(connection), add = TRUE)
  dbms <- connection@dbms

  all_results <- list()
  problems <- character(0)

  for (co in consumers) {
    dir <- resolve_consumer_dir(co, repo_root)
    if (!dir.exists(dir)) {
      problems <- c(problems, paste0(co$study, ": repository not found at ", dir,
                                     " (clone it into the workspace, or set repo_dir)"))
      next
    }

    spec <- parse_spec_roles(file.path(dir, co$spec_script))
    roles <- list(target_id = co$target_id %||% spec$target_id,
                  outcome_ids = if (length(co$outcome_ids)) co$outcome_ids else spec$outcome_ids)
    if (is.null(roles$target_id) || length(roles$outcome_ids) == 0) {
      problems <- c(problems, paste0(co$study, ": could not determine target and outcome cohort ids from ",
                                     co$spec_script, "; set target_id and outcome_ids in consumers.yaml"))
      next
    }

    cohorts <- tryCatch(load_consumer_cohorts(dir, co), error = function(e) {
      problems <<- c(problems, paste0(co$study, ": ", conditionMessage(e))); NULL })
    if (is.null(cohorts)) next
    missing_roles <- setdiff(c(roles$target_id, roles$outcome_ids), cohorts$cohortId)
    if (length(missing_roles)) {
      problems <- c(problems, paste0(co$study, ": role cohort id(s) not in the manifest: ",
                                     paste(missing_roles, collapse = ", ")))
      next
    }

    slug <- gsub("[^a-z0-9]+", "_", tolower(co$study))
    table_names <- CohortGenerator::getCohortTableNames(cohortTable = paste0("qc_consumer_", slug))
    CohortGenerator::createCohortTables(connection = connection, cohortDatabaseSchema = results_schema,
                                        cohortTableNames = table_names, incremental = FALSE)
    # CohortGenerator also creates checksum and subset-attrition tables that
    # dropCohortStatsTables() leaves behind, so drop every scratch table.
    cleanup <- function() drop_scratch_tables(connection, results_schema, table_names)

    outcome <- tryCatch({
      gen <- CohortGenerator::generateCohortSet(
        connection = connection, cdmDatabaseSchema = cdm_schema,
        cohortDatabaseSchema = results_schema, cohortTableNames = table_names,
        cohortDefinitionSet = cohorts, stopOnError = FALSE, incremental = FALSE)

      tbl <- paste0(results_schema, ".", table_names$cohortTable)
      counts <- DatabaseConnector::querySql(connection, SqlRender::translate(SqlRender::render(
        "SELECT cohort_definition_id, COUNT(DISTINCT subject_id) AS subjects
         FROM @tbl GROUP BY cohort_definition_id;", tbl = tbl), targetDialect = dbms),
        snakeCaseToCamelCase = TRUE)
      overlap <- DatabaseConnector::querySql(connection, SqlRender::translate(SqlRender::render(
        "SELECT o.cohort_definition_id AS cohort_definition_id,
                COUNT(DISTINCT o.subject_id) AS subjects
         FROM @tbl o
         INNER JOIN @tbl t ON t.subject_id = o.subject_id AND t.cohort_definition_id = @tid
         WHERE o.cohort_definition_id IN (@oids)
         GROUP BY o.cohort_definition_id;",
        tbl = tbl, tid = roles$target_id, oids = roles$outcome_ids), targetDialect = dbms),
        snakeCaseToCamelCase = TRUE)

      failed_rows <- gen[gen$generationStatus == "FAILED", , drop = FALSE]
      list(counts = counts, overlap = overlap, failed_rows = failed_rows)
    }, finally = cleanup())

    named <- function(df, col) setNames(as.numeric(df[[col]]), as.character(df$cohortDefinitionId))
    failed <- if (nrow(outcome$failed_rows)) {
      setNames(as.character(outcome$failed_rows$generationStatus), as.character(outcome$failed_rows$cohortId))
    } else character(0)

    all_results[[co$study]] <- evaluate_consumer_results(
      consumer = co,
      cohort_names = setNames(cohorts$cohortName, as.character(cohorts$cohortId)),
      roles = roles,
      subjects = named(outcome$counts, "subjects"),
      overlap = if (nrow(outcome$overlap)) named(outcome$overlap, "subjects") else numeric(0),
      failed = failed,
      hand_authored = spec$hand_authored)
  }

  list(results = if (length(all_results)) do.call(rbind, unname(all_results)) else NULL,
       problems = problems)
}
