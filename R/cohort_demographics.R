# R/cohort_demographics.R
# Extract cohort demographic and procedural characteristics from OMOP CDM
# Used by the extended report generation

#' Calculate cohort summary statistics
#'
#' @param person_level Data frame with person-level scores (from risk_score_pipeline)
#' @param connection DatabaseConnector connection object
#' @param config Configuration list with CDM/cohort details
#' @return Data frame with cohort summary statistics
calculate_cohort_summary <- function(person_level, connection, config) {
  
  if (is.null(person_level) || nrow(person_level) == 0) {
    return(NULL)
  }
  
  # Extract basic counts
  n_total_procedures <- nrow(person_level)
  n_unique_patients <- length(unique(person_level$subject_id))
  n_ssi_events <- sum(person_level$outcome, na.rm = TRUE)
  ssi_rate <- round(100 * n_ssi_events / n_total_procedures, 2)
  
  # Age statistics
  sql_age <- SqlRender::render(
    "SELECT YEAR(p.birth_datetime) AS birth_year,
            YEAR(c.cohort_start_date) - YEAR(p.birth_datetime) AS age_at_index
     FROM @results_schema.@cohort_table c
     INNER JOIN @cdm_schema.person p ON c.subject_id = p.person_id
     WHERE c.cohort_definition_id = @target_id",
    results_schema = config$results_schema,
    cohort_table = config$cohort_table,
    cdm_schema = config$cdm_schema,
    target_id = config$target_cohort_id
  )
  
  age_data <- tryCatch({
    DatabaseConnector::querySql(connection, SqlRender::translate(sql_age, targetDialect = "sql server"))
  }, error = function(e) NULL)
  
  age_stats <- NULL
  if (!is.null(age_data) && nrow(age_data) > 0) {
    age_data$AGE_AT_INDEX <- as.numeric(age_data$AGE_AT_INDEX)
    age_stats <- list(
      mean_age = round(mean(age_data$AGE_AT_INDEX, na.rm = TRUE), 1),
      sd_age = round(sd(age_data$AGE_AT_INDEX, na.rm = TRUE), 1),
      median_age = as.numeric(median(age_data$AGE_AT_INDEX, na.rm = TRUE)),
      min_age = as.numeric(min(age_data$AGE_AT_INDEX, na.rm = TRUE)),
      max_age = as.numeric(max(age_data$AGE_AT_INDEX, na.rm = TRUE))
    )
  }
  
  # Gender distribution
  sql_gender <- SqlRender::render(
    "SELECT gc.concept_name AS gender,
            COUNT(DISTINCT p.person_id) AS count
     FROM @cdm_schema.person p
     INNER JOIN @results_schema.@cohort_table c ON p.person_id = c.subject_id
     INNER JOIN @cdm_schema.concept gc ON p.gender_concept_id = gc.concept_id
     WHERE c.cohort_definition_id = @target_id
     GROUP BY gc.concept_name
     ORDER BY count DESC",
    results_schema = config$results_schema,
    cohort_table = config$cohort_table,
    cdm_schema = config$cdm_schema,
    target_id = config$target_cohort_id
  )
  
  gender_data <- tryCatch({
    DatabaseConnector::querySql(connection, SqlRender::translate(sql_gender, targetDialect = "sql server"))
  }, error = function(e) NULL)
  
  # Return summary as data frame
  summary_df <- data.frame(
    characteristic = c(
      "Total procedures", "Unique patients", "SSI events", "SSI rate (%)",
      "Mean age (SD)", "Median age [min, max]"
    ),
    value = c(
      as.character(n_total_procedures),
      as.character(n_unique_patients),
      as.character(n_ssi_events),
      as.character(ssi_rate),
      if (!is.null(age_stats)) 
        paste0(age_stats$mean_age, " (", age_stats$sd_age, ")")
      else "N/A",
      if (!is.null(age_stats))
        paste0(age_stats$median_age, " [", age_stats$min_age, ", ", age_stats$max_age, "]")
      else "N/A"
    ),
    stringsAsFactors = FALSE
  )
  
  # Add gender distribution if available
  if (!is.null(gender_data) && nrow(gender_data) > 0) {
    for (i in seq_len(nrow(gender_data))) {
      pct <- round(100 * gender_data$COUNT[i] / n_unique_patients, 1)
      summary_df <- rbind(summary_df, data.frame(
        characteristic = paste0(gender_data$GENDER[i], " (%)"),
        value = paste0(gender_data$COUNT[i], " (", pct, "%)"),
        stringsAsFactors = FALSE
      ))
    }
  }
  
  summary_df
}

#' Build combined feature table (components + prevalence)
#'
#' @param components Data frame from specs$components
#' @param component_summary Data frame from risk_score_pipeline output
#' @return Data frame suitable for flextable display
build_combined_feature_table <- function(components, component_summary) {
  
  if (is.null(component_summary)) {
    return(NULL)
  }
  
  # Merge components with prevalence data
  combined <- merge(
    components[, c("component_name", "points", "lookback_start_day", "lookback_end_day")],
    component_summary[, c("component_name", "n_positive", "n_total")],
    by = "component_name",
    all.x = TRUE
  )
  
  combined$lookback <- paste0(
    combined$lookback_start_day, " to ",
    combined$lookback_end_day, " days"
  )
  combined$prevalence <- paste0(
    combined$n_positive, " / ", combined$n_total, " (",
    round(100 * combined$n_positive / combined$n_total, 1), "%)"
  )
  
  # Select and reorder columns
  combined <- combined[, c("component_name", "points", "lookback", "prevalence")]
  names(combined) <- c("Component", "Points", "Lookback Window", "Prevalence (n / N, %)")
  
  combined
}
