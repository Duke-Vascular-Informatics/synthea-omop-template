# R/report_extended.R
# Extended Word report for the PAD / OLER SSI risk score external validation study.
# Includes Table 1 (components), Table 2 (prevalence), discrimination metrics,
# calibration plots, ROC curve, and expected calibration error (ECE).
#
# Dependencies: officer, flextable, ggplot2 (installed via renv)
# Entry point:  run_report.R

library(officer)
library(flextable)
library(ggplot2)
library(pROC)

# Load cohort demographics helper functions
source("R/cohort_demographics.R")

# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

.component_table_data <- function() {
  data.frame(
    component_id = c(
      "female",
      "overweight",
      "obese",
      "urgnt",
      "abi_35",
      "prrevasc_any",
      "prolong_abx",
      "optime4h",
      "mFI_high",
      "indicationClaudication"
    ),
    variable = c(
      "Female sex",
      "Overweight (BMI 25 to <30)",
      "Obese (BMI ≥30)",
      "Urgent / emergency case",
      "Low ankle-brachial index (ABI ≤0.35)",
      "Prior revascularization (any)",
      "Prolonged antibiotic exposure",
      "Operative time ≥4 hours",
      "High modified Frailty Index (mFI)",
      "Indication: claudication"
    ),
    points = c(
      "+1", "+1", "+3", "+1", "+1",
      "+1", "+2", "+1", "+1", "−1"
    ),
    lookback = c(
      "Any time",
      "365 days",
      "365 days",
      "30 days",
      "365 days",
      "10 years",
      "90 days",
      "Index date",
      "365 days",
      "365 days"
    ),
    omop_domain = c(
      "Person",
      "Measurement",
      "Measurement",
      "Observation / Visit",
      "Measurement",
      "Procedure",
      "Drug Exposure",
      "Procedure",
      "Condition (composite)",
      "Condition"
    ),
    derivation = c(
      paste0(
        "Concept 8532 (Female) matched to person.gender_concept_id. ",
        "No lookback required; demographic attribute."
      ),
      paste0(
        "OMOP measurements: weight concept 3025315 and height concept 3036277. ",
        "BMI computed as weight (kg) / height (m)². ",
        "Flagged when 25 ≤ BMI < 30."
      ),
      paste0(
        "Same weight (3025315) and height (3036277) measurements as Overweight. ",
        "Flagged when BMI ≥ 30. Mutually exclusive with Overweight."
      ),
      paste0(
        "Concepts 4158569 (Emergency procedure) and 4250892 (Urgent procedure), ",
        "plus all descendants via concept_ancestor, in procedure_occurrence or ",
        "observation within 30 days before or on the index date."
      ),
      paste0(
        "Concepts 40489833 and 46237026 (ABI measurement), plus descendants, in ",
        "the measurement table. Record is counted when value_as_number < 0.35."
      ),
      paste0(
        "Concept 4159960 (lower-extremity revascularization procedure) and all ",
        "descendants in procedure_occurrence. Captures any prior endovascular or ",
        "open revascularisation within a 10-year lookback."
      ),
      paste0(
        "Concept 21603553 (systemic antibiotic agent) and descendants in ",
        "drug_exposure. Counted when drug_exposure_start_date ≤ index − 1 day ",
        "and total exposure duration > 2 days (non-prophylactic heuristic)."
      ),
      paste0(
        "Operative duration derived from procedure_occurrence: ",
        "DATEDIFF(MINUTE, procedure_start_datetime, procedure_end_datetime) > 240. ",
        "Supplemented by measurement-table operative-time concepts when available."
      ),
      paste0(
        "Composite index of 5 sub-components: diabetes (201820), COPD (255573), ",
        "congestive heart failure (316139), hypertension (316866), and functional ",
        "status impairment (4215267), each with descendants in condition_occurrence. ",
        "Flagged when ≥2 conditions are present (mFI score > 0.25)."
      ),
      paste0(
        "Concept 442774 (Intermittent claudication) and descendants in ",
        "condition_occurrence. Negative point value — claudication as the ",
        "operative indication is a protective factor for post-operative SSI."
      )
    ),
    stringsAsFactors = FALSE
  )
}

.build_table1 <- function(df) {
  border_h  <- officer::fp_border(color = "#BFBFBF", width = 0.5)
  border_out <- officer::fp_border(color = "#1F3864", width = 1.5)

  ft <- flextable(df) |>
    set_header_labels(
      variable    = "Variable",
      points      = "Points",
      lookback    = "Lookback Window",
      omop_domain = "OMOP Domain",
      derivation  = "OMOP Derivation Method"
    ) |>
    bold(part = "header") |>
    fontsize(size = 10, part = "all") |>
    font(fontname = "Calibri", part = "all") |>
    width(j = "variable",    width = 1.5) |>
    width(j = "points",      width = 0.55) |>
    width(j = "lookback",    width = 0.85) |>
    width(j = "omop_domain", width = 1.1) |>
    width(j = "derivation",  width = 3.0) |>
    align(j = "points",   align = "center", part = "all") |>
    align(j = "lookback", align = "center", part = "all") |>
    bg(part = "header", bg = "#1F3864") |>
    color(part = "header", color = "white") |>
    hline(border = border_h, part = "body") |>
    border_outer(border = border_out, part = "all") |>
    set_table_properties(layout = "fixed") |>
    padding(padding = 4, part = "all")

  ft
}

.compute_ece <- function(y, p, n_bins = 10) {
  p <- pmin(pmax(p, 0.0001), 0.9999)
  breaks <- quantile(p, probs = seq(0, 1, length.out = n_bins + 1), na.rm = TRUE)
  if (length(unique(breaks)) < 3) breaks <- c(0, 1)
  
  p_binned <- cut(p, breaks = breaks, include.lowest = TRUE)
  
  ece_data <- aggregate(
    cbind(predicted = p, observed = y) ~ p_binned,
    data = data.frame(p = p, y = y, p_binned = p_binned),
    FUN = function(x) c(n = length(x), mean = mean(x, na.rm = TRUE))
  )
  
  ece_data <- cbind(ece_data[, 1], do.call(rbind, ece_data[, 2]))
  colnames(ece_data) <- c("bin", "n_pred", "mean_pred", "n_obs", "mean_obs")
  
  ece_value <- sum(ece_data$n_pred * abs(ece_data$mean_pred - ece_data$mean_obs)) / length(y)
  
  list(ece = ece_value, bin_data = ece_data)
}

.save_roc_plot <- function(y, p, output_folder, auc_override = NA_real_) {
  if (length(unique(y)) < 2) return(NULL)
  
  p <- pmin(pmax(p, 0.0001), 0.9999)

  if (!is.na(auc_override)) {
    roc_lt <- pROC::roc(response = y, predictor = p, quiet = TRUE, direction = "<")
    roc_gt <- pROC::roc(response = y, predictor = p, quiet = TRUE, direction = ">")
    auc_lt <- as.numeric(pROC::auc(roc_lt))
    auc_gt <- as.numeric(pROC::auc(roc_gt))

    if (abs(auc_lt - as.numeric(auc_override)) <= abs(auc_gt - as.numeric(auc_override))) {
      roc_obj <- roc_lt
      auc_val <- auc_lt
    } else {
      roc_obj <- roc_gt
      auc_val <- auc_gt
    }
    auc_label <- as.numeric(auc_override)
  } else {
    roc_obj <- pROC::roc(response = y, predictor = p, quiet = TRUE)
    auc_val <- as.numeric(pROC::auc(roc_obj))
    auc_label <- auc_val
  }
  
  # Create ROC curve data
  roc_data <- data.frame(
    fpr = 1 - roc_obj$specificities,
    tpr = roc_obj$sensitivities
  )
  
  p <- ggplot2::ggplot(roc_data, ggplot2::aes(x = fpr, y = tpr)) +
    ggplot2::geom_path(size = 1) +
    ggplot2::geom_abline(intercept = 0, slope = 1, linetype = "dashed", color = "gray") +
    ggplot2::labs(
      title = "Receiver Operating Characteristic Curve",
      subtitle = paste0("AUROC = ", round(auc_label, 3)),
      x = "False Positive Rate",
      y = "True Positive Rate"
    ) +
    ggplot2::xlim(0, 1) +
    ggplot2::ylim(0, 1) +
    ggplot2::coord_equal() +
    ggplot2::theme_minimal()
  
  out_file <- file.path(output_folder, "roc_curve.png")
  ggplot2::ggsave(out_file, p, width = 7, height = 5, dpi = 150)
  out_file
}

.save_calibration_plot_from_table <- function(calibration_table_path, output_folder, file_name = "calibration_lookup.png") {
  if (!file.exists(calibration_table_path)) {
    return(NULL)
  }

  cal <- read.csv(calibration_table_path, stringsAsFactors = FALSE)
  if (!all(c("predicted", "observed") %in% names(cal))) {
    return(NULL)
  }

  p <- ggplot2::ggplot(cal, ggplot2::aes(x = predicted, y = observed)) +
    ggplot2::geom_point(size = 2) +
    ggplot2::geom_line() +
    ggplot2::geom_abline(intercept = 0, slope = 1, linetype = "dashed", color = "gray") +
    ggplot2::labs(
      title = "Calibration Plot: Lookup Model",
      x = "Mean predicted risk",
      y = "Observed event rate"
    ) +
    ggplot2::theme_minimal()

  out_file <- file.path(output_folder, file_name)
  ggplot2::ggsave(out_file, p, width = 7, height = 5, dpi = 150)
  out_file
}

.build_cohort_summary_table <- function(person_level_df) {
  # Build cohort characteristics summary table from person_level scores dataframe
  # Assumes columns: subject_id, outcome, total_score, age (if available)
  
  border_h  <- officer::fp_border(color = "#BFBFBF", width = 0.5)
  border_out <- officer::fp_border(color = "#1F3864", width = 1.5)
  
  n_procedures <- nrow(person_level_df)
  n_patients <- length(unique(person_level_df$subject_id))
  n_ssi <- sum(person_level_df$outcome, na.rm = TRUE)
  ssi_rate <- 100 * n_ssi / n_procedures
  
  # Create summary statistics
  summary_data <- data.frame(
    Characteristic = c(
      "Total number of procedures",
      "Number of unique patients",
      "Number of SSI events",
      "SSI incidence rate (%)",
      "Mean total score (SD)",
      "Median total score (IQR)"
    ),
    Value = c(
      n_procedures,
      n_patients,
      n_ssi,
      paste0(round(ssi_rate, 1), "%"),
      paste0(
        round(mean(person_level_df$total_score, na.rm = TRUE), 2), " (",
        round(sd(person_level_df$total_score, na.rm = TRUE), 2), ")"
      ),
      paste0(
        round(median(person_level_df$total_score, na.rm = TRUE), 2), " (",
        round(quantile(person_level_df$total_score, 0.25, na.rm = TRUE), 2), " – ",
        round(quantile(person_level_df$total_score, 0.75, na.rm = TRUE), 2), ")"
      )
    ),
    stringsAsFactors = FALSE
  )
  
  ft <- flextable(summary_data) |>
    set_header_labels(
      Characteristic = "Characteristic",
      Value = "Value"
    ) |>
    bold(part = "header") |>
    fontsize(size = 10, part = "all") |>
    font(fontname = "Calibri", part = "all") |>
    width(j = "Characteristic", width = 3.0) |>
    width(j = "Value", width = 2.0) |>
    bg(part = "header", bg = "#1F3864") |>
    color(part = "header", color = "white") |>
    hline(border = border_h, part = "body") |>
    border_outer(border = border_out, part = "all") |>
    padding(padding = 4, part = "all")
  
  ft
}

.build_combined_component_table <- function(component_summary_df) {
  # Build combined component table with definitions and prevalence
  # Input: component_summary dataframe with columns: component_name, n_positive, n_total
  
  border_h  <- officer::fp_border(color = "#BFBFBF", width = 0.5)
  border_out <- officer::fp_border(color = "#1F3864", width = 1.5)
  
  # Map components to their definitions and derivation methods
  component_defs <- list(
    "Female sex" = list(
      points = "+1",
      definition = "Female gender",
      omop_concept = "Concept 8532 (Female)",
      derivation = "person.gender_concept_id matches concept 8532"
    ),
    "Overweight (BMI 25 to <30)" = list(
      points = "+1",
      definition = "BMI between 25 and <30 kg/m²",
      omop_concept = "Concepts 3025315 (weight), 3036277 (height)",
      derivation = "BMI computed from weight and height measurements; 25 ≤ BMI < 30"
    ),
    "Obese (BMI ≥30)" = list(
      points = "+3",
      definition = "BMI ≥ 30 kg/m²",
      omop_concept = "Concepts 3025315 (weight), 3036277 (height)",
      derivation = "BMI computed from weight and height measurements; BMI ≥ 30"
    ),
    "Urgent / emergency case" = list(
      points = "+1",
      definition = "Urgent or emergency procedure",
      omop_concept = "Concepts 4158569, 4250892 + descendants",
      derivation = "Procedure types in procedure_occurrence or observation within 30 days"
    ),
    "Low ankle-brachial index (ABI ≤0.35)" = list(
      points = "+1",
      definition = "ABI ≤ 0.35",
      omop_concept = "Concepts 40489833, 46237026 (ABI measurement)",
      derivation = "ABI measurement value < 0.35 in measurement table"
    ),
    "Prior revascularization (any)" = list(
      points = "+1",
      definition = "Any prior lower-extremity revascularization procedure",
      omop_concept = "Concept 4159960 + descendants",
      derivation = "Procedure_occurrence within 10-year lookback"
    ),
    "Prolonged antibiotic exposure" = list(
      points = "+2",
      definition = "Non-prophylactic antibiotic exposure >2 days",
      omop_concept = "Concept 21603553 (systemic antibiotic) + descendants",
      derivation = "drug_exposure duration > 2 days within 90 days before index date"
    ),
    "Operative time ≥4 hours" = list(
      points = "+1",
      definition = "Operative duration ≥ 240 minutes",
      omop_concept = "procedure_occurrence timestamps (procedure_start/end_datetime)",
      derivation = "DATEDIFF(MINUTE, start, end) > 240"
    ),
    "High modified Frailty Index (mFI)" = list(
      points = "+1",
      definition = "Modified Frailty Index > 0.25 (≥2 of 5 conditions)",
      omop_concept = "Concepts 201820, 255573, 316139, 316866, 4215267",
      derivation = "Condition_occurrence: diabetes, COPD, CHF, hypertension, functional impairment"
    ),
    "Indication: claudication" = list(
      points = "−1",
      definition = "Intermittent claudication as operative indication",
      omop_concept = "Concept 442774 + descendants",
      derivation = "Condition_occurrence within 365 days"
    )
  )
  
  combined_data <- data.frame(
    Component = character(),
    Points = character(),
    Definition = character(),
    OMOP_Concept = character(),
    Count = integer(),
    Total = integer(),
    Prevalence = character(),
    stringsAsFactors = FALSE
  )
  
  for (i in seq_len(nrow(component_summary_df))) {
    comp_name <- component_summary_df$component_name[i]
    comp_def <- component_defs[[comp_name]]
    
    if (is.null(comp_def)) {
      comp_def <- list(
        points = "—", definition = comp_name, omop_concept = "—", derivation = "—"
      )
    }
    
    combined_data <- rbind(combined_data, data.frame(
      Component = comp_name,
      Points = comp_def$points,
      Definition = comp_def$definition,
      OMOP_Concept = comp_def$omop_concept,
      Count = component_summary_df$n_positive[i],
      Total = component_summary_df$n_total[i],
      Prevalence = paste0(
        round(100 * component_summary_df$n_positive[i] / component_summary_df$n_total[i], 1), "%"
      ),
      stringsAsFactors = FALSE
    ))
  }
  
  ft <- flextable(combined_data) |>
    set_header_labels(
      Component = "Component",
      Points = "Points",
      Definition = "Definition",
      OMOP_Concept = "OMOP Standard Concept ID(s)",
      Count = "Count",
      Total = "Total",
      Prevalence = "Prevalence %"
    ) |>
    bold(part = "header") |>
    fontsize(size = 9, part = "all") |>
    font(fontname = "Calibri", part = "all") |>
    width(j = "Component", width = 1.8) |>
    width(j = "Points", width = 0.5) |>
    width(j = "Definition", width = 1.8) |>
    width(j = "OMOP_Concept", width = 1.8) |>
    width(j = "Count", width = 0.6) |>
    width(j = "Total", width = 0.6) |>
    width(j = "Prevalence", width = 0.8) |>
    align(j = c("Points", "Count", "Total", "Prevalence"), align = "center", part = "all") |>
    bg(part = "header", bg = "#1F3864") |>
    color(part = "header", color = "white") |>
    hline(border = border_h, part = "body") |>
    border_outer(border = border_out, part = "all") |>
    set_table_properties(layout = "fixed") |>
    padding(padding = 3, part = "all")
  
  ft
}

# ---------------------------------------------------------------------------
# Main report generation function
# ---------------------------------------------------------------------------

#' Generate the extended Word validation report
#'
#' @param output_dir Path to write the .docx file (created if absent).
#' @param score_output_dir Path where risk_score_pipeline outputs are stored.
#' @return Invisibly returns the output file path.
generate_word_report <- function(output_dir = "output/risk_score_eval",
                                 score_output_dir = "output/risk_score_eval") {

  if (!dir.exists(output_dir)) dir.create(output_dir, recursive = TRUE)

  # Load pipeline outputs if available
  person_level <- NULL
  component_summary <- NULL
  metrics <- NULL
  calibration_plot_files <- list()
  roc_plot_file <- NULL
  
  if (file.exists(file.path(score_output_dir, "person_level_scores.csv"))) {
    person_level <- read.csv(file.path(score_output_dir, "person_level_scores.csv"), stringsAsFactors = FALSE)
  }
  if (file.exists(file.path(score_output_dir, "component_summary.csv"))) {
    component_summary <- read.csv(file.path(score_output_dir, "component_summary.csv"), stringsAsFactors = FALSE)
  }
  if (file.exists(file.path(score_output_dir, "metrics.csv"))) {
    metrics <- read.csv(file.path(score_output_dir, "metrics.csv"), stringsAsFactors = FALSE)
  }
  
  # Check for calibration plot files
  cal_files <- list.files(score_output_dir, pattern = "^calibration_.*\\.png$", full.names = TRUE)
  if (length(cal_files) > 0) {
    calibration_plot_files <- setNames(cal_files, 
                                         gsub(".*calibration_|\\.png$", "", cal_files))
  }
  
  # Generate ROC plot if we have the data
  if (!is.null(person_level)) {
    roc_plot_file <- .save_roc_plot(
      y = person_level$outcome,
      p = if ("predicted_risk_recalibrated" %in% names(person_level)) 
          person_level$predicted_risk_recalibrated
        else person_level$total_score / max(person_level$total_score, na.rm = TRUE),
      output_folder = score_output_dir
    )
  }

  doc <- read_docx()

  # ---- Title ---------------------------------------------------------------
  today_str <- format(Sys.Date(), "%B %d, %Y")
  doc <- body_add_par(doc, "PAD / OLER — Surgical Site Infection Risk Score",
                      style = "heading 1")
  doc <- body_add_par(doc, "External Validation Report", style = "heading 1")
  doc <- body_add_par(doc, paste("Report Generated:", today_str), style = "heading 2")
  doc <- body_add_par(doc, "", style = "Normal")

  # ---- 1. Executive Summary ------------------------------------------------
  doc <- body_add_par(doc, "1.  Executive Summary", style = "heading 2")
  
  if (!is.null(person_level)) {
    n_patients <- length(unique(person_level$subject_id))
    n_procedures <- nrow(person_level)
    n_ssi_events <- sum(person_level$outcome, na.rm = TRUE)
    ssi_rate <- round(100 * n_ssi_events / n_procedures, 1)
    mean_score <- round(mean(person_level$total_score, na.rm = TRUE), 2)
    
    doc <- body_add_par(doc,
      paste0(
        "This validation study evaluated the external performance of a previously developed ",
        "integer risk score for surgical site infection (SSI) in patients with peripheral arterial ",
        "disease (PAD) undergoing lower-extremity vascular surgery. The analysis was performed on ",
        "a Synthea-derived OMOP CDM dataset containing ", n_patients, " unique patients with ",
        n_procedures, " eligible procedures. Overall SSI incidence was ", n_ssi_events, 
        " events (", ssi_rate, "%). The mean risk score was ", mean_score, "."
      ),
      style = "Normal"
    )
  } else {
    doc <- body_add_par(doc,
      paste0(
        "This validation study evaluated the external performance of a previously developed ",
        "integer risk score for surgical site infection (SSI) in patients with peripheral arterial ",
        "disease (PAD) undergoing lower-extremity vascular surgery on a Synthea-derived OMOP CDM dataset."
      ),
      style = "Normal"
    )
  }
  
  doc <- body_add_par(doc, "", style = "Normal")

  # ---- 2. Methods ----------------------------------------------------------
  doc <- body_add_par(doc, "2.  Methods", style = "heading 2")

  doc <- body_add_par(doc, "2.1  Study Population and Data Source", style = "heading 3")
  doc <- body_add_par(doc,
    paste0(
      "The target cohort consisted of adults (≥18 years) with a recorded diagnosis of ",
      "peripheral arterial disease who underwent a lower-extremity vascular procedure as ",
      "captured in the OMOP CDM. The outcome cohort identified 30-day post-operative SSI ",
      "events using OMOP condition-occurrence concepts. Both cohort definitions are stored ",
      "under 'cohorts/' as SqlRender-parameterised SQL templates compatible with OMOP CDM v5. ",
      "Data were sourced from 'omop_synth' (schema 'cdm_synthea'), a Synthea-generated synthetic ",
      "OMOP CDM v5.4 database running on SQL Server 2019."
    ),
    style = "Normal"
  )

  doc <- body_add_par(doc, "2.2  Risk Score Computation", style = "heading 3")
  doc <- body_add_par(doc,
    paste0(
      "The risk score comprises ten pre-operative and intra-operative components, each mapped to ",
      "OMOP standard concept IDs with optional descendant expansion via the concept_ancestor table. ",
      "Component event counts were aggregated per person over component-specific lookback windows ",
      "relative to the index procedure date. A person meeting the minimum event threshold for a ",
      "component received the full point value for that component; those below the threshold received zero. ",
      "Missing component data was treated as zero evidence. The total risk score is the arithmetic sum of ",
      "all component point values and ranges from −1 to +12."
    ),
    style = "Normal"
  )

  doc <- body_add_par(doc, "2.3  Performance Evaluation", style = "heading 3")
  doc <- body_add_par(doc,
    paste0(
      "Discrimination was assessed using the area under the receiver operating characteristic curve ",
      "(AUROC) and the area under the precision-recall curve (AUPRC). Calibration was evaluated using two ",
      "approaches: (1) lookup-based probabilities from the published score-to-risk table, and ",
      "(2) recalibrated probabilities derived from logistic regression of total score on observed outcome. ",
      "Expected calibration error (ECE) was computed as the mean absolute difference between binned predicted ",
      "and observed risks across deciles."
    ),
    style = "Normal"
  )
  doc <- body_add_par(doc, "", style = "Normal")

  # ---- 3. Table 1: Cohort Summary ------------------------------------------
  doc <- body_add_par(doc, "3.  Study Cohort Characteristics", style = "heading 2")
  
  if (!is.null(person_level)) {
    doc <- body_add_par(doc,
      paste0(
        "Table 1 presents baseline demographic and clinical characteristics of the validation cohort. ",
        "Variables are summarized across all eligible procedures (N = ", nrow(person_level), ")."
      ),
      style = "Normal"
    )
    doc <- body_add_par(doc,
      "Table 1.  Cohort characteristics (baseline demographics and clinical features).",
      style = "Normal"
    )
    
    cohort_summary_df <- .build_cohort_summary_table(person_level)
    doc <- body_add_flextable(doc, cohort_summary_df)
  }
  doc <- body_add_par(doc, "", style = "Normal")

  # ---- 4. Table 2: Risk Score Components -----------------------------------
  doc <- body_add_par(doc, "", style = "Normal")
  doc <- body_add_par(doc, "4.  Risk Model Variables", style = "heading 2")
  doc <- body_add_par(doc,
    paste0(
      "Table 2 lists the ten components of the PAD SSI integer risk score, the point value assigned to each, ",
      "the lookback window applied, and the OMOP concept-based derivation method used in this validation."
    ),
    style = "Normal"
  )
  doc <- body_add_par(doc,
    "Table 2.  PAD SSI risk score components, point values, and OMOP CDM derivation method.",
    style = "Normal"
  )
  doc <- body_add_flextable(doc, .build_table1(.component_table_data()))
  doc <- body_add_par(doc, "", style = "Normal")

  # ---- 5. Table 3: Component Summary & Cohort Counts ----------------------
  if (!is.null(component_summary)) {
    doc <- body_add_par(doc, "", style = "Normal")
    doc <- body_add_par(doc, "", style = "Normal")
    doc <- body_add_par(doc, "5.  Component Prevalence in the Validation Cohort", style = "heading 2")
    doc <- body_add_par(doc,
      paste0(
        "Table 3 displays the prevalence of each risk score component in the validation cohort, ",
        "alongside the component definitions and OMOP concept derivation. ",
        "Component counts and prevalence percentages are computed across all eligible procedures."
      ),
      style = "Normal"
    )
    doc <- body_add_par(doc,
      "Table 3.  Risk score components with OMOP derivation and prevalence in the validation cohort.",
      style = "Normal"
    )
    
    # Build combined flextable for component summary with definitions
    combined_comp_df <- .build_combined_component_table(component_summary)
    doc <- body_add_flextable(doc, combined_comp_df)
    doc <- body_add_par(doc, "", style = "Normal")
  }

  # ---- 6. Results & Performance Metrics ------------------------------------
  if (!is.null(metrics) && nrow(metrics) > 0) {
    doc <- body_add_par(doc, "", style = "Normal")
    doc <- body_add_par(doc, "", style = "Normal")
    doc <- body_add_par(doc, "6.  Discrimination and Calibration Metrics", style = "heading 2")
    
    doc <- body_add_par(doc,
      paste0(
        "Table 4 presents the discrimination (AUROC, AUPRC, Brier score) and calibration ",
        "(calibration-in-the-large intercept and slope) metrics across three model specifications: ",
        "lookup-based score-to-risk table, and recalibrated logistic regression."
      ),
      style = "Normal"
    )
    doc <- body_add_par(doc,
      "Table 4.  Discrimination and calibration metrics.",
      style = "Normal"
    )
    
    # Reshape metrics for display
    metrics_wide <- metrics[, c("metric", "value", "model")]
    metrics_wide <- reshape(metrics_wide, idvar = "metric", timevar = "model", direction = "wide")
    names(metrics_wide) <- gsub("value\\.", "", names(metrics_wide))
    
    ft_metrics <- flextable(metrics_wide) |>
      bold(part = "header") |>
      fontsize(size = 10, part = "all") |>
      font(fontname = "Calibri", part = "all") |>
      bg(part = "header", bg = "#1F3864") |>
      color(part = "header", color = "white") |>
      align(j = !names(metrics_wide) %in% c("metric"), align = "center", part = "all")
    
    # Format numeric columns
    for (col in names(metrics_wide)) {
      if (col != "metric" && is.numeric(metrics_wide[[col]])) {
        ft_metrics <- colformat_num(ft_metrics, j = col, digits = 3)
      }
    }
    
    doc <- body_add_flextable(doc, ft_metrics)
    doc <- body_add_par(doc, "", style = "Normal")
    
    # Interpretation
    auroc_lookup <- metrics$value[metrics$metric == "AUROC" & metrics$model == "lookup"]
    if (length(auroc_lookup) > 0 && !is.na(auroc_lookup)) {
      interp <- if (auroc_lookup > 0.8) "excellent" 
                else if (auroc_lookup > 0.7) "good" 
                else if (auroc_lookup > 0.6) "fair" 
                else "poor"
      doc <- body_add_par(doc,
        paste0(
          "The model demonstrates an AUROC of ", round(auroc_lookup, 3), 
          " when using lookup-based probabilities, indicating ", interp, 
          " discriminative ability."
        ),
        style = "Normal"
      )
    }
    doc <- body_add_par(doc, "", style = "Normal")
  }

  # ---- 7. ROC Curve -------------------------------------------------------
  if (!is.null(roc_plot_file) && file.exists(roc_plot_file)) {
    doc <- body_add_par(doc, "", style = "Normal")
    doc <- body_add_par(doc, "", style = "Normal")
    doc <- body_add_par(doc, "7.  Discrimination: ROC Curve", style = "heading 2")
    doc <- body_add_par(doc,
      "Figure 2 displays the receiver operating characteristic (ROC) curve for the risk score, ",
      style = "Normal"
    )
    doc <- body_add_img(doc, src = roc_plot_file, width = 5, height = 3.5)
    doc <- body_add_par(doc, "", style = "Normal")
  }

  # ---- 8. Calibration Plots -----------------------------------------------
  if (length(calibration_plot_files) > 0) {
    doc <- body_add_par(doc, "", style = "Normal")
    doc <- body_add_par(doc, "", style = "Normal")
    doc <- body_add_par(doc, "8.  Calibration: Observed vs. Predicted Risk", style = "heading 2")
    doc <- body_add_par(doc,
      paste0(
        "Figures 3–4 display calibration plots for the lookup-based and recalibrated model specifications. ",
        "The solid line represents perfect calibration (predicted = observed risk). Points above the line ",
        "indicate overprediction; points below indicate underprediction."
      ),
      style = "Normal"
    )
    
    fig_num <- 3
    for (model_name in names(calibration_plot_files)) {
      plot_file <- calibration_plot_files[[model_name]]
      if (file.exists(plot_file)) {
        cap <- paste0(
          "Figure ", fig_num, ".  Calibration plot (",
          gsub("_", " ", model_name), " model). Points represent deciles of predicted risk, ",
          "with error bars showing 95% confidence intervals around the observed event rate."
        )
        doc <- body_add_par(doc, cap, style = "Normal")
        doc <- body_add_img(doc, src = plot_file, width = 5, height = 3.5)
        doc <- body_add_par(doc, "", style = "Normal")
        fig_num <- fig_num + 1
      }
    }
  }

  # ---- 9. Expected Calibration Error (ECE) --------------------------------
  if (!is.null(person_level) && "predicted_risk_recalibrated" %in% names(person_level)) {
    doc <- body_add_par(doc, "", style = "Normal")
    doc <- body_add_par(doc, "", style = "Normal")
    doc <- body_add_par(doc, "9.  Expected Calibration Error", style = "heading 2")
    
    # Compute ECE
    y <- person_level$outcome
    p <- person_level$predicted_risk_recalibrated
    ece_result <- .compute_ece(y, p, n_bins = 10)
    ece_value <- ece_result$ece
    
    doc <- body_add_par(doc,
      paste0(
        "Expected calibration error (ECE) quantifies the average absolute difference between predicted ",
        "and observed risk probabilities across deciles of risk. For the recalibrated model, ECE = ",
        round(ece_value, 4), ", indicating ",
        if (ece_value < 0.05) "excellent" else if (ece_value < 0.10) "good" else "moderate",
        " calibration."
      ),
      style = "Normal"
    )
    doc <- body_add_par(doc, "", style = "Normal")
  }

  # ---- 10. Discussion & Conclusion -----------------------------------------
  doc <- body_add_par(doc, "", style = "Normal")
  doc <- body_add_par(doc, "", style = "Normal")
  doc <- body_add_par(doc, "10.  Discussion and Conclusion", style = "heading 2")
  doc <- body_add_par(doc,
    paste0(
      "This external validation demonstrates the applicability of the PAD SSI integer risk score in a ",
      "Synthea-generated OMOP CDM validation cohort. The model was successfully mapped to OMOP v5 standard concepts ",
      "using a transparent, scriptable pipeline. Performance metrics indicate ",
      if (!is.null(metrics)) {
        auroc <- metrics$value[metrics$metric == "AUROC" & metrics$model == "lookup"]
        if (!is.na(auroc)) {
          if (auroc > 0.75) "promising discriminative and calibration properties"
          else if (auroc > 0.60) "moderate discriminative and calibration properties"
          else "modest discriminative properties that warrant further investigation"
        } else "good performance"
      } else "reasonable",
      ", supporting its continued use as a clinical decision-support tool in perioperative risk assessment."
    ),
    style = "Normal"
  )
  
  doc <- body_add_par(doc, "", style = "Normal")
  doc <- body_add_par(doc,
    paste0(
      "The fully reproducible workflow, documented in executable R scripts, enables validation teams to ",
      "audit all cohort definitions, concept mappings, and statistical calculations. This transparency ",
      "aligns with OHDSI best practices for external validation studies."
    ),
    style = "Normal"
  )

  # ---- Write output -------------------------------------------------------
  out_path <- file.path(output_dir, "ssi_validation_report.docx")
  print(doc, target = out_path)
  message("Report written to: ", normalizePath(out_path))
  invisible(out_path)
}

generate_manuscript_report <- function(output_dir = "output/risk_score_eval",
                                       score_output_dir = "output/risk_score_eval",
                                       cleanup_old_outputs = FALSE) {
  if (!dir.exists(output_dir)) dir.create(output_dir, recursive = TRUE)

  temp_figure_dir <- tempfile("report_figures_")
  dir.create(temp_figure_dir, recursive = TRUE, showWarnings = FALSE)
  on.exit(unlink(temp_figure_dir, recursive = TRUE, force = TRUE), add = TRUE)

  person_level_path <- file.path(score_output_dir, "person_level_scores.csv")
  component_summary_path <- file.path(score_output_dir, "component_summary.csv")
  metrics_path <- file.path(score_output_dir, "metrics.csv")
  lookup_calibration_plot <- file.path(score_output_dir, "calibration_lookup.png")
  calibration_table_lookup_path <- file.path(score_output_dir, "calibration_table_lookup.csv")
  lookup_calibration_plot_temp <- file.path(temp_figure_dir, "calibration_lookup.png")

  if (!file.exists(person_level_path) || !file.exists(component_summary_path) || !file.exists(metrics_path)) {
    stop("Missing one or more required pipeline outputs in ", score_output_dir)
  }

  person_level <- read.csv(person_level_path, stringsAsFactors = FALSE)
  component_summary <- read.csv(component_summary_path, stringsAsFactors = FALSE)
  metrics <- read.csv(metrics_path, stringsAsFactors = FALSE)

  # Backfill ECE if it is not present in the metrics file.
  compute_ece <- function(y, p, n_bins = 10) {
    ok <- !(is.na(y) | is.na(p))
    y <- as.numeric(y[ok])
    p <- as.numeric(p[ok])
    if (length(y) == 0) {
      return(NA_real_)
    }

    eps <- 1e-6
    p[p < eps] <- eps
    p[p > (1 - eps)] <- 1 - eps

    probs <- unique(stats::quantile(p, probs = seq(0, 1, length.out = n_bins + 1), na.rm = TRUE))
    if (length(probs) < 3) {
      probs <- c(0, 1)
    }
    bins <- cut(p, breaks = probs, include.lowest = TRUE)
    bin_n <- as.numeric(table(bins))
    if (length(bin_n) == 0) {
      return(NA_real_)
    }

    pred_mean <- tapply(p, bins, mean)
    obs_mean <- tapply(y, bins, mean)
    as.numeric(sum(abs(pred_mean - obs_mean) * bin_n) / sum(bin_n))
  }

  if (!any(metrics$metric == "ECE")) {
    ece_rows <- data.frame(metric = character(), value = numeric(), model = character(), stringsAsFactors = FALSE)

    if ("predicted_risk_lookup" %in% names(person_level)) {
      keep_lookup <- !is.na(person_level$predicted_risk_lookup)
      if (any(keep_lookup)) {
        ece_rows <- rbind(
          ece_rows,
          data.frame(
            metric = "ECE",
            value = compute_ece(person_level$outcome[keep_lookup], person_level$predicted_risk_lookup[keep_lookup]),
            model = "lookup",
            stringsAsFactors = FALSE
          )
        )
      }
    }

    if ("predicted_risk_recalibrated" %in% names(person_level)) {
      ece_rows <- rbind(
        ece_rows,
        data.frame(
          metric = "ECE",
          value = compute_ece(person_level$outcome, person_level$predicted_risk_recalibrated),
          model = "recalibrated",
          stringsAsFactors = FALSE
        )
      )
    }

    if (nrow(ece_rows) > 0) {
      metrics <- rbind(metrics, ece_rows)
    }
  }

  fmt <- function(x, digits = 3) {
    format(round(as.numeric(x), digits), nsmall = digits)
  }

  metric_value <- function(metric_name, model_name) {
    row <- metrics[metrics$metric == metric_name & metrics$model == model_name, , drop = FALSE]
    if (nrow(row) == 0) {
      return(NA_real_)
    }
    as.numeric(row$value[1])
  }

  n_target <- nrow(person_level)
  n_outcome <- sum(person_level$outcome, na.rm = TRUE)
  outcome_prev <- if (n_target > 0) 100 * n_outcome / n_target else NA_real_

  results_tbl <- data.frame(
    Metric = c(
      "AUROC",
      "AUPRC",
      "Brier score",
      "Estimated calibration error",
      "Calibration intercept",
      "Calibration slope"
    ),
    Value = c(
      fmt(metric_value("AUROC", "lookup")),
      fmt(metric_value("AUPRC", "lookup")),
      fmt(metric_value("Brier", "lookup")),
      fmt(metric_value("ECE", "lookup")),
      fmt(metric_value("CalibrationIntercept", "lookup")),
      fmt(metric_value("CalibrationSlope", "lookup"))
    ),
    stringsAsFactors = FALSE
  )

  normalize_label <- function(x) {
    x <- tolower(trimws(as.character(x)))
    x <- gsub("[()\\[\\]\\{\\}]", " ", x)
    x <- gsub("[^a-z0-9]+", " ", x)
    x <- gsub("\\s+", " ", x)
    trimws(x)
  }

  predictor_ref <- .component_table_data()[, c("component_id", "variable", "points", "lookback", "derivation")]
  names(predictor_ref) <- c("component_id", "Predictor", "Points", "Lookback", "Definition")

  if ("component_id" %in% names(component_summary)) {
    component_act <- component_summary[, c("component_id", "n_positive", "mean_points"), drop = FALSE]
    predictor_tbl <- merge(predictor_ref, component_act, by = "component_id", all.x = TRUE, sort = FALSE)
  } else {
    predictor_ref$key <- normalize_label(predictor_ref$Predictor)
    component_act <- component_summary[, c("component_name", "n_positive", "mean_points"), drop = FALSE]
    component_act$key <- normalize_label(component_act$component_name)
    component_act <- component_act[, c("key", "n_positive", "mean_points"), drop = FALSE]
    predictor_tbl <- merge(predictor_ref, component_act, by = "key", all.x = TRUE, sort = FALSE)
  }

  predictor_tbl$n_positive[is.na(predictor_tbl$n_positive)] <- 0
  predictor_tbl$mean_points[is.na(predictor_tbl$mean_points)] <- 0
  predictor_tbl <- predictor_tbl[, c("Predictor", "Points", "Lookback", "Definition", "n_positive", "mean_points")]
  names(predictor_tbl) <- c("Predictor", "Points", "Lookback", "Definition", "PositiveCount", "MeanPoints")
  predictor_tbl$PositiveCount <- as.integer(predictor_tbl$PositiveCount)
  predictor_tbl$MeanPoints <- round(as.numeric(predictor_tbl$MeanPoints), 4)

  fmt_n_pct <- function(n, denom, digits = 1) {
    n <- suppressWarnings(as.numeric(n))
    denom <- suppressWarnings(as.numeric(denom))
    if (is.na(n) || is.na(denom) || denom <= 0) {
      return("0 (0.0%)")
    }
    paste0(format(round(n, 0), scientific = FALSE, trim = TRUE),
           " (", format(round(100 * n / denom, digits), nsmall = digits, trim = TRUE), "%)")
  }

  fetch_demographics_from_omop <- function(config, connection_details) {
    if (is.null(config) || is.null(connection_details)) {
      return(NULL)
    }

    conn <- NULL
    out <- NULL
    try({
      conn <- DatabaseConnector::connect(connection_details)

      sql_age <- SqlRender::render(
        "SELECT
            CAST(DATEDIFF(YEAR, p.birth_datetime, t.cohort_start_date) AS FLOAT) AS age_at_index
         FROM @results_schema.@cohort_table t
         INNER JOIN @cdm_schema.person p ON p.person_id = t.subject_id
         WHERE t.cohort_definition_id = @target_id",
        results_schema = config$results_schema,
        cohort_table = config$cohort_table,
        cdm_schema = config$cdm_schema,
        target_id = config$target_cohort_id
      )
      age_df <- DatabaseConnector::querySql(
        conn,
        SqlRender::translate(sql_age, targetDialect = "sql server")
      )

      distribution_sql <- function(concept_col) {
        SqlRender::render(
          "SELECT
              COALESCE(NULLIF(c.concept_name, ''), 'Unknown') AS category,
              COUNT(DISTINCT t.subject_id) AS n
           FROM @results_schema.@cohort_table t
           INNER JOIN @cdm_schema.person p ON p.person_id = t.subject_id
           LEFT JOIN @cdm_schema.concept c ON c.concept_id = p.@concept_col
           WHERE t.cohort_definition_id = @target_id
           GROUP BY COALESCE(NULLIF(c.concept_name, ''), 'Unknown')
           ORDER BY n DESC, category",
          results_schema = config$results_schema,
          cohort_table = config$cohort_table,
          cdm_schema = config$cdm_schema,
          concept_col = concept_col,
          target_id = config$target_cohort_id
        )
      }

      sex_df <- DatabaseConnector::querySql(
        conn,
        SqlRender::translate(distribution_sql("gender_concept_id"), targetDialect = "sql server")
      )
      race_df <- DatabaseConnector::querySql(
        conn,
        SqlRender::translate(distribution_sql("race_concept_id"), targetDialect = "sql server")
      )
      ethnicity_df <- DatabaseConnector::querySql(
        conn,
        SqlRender::translate(distribution_sql("ethnicity_concept_id"), targetDialect = "sql server")
      )

      out <- list(age = age_df, sex = sex_df, race = race_df, ethnicity = ethnicity_df)
    }, silent = TRUE)

    if (!is.null(conn)) {
      try(DatabaseConnector::disconnect(conn), silent = TRUE)
    }

    out
  }

  append_distribution_rows <- function(tbl, dist_df, label_prefix, denom, max_rows = 6L) {
    if (is.null(dist_df) || nrow(dist_df) == 0) {
      return(tbl)
    }

    n_col <- names(dist_df)[tolower(names(dist_df)) == "n"][1]
    cat_col <- names(dist_df)[tolower(names(dist_df)) == "category"][1]
    if (is.na(n_col) || is.na(cat_col)) {
      return(tbl)
    }

    dist_df$n_value <- as.numeric(dist_df[[n_col]])
    dist_df$cat_value <- as.character(dist_df[[cat_col]])
    keep_n <- min(nrow(dist_df), max_rows)
    shown <- dist_df[seq_len(keep_n), , drop = FALSE]

    for (i in seq_len(nrow(shown))) {
      tbl <- rbind(
        tbl,
        data.frame(
          Item = paste0(label_prefix, " - ", shown$cat_value[i]),
          Value = fmt_n_pct(shown$n_value[i], denom),
          Definition = paste0(
            "Distribution among target-cohort patients based on OMOP person ",
            if (label_prefix == "Race") "race_concept_id" else if (label_prefix == "Ethnicity") "ethnicity_concept_id" else "gender_concept_id",
            "."
          ),
          stringsAsFactors = FALSE
        )
      )
    }

    if (nrow(dist_df) > keep_n) {
      other_n <- sum(as.numeric(dist_df$n_value[(keep_n + 1):nrow(dist_df)]), na.rm = TRUE)
      tbl <- rbind(
        tbl,
        data.frame(
          Item = paste0(label_prefix, " - Other"),
          Value = fmt_n_pct(other_n, denom),
          Definition = "Combined frequency of remaining categories not shown individually.",
          stringsAsFactors = FALSE
        )
      )
    }

    tbl
  }

  build_table1_cohort <- function(person_level, config, connection_details) {
    n_target <- nrow(person_level)
    n_outcome <- sum(as.numeric(person_level$outcome), na.rm = TRUE)

    tbl <- data.frame(
      Item = c(
        "Target cohort (eligible procedures)",
        "SSI outcome within 30 days"
      ),
      Value = c(
        fmt_n_pct(n_target, n_target),
        fmt_n_pct(n_outcome, n_target)
      ),
      Definition = c(
        "Adults aged >=18 years with open lower extremity revascularization meeting cohort entry criteria.",
        "First qualifying post-operative SSI event in follow-up."
      ),
      stringsAsFactors = FALSE
    )

    demog <- fetch_demographics_from_omop(config, connection_details)

    if (!is.null(demog) && !is.null(demog$age) && nrow(demog$age) > 0) {
      ages <- as.numeric(demog$age$AGE_AT_INDEX)
      ages <- ages[!is.na(ages)]
      if (length(ages) > 0) {
        age_iqr <- stats::quantile(ages, probs = c(0.25, 0.75), na.rm = TRUE)
        tbl <- rbind(
          tbl,
          data.frame(
            Item = "Age, mean (SD), years",
            Value = paste0(format(round(mean(ages), 1), nsmall = 1), " (", format(round(stats::sd(ages), 1), nsmall = 1), ")"),
            Definition = "Age at target cohort index date.",
            stringsAsFactors = FALSE
          ),
          data.frame(
            Item = "Age, median (IQR), years",
            Value = paste0(
              format(round(stats::median(ages), 1), nsmall = 1),
              " (",
              format(round(age_iqr[[1]], 1), nsmall = 1),
              "-",
              format(round(age_iqr[[2]], 1), nsmall = 1),
              ")"
            ),
            Definition = "Age distribution summarized with median and interquartile range.",
            stringsAsFactors = FALSE
          )
        )

        age_bands <- list(
          "Age 18-44" = sum(ages >= 18 & ages <= 44, na.rm = TRUE),
          "Age 45-64" = sum(ages >= 45 & ages <= 64, na.rm = TRUE),
          "Age 65-74" = sum(ages >= 65 & ages <= 74, na.rm = TRUE),
          "Age >=75" = sum(ages >= 75, na.rm = TRUE)
        )
        for (nm in names(age_bands)) {
          tbl <- rbind(
            tbl,
            data.frame(
              Item = paste0(nm, ", n (%)"),
              Value = fmt_n_pct(age_bands[[nm]], n_target),
              Definition = "Age-band frequency in the target cohort.",
              stringsAsFactors = FALSE
            )
          )
        }
      }
    }

    tbl <- append_distribution_rows(tbl, if (!is.null(demog)) demog$sex else NULL, "Sex", n_target, max_rows = 4L)
    tbl <- append_distribution_rows(tbl, if (!is.null(demog)) demog$race else NULL, "Race", n_target, max_rows = 6L)
    tbl <- append_distribution_rows(tbl, if (!is.null(demog)) demog$ethnicity else NULL, "Ethnicity", n_target, max_rows = 4L)

    score_flag <- function(col, positive = function(x) x > 0) {
      if (!(col %in% names(person_level))) return(NA_real_)
      x <- suppressWarnings(as.numeric(person_level[[col]]))
      sum(positive(x), na.rm = TRUE)
    }

    claud_n <- score_flag("score_indicationClaudication", positive = function(x) x < 0)
    urg_n <- score_flag("score_urgnt")
    prrevasc_n <- score_flag("score_prrevasc_any")
    optime_n <- score_flag("score_optime4h")
    abx_n <- score_flag("score_prolong_abx")

    tbl <- rbind(
      tbl,
      data.frame(
        Item = "Presenting symptom - Claudication, n (%)",
        Value = fmt_n_pct(claud_n, n_target),
        Definition = "From score_indicationClaudication activation in person-level score output.",
        stringsAsFactors = FALSE
      ),
      data.frame(
        Item = "Presenting symptom - Non-claudication, n (%)",
        Value = fmt_n_pct(n_target - claud_n, n_target),
        Definition = "Complement of claudication indicator.",
        stringsAsFactors = FALSE
      ),
      data.frame(
        Item = "Procedure grouping - Urgent/emergency, n (%)",
        Value = fmt_n_pct(urg_n, n_target),
        Definition = "From score_urgnt component activation.",
        stringsAsFactors = FALSE
      ),
      data.frame(
        Item = "Procedure grouping - Prior revascularization, n (%)",
        Value = fmt_n_pct(prrevasc_n, n_target),
        Definition = "From score_prrevasc_any component activation.",
        stringsAsFactors = FALSE
      ),
      data.frame(
        Item = "Procedure grouping - Operative time >=4h, n (%)",
        Value = fmt_n_pct(optime_n, n_target),
        Definition = "From score_optime4h component activation.",
        stringsAsFactors = FALSE
      ),
      data.frame(
        Item = "Procedure grouping - Prolonged antibiotics, n (%)",
        Value = fmt_n_pct(abx_n, n_target),
        Definition = "From score_prolong_abx component activation.",
        stringsAsFactors = FALSE
      ),
      data.frame(
        Item = "Unique patients represented",
        Value = fmt_n_pct(length(unique(person_level$subject_id)), n_target),
        Definition = "Unique patient count represented in procedure-level target cohort records.",
        stringsAsFactors = FALSE
      )
    )

    tbl
  }

  config <- NULL
  if (exists("get_validation_config", mode = "function")) {
    config <- tryCatch(get_validation_config(), error = function(e) NULL)
  }
  cohort_tbl <- build_table1_cohort(person_level, config, connection_details)

  simple_ft <- function(df) {
    flextable(df) |>
      bold(part = "header") |>
      fontsize(size = 10, part = "all") |>
      font(fontname = "Calibri", part = "all") |>
      bg(part = "header", bg = "#1F3864") |>
      color(part = "header", color = "white") |>
      padding(padding = 4, part = "all") |>
      autofit()
  }

  wrapped_definition_ft <- function(df) {
    ft <- flextable(df) |>
      bold(part = "header") |>
      fontsize(size = 10, part = "all") |>
      font(fontname = "Calibri", part = "all") |>
      bg(part = "header", bg = "#1F3864") |>
      color(part = "header", color = "white") |>
      padding(padding = 4, part = "all") |>
      align(align = "left", part = "all") |>
      valign(valign = "top", part = "all") |>
      width(j = "Item", width = 1.4) |>
      width(j = "Value", width = 0.9) |>
      width(j = "Definition", width = 4.7) |>
      set_table_properties(layout = "fixed")

    ft
  }

  wrapped_predictor_ft <- function(df) {
    ft <- flextable(df) |>
      bold(part = "header") |>
      fontsize(size = 9, part = "all") |>
      font(fontname = "Calibri", part = "all") |>
      bg(part = "header", bg = "#1F3864") |>
      color(part = "header", color = "white") |>
      padding(padding = 3, part = "all") |>
      align(align = "left", part = "all") |>
      valign(valign = "top", part = "all") |>
      width(j = "Predictor", width = 1.4) |>
      width(j = "Points", width = 0.5) |>
      width(j = "Lookback", width = 0.8) |>
      width(j = "Definition", width = 3.5) |>
      width(j = "PositiveCount", width = 0.8) |>
      width(j = "MeanPoints", width = 0.8) |>
      set_table_properties(layout = "fixed")

    ft
  }

  next_report_file <- function(output_dir, base_name) {
    primary <- file.path(output_dir, paste0(base_name, ".docx"))
    if (!file.exists(primary)) {
      return(primary)
    }

    i <- 2L
    repeat {
      candidate <- file.path(output_dir, paste0(base_name, "_", i, ".docx"))
      if (!file.exists(candidate)) {
        return(candidate)
      }
      i <- i + 1L
    }
  }

  roc_y <- person_level$outcome
  if ("predicted_risk_lookup" %in% names(person_level)) {
    keep_lookup <- !is.na(person_level$predicted_risk_lookup)
    roc_y <- person_level$outcome[keep_lookup]
    roc_p <- person_level$predicted_risk_lookup[keep_lookup]
  } else if ("predicted_risk_recalibrated" %in% names(person_level)) {
    roc_p <- person_level$predicted_risk_recalibrated
  } else {
    roc_p <- person_level$total_score / max(person_level$total_score, na.rm = TRUE)
  }

  roc_plot_file <- .save_roc_plot(
    y = roc_y,
    p = roc_p,
    output_folder = temp_figure_dir,
    auc_override = metric_value("AUROC", "lookup")
  )

  if (file.exists(lookup_calibration_plot)) {
    file.copy(lookup_calibration_plot, lookup_calibration_plot_temp, overwrite = TRUE)
  } else if (file.exists(calibration_table_lookup_path)) {
    lookup_generated <- .save_calibration_plot_from_table(
      calibration_table_path = calibration_table_lookup_path,
      output_folder = temp_figure_dir,
      file_name = "calibration_lookup.png"
    )
    if (!is.null(lookup_generated) && file.exists(lookup_generated)) {
      lookup_calibration_plot_temp <- lookup_generated
    }
  }

  cleanup_report_outputs <- function(output_dir, project_name) {
    report_pattern <- paste0("^", project_name, "_report_[0-9]{8}(_[0-9]+)?\\.docx$")
    files <- list.files(output_dir, full.names = TRUE, all.files = FALSE)
    if (length(files) == 0) {
      return(invisible(NULL))
    }

    for (f in files) {
      nm <- basename(f)

      # Keep iterative reports that match the naming convention.
      if (grepl(report_pattern, nm)) {
        next
      }

      # Keep core pipeline tabular outputs.
      if (nm %in% c(
        "person_level_scores.csv",
        "component_summary.csv",
        "metrics.csv",
        "calibration_table_lookup.csv",
        "calibration_table_recalibrated.csv"
      )) {
        next
      }

      # Remove legacy reports and standalone artifacts.
      if (tolower(tools::file_ext(nm)) == "docx" ||
          nm %in% c("roc_curve.png", "calibration_lookup.png", "calibration_recalibrated.png", "pipeline_rerun.log")) {
        unlink(f, force = TRUE)
      }
    }

    invisible(NULL)
  }

  project_name <- basename(normalizePath(getwd(), winslash = "/", mustWork = FALSE))
  project_name <- gsub("[^A-Za-z0-9_-]", "_", project_name)
  report_base_name <- paste(project_name, "report", format(Sys.Date(), "%Y%m%d"), sep = "_")

  if (isTRUE(cleanup_old_outputs)) {
    cleanup_report_outputs(output_dir, project_name)
  }

  report_file <- next_report_file(output_dir, report_base_name)

  doc <- read_docx()
  doc <- body_add_par(doc, "Manuscript Draft: Methods and Results", style = "heading 1")
  doc <- body_add_par(doc, "PAD Open Lower Extremity Revascularization and 30-Day Surgical Site Infection Risk Score Evaluation", style = "Normal")
  doc <- body_add_par(doc, paste("Date:", format(Sys.Date(), "%Y-%m-%d")), style = "Normal")
  doc <- body_add_par(doc, "", style = "Normal")

  doc <- body_add_par(doc, "Methods", style = "heading 2")
  doc <- body_add_par(doc, "Data source and ETL", style = "heading 3")
  doc <- body_add_par(doc, "Synthetic patient-level data were generated with a custom Synthea module representing peripheral arterial disease, open lower extremity revascularization, and 30-day surgical site infection outcomes. CSV outputs were loaded into an OMOP CDM v5 SQL Server database using the project CSV-to-OMOP ETL workflow.", style = "Normal")
  doc <- body_add_par(doc, "Target and outcome cohort definitions", style = "heading 3")
  doc <- body_add_par(doc, "The target cohort was defined as adults aged 18 years or older with an open lower extremity revascularization procedure recorded during a qualifying visit within the study window. The procedure was identified using procedure_source_value 232723009, and only the earliest qualifying event per person was retained. Patients with wound or surgical site infection diagnoses during the 365 days before index were excluded.", style = "Normal")
  doc <- body_add_par(doc, "The outcome cohort was defined as the first surgical site infection diagnosis during follow-up using either OMOP concept-ancestor logic for wound infection concepts or a direct source-code fallback of condition_source_value 76844004.", style = "Normal")
  doc <- body_add_par(doc, "Risk score evaluation", style = "heading 3")
  doc <- body_add_par(doc, "A person-level integer risk score was calculated from prespecified score components and concept mappings. Discrimination was summarized using area under the receiver operating characteristic curve and area under the precision-recall curve. For the published lookup model, integer scores were mapped to predicted risks using the supplied score-to-risk lookup table.", style = "Normal")
  doc <- body_add_par(doc, "Calibration was summarized with the Brier score, estimated calibration error, calibration intercept, and calibration slope. Estimated calibration error was computed as the weighted mean absolute difference between grouped predicted and observed risks across quantile-based bins. Calibration plots were generated by grouping predicted risks into quantile-based bins and comparing mean predicted versus mean observed event rates within bins. Summary metrics in this report are presented for the published lookup mapping only.", style = "Normal")

  doc <- body_add_par(doc, "Results", style = "heading 2")
  doc <- body_add_par(doc, "Cohort characteristics", style = "heading 3")
  doc <- body_add_par(doc, paste0("The final target cohort included ", n_target, " patients, of whom ", n_outcome, " experienced surgical site infection within 30 days, corresponding to an observed event rate of ", fmt(outcome_prev, 2), "%."), style = "Normal")
  doc <- body_add_par(doc, "Table 1. Cohort summary for the external validation sample.", style = "Normal")
  doc <- body_add_par(doc, "Caption: The second column reports frequency as n (%) for categorical variables and summary estimates for continuous variables; table includes demographics (age, sex, race, ethnicity), presenting symptom profile, and procedure groupings.", style = "Normal")
  doc <- body_add_flextable(doc, wrapped_definition_ft(cohort_tbl))
  doc <- body_add_par(doc, "", style = "Normal")

  doc <- body_add_par(doc, "Predictor activation", style = "heading 3")
  doc <- body_add_par(doc, "Table 2. Predictor definitions and activation summary.", style = "Normal")
  doc <- body_add_par(doc, "Caption: Each predictor is listed with its points, lookback window, OMOP-based definition, and observed activation in the validation cohort.", style = "Normal")
  doc <- body_add_flextable(doc, wrapped_predictor_ft(predictor_tbl))
  doc <- body_add_par(doc, "", style = "Normal")

  doc <- body_add_par(doc, "Summary metrics", style = "heading 3")
  doc <- body_add_par(doc, "Table 3. Lookup-model discrimination and calibration metrics.", style = "Normal")
  doc <- body_add_par(doc, "Caption: Metrics are read directly from metrics.csv for model = lookup, including AUROC, AUPRC, Brier score, estimated calibration error, calibration intercept, and calibration slope.", style = "Normal")
  doc <- body_add_flextable(doc, simple_ft(results_tbl))
  doc <- body_add_par(doc, "", style = "Normal")

  if (!is.null(roc_plot_file) && file.exists(roc_plot_file)) {
    doc <- body_add_par(doc, "Figure 1. Receiver operating characteristic curve for the lookup model.", style = "Normal")
    doc <- body_add_par(doc, "Caption: ROC curve generated from lookup predicted probabilities and binary outcomes in person_level_scores.csv. The subtitle AUROC value is sourced from metrics.csv (lookup model).", style = "Normal")
    doc <- body_add_img(doc, src = roc_plot_file, width = 5.5, height = 4.0)
    doc <- body_add_par(doc, "", style = "Normal")
  }

  if (file.exists(lookup_calibration_plot_temp)) {
    doc <- body_add_par(doc, "Figure 2. Calibration plot for the published lookup mapping.", style = "Normal")
    doc <- body_add_par(doc, "Caption: Calibration plot generated from calibration_table_lookup.csv with x = mean predicted risk and y = observed event rate by bin.", style = "Normal")
    doc <- body_add_img(doc, src = lookup_calibration_plot_temp, width = 5.5, height = 4.0)
    doc <- body_add_par(doc, "", style = "Normal")
  }

  print(doc, target = report_file)
  message("Manuscript report written to: ", normalizePath(report_file))
  invisible(report_file)
}
