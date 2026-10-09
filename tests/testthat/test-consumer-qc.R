# Tests for R/consumer_qc.R (consumer-study QC).
#
# Concept IDs below (900001-900003) are FAKE test-fixture IDs in a throwaway
# SQLite CDM. They make no claim about the OMOP vocabulary and must never be
# copied into a real cohort (Rule 1).
source(file.path(.PROJ_ROOT, "R/consumer_qc.R"))

write_consumers_yaml <- function(dir, body) {
  p <- file.path(dir, "consumers.yaml"); writeLines(body, p); p
}

test_that("read_consumers applies defaults and rejects duplicates", {
  d <- withr::local_tempdir()
  p <- write_consumers_yaml(d, c(
    "dataset_id: ds1",
    "consumers:",
    "  - study: study-a",
    "  - study: study-b",
    "    min_target_subjects: 50",
    "    target_id: 7",
    "    outcome_ids: [8, 9]"))
  r <- read_consumers(p)
  expect_equal(r$dataset_id, "ds1")
  expect_equal(r$consumers[[1]]$min_target_subjects, 100)
  expect_equal(r$consumers[[1]]$cohorts_manifest, "inst/Cohorts.csv")
  expect_null(r$consumers[[1]]$target_id)
  expect_equal(r$consumers[[2]]$min_target_subjects, 50)
  expect_equal(r$consumers[[2]]$outcome_ids, c(8L, 9L))
  expect_null(r$consumers[[1]]$expected_empty)

  p2 <- write_consumers_yaml(d, c("consumers:", "  - study: x", "  - study: x"))
  expect_error(read_consumers(p2), "duplicate")
  p3 <- write_consumers_yaml(d, c("consumers:", "  - repo_dir: foo"))
  expect_error(read_consumers(p3), "study")
  p4 <- write_consumers_yaml(d, c("consumers: []", "not_checked: [a, b]"))
  expect_length(read_consumers(p4)$consumers, 0)
  expect_equal(read_consumers(p4)$not_checked, c("a", "b"))
})

test_that("parse_spec_roles reads target, outcomes and hand-authored ids", {
  d <- withr::local_tempdir()
  spec <- file.path(d, "spec.R")
  writeLines(c(
    "targetId   <- 9100001L   # the target",
    "outcomeIds <- c(9100002L,",
    "                9100003L)  # two outcomes",
    "HAND_AUTHORED <- c(9100003L)"), spec)
  r <- parse_spec_roles(spec)
  expect_equal(r$target_id, 9100001L)
  expect_equal(r$outcome_ids, c(9100002L, 9100003L))
  expect_equal(r$hand_authored, 9100003L)

  # Template placeholders (0) and a missing file are treated as unresolved.
  writeLines(c("targetId <- 0L", "outcomeIds <- c(0L)", "HAND_AUTHORED <- integer(0)"), spec)
  r0 <- parse_spec_roles(spec)
  expect_null(r0$target_id); expect_length(r0$outcome_ids, 0); expect_length(r0$hand_authored, 0)
  expect_null(parse_spec_roles(file.path(d, "nope.R"))$target_id)
})

test_that("evaluate_consumer_results classifies roles and applies thresholds", {
  co <- list(study = "s", min_target_subjects = 100, min_outcome_subjects = 10,
             min_covariate_subjects = 1)
  names_ <- c(`1` = "Target", `2` = "Outcome", `3` = "Cov A", `4` = "Cov B")
  res <- evaluate_consumer_results(
    co, names_, roles = list(target_id = 1L, outcome_ids = 2L),
    subjects = c(`1` = 120, `2` = 50, `3` = 5),           # cohort 4 absent -> 0
    overlap = c(`2` = 8),                                  # only 8 outcome subjects in the target
    failed = c(`3` = "FAILED"), hand_authored = 4L)
  get <- function(id) res[res$cohort_id == id, ]
  expect_equal(get(1)$role, "target");    expect_equal(get(1)$status, "PASS")
  expect_equal(get(2)$role, "outcome");   expect_equal(get(2)$status, "FAIL")  # 8 < 10
  expect_equal(get(2)$metric, "subjects_in_target")
  expect_equal(get(3)$status, "FAIL");    expect_match(get(3)$note, "generation failed")
  expect_equal(get(4)$role, "covariate"); expect_equal(get(4)$status, "FAIL")  # 0 < 1
  expect_match(get(4)$note, "hand-authored")
})

test_that("expected_empty cohorts get no minimum but are annotated", {
  co <- list(study = "s", min_target_subjects = 100, min_outcome_subjects = 10,
             min_covariate_subjects = 1, expected_empty = 4L)
  res <- evaluate_consumer_results(
    co, c(`1` = "T", `2` = "O", `4` = "O-empty"), roles = list(target_id = 1L, outcome_ids = c(2L, 4L)),
    subjects = c(`1` = 120, `2` = 50), overlap = c(`2` = 20))
  expect_equal(res$status[res$cohort_id == 4], "PASS")
  expect_match(res$note[res$cohort_id == 4], "expected empty")
  expect_equal(res$status[res$cohort_id == 2], "PASS")
  # Without the declaration the same empty outcome fails.
  co$expected_empty <- NULL
  res2 <- evaluate_consumer_results(co, c(`1` = "T", `2` = "O", `4` = "O-empty"),
    roles = list(target_id = 1L, outcome_ids = c(2L, 4L)),
    subjects = c(`1` = 120, `2` = 50), overlap = c(`2` = 20))
  expect_equal(res2$status[res2$cohort_id == 4], "FAIL")
})

test_that("check_registry_agreement reports mismatches in both directions", {
  d <- withr::local_tempdir()
  reg <- file.path(d, "registry.yaml")
  writeLines(c("datasets:", "  - id: ds1", "    used_by:",
               "      - study_id: study-a", "      - study_id: study-c"), reg)
  p <- check_registry_agreement("ds1", c("study-a", "study-b"), reg)
  expect_length(p, 2)
  expect_true(any(grepl("study-b", p) & grepl("not in registry", p)))
  expect_true(any(grepl("study-c", p) & grepl("not in consumers.yaml", p)))
  expect_length(check_registry_agreement("ds1", c("study-a", "study-c"), reg), 0)
  expect_match(check_registry_agreement("nope", "x", reg), "not in")
  expect_match(check_registry_agreement(NA_character_, "x", reg), "no dataset_id")

  # Real registries often list consumers as plain strings, include the producer
  # repo, and list retired / non-Strategus studies; those must not warn.
  reg2 <- file.path(d, "registry2.yaml")
  writeLines(c("datasets:", "  - id: ds2", "    source_repo: the-synth",
               "    used_by:", "      - the-synth   # produces it",
               "      - study-a", "      - old-study  # retired", "      - plp-network"), reg2)
  expect_length(check_registry_agreement("ds2", "study-a", reg2, c("old-study", "plp-network")), 0)
  p2 <- check_registry_agreement("ds2", "study-a", reg2)
  expect_length(p2, 2)
  expect_false(any(grepl("the-synth", p2)))
  expect_match(check_registry_agreement("ds1", "x", file.path(d, "missing.yaml")), "not found")
})

# -----------------------------------------------------------------------------
# End to end on SQLite: renders circe JSON, instantiates cohorts with
# CohortGenerator, counts subjects, and cleans up scratch tables.
# -----------------------------------------------------------------------------
circe_condition_json <- function(concept_id, name) {
  sprintf('{"ConceptSets":[{"id":0,"name":"%s","expression":{"items":[{"concept":{"CONCEPT_ID":%d,"CONCEPT_NAME":"%s","STANDARD_CONCEPT":"S","STANDARD_CONCEPT_CAPTION":"Standard","INVALID_REASON":"V","INVALID_REASON_CAPTION":"Valid","CONCEPT_CODE":"T%d","DOMAIN_ID":"Condition","VOCABULARY_ID":"TEST","CONCEPT_CLASS_ID":"Test"},"includeDescendants":false,"includeMapped":false,"isExcluded":false}]}}],"PrimaryCriteria":{"CriteriaList":[{"ConditionOccurrence":{"CodesetId":0}}],"ObservationWindow":{"PriorDays":0,"PostDays":0},"PrimaryCriteriaLimit":{"Type":"All"}},"QualifiedLimit":{"Type":"First"},"ExpressionLimit":{"Type":"First"},"InclusionRules":[],"CensoringCriteria":[],"CollapseSettings":{"CollapseType":"ERA","EraPad":0},"CensorWindow":{}}',
          name, concept_id, name, concept_id)
}

test_that("run_consumer_cohort_qc counts target, outcome-in-target and covariate cohorts", {
  skip_if_not_installed("RSQLite")
  skip_if_not_installed("CohortGenerator")
  skip_if_not_installed("CirceR")
  skip_if_not_installed("DatabaseConnector")

  tmp <- withr::local_tempdir()

  # --- Fake CDM: persons 1-10 have the target condition (900001); persons 1-4
  # also have the outcome (900002); persons 11-12 have the outcome only; only
  # person 1 has the covariate condition (900003).
  db <- file.path(tmp, "cdm.sqlite")
  cd <- DatabaseConnector::createConnectionDetails(dbms = "sqlite", server = db)
  con <- DatabaseConnector::connect(cd)
  ins <- function(name, df) DatabaseConnector::insertTable(con, databaseSchema = "main",
    tableName = name, data = df, dropTableIfExists = TRUE, createTable = TRUE,
    progressBar = FALSE, camelCaseToSnakeCase = FALSE)
  persons <- 1:12
  ins("person", data.frame(person_id = persons))
  ins("observation_period", data.frame(
    observation_period_id = persons, person_id = persons,
    observation_period_start_date = as.Date("2000-01-01"),
    observation_period_end_date = as.Date("2030-01-01"),
    period_type_concept_id = 0L))
  cond <- rbind(
    data.frame(person_id = 1:10,  condition_concept_id = 900001L),
    data.frame(person_id = c(1:4, 11:12), condition_concept_id = 900002L),
    data.frame(person_id = 1L,    condition_concept_id = 900003L))
  cond$condition_occurrence_id <- seq_len(nrow(cond))
  cond$condition_start_date <- as.Date("2020-06-01")
  cond$condition_end_date <- as.Date("2020-06-02")
  cond$condition_type_concept_id <- 0L
  cond$visit_occurrence_id <- NA_integer_
  ins("condition_occurrence", cond)
  cs <- data.frame(concept_id = c(900001L, 900002L, 900003L),
                   concept_name = c("TEST A", "TEST B", "TEST C"),
                   domain_id = "Condition", vocabulary_id = "TEST", concept_class_id = "Test",
                   standard_concept = "S", concept_code = c("T1", "T2", "T3"),
                   invalid_reason = NA_character_)
  ins("concept", cs)
  ins("concept_ancestor", data.frame(ancestor_concept_id = cs$concept_id,
        descendant_concept_id = cs$concept_id, min_levels_of_separation = 0L,
        max_levels_of_separation = 0L))
  ins("concept_relationship", data.frame(concept_id_1 = 1L, concept_id_2 = 1L,
        relationship_id = "x", invalid_reason = NA_character_))
  DatabaseConnector::disconnect(con)

  # --- Fake consumer Strategus repo
  consumer_dir <- file.path(tmp, "study-a")
  dir.create(file.path(consumer_dir, "inst", "cohorts"), recursive = TRUE)
  writeLines(c("atlas_id,cohort_id,cohort_name,logic_description,generate_stats",
               "0,0,EXAMPLE,delete me,TRUE",
               "0,11,Target cohort,x,TRUE",
               "0,12,Outcome cohort,x,TRUE",
               "0,13,Covariate cohort,x,TRUE"),
             file.path(consumer_dir, "inst", "Cohorts.csv"))
  writeLines(circe_condition_json(900001, "A"), file.path(consumer_dir, "inst", "cohorts", "11.json"))
  writeLines(circe_condition_json(900002, "B"), file.path(consumer_dir, "inst", "cohorts", "12.json"))
  writeLines(circe_condition_json(900003, "C"), file.path(consumer_dir, "inst", "cohorts", "13.json"))
  writeLines(c("targetId   <- 11L", "outcomeIds <- c(12L)"),
             file.path(consumer_dir, "CreateStrategusAnalysisSpecification.R"))

  yml <- write_consumers_yaml(tmp, c(
    "dataset_id: ds1", "consumers:",
    paste0("  - study: study-a"),
    paste0("    repo_dir: ", consumer_dir),
    "    min_target_subjects: 5", "    min_outcome_subjects: 3", "    min_covariate_subjects: 2"))
  cfg <- read_consumers(yml)

  out <- run_consumer_cohort_qc(cd, cdm_schema = "main", results_schema = "main",
                                consumers = cfg$consumers, repo_root = file.path(tmp, "synth"))
  expect_length(out$problems, 0)
  res <- out$results
  get <- function(id) res[res$cohort_id == id, ]
  expect_equal(get(11)$subjects, 10);            expect_equal(get(11)$status, "PASS")
  expect_equal(get(12)$subjects, 6)              # 4 in the target + 2 outside it
  expect_equal(get(12)$subjects_in_target, 4);   expect_equal(get(12)$status, "PASS")
  expect_equal(get(13)$role, "covariate")
  expect_equal(get(13)$subjects, 1);             expect_equal(get(13)$status, "FAIL")  # 1 < 2

  # Scratch cohort tables are dropped, and the CDM tables are untouched.
  con <- DatabaseConnector::connect(cd)
  on.exit(DatabaseConnector::disconnect(con), add = TRUE)
  tables <- tolower(DatabaseConnector::getTableNames(con, databaseSchema = "main"))
  expect_false(any(grepl("^qc_consumer_", tables)))
  expect_true(all(c("person", "condition_occurrence") %in% tables))

  # An unexpected SQL error (here: a results schema that does not exist) is
  # reported as a problem for that consumer instead of aborting the whole run.
  out3 <- run_consumer_cohort_qc(cd, "main", "no_such_schema", cfg$consumers, file.path(tmp, "synth"))
  expect_match(out3$problems, "QC query failed")
  expect_null(out3$results)

  # Schemas are qualified as <database>.<schema> only when asked, and never twice.
  expect_equal(qualify_schema("plp_results", "omop_synth"), "omop_synth.plp_results")
  expect_equal(qualify_schema("omop_synth.plp_results", "omop_synth"), "omop_synth.plp_results")
  expect_equal(qualify_schema("plp_results", NULL), "plp_results")

  # A missing consumer repo is reported as a problem rather than skipped silently.
  gone <- cfg$consumers; gone[[1]]$repo_dir <- file.path(tmp, "does-not-exist")
  out2 <- run_consumer_cohort_qc(cd, "main", "main", gone, file.path(tmp, "synth"))
  expect_match(out2$problems, "repository not found")
})
