---
description: "Use when writing R or SQL code that queries or processes OMOP CDM data, defines cohorts, uses OHDSI packages (DatabaseConnector, SqlRender, PatientLevelPrediction, FeatureExtraction, CohortGenerator), or works with concept IDs, domain tables, or cohort logic."
applyTo: ["**/*.R", "**/*.sql"]
---

# OMOP CDM and OHDSI Coding Conventions

## Database Connection

Always use `DatabaseConnector` — never raw JDBC, `DBI`, or `odbc` directly:

```r
config  <- get_validation_config()
connDetails <- DatabaseConnector::createConnectionDetails(
  dbms     = config$dbms,
  server   = paste0(config$server, "/", config$database),
  port     = config$sql_server_port,
  pathToDriver = config$path_to_driver
)
conn <- DatabaseConnector::connect(connDetails)
on.exit(DatabaseConnector::disconnect(conn))
```

## SQL Authoring (SqlRender)

All SQL must be written as SqlRender-parameterized templates, then rendered and translated:

```r
sql <- SqlRender::render(
  "SELECT * FROM @cdm_schema.person WHERE year_of_birth > @min_year",
  cdm_schema = config$cdm_schema,
  min_year   = 1920L
)
sql <- SqlRender::translate(sql, targetDialect = config$dbms)
result <- DatabaseConnector::querySql(conn, sql, snakeCaseToCamelCase = TRUE)
```

- Never concatenate user-supplied values directly into SQL strings (injection risk).
- Use `@parameter` syntax for all variable schema/table/value substitutions.
- Target dialect is always `"sql server"` for this project.

## OMOP CDM Structure (v5)

Key tables in `cdm_synthea` schema:

| Domain | Table | Key columns |
|--------|-------|-------------|
| Person | `person` | `person_id`, `gender_concept_id`, `year_of_birth` |
| Visit | `visit_occurrence` | `person_id`, `visit_start_date`, `visit_end_date`, `visit_concept_id` |
| Condition | `condition_occurrence` | `person_id`, `condition_concept_id`, `condition_start_date` |
| Drug | `drug_exposure` | `person_id`, `drug_concept_id`, `drug_exposure_start_date` |
| Procedure | `procedure_occurrence` | `person_id`, `procedure_concept_id`, `procedure_date` |
| Measurement | `measurement` | `person_id`, `measurement_concept_id`, `measurement_date`, `value_as_number` |
| Observation | `observation` | `person_id`, `observation_concept_id`, `observation_date` |
| Concept | `concept` | `concept_id`, `concept_name`, `domain_id`, `vocabulary_id`, `standard_concept` |
| Concept ancestor | `concept_ancestor` | `ancestor_concept_id`, `descendant_concept_id` |

Rules:
- Always use **standard concept IDs** (`standard_concept = 'S'`), not source codes.
- Join via `concept_ancestor` when descendant expansion is needed (e.g., all subtypes of a drug).
- Filter out invalid records: `condition_status_concept_id != 4230359` (exclude provisional).

## Cohort Table Convention

Cohorts follow the standard OHDSI structure in `config$cohort_table`:

```sql
cohort_definition_id  BIGINT  -- 1 = target, 2 = outcome (local); ATLAS IDs when copied
subject_id            BIGINT  -- maps to person_id
cohort_start_date     DATE
cohort_end_date       DATE
```

- `target_cohort_id = 1L` and `outcome_cohort_id = 2L` as set in `config.R`.
- When `use_atlas_cohorts = TRUE`, call `copy_atlas_cohort()` from `R/cohorts.R` instead
  of running SQL from `cohorts/`.

## PatientLevelPrediction

```r
# External validation only — never re-train in this project
PatientLevelPrediction::validateExternal(
  validationDatabaseDetails = ...,
  validationCohortId        = config$target_cohort_id,
  outcomeId                 = config$outcome_cohort_id,
  outputFolder              = config$output_folder
)
```

- Do not retrain or update model coefficients; this is a validation-only project.
- Model is loaded from `config$model_path` (a `plpResult` directory).

## FeatureExtraction

- Use `FeatureExtraction::createCovariateSettings()` with explicit covariate lists.
- Do not use `addDescendantsToExclude` without confirming concept IDs against the CDM.

## CohortGenerator

- Use `CohortGenerator::generateCohortSet()` only when cohorts are defined in `cohorts/` SQL.
- When ATLAS cohorts are available (`use_atlas_cohorts = TRUE`), skip `CohortGenerator`.

## Integer Risk Score Queries

For the `R/risk_score_pipeline.R` pipeline:
- One SQL query per domain (condition, drug, procedure, measurement, observation, visit).
- Use `concept_ancestor` when `include_descendants = TRUE` in `component_concepts.csv`.
- Exposure windows are relative to `cohort_start_date` and parameterized via
  `lookback_start_day` / `lookback_end_day` from `risk_score/components.csv`.

## Concept ID Lookup (Live Vocabulary)

Never guess or assume OMOP concept IDs from training knowledge. Always verify against
the actual vocabulary loaded in `cdm_synthea` by running the `/concept-lookup` prompt.

Invoke it in chat before writing any concept ID into code or CSV files:

```
/concept-lookup <clinical term> [domain]
```

Examples:
```
/concept-lookup peripheral arterial disease condition
/concept-lookup cefazolin drug
/concept-lookup ankle brachial index measurement
/concept-lookup femoral popliteal bypass procedure
```

The prompt connects to `omop_synth` via the MSSQL MCP tooling and queries
`cdm_synthea.concept` directly — returning only standard concepts (`standard_concept = 'S'`)
that are confirmed to exist in this database instance.

## Anti-patterns

- Do not hardcode schema or table names — always use `@cdm_schema`, `@results_schema`, etc.
- Do not use `dbplyr` or `dplyr` remote tables for this project; use explicit SQL.
- Do not use source-vocabulary concept codes (ICD-10, NDC) — map to standard OMOP concept IDs first.
- Do not hard-code concept IDs without first running `/concept-lookup` to confirm they exist in `cdm_synthea`.
