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

query_component_counts <- function(connection, config, component, component_concepts) {
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
  names(outcomes)[names(outcomes) == "SUBJECT_ID"] <- "subject_id"
  names(outcomes)[names(outcomes) == "INDEX_DATE"] <- "index_date"
  names(outcomes)[names(outcomes) == "OUTCOME"] <- "outcome"

  components <- specs$components
  concepts <- specs$concepts

  component_matrix <- outcomes[, c("subject_id")]
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
      names(counts)[names(counts) == "SUBJECT_ID"] <- "subject_id"
      names(counts)[names(counts) == "EVENT_COUNT"] <- "event_count"
    }

    df <- merge(
      outcomes[, c("subject_id")],
      counts[, c("subject_id", "event_count"), drop = FALSE],
      by = "subject_id",
      all.x = TRUE
    )
    df$event_count[is.na(df$event_count)] <- 0L

    score_col <- paste0("score_", comp$component_id)
    df[[score_col]] <- ifelse(df$event_count >= comp$min_count, comp$points, 0)

    component_matrix <- merge(component_matrix, df[, c("subject_id", score_col)], by = "subject_id", all.x = TRUE)

    component_summary <- rbind(
      component_summary,
      data.frame(
        component_id = comp$component_id,
        component_name = comp$component_name,
        domain = comp$domain,
        n_positive = sum(df[[score_col]] > 0, na.rm = TRUE),
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

score_discrimination_metrics <- function(y, score) {
  if (length(unique(y)) < 2) {
    return(data.frame(metric = c("AUROC", "AUPRC"), value = NA_real_, model = "score_only"))
  }

  roc_obj <- pROC::roc(response = y, predictor = score, quiet = TRUE, direction = "<")
  auc_val <- as.numeric(pROC::auc(roc_obj))

  pr <- PRROC::pr.curve(
    scores.class0 = score[y == 1],
    scores.class1 = score[y == 0],
    curve = FALSE
  )

  data.frame(
    metric = c("AUROC", "AUPRC"),
    value = c(auc_val, as.numeric(pr$auc.integral)),
    model = "score_only",
    stringsAsFactors = FALSE
  )
}

probability_metrics <- function(y, p, model_name) {
  p <- clamp_probability(p)
  lp <- qlogis(p)

  if (length(unique(y)) < 2) {
    return(data.frame(
      metric = c("AUROC", "AUPRC", "Brier", "CalibrationIntercept", "CalibrationSlope"),
      value = NA_real_,
      model = model_name,
      stringsAsFactors = FALSE
    ))
  }

  roc_obj <- pROC::roc(response = y, predictor = p, quiet = TRUE, direction = "<")
  auc_val <- as.numeric(pROC::auc(roc_obj))

  pr <- PRROC::pr.curve(
    scores.class0 = p[y == 1],
    scores.class1 = p[y == 0],
    curve = FALSE
  )

  brier <- mean((p - y)^2)

  intercept_fit <- glm(y ~ 1 + offset(lp), family = binomial())
  calib_intercept <- unname(coef(intercept_fit)[1])

  slope_fit <- glm(y ~ lp, family = binomial())
  calib_slope <- unname(coef(slope_fit)[2])

  data.frame(
    metric = c("AUROC", "AUPRC", "Brier", "CalibrationIntercept", "CalibrationSlope"),
    value = c(auc_val, as.numeric(pr$auc.integral), brier, calib_intercept, calib_slope),
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
