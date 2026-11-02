# Tests for R/module_coverage.R (module-build coverage).
#
# Concept ids (910001...) and codes are FAKE test fixtures in a throwaway SQLite
# vocabulary. They make no claim about the OMOP vocabulary (Rule 1).
source(file.path(.PROJ_ROOT, "R/consumer_qc.R"))
source(file.path(.PROJ_ROOT, "R/module_coverage.R"))

write_module <- function(path, states) {
  writeLines(jsonlite::toJSON(list(name = "t", states = states), auto_unbox = TRUE), path)
}

test_that("collect_codes_from_module emits codes but skips guards and End states", {
  d <- withr::local_tempdir()
  p <- file.path(d, "m.json")
  write_module(p, list(
    Onset = list(type = "ConditionOnset", codes = list(list(system = "SNOMED-CT", code = "C1", display = "cond one")),
                 direct_transition = "Proc"),
    Proc  = list(type = "Procedure", codes = list(list(system = "SNOMED-CT", code = "P1", display = "proc one")),
                 conditional_transition = list(list(condition = list(condition_type = "Active Condition",
                   codes = list(list(system = "SNOMED-CT", code = "GUARD", display = "guard"))), transition = "Obs"))),
    Obs   = list(type = "Observation", codes = list(list(system = "LOINC", code = "L1", display = "lab")),
                 value_code = list(system = "SNOMED-CT", code = "V1", display = "value")),
    Stop  = list(type = "ConditionEnd", codes = list(list(system = "SNOMED-CT", code = "END1", display = "end")))
  ))
  codes <- collect_codes_from_module(p, "custom")
  expect_setequal(codes$code, c("C1", "P1", "L1", "V1"))
  expect_false(any(c("GUARD", "END1") %in% codes$code))
  expect_true(all(codes$module == "custom"))
})

test_that("collect_all_module_codes adds built-in modules and does not double count the custom one", {
  d <- withr::local_tempdir()
  home <- file.path(d, "synthea"); mdir <- file.path(home, "src", "main", "resources", "modules", "sub")
  dir.create(mdir, recursive = TRUE)
  custom <- file.path(d, "mine.json")
  write_module(custom, list(S = list(type = "ConditionOnset", codes = list(list(system = "SNOMED-CT", code = "C1")))))
  file.copy(custom, file.path(dirname(mdir), "mine.json"))                 # synced copy, same name
  write_module(file.path(mdir, "builtin.json"),
               list(S = list(type = "ConditionOnset", codes = list(list(system = "SNOMED-CT", code = "B1")))))
  r <- collect_all_module_codes(custom, home)
  expect_true(r$builtin_found); expect_equal(r$n_builtin, 1L)
  expect_setequal(r$codes$code, c("C1", "B1"))
  expect_match(r$codes$module[r$codes$code == "B1"], "^built-in:")
  expect_false(collect_all_module_codes(custom, file.path(d, "nowhere"))$builtin_found)
})

cohort_json <- function(primary_sets, concept_sets, inclusion = NULL, primary_table = "ConditionOccurrence") {
  jsonlite::toJSON(list(
    ConceptSets = lapply(names(concept_sets), function(id) list(id = as.integer(id), name = id,
      expression = list(items = lapply(seq_len(nrow(concept_sets[[id]])), function(i) list(
        concept = list(CONCEPT_ID = concept_sets[[id]]$concept_id[i]),
        includeDescendants = concept_sets[[id]]$descendants[i],
        isExcluded = concept_sets[[id]]$excluded[i], includeMapped = FALSE))))),
    PrimaryCriteria = list(CriteriaList = lapply(primary_sets, function(id)
      if (is.na(id)) list(ObservationPeriod = list()) else setNames(list(list(CodesetId = id)), primary_table))),
    InclusionRules = inclusion %||% list()), auto_unbox = TRUE)
}

test_that("parse_cohort_requirements finds primary (OR) and required inclusion sets", {  # ALL criteria, ANY groups, exactly-0
  cs <- list(`0` = data.frame(concept_id = 910001, descendants = TRUE, excluded = FALSE),
             `1` = data.frame(concept_id = 910002, descendants = FALSE, excluded = FALSE))
  incl <- list(list(name = "needs set 1", expression = list(Type = "ALL", CriteriaList = list(
    list(Criteria = list(Measurement = list(CodesetId = 1L)), Occurrence = list(Type = 2L, Count = 1L))),
    Groups = list())),
    list(name = "any group", expression = list(Type = "ANY", CriteriaList = list(
    list(Criteria = list(Measurement = list(CodesetId = 0L)), Occurrence = list(Type = 2L, Count = 1L))),
    Groups = list())),
    list(name = "must be absent", expression = list(Type = "ALL", CriteriaList = list(
    list(Criteria = list(Measurement = list(CodesetId = 0L)), Occurrence = list(Type = 0L, Count = 0L))),
    Groups = list())))
  req <- parse_cohort_requirements(cohort_json(c(0L), cs, incl))
  expect_equal(req$primary, 0L)
  expect_equal(req$required, list(1L, 0L)) # ALL-group criterion; the ANY group is one requirement; exactly-0 requires nothing
  expect_false(req$unevaluable)
  expect_equal(req$concept_sets[["0"]]$descendants, TRUE)
  req2 <- parse_cohort_requirements(cohort_json(c(0L, NA), cs))
  expect_true(req2$unevaluable)
})

test_that("visit entry events are not judged; the cohort rests on its other required criteria", {
  cs <- list(`0` = data.frame(concept_id = 9201, descendants = FALSE, excluded = FALSE),
             `1` = data.frame(concept_id = 910001, descendants = FALSE, excluded = FALSE))
  visit_json <- function(incl) jsonlite::toJSON(list(
    ConceptSets = lapply(names(cs), function(id) list(id = as.integer(id), name = id, expression = list(items = list(list(
      concept = list(CONCEPT_ID = cs[[id]]$concept_id), includeDescendants = FALSE, isExcluded = FALSE, includeMapped = FALSE))))),
    PrimaryCriteria = list(CriteriaList = list(list(VisitOccurrence = list(CodesetId = 0L)))),
    InclusionRules = incl), auto_unbox = TRUE)
  need1 <- list(list(name = "needs set 1", expression = list(Type = "ALL", CriteriaList = list(
    list(Criteria = list(ProcedureOccurrence = list(CodesetId = 1L)), Occurrence = list(Type = 2L, Count = 1L))), Groups = list())))

  # Visit-only cohort: nothing to judge.
  r0 <- parse_cohort_requirements(visit_json(list()))
  expect_true(r0$visit_entry); expect_length(r0$primary, 0)
  expect_equal(evaluate_cohort_coverage(r0, list())$status, "NOT_EVALUABLE")

  # Visit entry plus a required procedure criterion: judged on the procedure.
  r1 <- parse_cohort_requirements(visit_json(need1))
  expect_equal(r1$required, list(1L))
  expect_equal(evaluate_cohort_coverage(r1, list(`1` = 5))$status, "COVERED")
  expect_equal(evaluate_cohort_coverage(r1, list(`1` = numeric(0)))$status, "NOT_COVERED")

  # A required VISIT criterion is skipped, not required.
  incl_visit <- list(list(name = "inpatient", expression = list(Type = "ALL", CriteriaList = list(
    list(Criteria = list(VisitOccurrence = list(CodesetId = 0L)), Occurrence = list(Type = 2L, Count = 1L))), Groups = list())))
  expect_length(parse_cohort_requirements(visit_json(incl_visit))$required, 0)
})

test_that("an ANY inclusion group is one requirement satisfied by any of its sets", {
  cs <- list(`0` = data.frame(concept_id = 910001, descendants = FALSE, excluded = FALSE),
             `1` = data.frame(concept_id = 910002, descendants = FALSE, excluded = FALSE),
             `2` = data.frame(concept_id = 910003, descendants = FALSE, excluded = FALSE))
  crit <- function(id, type = 2L, cnt = 1L) list(Criteria = list(ConditionOccurrence = list(CodesetId = id)),
                                                 Occurrence = list(Type = type, Count = cnt))
  any_rule <- list(list(name = "any of 1,2", expression = list(Type = "ANY", CriteriaList = list(crit(1L), crit(2L)), Groups = list())))
  req <- parse_cohort_requirements(cohort_json(0L, cs, any_rule))
  expect_equal(req$required, list(c(1L, 2L)))
  expect_equal(evaluate_cohort_coverage(req, list(`0` = 1, `1` = numeric(0), `2` = 7))$status, "COVERED")      # one set is enough
  r <- evaluate_cohort_coverage(req, list(`0` = 1, `1` = numeric(0), `2` = numeric(0)))
  expect_equal(r$status, "NOT_COVERED"); expect_equal(r$missing, c(1L, 2L))

  # An ANY group containing a criterion that cannot be judged (an exclusion) is skipped, not required.
  mixed <- list(list(name = "mixed", expression = list(Type = "ANY",
              CriteriaList = list(crit(1L), crit(2L, type = 0L, cnt = 0L)), Groups = list())))
  expect_length(parse_cohort_requirements(cohort_json(0L, cs, mixed))$required, 0)
})

test_that("evaluate_cohort_coverage applies OR for primary and AND for required", {
  req <- list(primary = c(0L, 1L), required = list(2L), unevaluable = FALSE)
  expect_equal(evaluate_cohort_coverage(req, list(`0` = 1, `1` = numeric(0), `2` = 5))$status, "COVERED")
  r <- evaluate_cohort_coverage(req, list(`0` = 1, `1` = numeric(0), `2` = numeric(0)))
  expect_equal(r$status, "NOT_COVERED"); expect_equal(r$missing, 2L)
  expect_equal(evaluate_cohort_coverage(req, list(`0` = numeric(0), `1` = numeric(0), `2` = 5))$status, "NOT_COVERED")
  unk <- list(primary = 0L, required = list(), unevaluable = TRUE)
  expect_equal(evaluate_cohort_coverage(unk, list(`0` = numeric(0)))$status, "NOT_EVALUABLE")
  expect_equal(evaluate_cohort_coverage(unk, list(`0` = 3))$status, "COVERED")
})

test_that("check_module_coverage works end to end on a SQLite vocabulary", {
  skip_if_not_installed("RSQLite"); skip_if_not_installed("DatabaseConnector")
  tmp <- withr::local_tempdir()
  cd <- DatabaseConnector::createConnectionDetails(dbms = "sqlite", server = file.path(tmp, "v.sqlite"))
  con <- DatabaseConnector::connect(cd)
  ins <- function(name, df) DatabaseConnector::insertTable(con, databaseSchema = "main", tableName = name,
    data = df, dropTableIfExists = TRUE, createTable = TRUE, progressBar = FALSE, camelCaseToSnakeCase = FALSE)
  # Fake vocabulary: source SNOMED codes S1/S2 map to standard 910001 / 910002;
  # 910003 is a child of 910001. 910009 is a standard concept no module emits.
  ins("concept", data.frame(concept_id = c(8001, 8002, 910001, 910002, 910003, 910009),
      concept_code = c("S1", "S2", "910001", "910002", "910003", "910009"),
      vocabulary_id = c("SNOMED", "SNOMED", "X", "X", "X", "X"),
      standard_concept = c(NA, NA, "S", "S", "S", "S"),
      domain_id = c("Condition", "Condition", rep("Condition", 4))))
  ins("concept_relationship", data.frame(concept_id_1 = c(8001, 8002), concept_id_2 = c(910001, 910002),
      relationship_id = "Maps to", invalid_reason = NA_character_))
  ins("concept_ancestor", data.frame(ancestor_concept_id = c(910001, 910002, 910003, 910009, 910001),
      descendant_concept_id = c(910001, 910002, 910003, 910009, 910003)))
  DatabaseConnector::disconnect(con)

  # Module emits S1 (-> 910001, which is an ancestor of 910003) and S2 (-> 910002).
  mod <- file.path(tmp, "mine.json")
  write_module(mod, list(
    A = list(type = "ConditionOnset", codes = list(list(system = "SNOMED-CT", code = "S1", display = "one"))),
    B = list(type = "ConditionOnset", codes = list(list(system = "SNOMED-CT", code = "S2", display = "two")))))
  inv <- collect_all_module_codes(mod, file.path(tmp, "no-synthea"))

  # Fake consumer: cohort 11 target needs 910003 (a descendant of what the module
  # emits only via ancestor 910001 -> NOT covered: the module emits the PARENT, not the child);
  # cohort 12 outcome needs 910001 with descendants (covered); cohort 13 needs 910009 (not covered);
  # cohort 14 needs 910001 but excludes 910001 itself (not covered); cohort 15 declared expected_empty.
  cdir <- file.path(tmp, "study-a"); dir.create(file.path(cdir, "inst", "cohorts"), recursive = TRUE)
  set <- function(id, desc = FALSE, excl = FALSE) data.frame(concept_id = id, descendants = desc, excluded = excl)
  writeLines(c("atlas_id,cohort_id,cohort_name", "0,11,T needs child", "0,12,O covered", "0,13,C not covered",
               "0,14,C excluded", "0,15,C expected empty"), file.path(cdir, "inst", "Cohorts.csv"))
  writeLines(cohort_json(0L, list(`0` = set(910003))), file.path(cdir, "inst", "cohorts", "11.json"))
  writeLines(cohort_json(0L, list(`0` = set(910001, desc = TRUE))), file.path(cdir, "inst", "cohorts", "12.json"))
  writeLines(cohort_json(0L, list(`0` = set(910009, desc = TRUE))), file.path(cdir, "inst", "cohorts", "13.json"))
  writeLines(cohort_json(0L, list(`0` = rbind(set(910001, desc = TRUE), set(910001, TRUE, TRUE)))), file.path(cdir, "inst", "cohorts", "14.json"))
  writeLines(cohort_json(0L, list(`0` = set(910009))), file.path(cdir, "inst", "cohorts", "15.json"))
  writeLines(c("targetId   <- 11L", "outcomeIds <- c(12L)"), file.path(cdir, "CreateStrategusAnalysisSpecification.R"))

  yml <- file.path(tmp, "consumers.yaml")
  writeLines(c("dataset_id: ds", "consumers:", "  - study: study-a", paste0("    repo_dir: ", cdir),
               "    expected_empty: [15]"), yml)
  cfg <- read_consumers(yml)

  con <- DatabaseConnector::connect(cd); on.exit(DatabaseConnector::disconnect(con), add = TRUE)
  out <- check_module_coverage(con, "main", cfg$consumers, inv$codes, repo_root = file.path(tmp, "synth"))
  expect_length(out$problems, 0)
  st <- setNames(out$results$status, out$results$cohort_id)
  expect_equal(unname(st["11"]), "NOT_COVERED")      # module emits the parent 910001, not 910003
  expect_equal(unname(st["12"]), "COVERED")
  expect_equal(unname(st["13"]), "NOT_COVERED")
  expect_equal(unname(st["14"]), "NOT_COVERED")      # excluded by its own concept set
  expect_equal(unname(st["15"]), "EXPECTED_EMPTY")
  expect_equal(out$results$role[out$results$cohort_id == 11], "target")
  expect_equal(out$results$role[out$results$cohort_id == 12], "outcome")
  expect_equal(out$results$provided_by[out$results$cohort_id == 12], "custom module")
})

# =============================================================================
# Domain-awareness: a mapped concept only counts toward a criterion when its
# domain_id is the one the criterion's table holds.
# =============================================================================

test_that("parse_cohort_requirements records the table each criterion reads", {
  cs <- list(`0` = data.frame(concept_id = 910001, descendants = TRUE, excluded = FALSE),
             `1` = data.frame(concept_id = 910002, descendants = FALSE, excluded = FALSE))
  crit <- function(tbl, id, type = 2L, cnt = 1L) list(Criteria = setNames(list(list(CodesetId = id)), tbl),
                                                      Occurrence = list(Type = type, Count = cnt))
  incl <- list(
    list(name = "all", expression = list(Type = "ALL", CriteriaList = list(crit("Measurement", 1L)), Groups = list())),
    list(name = "any", expression = list(Type = "ANY", Groups = list(),
         CriteriaList = list(crit("DrugExposure", 0L), crit("ProcedureOccurrence", 1L)))))
  req <- parse_cohort_requirements(cohort_json(0L, cs, incl, primary_table = "Observation"))
  expect_equal(req$primary, 0L);              expect_equal(req$primary_table, "Observation")
  expect_equal(req$required, list(1L, c(0L, 1L)))
  expect_equal(req$required_table, list("Measurement", c("DrugExposure", "ProcedureOccurrence")))
  # The same set read through two different tables stays two requirements.
  same <- list(list(name = "a", expression = list(Type = "ALL", Groups = list(), CriteriaList = list(
    crit("Measurement", 0L), crit("Observation", 0L)))))
  r2 <- parse_cohort_requirements(cohort_json(0L, cs, same))
  expect_equal(r2$required, list(0L, 0L)); expect_equal(unlist(r2$required_table), c("Measurement", "Observation"))
})

test_that("filter_hits_by_domain keeps only concepts of the criterion table's domain", {
  dom <- c(`1` = "Condition", `2` = "Observation", `3` = "Drug")
  expect_equal(filter_hits_by_domain(c(1, 2, 3), dom, "Observation"), 2)
  expect_equal(filter_hits_by_domain(c(1, 2, 3), dom, "ConditionOccurrence"), 1)
  expect_equal(filter_hits_by_domain(c(1, 2, 3), dom, "DrugExposure"), 3)
  # Not filtered: unmapped criterion table, no domain info, unknown concept domain.
  expect_equal(filter_hits_by_domain(c(1, 2, 3), dom, "Death"), c(1, 2, 3))
  expect_equal(filter_hits_by_domain(c(1, 2), NULL, "Observation"), c(1, 2))
  expect_equal(filter_hits_by_domain(c(1, 99), dom, "Observation"), 99)
  expect_equal(filter_hits_by_domain(numeric(0), dom, "Observation"), numeric(0))
})

test_that("evaluate_cohort_coverage rejects hits in the wrong domain and says why", {
  dom <- c(`10` = "Condition", `20` = "Observation")
  req <- list(primary = 0L, primary_table = "Observation", required = list(), unevaluable = FALSE)
  r <- evaluate_cohort_coverage(req, list(`0` = 10), dom)          # only a Condition reaches the set
  expect_equal(r$status, "NOT_COVERED"); expect_equal(r$missing, 0L)
  expect_equal(unname(r$domain_notes["0"]),
               "codes reach the concept set only in the Condition domain; criterion reads Observation")
  expect_equal(evaluate_cohort_coverage(req, list(`0` = c(10, 20)), dom)$status, "COVERED")
  expect_equal(evaluate_cohort_coverage(req, list(`0` = numeric(0)), dom)$domain_notes, character(0))  # nothing reaches it: no domain note
  # Without domains the legacy behaviour (any domain counts) is unchanged.
  expect_equal(evaluate_cohort_coverage(req, list(`0` = 10))$status, "COVERED")

  # A required inclusion criterion is domain-checked too, and its note is reported.
  rq <- list(primary = 0L, primary_table = "ConditionOccurrence", required = list(1L),
             required_table = list("Measurement"), unevaluable = FALSE)
  r2 <- evaluate_cohort_coverage(rq, list(`0` = 10, `1` = 10), dom)
  expect_equal(r2$status, "NOT_COVERED"); expect_equal(r2$missing, 1L)
  expect_match(r2$domain_notes[["1"]], "criterion reads Measurement")
})

test_that("module coverage is domain-aware end to end (the VA-FI Falls case)", {
  skip_if_not_installed("RSQLite"); skip_if_not_installed("DatabaseConnector")
  tmp <- withr::local_tempdir()
  cd <- DatabaseConnector::createConnectionDetails(dbms = "sqlite", server = file.path(tmp, "v.sqlite"))
  con <- DatabaseConnector::connect(cd)
  ins <- function(name, df) DatabaseConnector::insertTable(con, databaseSchema = "main", tableName = name,
    data = df, dropTableIfExists = TRUE, createTable = TRUE, progressBar = FALSE, camelCaseToSnakeCase = FALSE)
  # Fake vocabulary. Source SNOMED codes map to standard concepts of different domains:
  #   F1 -> 910101 Condition ("fracture"), F2 -> 910102 Observation ("history of falls"),
  #   M1 -> 910103 Measurement. 910104 is an Observation-domain concept no module emits.
  ins("concept", data.frame(concept_id = c(8101, 8102, 8103, 910101, 910102, 910103, 910104),
      concept_code = c("F1", "F2", "M1", "910101", "910102", "910103", "910104"),
      vocabulary_id = c("SNOMED", "SNOMED", "SNOMED", "X", "X", "X", "X"),
      standard_concept = c(NA, NA, NA, "S", "S", "S", "S"),
      domain_id = c("Condition", "Observation", "Measurement", "Condition", "Observation", "Measurement", "Observation")))
  ins("concept_relationship", data.frame(concept_id_1 = c(8101, 8102, 8103),
      concept_id_2 = c(910101, 910102, 910103), relationship_id = "Maps to", invalid_reason = NA_character_))
  ins("concept_ancestor", data.frame(ancestor_concept_id = c(910101, 910102, 910103, 910104),
      descendant_concept_id = c(910101, 910102, 910103, 910104)))
  DatabaseConnector::disconnect(con)

  # Direct check of the mapping: domain_id of the MAPPED concept comes back with it.
  mod <- file.path(tmp, "mine.json")
  write_module(mod, list(
    # Condition-domain concept via a ConditionOnset (the Falls module's situation)
    A = list(type = "ConditionOnset", codes = list(list(system = "SNOMED-CT", code = "F1", display = "fracture"))),
    # Observation-domain concept ALSO via ConditionOnset: the ETL routes it to the observation table
    B = list(type = "ConditionOnset", codes = list(list(system = "SNOMED-CT", code = "F2", display = "fall history"))),
    C = list(type = "Observation", codes = list(list(system = "SNOMED-CT", code = "M1", display = "a measure")))))
  inv <- collect_all_module_codes(mod, file.path(tmp, "no-synthea"))
  con <- DatabaseConnector::connect(cd)
  m <- map_codes_to_concepts(con, "main", inv$codes)
  DatabaseConnector::disconnect(con)
  expect_equal(setNames(m$domain_id, m$code)[c("F1", "F2", "M1")],
               c(F1 = "Condition", F2 = "Observation", M1 = "Measurement"))

  # Consumer cohorts. `set()` builds one concept-set item; `inc()` one ALL inclusion rule.
  set <- function(ids, desc = FALSE) data.frame(concept_id = ids, descendants = desc, excluded = FALSE)
  cdir <- file.path(tmp, "study-d"); dir.create(file.path(cdir, "inst", "cohorts"), recursive = TRUE)
  writeLines(c("atlas_id,cohort_id,cohort_name", "0,21,Falls Observation only Condition reached",
               "0,22,Same set read as ConditionOccurrence", "0,23,Observation reached via ConditionOnset",
               "0,24,Required Measurement criterion wrong table", "0,25,Required Measurement criterion right table"),
             file.path(cdir, "inst", "Cohorts.csv"))
  w <- function(id, txt) writeLines(txt, file.path(cdir, "inst", "cohorts", paste0(id, ".json")))
  # 21: mirrors pad-amp-ed-desc 1797962: Observation entry; the set holds a Condition concept
  #     the module emits (910101) and an Observation concept it does not (910104).
  falls <- list(`0` = set(c(910101, 910104)))
  w(21, cohort_json(0L, falls, primary_table = "Observation"))
  # 22: identical set, but read through ConditionOccurrence -> the Condition concept counts.
  w(22, cohort_json(0L, falls, primary_table = "ConditionOccurrence"))
  # 23: Observation entry on the Observation-domain concept the module emits through ConditionOnset.
  w(23, cohort_json(0L, list(`0` = set(910102)), primary_table = "Observation"))
  inc <- function(tbl, id) list(list(name = "needs", expression = list(Type = "ALL", Groups = list(),
    CriteriaList = list(list(Criteria = setNames(list(list(CodesetId = id)), tbl),
                             Occurrence = list(Type = 2L, Count = 1L))))))
  # 24/25: required inclusion criterion on the Measurement-domain concept 910103, read through
  #        Observation (wrong table: the set only has a Measurement concept) vs Measurement.
  two <- list(`0` = set(910101), `1` = set(910103))
  w(24, cohort_json(0L, two, inc("Observation", 1L)))
  w(25, cohort_json(0L, two, inc("Measurement", 1L)))
  writeLines(c("targetId   <- 21L", "outcomeIds <- c(22L)"), file.path(cdir, "CreateStrategusAnalysisSpecification.R"))
  yml <- file.path(tmp, "consumers.yaml")
  writeLines(c("dataset_id: ds", "consumers:", "  - study: study-d", paste0("    repo_dir: ", cdir)), yml)
  cfg <- read_consumers(yml)

  con <- DatabaseConnector::connect(cd); on.exit(DatabaseConnector::disconnect(con), add = TRUE)
  out <- check_module_coverage(con, "main", cfg$consumers, inv$codes, repo_root = file.path(tmp, "synth"))
  expect_length(out$problems, 0)
  res <- out$results[order(out$results$cohort_id), ]
  st <- setNames(res$status, res$cohort_id); dt <- setNames(res$detail, res$cohort_id)

  expect_equal(unname(st["21"]), "NOT_COVERED")   # the Falls case: previously (wrongly) COVERED
  expect_match(dt[["21"]], "codes reach the concept set only in the Condition domain; criterion reads Observation", fixed = TRUE)
  expect_equal(unname(st["22"]), "COVERED")       # same set, ConditionOccurrence reads Condition concepts
  expect_equal(unname(st["23"]), "COVERED")       # Observation-domain concept via a ConditionOnset state
  expect_equal(unname(st["24"]), "NOT_COVERED")
  expect_match(dt[["24"]], "only in the Measurement domain; criterion reads Observation", fixed = TRUE)
  expect_equal(unname(st["25"]), "COVERED")
  # Only the concept that can reach the table is credited as the provider.
  expect_match(res$example_codes[res$cohort_id == 23], "fall history", fixed = TRUE)
  expect_false(grepl("fracture", res$example_codes[res$cohort_id == 23]))
})
