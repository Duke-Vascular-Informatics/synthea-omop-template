# =============================================================================
# R/risk_score_pipeline.R
# Integer risk score evaluation pipeline on OMOP cohorts.
#
# Inputs:
# - components.csv: score component logic and point weights
# - component_concepts.csv: OMOP concept IDs mapped to each component
# - risk_lookup.csv (optional): integer score -> predicted risk mapping
#
# Output:
# - person-level scores and outcomes
# - discrimination metrics (AUROC/AUPRC)
# - calibration metrics and plots
# =============================================================================

read_score_specs <- function(config) {
  components <- read.csv(config$risk_score_components_file, stringsAsFactors = FALSE)
  concepts <- read.csv(config$risk_score_concepts_file, stringsAsFactors = FALSE, comment.char = "#")

  required_component_cols <- c(
    "component_id", "component_name", "domain",
    "lookback_start_day", "lookback_end_day", "min_count", "points"
  )
  missing_component_cols <- setdiff(required_component_cols, names(components))
  if (length(missing_component_cols) > 0) {
    stop("Missing required columns in components.csv: ", paste(missing_component_cols, collapse = ", "))
  }

  required_concept_cols <- c("component_id", "concept_id", "include_descendants")
  missing_concept_cols <- setdiff(required_concept_cols, names(concepts))
  if (length(missing_concept_cols) > 0) {
    stop("Missing required columns in component_concepts.csv: ", paste(missing_concept_cols, collapse = ", "))
  }

  components$domain <- tolower(trimws(components$domain))
  valid_domains <- c("condition", "drug", "procedure", "measurement", "observation", "visit")
  invalid_domains <- unique(components$domain[!components$domain %in% valid_domains])
  if (length(invalid_domains) > 0) {
    stop("Unsupported domains in components.csv: ", paste(invalid_domains, collapse = ", "))
  }

  components$lookback_start_day <- as.integer(components$lookback_start_day)
  components$lookback_end_day <- as.integer(components$lookback_end_day)
  components$min_count <- as.integer(components$min_count)
  components$points <- as.numeric(components$points)

  concepts$concept_id <- as.integer(concepts$concept_id)
  concepts$include_descendants <- tolower(trimws(as.character(concepts$include_descendants))) %in% c("true", "1", "t", "yes", "y")
  if (!"concept_role" %in% names(concepts)) {
    concepts$concept_role <- NA_character_
  }
  concepts$concept_role <- tolower(trimws(as.character(concepts$concept_role)))
  concepts$concept_role[concepts$concept_role == ""] <- NA_character_

  if (any(is.na(concepts$concept_id))) {
    stop("component_concepts.csv contains non-integer concept_id values.")
  }

  missing_components <- setdiff(components$component_id, concepts$component_id)
  if (length(missing_components) > 0) {
    stop("No concept mappings found for component_id(s): ", paste(missing_components, collapse = ", "))
  }

  lookup <- NULL
  if (file.exists(config$risk_score_lookup_file)) {
    lookup <- read.csv(config$risk_score_lookup_file, stringsAsFactors = FALSE)
    if (!all(c("score", "risk") %in% names(lookup))) {
      stop("risk_lookup.csv must contain columns: score,risk")
    }
    lookup$score <- as.integer(lookup$score)
    lookup$risk <- as.numeric(lookup$risk)
  }

  list(components = components, concepts = concepts, lookup = lookup)
}

get_domain_mapping <- function(domain) {
  switch(
    domain,
    condition = list(table = "condition_occurrence", concept_col = "condition_concept_id", date_col = "condition_start_date"),
    drug = list(table = "drug_exposure", concept_col = "drug_concept_id", date_col = "drug_exposure_start_date"),
    procedure = list(table = "procedure_occurrence", concept_col = "procedure_concept_id", date_col = "procedure_date"),
    measurement = list(table = "measurement", concept_col = "measurement_concept_id", date_col = "measurement_date"),
    observation = list(table = "observation", concept_col = "observation_concept_id", date_col = "observation_date"),
    visit = list(table = "visit_occurrence", concept_col = "visit_concept_id", date_col = "visit_start_date"),
    stop("Unsupported domain: ", domain)
  )
}

get_target_population <- function(connection, config) {
  sql <- SqlRender::render(
    sql = "SELECT c.subject_id,
                  CAST(c.cohort_start_date AS DATE) AS index_date
           FROM @results_schema.@cohort_table c
           WHERE c.cohort_definition_id = @target_id",
    results_schema = config$results_schema,
    cohort_table = config$cohort_table,
    target_id = config$target_cohort_id
  )
  DatabaseConnector::querySql(connection, SqlRender::translate(sql, targetDialect = "sql server"))
}

get_outcomes <- function(connection, config) {
  sql <- SqlRender::render(
    sql = "SELECT t.subject_id,
                  t.index_date,
                  CASE WHEN EXISTS (
                    SELECT 1
                    FROM @results_schema.@cohort_table o
                    WHERE o.cohort_definition_id = @outcome_id
                      AND o.subject_id = t.subject_id
                      AND o.cohort_start_date >= t.index_date
                      AND o.cohort_start_date <= DATEADD(DAY, @prediction_window_days, t.index_date)
                  ) THEN 1 ELSE 0 END AS outcome
           FROM (
             SELECT c.subject_id,
                    CAST(c.cohort_start_date AS DATE) AS index_date
             FROM @results_schema.@cohort_table c
             WHERE c.cohort_definition_id = @target_id
           ) t",
    results_schema = config$results_schema,
    cohort_table = config$cohort_table,
    target_id = config$target_cohort_id,
    outcome_id = config$outcome_cohort_id,
    prediction_window_days = config$prediction_window_days
  )
  DatabaseConnector::querySql(connection, SqlRender::translate(sql, targetDialect = "sql server"))
}

ensure_concept_ancestor_indexes <- function(connection, config) {
  sql <- SqlRender::render(
    sql = "IF OBJECT_ID('@cdm_schema.concept_ancestor', 'U') IS NOT NULL
           BEGIN
             IF NOT EXISTS (
               SELECT 1
               FROM sys.indexes
               WHERE object_id = OBJECT_ID('@cdm_schema.concept_ancestor')
                 AND name = 'IX_concept_ancestor_ancestor'
             )
             BEGIN
               CREATE INDEX IX_concept_ancestor_ancestor
                 ON @cdm_schema.concept_ancestor (ancestor_concept_id)
                 INCLUDE (descendant_concept_id, min_levels_of_separation, max_levels_of_separation);
             END;

             IF NOT EXISTS (
               SELECT 1
               FROM sys.indexes
               WHERE object_id = OBJECT_ID('@cdm_schema.concept_ancestor')
                 AND name = 'IX_concept_ancestor_descendant'
             )
             BEGIN
               CREATE INDEX IX_concept_ancestor_descendant
                 ON @cdm_schema.concept_ancestor (descendant_concept_id)
                 INCLUDE (ancestor_concept_id);
             END;
           END;",
    cdm_schema = config$cdm_schema
  )

  sql <- SqlRender::translate(sql, targetDialect = "sql server")

  tryCatch({
    DatabaseConnector::executeSql(connection, sql)
    message("concept_ancestor indexes verified/created.")
  }, error = function(e) {
    warning(
      "Unable to verify/create concept_ancestor indexes. Descendant-expansion queries may be slow. Details: ",
      conditionMessage(e)
    )
  })

  invisible(NULL)
}

query_bmi_component_counts <- function(connection, config, component, component_concepts) {
  if (!"concept_role" %in% names(component_concepts)) {
    stop("BMI-derived components require concept_role values: weight and height.")
  }

  roles <- tolower(trimws(as.character(component_concepts$concept_role)))
  weight_ids <- unique(component_concepts$concept_id[roles == "weight"])
  height_ids <- unique(component_concepts$concept_id[roles == "height"])
  weight_ids <- weight_ids[!is.na(weight_ids) & weight_ids > 0]
  height_ids <- height_ids[!is.na(height_ids) & height_ids > 0]

  if (length(weight_ids) == 0 || length(height_ids) == 0) {
    stop(
      "Component ", component$component_id,
      " requires at least one weight and one height concept_id with concept_role set in component_concepts.csv"
    )
  }

  bmi_where_clause <- switch(
    component$component_id,
    overweight = "b.bmi >= 25 AND b.bmi < 30",
    obese = "b.bmi >= 30",
    stop("Unsupported BMI-derived component_id: ", component$component_id)
  )

  # OMOP standard UCUM units validated in this database instance.
  kilogram_unit_id <- 9529L
  pound_unit_ids <- c(8739L)
  meter_unit_id <- 9546L
  centimeter_unit_id <- 8582L
  inch_unit_ids <- c(9326L, 9327L, 9330L)

  sql <- SqlRender::render(
    sql = "WITH target_population AS (
             SELECT c.subject_id,
                    CAST(c.cohort_start_date AS DATE) AS index_date
             FROM @results_schema.@cohort_table c
             WHERE c.cohort_definition_id = @target_id
           ),
           weight_concepts AS (
             SELECT CAST(id AS BIGINT) AS concept_id
             FROM (SELECT value AS id FROM string_split('@weight_concept_ids', ',')) s
           ),
           height_concepts AS (
             SELECT CAST(id AS BIGINT) AS concept_id
             FROM (SELECT value AS id FROM string_split('@height_concept_ids', ',')) s
           ),
           latest_weight AS (
             SELECT t.subject_id,
                    CASE
                      WHEN m.unit_concept_id = @kilogram_unit_id THEN m.value_as_number
                      WHEN m.unit_concept_id IN (@pound_unit_ids) THEN m.value_as_number * 0.45359237
                      ELSE NULL
                    END AS weight_kg,
                    ROW_NUMBER() OVER (
                      PARTITION BY t.subject_id
                      ORDER BY m.measurement_date DESC, m.measurement_id DESC
                    ) AS rn
             FROM target_population t
             JOIN @cdm_schema.measurement m
               ON m.person_id = t.subject_id
             JOIN weight_concepts wc
               ON m.measurement_concept_id = wc.concept_id
             WHERE m.value_as_number IS NOT NULL
               AND m.measurement_date >= DATEADD(DAY, @lookback_start, t.index_date)
               AND m.measurement_date <= DATEADD(DAY, @lookback_end, t.index_date)
           ),
           latest_height AS (
             SELECT t.subject_id,
                    CASE
                      WHEN m.unit_concept_id = @meter_unit_id THEN m.value_as_number
                      WHEN m.unit_concept_id = @centimeter_unit_id THEN m.value_as_number / 100.0
                      WHEN m.unit_concept_id IN (@inch_unit_ids) THEN m.value_as_number * 0.0254
                      ELSE NULL
                    END AS height_m,
                    ROW_NUMBER() OVER (
                      PARTITION BY t.subject_id
                      ORDER BY m.measurement_date DESC, m.measurement_id DESC
                    ) AS rn
             FROM target_population t
             JOIN @cdm_schema.measurement m
               ON m.person_id = t.subject_id
             JOIN height_concepts hc
               ON m.measurement_concept_id = hc.concept_id
             WHERE m.value_as_number IS NOT NULL
               AND m.measurement_date >= DATEADD(DAY, @lookback_start, t.index_date)
               AND m.measurement_date <= DATEADD(DAY, @lookback_end, t.index_date)
           ),
           bmi_values AS (
             SELECT w.subject_id,
                    CASE
                      WHEN h.height_m IS NULL OR w.weight_kg IS NULL THEN NULL
                      WHEN h.height_m <= 0 THEN NULL
                      WHEN w.weight_kg <= 0 THEN NULL
                      ELSE w.weight_kg / POWER(h.height_m, 2)
                    END AS bmi
             FROM latest_weight w
             JOIN latest_height h
               ON w.subject_id = h.subject_id
             WHERE w.rn = 1
               AND h.rn = 1
           )
           SELECT b.subject_id,
                  1 AS event_count
           FROM bmi_values b
           WHERE @bmi_where_clause",
    results_schema = config$results_schema,
    cohort_table = config$cohort_table,
    target_id = config$target_cohort_id,
    cdm_schema = config$cdm_schema,
    weight_concept_ids = paste(weight_ids, collapse = ","),
    height_concept_ids = paste(height_ids, collapse = ","),
    kilogram_unit_id = kilogram_unit_id,
    pound_unit_ids = paste(pound_unit_ids, collapse = ","),
    meter_unit_id = meter_unit_id,
    centimeter_unit_id = centimeter_unit_id,
    inch_unit_ids = paste(inch_unit_ids, collapse = ","),
    lookback_start = as.integer(component$lookback_start_day),
    lookback_end = as.integer(component$lookback_end_day),
    bmi_where_clause = bmi_where_clause
  )

  DatabaseConnector::querySql(connection, SqlRender::translate(sql, targetDialect = "sql server"))
}

query_abi_component_counts <- function(connection, config, component, component_concepts) {
  concept_ids <- unique(component_concepts$concept_id)
  concept_ids <- concept_ids[!is.na(concept_ids) & concept_ids > 0]
  include_desc <- any(component_concepts$include_descendants)

  if (length(concept_ids) == 0) {
    stop(
      "Component ", component$component_id,
      " requires at least one ABI measurement concept_id in component_concepts.csv"
    )
  }

  sql <- SqlRender::render(
    sql = "WITH target_population AS (
             SELECT c.subject_id,
                    CAST(c.cohort_start_date AS DATE) AS index_date
             FROM @results_schema.@cohort_table c
             WHERE c.cohort_definition_id = @target_id
           ),
           concept_ids AS (
             SELECT CAST(id AS BIGINT) AS concept_id
             FROM (SELECT value AS id FROM string_split('@concept_ids', ',')) s
           ),
           expanded_concepts AS (
             SELECT concept_id FROM concept_ids
             UNION
             SELECT ca.descendant_concept_id AS concept_id
             FROM @cdm_schema.concept_ancestor ca
             JOIN concept_ids i
               ON ca.ancestor_concept_id = i.concept_id
             WHERE @include_descendants = 1
           )
           SELECT t.subject_id,
                  COUNT(*) AS event_count
           FROM target_population t
           JOIN @cdm_schema.measurement m
             ON m.person_id = t.subject_id
           JOIN expanded_concepts ec
             ON m.measurement_concept_id = ec.concept_id
           WHERE m.measurement_date >= DATEADD(DAY, @lookback_start, t.index_date)
             AND m.measurement_date <= DATEADD(DAY, @lookback_end, t.index_date)
             AND m.value_as_number IS NOT NULL
             AND m.value_as_number < @abi_threshold
           GROUP BY t.subject_id",
    results_schema = config$results_schema,
    cohort_table = config$cohort_table,
    target_id = config$target_cohort_id,
    cdm_schema = config$cdm_schema,
    concept_ids = paste(concept_ids, collapse = ","),
    include_descendants = ifelse(include_desc, 1, 0),
    lookback_start = as.integer(component$lookback_start_day),
    lookback_end = as.integer(component$lookback_end_day),
    abi_threshold = 0.35
  )

  DatabaseConnector::querySql(connection, SqlRender::translate(sql, targetDialect = "sql server"))
}

query_prolonged_antibiotic_counts <- function(connection, config, component, component_concepts) {
  concept_ids <- unique(component_concepts$concept_id)
  concept_ids <- concept_ids[!is.na(concept_ids) & concept_ids > 0]
  include_desc <- any(component_concepts$include_descendants)

  if (length(concept_ids) == 0) {
    stop(
      "Component ", component$component_id,
      " requires at least one antibiotic drug concept_id in component_concepts.csv"
    )
  }

  # Operational definition for non-prophylactic prior antibiotic exposure:
  # - Exposure must start before the day immediately prior to index (<= index - 2 days)
  # - Exposure must represent a treatment-like duration (>= 2 days from end date or days_supply)
  sql <- SqlRender::render(
    sql = "WITH target_population AS (
             SELECT c.subject_id,
                    CAST(c.cohort_start_date AS DATE) AS index_date
             FROM @results_schema.@cohort_table c
             WHERE c.cohort_definition_id = @target_id
           ),
           concept_ids AS (
             SELECT CAST(id AS BIGINT) AS concept_id
             FROM (SELECT value AS id FROM string_split('@concept_ids', ',')) s
           ),
           expanded_concepts AS (
             SELECT concept_id FROM concept_ids
             UNION
             SELECT ca.descendant_concept_id AS concept_id
             FROM @cdm_schema.concept_ancestor ca
             JOIN concept_ids i
               ON ca.ancestor_concept_id = i.concept_id
             WHERE @include_descendants = 1
           )
           SELECT t.subject_id,
                  COUNT(*) AS event_count
           FROM target_population t
           JOIN @cdm_schema.drug_exposure d
             ON d.person_id = t.subject_id
           JOIN expanded_concepts ec
             ON d.drug_concept_id = ec.concept_id
           WHERE d.drug_exposure_start_date >= DATEADD(DAY, @lookback_start, t.index_date)
             AND d.drug_exposure_start_date <= DATEADD(DAY, @lookback_end, t.index_date)
             AND d.drug_exposure_start_date <= DATEADD(DAY, -@non_prophylaxis_buffer_days, t.index_date)
             AND (
               (d.drug_exposure_end_date IS NOT NULL
                AND DATEDIFF(DAY, d.drug_exposure_start_date, d.drug_exposure_end_date) > @min_treatment_days)
               OR (d.days_supply IS NOT NULL AND d.days_supply > @min_treatment_days)
             )
           GROUP BY t.subject_id",
    results_schema = config$results_schema,
    cohort_table = config$cohort_table,
    target_id = config$target_cohort_id,
    cdm_schema = config$cdm_schema,
    concept_ids = paste(concept_ids, collapse = ","),
    include_descendants = ifelse(include_desc, 1, 0),
    lookback_start = as.integer(component$lookback_start_day),
    lookback_end = as.integer(component$lookback_end_day),
    non_prophylaxis_buffer_days = 1,
    min_treatment_days = 2
  )

  DatabaseConnector::querySql(connection, SqlRender::translate(sql, targetDialect = "sql server"))
}

query_operative_time_component_counts <- function(connection, config, component, component_concepts) {
  # Captures operative time > 240 minutes (4 hours) from either:
  # 1. procedure_end_datetime (calculated duration from procedure_occurrence)
  # 2. Measurement/Observation concepts for operative time
  # Combines both sources to identify patients with prolonged operative time.
  
  concept_ids <- unique(component_concepts$concept_id)
  concept_ids <- concept_ids[!is.na(concept_ids) & concept_ids > 0]
  include_desc <- any(component_concepts$include_descendants)
  
  operative_time_threshold_minutes <- 240  # 4 hours
  
  sql <- SqlRender::render(
    sql = "WITH target_population AS (
             SELECT c.subject_id,
                    CAST(c.cohort_start_date AS DATE) AS index_date
             FROM @results_schema.@cohort_table c
             WHERE c.cohort_definition_id = @target_id
           ),
           concept_ids AS (
             SELECT CAST(id AS BIGINT) AS concept_id
             FROM (SELECT value AS id FROM string_split('@concept_ids', ',')) s
           ),
           expanded_concepts AS (
             SELECT concept_id FROM concept_ids
             UNION
             SELECT ca.descendant_concept_id AS concept_id
             FROM @cdm_schema.concept_ancestor ca
             JOIN concept_ids i
               ON ca.ancestor_concept_id = i.concept_id
             WHERE @include_descendants = 1
           ),
           procedure_duration_mins AS (
             -- Extract operative time from procedure_end_datetime if available
             SELECT DISTINCT t.subject_id
             FROM target_population t
             JOIN @cdm_schema.procedure_occurrence po
               ON po.person_id = t.subject_id
             WHERE CAST(po.procedure_date AS DATE) = t.index_date
               AND po.procedure_end_datetime IS NOT NULL
               AND DATEDIFF(MINUTE, po.procedure_datetime, po.procedure_end_datetime) > @operative_time_threshold
           ),
           measurement_operative_time AS (
             -- Extract operative time from measurement table (e.g., LOINC operative time)
             SELECT DISTINCT t.subject_id
             FROM target_population t
             JOIN @cdm_schema.measurement m
               ON m.person_id = t.subject_id
             JOIN expanded_concepts ec
               ON m.measurement_concept_id = ec.concept_id
             WHERE CAST(m.measurement_date AS DATE) >= DATEADD(DAY, @lookback_start, t.index_date)
               AND CAST(m.measurement_date AS DATE) <= DATEADD(DAY, @lookback_end, t.index_date)
               AND m.value_as_number > @operative_time_threshold
           ),
           combined_operative_time AS (
             SELECT subject_id FROM procedure_duration_mins
             UNION
             SELECT subject_id FROM measurement_operative_time
           )
           SELECT subject_id,
                  COUNT(*) AS event_count
           FROM combined_operative_time
           GROUP BY subject_id",
    results_schema = config$results_schema,
    cohort_table = config$cohort_table,
    target_id = config$target_cohort_id,
    cdm_schema = config$cdm_schema,
    concept_ids = paste(concept_ids, collapse = ","),
    include_descendants = ifelse(include_desc, 1, 0),
    lookback_start = as.integer(component$lookback_start_day),
    lookback_end = as.integer(component$lookback_end_day),
    operative_time_threshold = operative_time_threshold_minutes
  )
  
  DatabaseConnector::querySql(connection, SqlRender::translate(sql, targetDialect = "sql server"))
}

query_mfi_component_counts <- function(connection, config, component, component_concepts) {
  # Modified Frailty Index: binary flag if (# sub-components present / total sub-components) > 0.25
  # Each sub-component is identified by concept_role in component_concepts.
  # Sub-components are queried from condition_occurrence.
  mfi_threshold <- 0.25

  valid_rows <- component_concepts[
    !is.na(component_concepts$concept_role) &
    trimws(component_concepts$concept_role) != "" &
    !is.na(component_concepts$concept_id) &
    component_concepts$concept_id > 0, ]

  roles <- unique(trimws(valid_rows$concept_role))
  n_sub <- length(roles)

  if (n_sub == 0) {
    stop("mFI_high requires concept_role entries with valid concept_ids in component_concepts.csv")
  }

  # Build CTE for target population
  tp_cte <- sprintf(
    paste0("target_population AS (\n",
           "  SELECT c.subject_id, CAST(c.cohort_start_date AS DATE) AS index_date\n",
           "  FROM %s.%s c\n",
           "  WHERE c.cohort_definition_id = %d\n",
           ")"),
    config$results_schema, config$cohort_table, as.integer(config$target_cohort_id)
  )

  # Build one CTE per sub-component, joined to target_population
  sub_cte_names <- paste0("sub_comp_", seq_along(roles))

  sub_ctes <- mapply(function(role, cte_name) {
    sc   <- valid_rows[trimws(valid_rows$concept_role) == role, ]
    ids  <- paste(unique(sc$concept_id), collapse = ", ")
    desc <- if (any(sc$include_descendants)) 1L else 0L

    concept_filter <- sprintf(
      paste0("(co.condition_concept_id IN (%s)\n",
             "         OR (%d = 1 AND co.condition_concept_id IN (\n",
             "               SELECT ca.descendant_concept_id\n",
             "               FROM %s.concept_ancestor ca\n",
             "               WHERE ca.ancestor_concept_id IN (%s)\n",
             "             )))"),
      ids, desc, config$cdm_schema, ids
    )

    sprintf(
      paste0("%s AS (\n",
             "  SELECT DISTINCT t.subject_id\n",
             "  FROM target_population t\n",
             "  JOIN %s.condition_occurrence co ON co.person_id = t.subject_id\n",
             "  WHERE %s\n",
             "    AND CAST(co.condition_start_date AS DATE) >= DATEADD(DAY, %d, t.index_date)\n",
             "    AND CAST(co.condition_start_date AS DATE) <= DATEADD(DAY, %d, t.index_date)\n",
             ")"),
      cte_name, config$cdm_schema, concept_filter,
      as.integer(component$lookback_start_day),
      as.integer(component$lookback_end_day)
    )
  }, roles, sub_cte_names, SIMPLIFY = TRUE)

  # CTE that sums sub-component flags per patient
  flag_expr <- paste(
    sprintf("CASE WHEN %s.subject_id IS NOT NULL THEN 1 ELSE 0 END", sub_cte_names),
    collapse = " +\n               "
  )
  join_clauses <- paste(
    sprintf("LEFT JOIN %s ON %s.subject_id = tp.subject_id",
            sub_cte_names, sub_cte_names),
    collapse = "\n  "
  )
  mfi_counts_cte <- sprintf(
    paste0("mfi_counts AS (\n",
           "  SELECT tp.subject_id,\n",
           "         (%s) AS sub_count\n",
           "  FROM target_population tp\n",
           "  %s\n",
           ")"),
    flag_expr, join_clauses
  )

  all_ctes <- paste(c(tp_cte, sub_ctes, mfi_counts_cte), collapse = ",\n")

  sql <- sprintf(
    paste0("WITH %s\n",
           "SELECT subject_id,\n",
           "       1 AS event_count\n",
           "FROM mfi_counts\n",
           "WHERE CAST(sub_count AS FLOAT) / %d > %s"),
    all_ctes, n_sub, mfi_threshold
  )

  DatabaseConnector::querySql(connection, SqlRender::translate(sql, targetDialect = "sql server"))
}

query_female_component_counts <- function(connection, config, component, component_concepts) {
  concept_ids <- unique(component_concepts$concept_id)
  concept_ids <- concept_ids[!is.na(concept_ids) & concept_ids > 0]

  if (length(concept_ids) == 0) {
    stop("Component female requires at least one concept_id mapping in component_concepts.csv")
  }

  sql <- SqlRender::render(
    sql = "WITH target_population AS (
             SELECT c.subject_id
             FROM @results_schema.@cohort_table c
             WHERE c.cohort_definition_id = @target_id
           ),
           concept_ids AS (
             SELECT CAST(id AS BIGINT) AS concept_id
             FROM (SELECT value AS id FROM string_split('@concept_ids', ',')) s
           )
           SELECT t.subject_id,
                  1 AS event_count
           FROM target_population t
           JOIN @cdm_schema.person p
             ON p.person_id = t.subject_id
           JOIN concept_ids ci
             ON p.gender_concept_id = ci.concept_id",
    results_schema = config$results_schema,
    cohort_table = config$cohort_table,
    target_id = config$target_cohort_id,
    cdm_schema = config$cdm_schema,
    concept_ids = paste(concept_ids, collapse = ",")
  )

  DatabaseConnector::querySql(connection, SqlRender::translate(sql, targetDialect = "sql server"))
}

query_component_counts <- function(connection, config, component, component_concepts) {
  if (component$component_id == "female") {
    return(query_female_component_counts(connection, config, component, component_concepts))
  }

  if (component$component_id %in% c("overweight", "obese")) {
    return(query_bmi_component_counts(connection, config, component, component_concepts))
  }

  if (component$component_id == "abi_35") {
    return(query_abi_component_counts(connection, config, component, component_concepts))
  }

  if (component$component_id == "prolong_abx") {
    return(query_prolonged_antibiotic_counts(connection, config, component, component_concepts))
  }

  if (component$component_id == "optime4h") {
    return(query_operative_time_component_counts(connection, config, component, component_concepts))
  }

  if (component$component_id == "mFI_high") {
    return(query_mfi_component_counts(connection, config, component, component_concepts))
  }

  map <- get_domain_mapping(component$domain)

  concept_ids <- unique(component_concepts$concept_id)
  concept_id_string <- paste(concept_ids, collapse = ",")
  include_desc <- any(component_concepts$include_descendants)

  sql <- SqlRender::render(
    sql = "WITH target_population AS (
             SELECT c.subject_id,
                    CAST(c.cohort_start_date AS DATE) AS index_date
             FROM @results_schema.@cohort_table c
             WHERE c.cohort_definition_id = @target_id
           ),
           concept_ids AS (
             SELECT CAST(id AS BIGINT) AS concept_id
             FROM (SELECT value AS id FROM string_split('@concept_ids', ',')) s
           ),
           expanded_concepts AS (
             SELECT concept_id FROM concept_ids
             UNION
             SELECT ca.descendant_concept_id AS concept_id
             FROM @cdm_schema.concept_ancestor ca
             JOIN concept_ids i
               ON ca.ancestor_concept_id = i.concept_id
             WHERE @include_descendants = 1
           )
           SELECT t.subject_id,
                  COUNT(*) AS event_count
           FROM target_population t
           JOIN @cdm_schema.@domain_table d
             ON d.person_id = t.subject_id
           JOIN expanded_concepts ec
             ON d.@domain_concept_col = ec.concept_id
           WHERE d.@domain_date_col >= DATEADD(DAY, @lookback_start, t.index_date)
             AND d.@domain_date_col <= DATEADD(DAY, @lookback_end, t.index_date)
           GROUP BY t.subject_id",
    results_schema = config$results_schema,
    cohort_table = config$cohort_table,
    target_id = config$target_cohort_id,
    cdm_schema = config$cdm_schema,
    domain_table = map$table,
    domain_concept_col = map$concept_col,
    domain_date_col = map$date_col,
    concept_ids = concept_id_string,
    include_descendants = ifelse(include_desc, 1, 0),
    lookback_start = as.integer(component$lookback_start_day),
    lookback_end = as.integer(component$lookback_end_day)
  )

  DatabaseConnector::querySql(connection, SqlRender::translate(sql, targetDialect = "sql server"))
}

calculate_scores <- function(connection, config, specs) {
  outcomes <- get_outcomes(connection, config)
  outcome_names <- tolower(names(outcomes))
  outcome_names[outcome_names == "subjectid"] <- "subject_id"
  outcome_names[outcome_names == "indexdate"] <- "index_date"
  names(outcomes) <- outcome_names

  components <- specs$components
  concepts <- specs$concepts

  component_matrix <- outcomes[, c("subject_id"), drop = FALSE]
  component_summary <- data.frame(
    component_id = character(),
    component_name = character(),
    domain = character(),
    n_positive = integer(),
    mean_points = numeric(),
    stringsAsFactors = FALSE
  )

  for (i in seq_len(nrow(components))) {
    comp <- components[i, ]
    comp_concepts <- concepts[concepts$component_id == comp$component_id, ]

    counts <- query_component_counts(connection, config, comp, comp_concepts)
    if (nrow(counts) > 0) {
      count_names <- tolower(names(counts))
      count_names[count_names == "subjectid"] <- "subject_id"
      count_names[count_names == "eventcount"] <- "event_count"
      names(counts) <- count_names
    } else {
      counts <- data.frame(subject_id = numeric(), event_count = numeric())
    }

    df <- merge(
      outcomes[, c("subject_id"), drop = FALSE],
      counts[, c("subject_id", "event_count"), drop = FALSE],
      by = "subject_id",
      all.x = TRUE
    )
    df$event_count[is.na(df$event_count)] <- 0L

    score_col <- paste0("score_", comp$component_id)
    df[[score_col]] <- ifelse(df$event_count >= comp$min_count, comp$points, 0)

    component_matrix <- merge(component_matrix, df[, c("subject_id", score_col)], by = "subject_id", all.x = TRUE)

    is_activated <- df$event_count >= comp$min_count

    component_summary <- rbind(
      component_summary,
      data.frame(
        component_id = comp$component_id,
        component_name = comp$component_name,
        domain = comp$domain,
        n_positive = sum(is_activated, na.rm = TRUE),
        mean_points = mean(df[[score_col]], na.rm = TRUE),
        stringsAsFactors = FALSE
      )
    )
  }

  score_cols <- grep("^score_", names(component_matrix), value = TRUE)
  component_matrix$total_score <- rowSums(component_matrix[, score_cols, drop = FALSE], na.rm = TRUE)

  person_level <- merge(outcomes, component_matrix, by = "subject_id", all.x = TRUE)
  list(person_level = person_level, component_summary = component_summary)
}

clamp_probability <- function(p, eps = 1e-6) {
  p <- as.numeric(p)
  p[p < eps] <- eps
  p[p > (1 - eps)] <- 1 - eps
  p
}

compute_ece <- function(y, p, n_bins = 10) {
  p <- clamp_probability(p)
  d <- data.frame(y = as.numeric(y), p = as.numeric(p))

  probs <- unique(stats::quantile(d$p, probs = seq(0, 1, length.out = n_bins + 1), na.rm = TRUE))
  if (length(probs) < 3) {
    probs <- c(0, 1)
  }
  d$bin <- cut(d$p, breaks = probs, include.lowest = TRUE)

  predicted_mean <- tapply(d$p, d$bin, mean, na.rm = TRUE)
  observed_mean  <- tapply(d$y, d$bin, mean, na.rm = TRUE)
  bin_size       <- tapply(d$y, d$bin, length)

  abs_diff <- abs(predicted_mean - observed_mean)
  ece <- sum(abs_diff * bin_size, na.rm = TRUE) / sum(bin_size, na.rm = TRUE)
  as.numeric(ece)
}

compute_binary_metrics <- function(y, estimate) {
  if (!requireNamespace("pROC", quietly = TRUE)) {
    stop("Package 'pROC' is required for AUROC metrics.")
  }
  if (!requireNamespace("PRROC", quietly = TRUE)) {
    stop("Package 'PRROC' is required for AUPRC metrics.")
  }

  y_num <- as.numeric(y)
  score <- as.numeric(estimate)

  if (length(unique(y_num)) < 2) {
    return(list(
      auroc = NA_real_,
      auprc = NA_real_,
      brier = mean((score - y_num)^2)
    ))
  }

  roc_obj <- pROC::roc(
    response = y_num,
    predictor = score,
    quiet = TRUE,
    direction = "<"
  )

  pr <- PRROC::pr.curve(
    scores.class0 = score[y_num == 1],
    scores.class1 = score[y_num == 0],
    curve = FALSE
  )

  list(
    auroc = as.numeric(pROC::auc(roc_obj)),
    auprc = as.numeric(pr$auc.integral),
    brier = mean((score - y_num)^2)
  )
}

score_discrimination_metrics <- function(y, score) {
  if (length(unique(y)) < 2) {
    return(data.frame(metric = c("AUROC", "AUPRC"), value = NA_real_, model = "score_only"))
  }

  discrim <- compute_binary_metrics(y, score)

  data.frame(
    metric = c("AUROC", "AUPRC"),
    value = c(discrim$auroc, discrim$auprc),
    model = "score_only",
    stringsAsFactors = FALSE
  )
}

probability_metrics <- function(y, p, model_name) {
  p <- clamp_probability(p)
  lp <- qlogis(p)

  if (length(unique(y)) < 2) {
    return(data.frame(
      metric = c("AUROC", "AUPRC", "Brier", "ECE", "CalibrationIntercept", "CalibrationSlope"),
      value = NA_real_,
      model = model_name,
      stringsAsFactors = FALSE
    ))
  }

  prob_metrics <- compute_binary_metrics(y, p)
  ece <- compute_ece(y, p)

  intercept_fit <- glm(y ~ 1 + offset(lp), family = binomial())
  calib_intercept <- unname(coef(intercept_fit)[1])

  slope_fit <- glm(y ~ lp, family = binomial())
  calib_slope <- unname(coef(slope_fit)[2])

  data.frame(
    metric = c("AUROC", "AUPRC", "Brier", "ECE", "CalibrationIntercept", "CalibrationSlope"),
    value = c(prob_metrics$auroc, prob_metrics$auprc, prob_metrics$brier, ece, calib_intercept, calib_slope),
    model = model_name,
    stringsAsFactors = FALSE
  )
}

build_calibration_table <- function(y, p, n_bins = 10) {
  p <- clamp_probability(p)
  d <- data.frame(y = y, p = p)

  probs <- unique(stats::quantile(d$p, probs = seq(0, 1, length.out = n_bins + 1), na.rm = TRUE))
  if (length(probs) < 3) {
    probs <- c(0, 1)
  }
  d$bin <- cut(d$p, breaks = probs, include.lowest = TRUE)

  aggregate(
    cbind(predicted = d$p, observed = d$y) ~ bin,
    data = d,
    FUN = mean
  )
}

evaluate_integer_risk_score <- function(person_level, lookup) {
  y <- as.integer(person_level$outcome)
  score <- as.numeric(person_level$total_score)

  metrics <- score_discrimination_metrics(y, score)
  calibration_tables <- list()

  if (!is.null(lookup)) {
    person_level <- merge(person_level, lookup, by.x = "total_score", by.y = "score", all.x = TRUE)
    names(person_level)[names(person_level) == "risk"] <- "predicted_risk_lookup"

    valid_lookup <- !is.na(person_level$predicted_risk_lookup)
    if (any(valid_lookup)) {
      metrics <- rbind(
        metrics,
        probability_metrics(
          y = y[valid_lookup],
          p = person_level$predicted_risk_lookup[valid_lookup],
          model_name = "lookup"
        )
      )
      calibration_tables$lookup <- build_calibration_table(
        y = y[valid_lookup],
        p = person_level$predicted_risk_lookup[valid_lookup]
      )
    }
  }

  recal_fit <- glm(y ~ score, family = binomial())
  person_level$predicted_risk_recalibrated <- stats::predict(recal_fit, type = "response")

  metrics <- rbind(
    metrics,
    probability_metrics(
      y = y,
      p = person_level$predicted_risk_recalibrated,
      model_name = "recalibrated"
    )
  )
  calibration_tables$recalibrated <- build_calibration_table(
    y = y,
    p = person_level$predicted_risk_recalibrated
  )

  list(person_level = person_level, metrics = metrics, calibration_tables = calibration_tables)
}

save_calibration_plot <- function(calibration_table, model_name, output_folder) {
  p <- ggplot2::ggplot(calibration_table, ggplot2::aes(x = predicted, y = observed)) +
    ggplot2::geom_point(size = 2) +
    ggplot2::geom_line() +
    ggplot2::geom_abline(intercept = 0, slope = 1, linetype = "dashed") +
    ggplot2::labs(
      title = paste("Calibration Plot:", model_name),
      x = "Mean predicted risk",
      y = "Observed event rate"
    ) +
    ggplot2::theme_minimal()

  out_file <- file.path(output_folder, paste0("calibration_", model_name, ".png"))
  ggplot2::ggsave(out_file, p, width = 7, height = 5, dpi = 150)
}

run_integer_risk_score_pipeline <- function(config, connection_details) {
  dir.create(config$risk_score_output_folder, recursive = TRUE, showWarnings = FALSE)

  message("\n=== Integer risk score pipeline ===")
  message("Reading score specification files ...")
  specs <- read_score_specs(config)

  conn <- DatabaseConnector::connect(connection_details)
  on.exit(DatabaseConnector::disconnect(conn), add = TRUE)

  message("Checking concept_ancestor indexes ...")
  ensure_concept_ancestor_indexes(conn, config)

  message("Calculating person-level score components ...")
  score_data <- calculate_scores(conn, config, specs)
  person_level <- score_data$person_level

  message("Evaluating discrimination and calibration ...")
  eval_results <- evaluate_integer_risk_score(person_level, specs$lookup)

  out <- config$risk_score_output_folder

  readr::write_csv(eval_results$person_level, file.path(out, "person_level_scores.csv"))
  readr::write_csv(score_data$component_summary, file.path(out, "component_summary.csv"))
  readr::write_csv(eval_results$metrics, file.path(out, "metrics.csv"))

  for (nm in names(eval_results$calibration_tables)) {
    tbl <- eval_results$calibration_tables[[nm]]
    readr::write_csv(tbl, file.path(out, paste0("calibration_table_", nm, ".csv")))
    save_calibration_plot(tbl, nm, out)
  }

  message("Output folder: ", normalizePath(out, winslash = "/", mustWork = FALSE))
  message("Wrote: person_level_scores.csv, component_summary.csv, metrics.csv, calibration tables, calibration plots")

  invisible(eval_results)
}
