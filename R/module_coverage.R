# =============================================================================
# R/module_coverage.R
#
# PURPOSE
#   Module-build coverage check: before spending 30-60 minutes generating data,
#   confirm that the Synthea modules that will run CAN produce the clinical
#   concepts each consuming Strategus study's cohorts need. This is the
#   pre-generation counterpart of consumer-study QC (R/consumer_qc.R), which
#   checks the final data.
#
#   How it works:
#     1. Collect every code the Synthea modules can emit: your custom module
#        AND the built-in modules in external/synthea, because workflow/04 runs
#        Synthea with all of them (it passes no -m flag).
#     2. Map those source codes (SNOMED-CT, RxNorm, LOINC, ...) to STANDARD
#        OMOP concepts through the loaded vocabulary ("Maps to").
#     3. For each consuming cohort, read its circe JSON and find the concept
#        sets that must be populated: the primary-criteria sets (any one is
#        enough) plus inclusion criteria that require "at least one" event.
#     4. A concept set is covered when at least one mapped module concept is the
#        set's concept, or a descendant of it (when the set includes
#        descendants), and is not excluded by the set.
#
# WHAT A PASS MEANS (limits)
#   "Covered" is necessary, not sufficient: the module can emit the concept, but
#   age, sex, branch probabilities and the ETL may still make it rare or empty.
#   The final data is judged by consumer-study QC. Not evaluated: cohorts whose
#   criteria have no concept set, source-concept sets, `includeMapped` items,
#   and OR-groups of inclusion rules (the check only under-requires).
#
# INPUTS   module JSON files, each consumer's inst/cohorts/<id>.json, omop_vocab
# OUTPUT   data frame of per-cohort coverage (see check_module_coverage())
# SIDE EFFECTS  none: read-only queries against the vocabulary schema.
# =============================================================================

if (!exists("%||%")) `%||%` <- function(a, b) if (is.null(a)) b else a

# NOTE: SqlRender::render(sql, ...) partial-matches argument names, so a template
# parameter called `s` or `sq` binds to render()'s own `sql` argument instead.
# Use descriptive parameter names (schema_name, ...) in every render() call.

# Synthea code-system names -> OMOP vocabulary_id. Systems not listed here are
# reported as unmapped rather than guessed at.
SYNTHEA_SYSTEM_TO_VOCAB <- c(
  "SNOMED-CT" = "SNOMED", "RxNorm" = "RxNorm", "LOINC" = "LOINC", "CVX" = "CVX",
  "ICD-10-CM" = "ICD10CM", "ICD-9-CM" = "ICD9CM", "CPT" = "CPT4", "HCPCS" = "HCPCS",
  "NUBC" = "NUBC"
)

# -----------------------------------------------------------------------------
# collect_codes_from_module
#
# Reads one Synthea GMF module and returns every code the module can EMIT.
# Codes are taken from the states themselves (`codes`, `code`, `value_code`).
# Transition blocks are skipped because their `condition` clauses test for a
# code rather than generate it, and so are the *End states (ConditionEnd,
# MedicationEnd, ...), which stop something that was already emitted.
#
# @param path   module JSON path
# @param label  how to report this module ("custom" or a relative file name)
# @return data.frame(module, state, state_type, system, code, display)
# -----------------------------------------------------------------------------
collect_codes_from_module <- function(path, label = basename(path)) {
  m <- tryCatch(jsonlite::fromJSON(path, simplifyVector = FALSE), error = function(e) NULL)
  empty <- data.frame(module = character(), state = character(), state_type = character(),
                      system = character(), code = character(), display = character(),
                      stringsAsFactors = FALSE)
  if (is.null(m) || is.null(m$states)) return(empty)

  skip_keys <- c("conditional_transition", "complex_transition", "direct_transition",
                 "distributed_transition", "lookup_table_transition")
  rows <- list()
  walk <- function(x, state, type) {
    if (!is.list(x)) return(invisible())
    if (!is.null(x$system) && !is.null(x$code) && !is.list(x$system) && !is.list(x$code)) {
      rows[[length(rows) + 1L]] <<- data.frame(
        module = label, state = state, state_type = type, system = as.character(x$system),
        code = as.character(x$code), display = as.character(x$display %||% ""),
        stringsAsFactors = FALSE)
      return(invisible())
    }
    for (nm in setdiff(names(x), skip_keys)) walk(x[[nm]], state, type)
    if (is.null(names(x))) for (el in x) walk(el, state, type)
  }
  for (state_name in names(m$states)) {
    st <- m$states[[state_name]]
    type <- st$type %||% ""
    if (grepl("End$", type)) next
    walk(st[setdiff(names(st), skip_keys)], state_name, type)
  }
  if (length(rows) == 0) return(empty)
  unique(do.call(rbind, rows))
}

# -----------------------------------------------------------------------------
# collect_all_module_codes
#
# The universe of codes Synthea can emit in a workflow/04 run: the custom
# module(s) plus every built-in module under <synthea_home>/src/main/resources/
# modules (recursively). The custom module is also copied into that folder by
# workflow/03/04; it is recognised by file name so it is not counted twice.
#
# @return list(codes = data.frame, builtin_found = logical, n_builtin = integer)
# -----------------------------------------------------------------------------
collect_all_module_codes <- function(custom_module_paths, synthea_home) {
  custom_names <- basename(custom_module_paths)
  parts <- lapply(custom_module_paths, function(p) collect_codes_from_module(p, "custom"))

  modules_dir <- file.path(synthea_home, "src", "main", "resources", "modules")
  builtin_found <- dir.exists(modules_dir)
  n_builtin <- 0L
  if (builtin_found) {
    files <- list.files(modules_dir, pattern = "\\.json$", recursive = TRUE, full.names = TRUE)
    files <- files[!basename(files) %in% custom_names]
    n_builtin <- length(files)
    for (f in files) {
      rel <- sub(paste0("^", gsub("([.|()\\^{}+$*?]|\\[|\\])", "\\\\\\1", modules_dir), "/?"), "", f)
      parts[[length(parts) + 1L]] <- collect_codes_from_module(f, paste0("built-in:", rel))
    }
  }
  list(codes = do.call(rbind, parts), builtin_found = builtin_found, n_builtin = n_builtin)
}

# -----------------------------------------------------------------------------
# map_codes_to_concepts
#
# Maps (system, code) pairs to standard OMOP concept ids using the vocabulary:
# the source concept's "Maps to" target, or the concept itself if it is
# standard. Batched per vocabulary; read-only.
#
# @return data.frame(system, code, concept_id) (unmapped codes are absent)
# -----------------------------------------------------------------------------
map_codes_to_concepts <- function(connection, vocab_schema, codes, batch_size = 500) {
  dbms <- connection@dbms
  out <- list()
  codes <- unique(codes[, c("system", "code")])
  codes$vocabulary_id <- unname(SYNTHEA_SYSTEM_TO_VOCAB[codes$system])
  codes <- codes[!is.na(codes$vocabulary_id), , drop = FALSE]
  for (vocab in unique(codes$vocabulary_id)) {
    sub <- codes[codes$vocabulary_id == vocab, , drop = FALSE]
    for (chunk in split(seq_len(nrow(sub)), ceiling(seq_len(nrow(sub)) / batch_size))) {
      code_list <- paste0("'", gsub("'", "''", sub$code[chunk], fixed = TRUE), "'", collapse = ", ")
      sql <- SqlRender::translate(SqlRender::render(
        "SELECT c.concept_code AS code,
                COALESCE(t.concept_id, CASE WHEN c.standard_concept = 'S' THEN c.concept_id END) AS concept_id
         FROM @vocab_schema.concept c
         LEFT JOIN @vocab_schema.concept_relationship r
                ON r.concept_id_1 = c.concept_id
               AND r.relationship_id = 'Maps to'
               AND r.invalid_reason IS NULL
         LEFT JOIN @vocab_schema.concept t ON t.concept_id = r.concept_id_2
         WHERE c.vocabulary_id = '@vocab_id' AND c.concept_code IN (@code_list);",
        vocab_schema = vocab_schema, vocab_id = vocab, code_list = code_list),
        targetDialect = dbms)
      res <- DatabaseConnector::querySql(connection, sql, snakeCaseToCamelCase = TRUE)
      if (nrow(res)) {
        res <- res[!is.na(res$conceptId), , drop = FALSE]
        out[[length(out) + 1L]] <- data.frame(
          system = names(SYNTHEA_SYSTEM_TO_VOCAB)[match(vocab, SYNTHEA_SYSTEM_TO_VOCAB)],
          code = as.character(res$code), concept_id = as.numeric(res$conceptId),
          stringsAsFactors = FALSE)
      }
    }
  }
  if (length(out) == 0) {
    return(data.frame(system = character(), code = character(), concept_id = numeric()))
  }
  unique(do.call(rbind, out))
}

# -----------------------------------------------------------------------------
# parse_cohort_requirements   (pure; no database)
#
# Reads a circe cohort JSON and returns what must be populated for the cohort
# to be non-empty:
#   primary   - concept-set ids of the primary criteria. The cohort needs ANY ONE.
#   required  - concept-set ids of inclusion criteria that need at least one
#               event, inside ALL groups (each is needed). OR-groups are skipped.
#   unevaluable - TRUE when a primary criterion has no concept set (e.g. an
#               observation-period or visit-only entry), so coverage is unknown.
#   concept_sets - list keyed by id: data.frame(concept_id, descendants,
#               excluded, mapped) of the set's items.
# -----------------------------------------------------------------------------
parse_cohort_requirements <- function(json_text) {
  j <- jsonlite::fromJSON(json_text, simplifyVector = FALSE)

  sets <- list()
  for (cs in j$ConceptSets %||% list()) {
    items <- cs$expression$items %||% list()
    sets[[as.character(cs$id)]] <- data.frame(
      concept_id  = vapply(items, function(i) as.numeric(i$concept$CONCEPT_ID), numeric(1)),
      descendants = vapply(items, function(i) isTRUE(i$includeDescendants), logical(1)),
      excluded    = vapply(items, function(i) isTRUE(i$isExcluded), logical(1)),
      mapped      = vapply(items, function(i) isTRUE(i$includeMapped), logical(1)),
      stringsAsFactors = FALSE)
  }

  codeset_of <- function(criterion) {
    inner <- criterion[[1]]
    if (is.null(inner$CodesetId)) NA_integer_ else as.integer(inner$CodesetId)
  }

  primary_ids <- vapply(j$PrimaryCriteria$CriteriaList %||% list(), codeset_of, integer(1))
  unevaluable <- length(primary_ids) == 0 || any(is.na(primary_ids))
  primary_ids <- primary_ids[!is.na(primary_ids)]

  required <- integer(0)
  walk_group <- function(g) {
    # Only an ALL group makes each of its "at least one" criteria mandatory.
    if (!identical(toupper(g$Type %||% ""), "ALL")) return(invisible())
    for (cr in g$CriteriaList %||% list()) {
      occ <- cr$Occurrence %||% list()
      type <- occ$Type %||% -1L; cnt <- occ$Count %||% 0L
      if (type %in% c(0L, 2L) && cnt >= 1L) {
        id <- codeset_of(cr$Criteria)
        if (!is.na(id)) required <<- c(required, id)
      }
    }
    for (sub in g$Groups %||% list()) walk_group(sub)
  }
  for (rule in j$InclusionRules %||% list()) walk_group(rule$expression)

  list(primary = unique(primary_ids), required = unique(required),
       unevaluable = unevaluable, concept_sets = sets)
}

# -----------------------------------------------------------------------------
# concept_set_hits
#
# Which of `module_concepts` fall inside one concept set: the set's included
# concepts (and their descendants where the item says so), minus anything the
# set excludes. Uses concept_ancestor, so it never expands the whole set.
#
# @param module_concepts numeric vector of standard concept ids the module emits
# @return numeric vector of the matching module concept ids
# -----------------------------------------------------------------------------
concept_set_hits <- function(connection, vocab_schema, set, module_concepts, batch_size = 900) {
  if (is.null(set) || nrow(set) == 0 || length(module_concepts) == 0) return(numeric(0))
  dbms <- connection@dbms

  matched_by <- function(items) {
    if (nrow(items) == 0) return(numeric(0))
    hits <- intersect(items$concept_id, module_concepts)           # the item itself
    desc_ids <- items$concept_id[items$descendants]
    if (length(desc_ids)) {
      for (chunk in split(module_concepts, ceiling(seq_along(module_concepts) / batch_size))) {
        sql <- SqlRender::translate(SqlRender::render(
          "SELECT DISTINCT descendant_concept_id AS concept_id
           FROM @vocab_schema.concept_ancestor
           WHERE ancestor_concept_id IN (@ancestors) AND descendant_concept_id IN (@descendants);",
          vocab_schema = vocab_schema, ancestors = desc_ids, descendants = chunk),
          targetDialect = dbms)
        res <- DatabaseConnector::querySql(connection, sql, snakeCaseToCamelCase = TRUE)
        hits <- union(hits, as.numeric(res$conceptId))
      }
    }
    hits
  }
  setdiff(matched_by(set[!set$excluded, , drop = FALSE]),
          matched_by(set[set$excluded, , drop = FALSE]))
}

# -----------------------------------------------------------------------------
# evaluate_cohort_coverage
#
# Applies the primary / required rules to per-set hits.
#
# @param req        parse_cohort_requirements() result
# @param hits       named list: concept-set id -> matching module concept ids
# @return list(status = "COVERED"|"NOT_COVERED"|"NOT_EVALUABLE", missing = <set ids>)
# -----------------------------------------------------------------------------
evaluate_cohort_coverage <- function(req, hits) {
  has <- function(id) length(hits[[as.character(id)]] %||% numeric(0)) > 0

  # A required inclusion criterion with no module code leaves the cohort empty
  # whatever the entry events do.
  missing_required <- req$required[!vapply(req$required, has, logical(1))]
  if (length(missing_required)) {
    return(list(status = "NOT_COVERED", missing = unique(missing_required)))
  }
  if (length(req$primary) > 0 && any(vapply(req$primary, has, logical(1)))) {
    return(list(status = "COVERED", missing = integer(0)))
  }
  # Primary criteria are OR-ed. If one has no concept set (observation period,
  # visit only, ...) it may still populate the cohort, so we cannot say.
  if (req$unevaluable) return(list(status = "NOT_EVALUABLE", missing = integer(0)))
  list(status = "NOT_COVERED", missing = unique(req$primary))
}

# -----------------------------------------------------------------------------
# check_module_coverage
#
# Runs the coverage check for every consumer.
#
# @param connection      DatabaseConnector connection (read-only use)
# @param vocab_schema    schema holding the loaded vocabulary
# @param consumers       `consumers` from read_consumers()
# @param module_codes    data.frame from collect_all_module_codes()$codes
# @param repo_root       this repo's root (consumer repos resolve from it)
# @return list(results, problems, unmapped_systems)
#   results: data.frame(consumer, cohort_id, cohort_name, role, status, detail,
#            provided_by, example_codes)
# -----------------------------------------------------------------------------
check_module_coverage <- function(connection, vocab_schema, consumers, module_codes,
                                  repo_root = getwd()) {
  mapped <- map_codes_to_concepts(connection, vocab_schema, module_codes)
  module_codes$concept_key <- paste(module_codes$system, module_codes$code)
  mapped$concept_key <- paste(mapped$system, mapped$code)
  by_concept <- merge(module_codes[, c("module", "state", "concept_key", "display")],
                      mapped[, c("concept_key", "concept_id")], by = "concept_key")
  module_concepts <- unique(by_concept$concept_id)
  unmapped_systems <- setdiff(unique(module_codes$system), names(SYNTHEA_SYSTEM_TO_VOCAB))

  results <- list(); problems <- character(0)
  for (co in consumers) {
    dir <- resolve_consumer_dir(co, repo_root)
    if (!dir.exists(dir)) {
      problems <- c(problems, paste0(co$study, ": repository not found at ", dir)); next
    }
    spec <- parse_spec_roles(file.path(dir, co$spec_script))
    roles <- list(target_id = co$target_id %||% spec$target_id,
                  outcome_ids = if (length(co$outcome_ids)) co$outcome_ids else spec$outcome_ids)
    manifest <- tryCatch(read_consumer_manifest(dir, co), error = function(e) {
      problems <<- c(problems, paste0(co$study, ": ", conditionMessage(e))); NULL })
    if (is.null(manifest)) next

    for (i in seq_len(nrow(manifest))) {
      cid <- manifest$cohortId[i]
      role <- if (isTRUE(cid == roles$target_id)) "target"
              else if (cid %in% roles$outcome_ids) "outcome" else "covariate"
      json_path <- file.path(dir, co$cohorts_json_dir, paste0(cid, ".json"))
      if (!file.exists(json_path)) {
        problems <- c(problems, paste0(co$study, ": missing cohort JSON ", json_path)); next
      }
      req <- parse_cohort_requirements(paste(readLines(json_path, warn = FALSE), collapse = "\n"))
      needed <- unique(c(req$primary, req$required))
      hits <- setNames(lapply(needed, function(id) {
        concept_set_hits(connection, vocab_schema, req$concept_sets[[as.character(id)]], module_concepts)
      }), as.character(needed))
      ev <- evaluate_cohort_coverage(req, hits)

      matched <- unique(unlist(hits[as.character(unique(c(req$primary, req$required)))]))
      src <- by_concept[by_concept$concept_id %in% matched, , drop = FALSE]
      provided_by <- if (nrow(src) == 0) "" else if (all(src$module == "custom")) "custom module"
                     else if (any(src$module == "custom")) "custom + built-in" else "built-in only"
      example <- head(unique(paste0(src$display, " [", src$module, "]")), 2)

      status <- ev$status
      detail <- if (length(ev$missing)) paste0("no module code reaches concept set(s) ",
                                               paste(ev$missing, collapse = ", ")) else ""
      if (cid %in% co$expected_empty) {
        detail <- paste(c(detail, if (status == "COVERED") "declared expected_empty but the module can emit it"
                                  else "expected empty"), collapse = if (nzchar(detail)) "; " else "")
        status <- if (status == "NOT_COVERED") "EXPECTED_EMPTY" else status
      }
      results[[length(results) + 1L]] <- data.frame(
        consumer = co$study, cohort_id = cid, cohort_name = manifest$cohortName[i], role = role,
        status = status, detail = detail, provided_by = provided_by,
        example_codes = paste(example, collapse = "; "), stringsAsFactors = FALSE)
    }
  }
  list(results = if (length(results)) do.call(rbind, results) else NULL,
       problems = problems, unmapped_systems = unmapped_systems)
}
