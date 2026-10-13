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
#        descendants), and is not excluded by the set, AND the concept's OMOP
#        domain is the one the criterion's table holds (see below).
#
#   DOMAIN-AWARENESS
#   A circe criterion reads exactly one OMOP table: PrimaryCriteria `Observation`
#   reads `observation`, `ConditionOccurrence` reads `condition_occurrence`, and so
#   on. A concept set can span several domains (a "falls" set may hold Condition
#   fractures and Observation fall-history concepts), yet only concepts whose
#   domain_id belongs to the criterion's table can ever appear in that table. So a
#   mapped concept counts toward a criterion only when its domain_id matches
#   (CRITERION_TABLE_DOMAIN). The domain is judged from the MAPPED STANDARD CONCEPT,
#   never from the Synthea state type: ETLSyntheaBuilder routes a conditions.csv
#   row to the observation table when the standard concept's domain is Observation,
#   so a ConditionOnset state with an Observation-domain concept DOES satisfy an
#   Observation criterion. Criteria on tables outside the map (Death, Specimen, ...)
#   and concepts with no known domain are not domain-filtered (the check only
#   under-requires).
#
# WHAT A PASS MEANS (limits)
#   "Covered" is necessary, not sufficient: the module can emit the concept, but
#   age, sex, branch probabilities and the ETL may still make it rare or empty.
#   The final data is judged by consumer-study QC. Not evaluated: cohorts whose
#   criteria have no concept set, source-concept sets, `includeMapped` items,
#   and OR-groups of inclusion rules (the check only under-requires).
#
#   Visit criteria are not evaluated either. Synthea never emits a visit concept
#   through a code: the ETL derives visit_concept_id from the encounter class. So a
#   VisitOccurrence entry event (e.g. "Inpatient Visit") is treated as satisfiable
#   and the cohort is judged on its other required criteria; a cohort that is only
#   a visit criterion is reported NOT_EVALUABLE.
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

# circe criterion name (= the OMOP table it reads) -> the concept domain_id that table
# holds. Era criteria read tables derived from the event tables, so they hold the same
# domain. Visit criteria are deliberately absent: they are not judged (see header).
CRITERION_TABLE_DOMAIN <- c(
  ConditionOccurrence = "Condition",   ConditionEra = "Condition",
  Observation         = "Observation",
  DrugExposure        = "Drug",        DrugEra = "Drug", DoseEra = "Drug",
  ProcedureOccurrence = "Procedure",
  Measurement         = "Measurement",
  DeviceExposure      = "Device"
)

# -----------------------------------------------------------------------------
# filter_hits_by_domain   (pure; no database)
#
# Keeps the concepts that can actually appear in the table a criterion reads.
#
# @param concept_ids numeric vector of mapped standard concept ids
# @param domains     named character vector: names = concept id, values = domain_id
#                    (NULL = no domain information, nothing is filtered)
# @param table       circe criterion name, e.g. "Observation" (NA = not filtered)
# @return numeric vector: concept_ids whose domain matches the table's domain; a concept
#         with unknown (NA) domain is kept, so a gap in the vocabulary never creates a
#         false NOT_COVERED.
# -----------------------------------------------------------------------------
filter_hits_by_domain <- function(concept_ids, domains, table = NA_character_) {
  want <- unname(CRITERION_TABLE_DOMAIN[table %||% NA_character_])
  if (is.na(want) || is.null(domains) || length(concept_ids) == 0) return(concept_ids)
  have <- unname(domains[as.character(concept_ids)])
  concept_ids[is.na(have) | have == want]
}

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
# standard. The target's domain_id is returned too, because it decides which OMOP
# table the ETL writes the event to (and so which criteria it can satisfy).
# Batched per vocabulary; read-only.
#
# @return data.frame(system, code, concept_id, domain_id) (unmapped codes are absent)
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
                COALESCE(t.concept_id, CASE WHEN c.standard_concept = 'S' THEN c.concept_id END) AS concept_id,
                COALESCE(t.domain_id, CASE WHEN c.standard_concept = 'S' THEN c.domain_id END) AS domain_id
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
          domain_id = as.character(res$domainId), stringsAsFactors = FALSE)
      }
    }
  }
  if (length(out) == 0) {
    return(data.frame(system = character(), code = character(), concept_id = numeric(),
                      domain_id = character()))
  }
  unique(do.call(rbind, out))
}

# -----------------------------------------------------------------------------
# parse_cohort_requirements   (pure; no database)
#
# Reads a circe cohort JSON and returns what must be populated for the cohort
# to be non-empty:
#   primary   - concept-set ids of the primary criteria. The cohort needs ANY ONE.
#   primary_table - the circe criterion (= OMOP table) each `primary` id is read from,
#               e.g. "Observation"; same length and order as `primary`.
#   required  - list of requirements, each a vector of concept-set ids satisfied by ANY of
#               them: one per "at least one" criterion inside an ALL group, and one per
#               ANY group whose criteria are all plain "at least one" concept-set criteria.
#   required_table - list parallel to `required`: the criterion name of each id. The same
#               concept set can be read by criteria on different tables, so the table
#               belongs to the criterion, not to the concept set.
#   unevaluable - TRUE when a primary criterion has no concept set (e.g. an
#               observation-period entry), so coverage is unknown.
#   visit_entry - TRUE when a primary criterion is a visit criterion (not judged).
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
  # Visit criteria are not judged here (see the header): Synthea gets visit types from
  # the ETL's encounter-class mapping, not from codes in the module.
  is_visit <- function(criterion) names(criterion)[1] %in% c("VisitOccurrence", "VisitDetail")

  primary_list <- j$PrimaryCriteria$CriteriaList %||% list()
  visit_entry  <- any(vapply(primary_list, is_visit, logical(1)))
  evaluable    <- primary_list[!vapply(primary_list, is_visit, logical(1))]
  primary_ids  <- vapply(evaluable, codeset_of, integer(1))
  # The criterion's name (first list key) is the OMOP table it reads.
  primary_tbl  <- vapply(evaluable, function(cr) names(cr)[1], character(1))
  unevaluable  <- (length(primary_list) == 0) || any(is.na(primary_ids))
  primary_tbl  <- primary_tbl[!is.na(primary_ids)]
  primary_ids  <- primary_ids[!is.na(primary_ids)]
  # Drop exact repeats (same set read from the same table); keep the same set on two tables.
  keep_p       <- !duplicated(paste(primary_ids, primary_tbl))
  primary_ids  <- primary_ids[keep_p]
  primary_tbl  <- primary_tbl[keep_p]

  # Each requirement is a vector of concept-set ids satisfied by ANY of them.
  #   ALL group: every criterion that needs "at least one" event is its own requirement
  #              (a vector of length one); sub-groups are walked.
  #   ANY group: one requirement made of all its criteria, but only when EVERY criterion
  #              is a plain "at least one" concept-set criterion; otherwise the group is
  #              skipped (the check only under-requires).
  # Visit criteria and criteria without a concept set are never required.
  required <- list(); required_table <- list()
  add_required <- function(ids, tables) {
    required[[length(required) + 1L]] <<- ids
    required_table[[length(required_table) + 1L]] <<- tables
  }
  at_least_one <- function(cr) {
    occ <- cr$Occurrence %||% list()
    (occ$Type %||% -1L) %in% c(0L, 2L) && (occ$Count %||% 0L) >= 1L
  }
  walk_group <- function(g) {
    type <- toupper(g$Type %||% "")
    crits <- g$CriteriaList %||% list()
    if (type == "ALL") {
      for (cr in crits) {
        if (at_least_one(cr) && !is_visit(cr$Criteria)) {
          id <- codeset_of(cr$Criteria)
          if (!is.na(id)) add_required(id, names(cr$Criteria)[1])
        }
      }
      for (sub in g$Groups %||% list()) walk_group(sub)
    } else if (type == "ANY" && length(crits) > 0 && length(g$Groups %||% list()) == 0) {
      ids <- vapply(crits, function(cr)
        if (at_least_one(cr) && !is_visit(cr$Criteria)) codeset_of(cr$Criteria) else NA_integer_, integer(1))
      if (!anyNA(ids)) {
        tbls <- vapply(crits, function(cr) names(cr$Criteria)[1], character(1))
        add_required(ids[!duplicated(paste(ids, tbls))], tbls[!duplicated(paste(ids, tbls))])
      }
    }
  }
  for (rule in j$InclusionRules %||% list()) walk_group(rule$expression)

  # Drop duplicate requirements (same ids on the same tables) from both lists together.
  keep_r <- !duplicated(mapply(function(i, t) paste(i, t, collapse = ","), required, required_table))
  list(primary = primary_ids, primary_table = primary_tbl,
       required = required[keep_r], required_table = required_table[keep_r],
       unevaluable = unevaluable, visit_entry = visit_entry, concept_sets = sets)
}

# -----------------------------------------------------------------------------
# concept_set_hits
#
# Which of `module_concepts` fall inside one concept set: the set's included
# concepts (and their descendants where the item says so), minus anything the
# set excludes. Uses concept_ancestor, so it never expands the whole set. Domain-agnostic
# on purpose: the domain test depends on the criterion that reads the set, not on the set,
# so it is applied afterwards by filter_hits_by_domain().
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
# Applies the primary / required rules to per-set hits, counting only the hits whose
# concept domain belongs to the table the criterion reads.
#
# @param req        parse_cohort_requirements() result
# @param hits       named list: concept-set id -> matching module concept ids (any domain)
# @param domains    named character vector: names = concept id, values = domain_id
#                   (NULL = skip the domain test)
# @return list(status = "COVERED"|"NOT_COVERED"|"NOT_EVALUABLE", missing = <set ids>, note,
#              domain_notes = named character vector: set id -> reason, for sets that
#              the module reaches only in a domain the criterion does not read)
# -----------------------------------------------------------------------------
evaluate_cohort_coverage <- function(req, hits, domains = NULL) {
  # Concepts of set `id` that can reach the table `tbl` (NA tbl = no domain test).
  hits_for <- function(id, tbl) {
    filter_hits_by_domain(hits[[as.character(id)]] %||% numeric(0), domains, tbl)
  }
  has <- function(id, tbl) length(hits_for(id, tbl)) > 0
  # Tables are optional so hand-built requirement lists (and older callers) still work.
  p_tbl <- req$primary_table %||% rep(NA_character_, length(req$primary))
  r_tbl <- req$required_table %||% lapply(req$required, function(ids) rep(NA_character_, length(ids)))

  # For a missing set: say so when the module DOES reach the set, just in another domain.
  # Named by set id; sets with no domain problem are left out.
  notes_for <- function(ids, tbls) {
    out <- character(0)
    for (k in seq_along(ids)) {
      all_hits <- hits[[as.character(ids[k])]] %||% numeric(0)
      if (length(all_hits) == 0 || has(ids[k], tbls[k])) next
      found <- sort(unique(stats::na.omit(unname(domains[as.character(all_hits)]))))
      out[as.character(ids[k])] <- paste0(
        "codes reach the concept set only in the ", paste(found, collapse = "/"),
        " domain; criterion reads ", tbls[k])
    }
    out
  }
  visit_entry <- isTRUE(req$visit_entry)

  # A required inclusion criterion (or ANY-group) with no module code leaves the cohort
  # empty whatever the entry events do.
  covered_req <- vapply(seq_along(req$required), function(k)
    any(mapply(has, req$required[[k]], r_tbl[[k]])), logical(1))
  if (any(!covered_req)) {
    bad <- which(!covered_req)
    notes <- unlist(lapply(bad, function(k) notes_for(req$required[[k]], r_tbl[[k]])))
    return(list(status = "NOT_COVERED", missing = unique(unlist(req$required[bad])), note = "",
                domain_notes = notes[!duplicated(names(notes))]))
  }
  if (length(req$primary) > 0 && any(mapply(has, req$primary, p_tbl))) {
    return(list(status = "COVERED", missing = integer(0), note = "", domain_notes = character(0)))
  }
  # Visit entry events are not judged (the ETL derives visit types from encounter
  # class). If the cohort has other required criteria, those decide and they are met.
  if (visit_entry) {
    if (length(req$required) > 0) {
      return(list(status = "COVERED", missing = integer(0), domain_notes = character(0),
                  note = "visit entry event not evaluated; its required criteria are covered"))
    }
    return(list(status = "NOT_EVALUABLE", missing = integer(0), domain_notes = character(0),
                note = "visit-only cohort: visit types come from the ETL, not module codes"))
  }
  # Primary criteria are OR-ed. If one has no concept set (observation period, ...)
  # it may still populate the cohort, so we cannot say.
  if (req$unevaluable) {
    return(list(status = "NOT_EVALUABLE", missing = integer(0), note = "", domain_notes = character(0)))
  }
  list(status = "NOT_COVERED", missing = unique(req$primary), note = "",
       domain_notes = notes_for(req$primary, p_tbl))
}

# -----------------------------------------------------------------------------
# satisfying_concepts   (pure)
#
# The module concepts that actually satisfy some criterion of the cohort: its primary and
# required sets, each filtered to the domain of the table that criterion reads. Used to
# report which module codes provide a cohort, so a concept that cannot reach the table
# is never credited.
# -----------------------------------------------------------------------------
satisfying_concepts <- function(req, hits, domains = NULL) {
  p_tbl <- req$primary_table %||% rep(NA_character_, length(req$primary))
  r_tbl <- req$required_table %||% lapply(req$required, function(ids) rep(NA_character_, length(ids)))
  ids  <- c(req$primary, unlist(req$required))
  tbls <- c(p_tbl, unlist(r_tbl))
  unique(unlist(lapply(seq_along(ids), function(k)
    filter_hits_by_domain(hits[[as.character(ids[k])]] %||% numeric(0), domains, tbls[k]))))
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
  # concept id -> OMOP domain of the mapped standard concept. This (not the Synthea state
  # type) decides which table the ETL writes the event to, hence which criteria it can meet.
  dom <- unique(mapped[, c("concept_id", "domain_id")])
  concept_domains <- setNames(dom$domain_id, as.character(dom$concept_id))
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
      needed <- unique(c(req$primary, unlist(req$required)))
      hits <- setNames(lapply(needed, function(id) {
        concept_set_hits(connection, vocab_schema, req$concept_sets[[as.character(id)]], module_concepts)
      }), as.character(needed))
      ev <- evaluate_cohort_coverage(req, hits, concept_domains)

      # Credit only concepts that can reach the table their criterion reads.
      matched <- satisfying_concepts(req, hits, concept_domains)
      src <- by_concept[by_concept$concept_id %in% matched, , drop = FALSE]
      provided_by <- if (nrow(src) == 0) "" else if (all(src$module == "custom")) "custom module"
                     else if (any(src$module == "custom")) "custom + built-in" else "built-in only"
      example <- head(unique(paste0(src$display, " [", src$module, "]")), 2)

      status <- ev$status
      # Sets reached only in the wrong domain get their own reason; the rest keep the
      # original "no module code reaches" wording.
      detail <- if (length(ev$missing)) {
        no_code <- setdiff(as.character(ev$missing), names(ev$domain_notes))
        paste(c(if (length(no_code)) paste0("no module code reaches concept set(s) ",
                                            paste(no_code, collapse = ", ")),
                if (length(ev$domain_notes)) paste0("concept set ", names(ev$domain_notes), ": ",
                                                    ev$domain_notes)), collapse = "; ")
      } else ev$note
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
