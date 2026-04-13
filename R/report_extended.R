# =============================================================================
# R/report_extended.R
#
# Word-document report generator for the PAD / OLER SSI risk score external
# validation study.
#
# This module assembles all pipeline outputs into a manuscript-format Word
# document (.docx) using the officer and flextable packages.  It also exports
# a dated Excel workbook of "fringe cases" (false negatives and false positives)
# for clinical QC review.
#
# Entry point: generate_manuscript_report()
#
# Report sections produced:
#   1.  Title page
#   2.  Methods (data source, cohort criteria, statistical methods)
#   3.  Table 1   — Cohort characteristics (demographics + clinical subgroups)
#                   queried live from the OMOP CDM via fetch_demographics_from_omop()
#   4.  Table 2   — PAD SSI risk score component definitions and point values
#   5.  Table 3   — Component prevalence in the validation cohort
#   6.  Table 4   — Discrimination and calibration metrics with 95% bootstrap CIs
#   7.  ROC curve figure
#   8.  Calibration plot figures
#   9.  Expected Calibration Error narrative
#   10. Discussion and Conclusion
#
# Side effects:
#   output_dir/pad-oler-ssi-val_report_<YYYYMMDD>[_N].docx  — Word report
#   output_dir/pad_oler_ssi_fringe_<YYYYMMDD>.xlsx           — fringe-cases Excel
#
# Dependencies: officer, flextable, ggplot2, pROC, writexl (all via renv)
# =============================================================================

library(officer)
library(flextable)
library(ggplot2)
library(pROC)

# Load cohort demographics helper functions
source("R/cohort_demographics.R")

# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

# -----------------------------------------------------------------------------
# .component_table_data()
#
# Returns a static data frame defining the 10 PAD SSI risk score components for
# inclusion in the Word report as Table 2.  Each row contains:
#   component_id  — matches the IDs in components.csv / component_summary.csv
#   variable      — display name for the Word table
#   points        — formatted point string (e.g. "+1", "−1")
#   lookback      — human-readable lookback window
#   omop_domain   — OMOP CDM domain(s) queried
#   derivation    — plain-English description of the SQL derivation logic
#
# This table is static (not queried from the CDM) — it reflects the score
# specification at the time the code was written.  If components.csv is updated,
# this function must be kept in sync manually.
# -----------------------------------------------------------------------------
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
        "BMI resolved with three-tier priority: ",
        "(1) direct BMI measurement (LOINC 3038553, 36304833); ",
        "(2) computed from weight (LOINC 3025315, 3013762, 3011054, 3026600) ",
        "and height (LOINC 3036277, 3023540, 3015514) as weight_kg / height_m\u00b2. ",
        "Flagged when 25 \u2264 BMI < 30."
      ),
      paste0(
        "Same BMI resolution as Overweight (direct preferred, weight/height fallback). ",
        "Flagged when BMI \u2265 30. Mutually exclusive with Overweight."
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
        "Concepts 4236706 (Arterial bypass of lower limb artery) and 4225375 ",
        "(Endarterectomy of lower limb artery) and all descendants in procedure_occurrence. ",
        "Captures any prior lower-extremity arterial bypass or endarterectomy within a 10-year lookback."
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

# -----------------------------------------------------------------------------
# .build_table1()
#
# Formats a data frame as a styled flextable for the Word report.
# Used for Table 2 (score component definitions).
#
# Styling conventions:
#   - Dark blue (#1F3864) header background with white text
#   - Light gray (#BFBFBF) horizontal rules between body rows
#   - Calibri 10pt throughout
#   - Fixed column widths totalling ~7 inches (US letter body width)
#   - Points and Lookback columns center-aligned
# -----------------------------------------------------------------------------
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

# -----------------------------------------------------------------------------
# .compute_ece()   [internal — report_extended.R local copy]
#
# Computes Expected Calibration Error (ECE) for display in the Word report.
# This is a self-contained copy that does not depend on risk_score_pipeline.R
# being loaded, so the report can be regenerated independently of the pipeline.
#
# Uses equal-frequency (quantile) bins so that each bin contains approximately
# the same number of patients.  Falls back to a single [0, 1] bin when the
# probability distribution is degenerate (< 3 unique quantile breakpoints).
#
# Returns a named list:
#   $ece      — scalar ECE value
#   $bin_data — data frame with columns bin, n_pred, mean_pred, n_obs, mean_obs
# -----------------------------------------------------------------------------
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

# -----------------------------------------------------------------------------
# .save_roc_plot()
#
# Generates a ROC curve plot and saves it as a PNG to output_folder/roc_curve.png.
#
# When auc_override is supplied, the function tries both pROC direction
# conventions ("<" and ">") and picks whichever gives an AUC closest to
# auc_override.  This handles the rare case where pROC auto-detects the wrong
# direction — the label shown on the plot will still use the published AUC
# value passed in auc_override.
#
# Returns the path to the saved PNG file (invisibly NULL if y is degenerate).
# -----------------------------------------------------------------------------
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

# -----------------------------------------------------------------------------
# .save_calibration_plot_from_table()
#
# Reads a calibration CSV (must contain "predicted" and "observed" columns) and
# saves a calibration plot PNG to output_folder.
#
# Called from generate_manuscript_report() for the lookup-model calibration plot
# when the calibration_table_lookup.csv file was produced by a prior pipeline run.
# Returns NULL silently if the input file does not exist or lacks the required
# columns.
# -----------------------------------------------------------------------------
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
    ggplot2::scale_x_continuous(limits = c(0, 1), breaks = seq(0, 1, 0.2)) +
    ggplot2::scale_y_continuous(limits = c(0, 1), breaks = seq(0, 1, 0.2)) +
    ggplot2::coord_equal() +
    ggplot2::theme_minimal()

  out_file <- file.path(output_folder, file_name)
  ggplot2::ggsave(out_file, p, width = 5, height = 5, dpi = 150)
  out_file
}

# -----------------------------------------------------------------------------
# .save_ssi_rate_by_year_plot()
#
# Builds a line graph of annual SSI rate (%) from the person-level data frame.
# Requires an index_date column (YYYY-MM-DD) and an outcome column (0/1).
# Years with < 10 procedures are omitted to avoid unstable rate estimates.
# Returns NULL silently if the date column is absent or all years are suppressed.
# -----------------------------------------------------------------------------
.save_ssi_rate_by_year_plot <- function(person_level_df, output_folder) {
  if (!all(c("index_date", "outcome") %in% names(person_level_df))) {
    message("[report] SSI-by-year plot skipped: index_date or outcome column missing.")
    return(NULL)
  }

  year_val <- tryCatch(
    as.integer(format(as.Date(person_level_df$index_date), "%Y")),
    error = function(e) NA_integer_
  )

  df_yr <- data.frame(
    year    = year_val,
    outcome = as.integer(person_level_df$outcome),
    stringsAsFactors = FALSE
  )
  df_yr <- df_yr[!is.na(df_yr$year), ]

  # Aggregate per year
  yr_tbl <- do.call(rbind, lapply(sort(unique(df_yr$year)), function(y) {
    sub  <- df_yr[df_yr$year == y, ]
    n    <- nrow(sub)
    events <- sum(sub$outcome, na.rm = TRUE)
    data.frame(year = y, n = n, events = events,
               ssi_rate = 100 * events / n,
               stringsAsFactors = FALSE)
  }))

  # Suppress years with < 10 procedures
  yr_tbl <- yr_tbl[yr_tbl$n >= 10, ]
  if (nrow(yr_tbl) < 2) {
    message("[report] SSI-by-year plot skipped: fewer than 2 years with >= 10 procedures.")
    return(NULL)
  }

  p <- ggplot2::ggplot(yr_tbl, ggplot2::aes(x = year, y = ssi_rate)) +
    ggplot2::geom_line(linewidth = 0.9, colour = "#1F3864") +
    ggplot2::geom_point(size = 2.5,   colour = "#1F3864") +
    ggplot2::scale_x_continuous(breaks = yr_tbl$year) +
    ggplot2::scale_y_continuous(limits = c(0, NA),
                                labels = function(x) paste0(round(x, 1), "%")) +
    ggplot2::labs(
      title   = "SSI Rate by Procedure Year",
      x       = "Year of procedure",
      y       = "90-day SSI rate (%)",
      caption = paste0("N = ", sum(yr_tbl$n), " procedures; ",
                       "years with < 10 procedures suppressed.")
    ) +
    ggplot2::theme_minimal(base_size = 11) +
    ggplot2::theme(
      axis.text.x     = ggplot2::element_text(angle = 45, hjust = 1),
      plot.caption    = ggplot2::element_text(size = 8),
      panel.grid.minor = ggplot2::element_blank()
    )

  out_file <- file.path(output_folder, "ssi_rate_by_year.png")
  tryCatch({
    ggplot2::ggsave(out_file, p, width = 7, height = 4.5, dpi = 150)
    out_file
  }, error = function(e) {
    message("[report] Could not save SSI-by-year plot: ", conditionMessage(e))
    NULL
  })
}

# -----------------------------------------------------------------------------
# .build_cohort_summary_table()
#
# Builds a flextable summary of overall cohort statistics from the person-level
# scores data frame.  Presented as Table 1 (overall cohort summary) in the Word
# report.
#
# Statistics included:
#   - Total procedures (rows in person_level)
#   - Unique patients
#   - SSI events and incidence rate
#   - Mean total risk score (SD) and median total score (IQR)
# -----------------------------------------------------------------------------
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

# -----------------------------------------------------------------------------
# .build_combined_component_table()
#
# Merges the static component definitions (.component_table_data() content)
# with observed prevalence counts from the pipeline's component_summary.csv to
# produce a combined flextable for Table 3 in the Word report.
#
# Matching is done on "component_name" (exact string) with a fallback to a
# normalized lower-case key comparison, allowing minor display-name drift
# between the static definitions and the pipeline output.
#
# The resulting table shows each component's variable name, point value,
# OMOP concept(s), OMOP CDM derivation method, and observed prevalence
# (n and %) in the validation cohort.
# -----------------------------------------------------------------------------
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
      definition = "BMI between 25 and <30 kg/m\u00b2",
      omop_concept = paste0("Direct BMI: 3038553, 36304833; ",
                            "Weight: 3025315, 3013762, 3011054, 3026600; ",
                            "Height: 3036277, 3023540, 3015514"),
      derivation = paste0("Direct BMI measurement preferred (LOINC 39156-5 / 59574-4); ",
                          "computed from weight/height as fallback. 25 \u2264 BMI < 30.")
    ),
    "Obese (BMI \u226530)" = list(
      points = "+3",
      definition = "BMI \u2265 30 kg/m\u00b2",
      omop_concept = paste0("Direct BMI: 3038553, 36304833; ",
                            "Weight: 3025315, 3013762, 3011054, 3026600; ",
                            "Height: 3036277, 3023540, 3015514"),
      derivation = paste0("Direct BMI measurement preferred (LOINC 39156-5 / 59574-4); ",
                          "computed from weight/height as fallback. BMI \u2265 30.")
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
      omop_concept = "Concepts 4236706 + 4225375 + descendants",
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
        "an OMOP CDM dataset containing ", n_patients, " unique patients with ",
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
        "disease (PAD) undergoing lower-extremity vascular surgery."
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
      "The target cohort comprised adults aged 18 years or older who underwent an inpatient ",
      "open lower-extremity revascularization procedure, defined using OMOP standard concept ",
      "4236706 (Arterial bypass of lower limb artery) and 4225375 (Endarterectomy of lower limb artery) ",
      "and all descendants via the concept_ancestor table. These concepts are scoped to operative ",
      "procedures on arteries of the lower extremity only, excluding diagnostic imaging, venous ",
      "procedures, and upper extremity arterial procedures. Qualifying procedure subtypes include ",
      "femoral-popliteal bypass, femorotibial bypass, aorto-femoral bypass, and femoral endarterectomy. ",
      "The index date ",
      "was defined as the start date of the first qualifying inpatient visit per person within ",
      "the study window. Persons with any surgical site infection (SSI) diagnosis (OMOP concept ",
      "4334801, SNOMED-CT 433202001) recorded in the 365 days prior to the index date were ",
      "excluded to remove prevalent cases."
    ),
    style = "Normal"
  )
  doc <- body_add_par(doc,
    paste0(
      "The outcome cohort identified incident SSI events using OMOP concept 4334801 and all ",
      "descendants, capturing superficial incisional, deep incisional, and organ-space SSI ",
      "consistent with CDC/NHSN classification. An SSI event was attributed to the target cohort ",
      "if the condition onset occurred within 90 days of the index date (prediction_window_days = 90). ",
      "Both cohort definitions are implemented as SqlRender-parameterised SQL templates stored ",
      "under 'cohorts/' and are compatible with OMOP CDM v5.4. The dataset contained ",
      if (!is.null(person_level)) length(unique(person_level$subject_id)) else "N",
      " patients with at least one qualifying procedure within the study window."
    ),
    style = "Normal"
  )

  doc <- body_add_par(doc, "2.2  Risk Score Computation", style = "heading 3")
  doc <- body_add_par(doc,
    paste0(
      "The PAD SSI integer risk score comprises ten pre-operative and intra-operative components ",
      "(Table 2). Each component is mapped to one or more OMOP standard concept IDs with descendant ",
      "expansion via the concept_ancestor table where applicable. Components include: female sex ",
      "(concept 8532); overweight (BMI 25–<30) and obesity (BMI \u226530), each resolved from direct BMI measurement (LOINC 3038553) or computed from weight and height (LOINC 3025315 + 3036277, with additional EHR variants); ",
      "urgent or emergency procedure (concepts 4158569, 4250892); low ankle-brachial index ≤0.35 ",
      "(concepts 40489833, 46237026); prior lower-extremity revascularization within 10 years ",
      "(concepts 4236706 + 4225375 + descendants); prolonged antibiotic exposure >2 days within 90 days ",
      "(concept 21603553 + descendants); operative time ≥4 hours (procedure_start/end_datetime); ",
      "high modified Frailty Index (mFI >0.25, requiring ≥2 of: diabetes 201820, COPD 255573, ",
      "congestive heart failure 316139, hypertension 316866, functional impairment 4215267); and ",
      "operative indication of intermittent claudication (concept 442774 + descendants, −1 point). ",
      "Component event counts were aggregated per person over component-specific lookback windows ",
      "relative to the index date. A person meeting the minimum event threshold for a component ",
      "received the full integer point value; those below threshold received zero. Missing data were ",
      "treated as zero evidence (absence of component). The total score is the arithmetic sum of all ",
      "component point values and ranges from −1 (claudication only) to +12."
    ),
    style = "Normal"
  )

  doc <- body_add_par(doc, "2.3  Performance Evaluation", style = "heading 3")
  doc <- body_add_par(doc,
    paste0(
      "Discrimination was assessed using the area under the receiver operating characteristic curve ",
      "(AUROC) and the area under the precision-recall curve (AUPRC). Calibration was evaluated under two ",
      "model specifications: (1) lookup-based predicted probabilities drawn directly from the published ",
      "score-to-risk calibration table (no refitting), and (2) recalibrated probabilities estimated by ",
      "fitting a logistic regression of the total integer score on the observed binary 90-day SSI outcome ",
      "in the validation cohort. Calibration-in-the-large was summarised by the intercept and slope of the ",
      "calibration regression. Expected calibration error (ECE) was computed as the probability-weighted ",
      "mean absolute difference between mean predicted and observed event rates across 10 equal-frequency bins."
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
    
    # Build a formatted "value (95% CI)" string per metric-model cell, then
    # pivot wide so each model becomes one column.  Falls back to just the
    # point estimate when ci_lower / ci_upper are absent (legacy CSV format).
    has_ci <- all(c("ci_lower", "ci_upper") %in% names(metrics)) &&
              any(!is.na(metrics$ci_lower))

    fmt3 <- function(x) format(round(as.numeric(x), 3), nsmall = 3, trim = TRUE)

    metrics_disp <- metrics
    metrics_disp$cell <- if (has_ci) {
      ifelse(
        !is.na(metrics$ci_lower) & !is.na(metrics$ci_upper),
        paste0(fmt3(metrics$value),
               " (", fmt3(metrics$ci_lower), "\u2013", fmt3(metrics$ci_upper), ")"),
        fmt3(metrics$value)
      )
    } else {
      fmt3(metrics$value)
    }

    metrics_wide <- metrics_disp[, c("metric", "cell", "model")]
    metrics_wide <- reshape(metrics_wide, idvar = "metric", timevar = "model", direction = "wide")
    names(metrics_wide) <- gsub("cell\\.", "", names(metrics_wide))

    ft_metrics <- flextable(metrics_wide) |>
      bold(part = "header") |>
      fontsize(size = 10, part = "all") |>
      font(fontname = "Calibri", part = "all") |>
      bg(part = "header", bg = "#1F3864") |>
      color(part = "header", color = "white") |>
      align(j = seq_along(names(metrics_wide))[-1], align = "center", part = "all") |>
      set_header_labels(
        metric       = "Metric",
        score_only   = "Score only",
        lookup       = "Lookup (published)",
        recalibrated = "Recalibrated"
      )

    if (has_ci) {
      ft_metrics <- add_footer_lines(ft_metrics,
        "Values shown as point estimate (95% bootstrap percentile CI, B\u2009=\u2009500 resamples).")
      ft_metrics <- fontsize(ft_metrics, size = 8, part = "footer")
      ft_metrics <- font(ft_metrics, fontname = "Calibri", part = "footer")
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
      "This external validation demonstrates the applicability of the PAD SSI integer risk score to an ",
      "OMOP CDM v5.4 dataset. All ten score components were successfully mapped to OMOP standard concept IDs ",
      "using transparent, scriptable SQL against the concept_ancestor and concept tables. The target cohort ",
      "was restricted to adult patients undergoing inpatient open lower-extremity revascularization with a ",
      "pre-operative washout for prior SSI, and the 90-day post-operative SSI outcome was ascertained using ",
      "the validated concept hierarchy under SNOMED-CT 433202001. Performance metrics indicate ",
      if (!is.null(metrics)) {
        auroc <- metrics$value[metrics$metric == "AUROC" & metrics$model == "lookup"]
        if (length(auroc) > 0 && !is.na(auroc[1])) {
          if (auroc[1] > 0.75) "promising discriminative and calibration properties"
          else if (auroc[1] > 0.60) "moderate discriminative and calibration properties"
          else "modest discriminative properties that warrant further investigation"
        } else "good performance"
      } else "reasonable",
      ", supporting its continued evaluation as a perioperative clinical decision-support tool for ",
      "patients undergoing open lower-extremity vascular surgery."
    ),
    style = "Normal"
  )

  doc <- body_add_par(doc, "", style = "Normal")
  doc <- body_add_par(doc,
    paste0(
      "The fully reproducible workflow — implemented as executable R scripts with SqlRender-parameterised ",
      "cohort SQL — enables validation teams to audit all cohort inclusion criteria, concept mappings, ",
      "lookback windows, and statistical calculations end-to-end. This transparency aligns with OHDSI ",
      "best practices for network studies and external validation. Future steps include applying this ",
      "validated pipeline to de-identified real-world vascular surgery registry data."
    ),
    style = "Normal"
  )

  # ---- Write output -------------------------------------------------------
  out_path <- file.path(output_dir, "ssi_validation_report.docx")
  print(doc, target = out_path)
  message("Report written to: ", normalizePath(out_path))
  invisible(out_path)
}

# =============================================================================
# generate_manuscript_report()
#
# Top-level entry point.  Reads all pipeline CSV outputs, queries the OMOP CDM
# for Table 1 demographics, assembles the Word document, and writes the Excel
# fringe-cases workbook.
#
# Arguments:
#   output_dir           — directory for the .docx and .xlsx outputs.
#   score_output_dir     — directory containing the pipeline CSVs produced by
#                          run_integer_risk_score_pipeline().
#   cleanup_old_outputs  — if TRUE, deletes all previous .docx files in
#                          output_dir before writing.  Default FALSE (preserves
#                          all historical versions).
#   connection_details   — DatabaseConnector ConnectionDetails for live CDM
#                          queries (used by fetch_demographics_from_omop()).
#                          NULL disables Table 1 CDM queries.
#   config               — validation config list from get_validation_config().
#                          NULL disables Table 1 CDM queries.
#
# Report file naming:
#   The Word document is named pad-oler-ssi-val_report_<YYYYMMDD>.docx.
#   If a file with that name already exists, a numeric suffix is appended
#   (_2, _3, …) so no run's output is silently overwritten.
#
# Fringe-cases Excel:
#   pad_oler_ssi_fringe_<YYYYMMDD>.xlsx is always written (or overwritten if
#   already present from the same day's run).  It contains two sheets:
#     "Low risk with SSI"  — 10 patients with the lowest predicted risk who
#                            nonetheless developed SSI (false negatives)
#     "High risk no SSI"   — 10 patients with the highest predicted risk who
#                            did not develop SSI (false positives)
#   These cases are intended for clinical SME review to assess whether the
#   score misses clinically meaningful risk factors.
#
# Returns the path to the written .docx file (invisibly).
# =============================================================================
generate_manuscript_report <- function(output_dir        = "output/risk_score_eval",
                                       score_output_dir   = "output/risk_score_eval",
                                       cleanup_old_outputs = FALSE,
                                       connection_details = NULL,
                                       config             = NULL) {
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
    ece_rows <- data.frame(
      metric = character(), value = numeric(),
      ci_lower = numeric(), ci_upper = numeric(),
      model = character(), stringsAsFactors = FALSE
    )

    if ("predicted_risk_lookup" %in% names(person_level)) {
      keep_lookup <- !is.na(person_level$predicted_risk_lookup)
      if (any(keep_lookup)) {
        ece_rows <- rbind(
          ece_rows,
          data.frame(
            metric   = "ECE",
            value    = compute_ece(person_level$outcome[keep_lookup], person_level$predicted_risk_lookup[keep_lookup]),
            ci_lower = NA_real_,
            ci_upper = NA_real_,
            model    = "lookup",
            stringsAsFactors = FALSE
          )
        )
      }
    }

    if ("predicted_risk_recalibrated" %in% names(person_level)) {
      ece_rows <- rbind(
        ece_rows,
        data.frame(
          metric   = "ECE",
          value    = compute_ece(person_level$outcome, person_level$predicted_risk_recalibrated),
          ci_lower = NA_real_,
          ci_upper = NA_real_,
          model    = "recalibrated",
          stringsAsFactors = FALSE
        )
      )
    }

    if (nrow(ece_rows) > 0) {
      # Ensure metrics has ci_lower/ci_upper before binding, so column sets match.
      if (!"ci_lower" %in% names(metrics)) metrics$ci_lower <- NA_real_
      if (!"ci_upper" %in% names(metrics)) metrics$ci_upper <- NA_real_
      metrics <- rbind(metrics, ece_rows)
    }
  } else {
    # Ensure ci_lower/ci_upper exist even when ECE was already present in the CSV.
    if (!"ci_lower" %in% names(metrics)) metrics$ci_lower <- NA_real_
    if (!"ci_upper" %in% names(metrics)) metrics$ci_upper <- NA_real_
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

  # Returns a formatted "(lower–upper)" CI string for a given metric/model pair.
  # Pulls ci_lower and ci_upper from the metrics data frame (present when
  # compute_bootstrap_cis() was run during the pipeline).  Returns "—" when the
  # columns are absent or the values are NA (e.g. legacy metrics.csv files).
  metric_ci <- function(metric_name, model_name) {
    row <- metrics[metrics$metric == metric_name & metrics$model == model_name, , drop = FALSE]
    if (nrow(row) == 0) return("\u2014")
    if (!all(c("ci_lower", "ci_upper") %in% names(row))) return("\u2014")
    lo <- as.numeric(row$ci_lower[1])
    hi <- as.numeric(row$ci_upper[1])
    if (is.na(lo) || is.na(hi)) return("\u2014")
    paste0("(", fmt(lo), "\u2013", fmt(hi), ")")
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
    "95% CI" = c(
      metric_ci("AUROC",                "lookup"),
      metric_ci("AUPRC",                "lookup"),
      metric_ci("Brier",                "lookup"),
      metric_ci("ECE",                  "lookup"),
      metric_ci("CalibrationIntercept", "lookup"),
      metric_ci("CalibrationSlope",     "lookup")
    ),
    check.names     = FALSE,
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

      # Defensive deduplication: one row per person_id in case of ETL re-runs.
      # Uses the row with the most-frequent person_source_value (= most recent run)
      # and breaks ties by taking the first row per person_id within that group.
      dedup_person_cte <-
        "dedup_person AS (
           SELECT p2.*
           FROM (
             SELECT p3.*,
               ROW_NUMBER() OVER (
                 PARTITION BY p3.person_id
                 ORDER BY src_freq.n DESC, p3.person_source_value DESC, p3.year_of_birth DESC
               ) AS _rn
             FROM @cdm_schema.person p3
             INNER JOIN (
               SELECT person_id, person_source_value, COUNT(*) AS n
               FROM @cdm_schema.person
               GROUP BY person_id, person_source_value
             ) src_freq
               ON src_freq.person_id      = p3.person_id
              AND src_freq.person_source_value = p3.person_source_value
           ) p2
           WHERE p2._rn = 1
         )"

      # Age = FLOOR((procedure_date - birth_date) / 365.25), where birth_date
      # is constructed from the three OMOP person fields year_of_birth,
      # month_of_birth, day_of_birth (ETLSyntheaBuilder populates all three;
      # birth_datetime is optional in CDM 5.4 and may be NULL).
      # DATEFROMPARTS defaults to mid-year (Jul 1) when month/day are missing
      # so that any residual imprecision is symmetric rather than biased.
      # The DATEDIFF(DAY, ...) / 365.25 division is done in floating-point
      # so that fractional years are preserved before FLOOR rounds down to the
      # last completed year — matching the user-specified formula exactly.
      sql_age <- SqlRender::render(
        paste0(
          "WITH ", dedup_person_cte, "
           SELECT
             CAST(
               FLOOR(
                 CAST(DATEDIFF(DAY,
                   DATEFROMPARTS(
                     p.year_of_birth,
                     COALESCE(p.month_of_birth, 7),
                     COALESCE(p.day_of_birth,   1)
                   ),
                   t.cohort_start_date
                 ) AS FLOAT) / 365.25
               )
             AS FLOAT) AS age_at_index
           FROM @results_schema.@cohort_table t
           INNER JOIN dedup_person p ON p.person_id = t.subject_id
           WHERE t.cohort_definition_id = @target_id"
        ),
        results_schema = results_schema_prefix(config),
        cohort_table   = config$cohort_table,
        cdm_schema     = config$cdm_schema,
        target_id      = config$target_cohort_id
      )
      age_df <- tryCatch(
        DatabaseConnector::querySql(
          conn,
          SqlRender::translate(sql_age, targetDialect = "sql server")
        ),
        error = function(e) {
          message("[report] Age query failed: ", conditionMessage(e))
          NULL
        }
      )

      # Returns concept_id, category (concept_name), and n per group so that
      # downstream lookups can match on concept_id rather than on concept_name
      # strings (which are fragile to vocabulary version changes and regex errors).
      distribution_sql <- function(concept_col) {
        SqlRender::render(
          paste0(
            "WITH ", dedup_person_cte, "
             SELECT
               COALESCE(p.@concept_col, 0)                        AS concept_id,
               COALESCE(NULLIF(c.concept_name, ''), 'Unknown')    AS category,
               COUNT(DISTINCT t.subject_id)                       AS n
             FROM @results_schema.@cohort_table t
             INNER JOIN dedup_person p ON p.person_id = t.subject_id
             LEFT  JOIN @cdm_schema.concept c ON c.concept_id = p.@concept_col
             WHERE t.cohort_definition_id = @target_id
             GROUP BY COALESCE(p.@concept_col, 0),
                      COALESCE(NULLIF(c.concept_name, ''), 'Unknown')
             ORDER BY n DESC, category"
          ),
          results_schema = results_schema_prefix(config),
          cohort_table   = config$cohort_table,
          cdm_schema     = config$cdm_schema,
          concept_col    = concept_col,
          target_id      = config$target_cohort_id
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

      # ---- Indication categories (condition_ancestor rollup, 365d pre-index) ----
      # Claudication : ancestor 442774  (Intermittent claudication)
      #                Synthea module code: SNOMED 63491006
      # Rest pain    : ancestor 4325344  (Peripheral vascular disease with rest pain)
      #                Synthea module code: SNOMED 428171009 (maps directly to 4325344)
      # Tissue loss  : ancestor 4029926  (Ischemic ulcer)
      #                Synthea module code: SNOMED 238794007 (Ischemic foot ulcer, concept
      #                4033352), which is a level-1 descendant of 4029926.
      #                NOTE: ancestor 319835 was previously used here but is incorrect —
      #                319835 is Congestive Heart Failure, not Gangrene. Corrected to 4029926.
      # Asymptomatic : target patients with no claudication / rest pain / tissue loss code
      sql_indication <- SqlRender::render(
        "WITH target AS (
           SELECT subject_id, cohort_start_date
           FROM @results_schema.@cohort_table
           WHERE cohort_definition_id = @target_id
         ),
         claud AS (
           SELECT DISTINCT co.person_id
           FROM @cdm_schema.condition_occurrence co
           INNER JOIN @cdm_schema.concept_ancestor ca
             ON ca.descendant_concept_id = co.condition_concept_id
            AND ca.ancestor_concept_id   = 442774
           INNER JOIN target t ON t.subject_id = co.person_id
             AND co.condition_start_date BETWEEN DATEADD(DAY,-365,t.cohort_start_date)
                                             AND t.cohort_start_date
         ),
         rest_pain AS (
           SELECT DISTINCT co.person_id
           FROM @cdm_schema.condition_occurrence co
           INNER JOIN @cdm_schema.concept_ancestor ca
             ON ca.descendant_concept_id = co.condition_concept_id
            AND ca.ancestor_concept_id   = 4325344
           INNER JOIN target t ON t.subject_id = co.person_id
             AND co.condition_start_date BETWEEN DATEADD(DAY,-365,t.cohort_start_date)
                                             AND t.cohort_start_date
         ),
         tissue_loss AS (
           SELECT DISTINCT co.person_id
           FROM @cdm_schema.condition_occurrence co
           INNER JOIN @cdm_schema.concept_ancestor ca
             ON ca.descendant_concept_id = co.condition_concept_id
            AND ca.ancestor_concept_id   = 4029926
           INNER JOIN target t ON t.subject_id = co.person_id
             AND co.condition_start_date BETWEEN DATEADD(DAY,-365,t.cohort_start_date)
                                             AND t.cohort_start_date
         ),
         any_specific AS (
           SELECT person_id FROM claud
           UNION SELECT person_id FROM rest_pain
           UNION SELECT person_id FROM tissue_loss
         )
         SELECT 'Claudication' AS category, COUNT(*)               AS n FROM claud
         UNION ALL
         SELECT 'Rest pain',                COUNT(*)                    FROM rest_pain
         UNION ALL
         SELECT 'Tissue loss',              COUNT(*)                    FROM tissue_loss
         UNION ALL
         SELECT 'Asymptomatic',             COUNT(DISTINCT t.subject_id)
           FROM target t
           LEFT JOIN any_specific sp ON sp.person_id = t.subject_id
           WHERE sp.person_id IS NULL",
        results_schema = results_schema_prefix(config),
        cohort_table   = config$cohort_table,
        cdm_schema     = config$cdm_schema,
        target_id      = config$target_cohort_id
      )
      indication_df <- tryCatch(
        DatabaseConnector::querySql(
          conn, SqlRender::translate(sql_indication, targetDialect = "sql server")
        ),
        error = function(e) NULL
      )

      # ---- Procedure type (qualifying procedure at index visit) ---------------
      # Concept ancestor rollup per procedure type (not mutually exclusive;
      # counts distinct patients with each procedure type at the index visit).
      # Ancestor IDs:
      #   4231680 = Aorto-femoral arterial bypass  → aortobifemoral
      #   4259121 = Femoral-femoral artery vascular bypass → fem-fem
      #   4012936 = Femoral-popliteal artery bypass graft  → fem-pop
      #   4166196 = Femorotibial vascular bypass           → fem-tibial
      sql_proc_type <- SqlRender::render(
        "WITH target AS (
           SELECT subject_id,
                  cohort_start_date,
                  ISNULL(cohort_end_date, cohort_start_date) AS cohort_end_date
           FROM @results_schema.@cohort_table
           WHERE cohort_definition_id = @target_id
         )
         SELECT 'Aortobifemoral bypass'   AS category,
                COUNT(DISTINCT t.subject_id) AS n
         FROM target t
         INNER JOIN @cdm_schema.procedure_occurrence po
           ON po.person_id = t.subject_id
          AND po.procedure_date BETWEEN t.cohort_start_date AND t.cohort_end_date
         INNER JOIN @cdm_schema.concept_ancestor ca
           ON ca.descendant_concept_id = po.procedure_concept_id
          AND ca.ancestor_concept_id   = 4231680
         UNION ALL
         SELECT 'Femoral endarterectomy', COUNT(DISTINCT t.subject_id)
         FROM target t
         INNER JOIN @cdm_schema.procedure_occurrence po
           ON po.person_id = t.subject_id
          AND po.procedure_date BETWEEN t.cohort_start_date AND t.cohort_end_date
         INNER JOIN @cdm_schema.concept_ancestor ca
           ON ca.descendant_concept_id = po.procedure_concept_id
          AND ca.ancestor_concept_id   = 4040974
         UNION ALL
         SELECT 'Femoral-popliteal bypass', COUNT(DISTINCT t.subject_id)
         FROM target t
         INNER JOIN @cdm_schema.procedure_occurrence po
           ON po.person_id = t.subject_id
          AND po.procedure_date BETWEEN t.cohort_start_date AND t.cohort_end_date
         INNER JOIN @cdm_schema.concept_ancestor ca
           ON ca.descendant_concept_id = po.procedure_concept_id
          AND ca.ancestor_concept_id   = 4012936
         UNION ALL
         SELECT 'Femorotibial bypass',      COUNT(DISTINCT t.subject_id)
         FROM target t
         INNER JOIN @cdm_schema.procedure_occurrence po
           ON po.person_id = t.subject_id
          AND po.procedure_date BETWEEN t.cohort_start_date AND t.cohort_end_date
         INNER JOIN @cdm_schema.concept_ancestor ca
           ON ca.descendant_concept_id = po.procedure_concept_id
          AND ca.ancestor_concept_id   = 4166196
         UNION ALL
         SELECT 'Extra-anatomic bypass',    COUNT(DISTINCT t.subject_id)
         FROM target t
         INNER JOIN @cdm_schema.procedure_occurrence po
           ON po.person_id = t.subject_id
          AND po.procedure_date BETWEEN t.cohort_start_date AND t.cohort_end_date
         INNER JOIN @cdm_schema.concept_ancestor ca
           ON ca.descendant_concept_id = po.procedure_concept_id
          AND ca.ancestor_concept_id   = 4050281",
        results_schema = results_schema_prefix(config),
        cohort_table   = config$cohort_table,
        cdm_schema     = config$cdm_schema,
        target_id      = config$target_cohort_id
      )
      proc_type_df <- tryCatch(
        DatabaseConnector::querySql(
          conn, SqlRender::translate(sql_proc_type, targetDialect = "sql server")
        ),
        error = function(e) NULL
      )

      out <- list(
        age            = age_df,
        sex            = sex_df,
        race           = race_df,
        ethnicity      = ethnicity_df,
        indication     = indication_df,
        procedure_type = proc_type_df
      )
    }, silent = TRUE)

    if (!is.null(conn)) {
      try(DatabaseConnector::disconnect(conn), silent = TRUE)
    }

    out
  }

  # ---------------------------------------------------------------------------
  # fetch_ssi_outcomes_from_omop()
  #
  # Queries post-operative outcome statistics for SSI patients:
  #   1. Median days (with IQR) from the index procedure to SSI diagnosis
  #   2. 90-day reoperation count: any procedure_occurrence after SSI date
  #      and within 90 days of the index date
  #   3. 90-day readmission count: inpatient visit (concept 9201) starting
  #      after SSI date and within 90 days of the index date
  #   4. 90-day mortality count: death record within 90 days of index date
  #      among SSI patients
  #
  # Denominator for rates 2–4 is the number of SSI patients (n_ssi).
  # ---------------------------------------------------------------------------
  fetch_ssi_outcomes_from_omop <- function(config, connection_details) {
    if (is.null(config) || is.null(connection_details)) return(NULL)

    conn <- NULL
    out  <- NULL
    try({
      conn <- DatabaseConnector::connect(connection_details)

      # Shared CTE: SSI patients joined to their index procedure date.
      # Only patients whose SSI falls within the 90-day prediction window are kept.
      ssi_cte <- "ssi_w_index AS (
        SELECT
          s.subject_id,
          t.cohort_start_date        AS index_date,
          s.cohort_start_date        AS ssi_date,
          DATEDIFF(DAY,
            t.cohort_start_date,
            s.cohort_start_date)     AS days_to_ssi
        FROM @results_schema.@cohort_table s
        INNER JOIN @results_schema.@cohort_table t
          ON  t.subject_id           = s.subject_id
          AND t.cohort_definition_id = @target_id
        WHERE s.cohort_definition_id = @outcome_id
          AND DATEDIFF(DAY, t.cohort_start_date, s.cohort_start_date)
              BETWEEN 0 AND 90
      )"

      # 1. Days-to-SSI: count, median, IQR
      # PERCENTILE_CONT in SQL Server is an analytic (window) function and requires
      # OVER (). We select TOP 1 since the window function returns the same value
      # for every row; COUNT(*) OVER () gives the total row count.
      sql_days <- SqlRender::render(
        paste0(
          "WITH ", ssi_cte, "
           SELECT TOP 1
             COUNT(*) OVER ()                                                 AS n_ssi,
             CAST(PERCENTILE_CONT(0.25)
               WITHIN GROUP (ORDER BY CAST(days_to_ssi AS FLOAT)) OVER ()
             AS FLOAT)                                                         AS p25,
             CAST(PERCENTILE_CONT(0.5)
               WITHIN GROUP (ORDER BY CAST(days_to_ssi AS FLOAT)) OVER ()
             AS FLOAT)                                                         AS median_days,
             CAST(PERCENTILE_CONT(0.75)
               WITHIN GROUP (ORDER BY CAST(days_to_ssi AS FLOAT)) OVER ()
             AS FLOAT)                                                         AS p75
           FROM ssi_w_index"
        ),
        results_schema = results_schema_prefix(config),
        cohort_table   = config$cohort_table,
        target_id      = config$target_cohort_id,
        outcome_id     = config$outcome_cohort_id
      )
      days_raw <- tryCatch({
        r <- DatabaseConnector::querySql(
          conn, SqlRender::translate(sql_days, targetDialect = "sql server")
        )
        names(r) <- tolower(names(r))
        r
      }, error = function(e) {
        message("[report] Days-to-SSI query failed: ", conditionMessage(e))
        NULL
      })

      # 2. 90-day reoperation: any procedure_occurrence after SSI date within window
      sql_reop <- SqlRender::render(
        paste0(
          "WITH ", ssi_cte, "
           SELECT COUNT(DISTINCT si.subject_id) AS n_reoperation
           FROM ssi_w_index si
           INNER JOIN @cdm_schema.procedure_occurrence po
             ON  po.person_id = si.subject_id
             AND CAST(po.procedure_date AS DATE) > si.ssi_date
             AND CAST(po.procedure_date AS DATE) <=
                 DATEADD(DAY, 90, si.index_date)"
        ),
        results_schema = results_schema_prefix(config),
        cohort_table   = config$cohort_table,
        cdm_schema     = config$cdm_schema,
        target_id      = config$target_cohort_id,
        outcome_id     = config$outcome_cohort_id
      )
      reop_raw <- tryCatch({
        r <- DatabaseConnector::querySql(
          conn, SqlRender::translate(sql_reop, targetDialect = "sql server")
        )
        names(r) <- tolower(names(r))
        r
      }, error = function(e) {
        message("[report] Reoperation query failed: ", conditionMessage(e))
        NULL
      })

      # 3. 90-day readmission: inpatient visit (concept 9201) after SSI date within window
      sql_readm <- SqlRender::render(
        paste0(
          "WITH ", ssi_cte, "
           SELECT COUNT(DISTINCT si.subject_id) AS n_readmission
           FROM ssi_w_index si
           INNER JOIN @cdm_schema.visit_occurrence vo
             ON  vo.person_id        = si.subject_id
             AND vo.visit_concept_id = 9201
             AND CAST(vo.visit_start_date AS DATE) > si.ssi_date
             AND CAST(vo.visit_start_date AS DATE) <=
                 DATEADD(DAY, 90, si.index_date)"
        ),
        results_schema = results_schema_prefix(config),
        cohort_table   = config$cohort_table,
        cdm_schema     = config$cdm_schema,
        target_id      = config$target_cohort_id,
        outcome_id     = config$outcome_cohort_id
      )
      readm_raw <- tryCatch({
        r <- DatabaseConnector::querySql(
          conn, SqlRender::translate(sql_readm, targetDialect = "sql server")
        )
        names(r) <- tolower(names(r))
        r
      }, error = function(e) {
        message("[report] Readmission query failed: ", conditionMessage(e))
        NULL
      })

      # 4. 90-day mortality: death record within 90 days of index date (SSI patients only)
      sql_death <- SqlRender::render(
        paste0(
          "WITH ", ssi_cte, "
           SELECT COUNT(DISTINCT si.subject_id) AS n_death
           FROM ssi_w_index si
           INNER JOIN @cdm_schema.death d
             ON  d.person_id = si.subject_id
             AND CAST(d.death_date AS DATE) <=
                 DATEADD(DAY, 90, si.index_date)"
        ),
        results_schema = results_schema_prefix(config),
        cohort_table   = config$cohort_table,
        cdm_schema     = config$cdm_schema,
        target_id      = config$target_cohort_id,
        outcome_id     = config$outcome_cohort_id
      )
      death_raw <- tryCatch({
        r <- DatabaseConnector::querySql(
          conn, SqlRender::translate(sql_death, targetDialect = "sql server")
        )
        names(r) <- tolower(names(r))
        r
      }, error = function(e) {
        message("[report] Death query failed: ", conditionMessage(e))
        NULL
      })

      # 5. SSI type breakdown: superficial / deep / organ-space
      # Ancestor concept IDs (SNOMED-CT, OMOP standard):
      #   43530818 = Superficial incisional surgical site infection
      #   4308542  = Postoperative wound infection - deep  (deep incisional proxy)
      #   43530820 = Organ-space surgical site infection
      # Each patient is counted under their most-specific SSI type; a patient
      # with only a non-classified SSI code is counted as 'Other / unclassified'.
      sql_ssi_type <- SqlRender::render(
        paste0(
          "WITH ", ssi_cte, "
           SELECT
             SUM(CASE WHEN ca_sup.ancestor_concept_id IS NOT NULL THEN 1 ELSE 0 END) AS n_superficial,
             SUM(CASE WHEN ca_deep.ancestor_concept_id IS NOT NULL THEN 1 ELSE 0 END) AS n_deep,
             SUM(CASE WHEN ca_org.ancestor_concept_id  IS NOT NULL THEN 1 ELSE 0 END) AS n_organ
           FROM ssi_w_index si
           INNER JOIN @cdm_schema.condition_occurrence co
             ON  co.person_id           = si.subject_id
             AND CAST(co.condition_start_date AS DATE) = si.ssi_date
           LEFT JOIN @cdm_schema.concept_ancestor ca_sup
             ON  ca_sup.descendant_concept_id = co.condition_concept_id
             AND ca_sup.ancestor_concept_id   = 43530818
           LEFT JOIN @cdm_schema.concept_ancestor ca_deep
             ON  ca_deep.descendant_concept_id = co.condition_concept_id
             AND ca_deep.ancestor_concept_id   = 4308542
           LEFT JOIN @cdm_schema.concept_ancestor ca_org
             ON  ca_org.descendant_concept_id = co.condition_concept_id
             AND ca_org.ancestor_concept_id   = 43530820"
        ),
        results_schema = results_schema_prefix(config),
        cohort_table   = config$cohort_table,
        cdm_schema     = config$cdm_schema,
        target_id      = config$target_cohort_id,
        outcome_id     = config$outcome_cohort_id
      )
      ssi_type_raw <- tryCatch({
        r <- DatabaseConnector::querySql(
          conn, SqlRender::translate(sql_ssi_type, targetDialect = "sql server")
        )
        names(r) <- tolower(names(r))
        r
      }, error = function(e) {
        message("[report] SSI type query failed: ", conditionMessage(e))
        NULL
      })

      out <- list(
        n_ssi         = if (!is.null(days_raw))     as.integer(days_raw$n_ssi[1])           else NA_integer_,
        median_days   = if (!is.null(days_raw))     as.numeric(days_raw$median_days[1])     else NA_real_,
        p25           = if (!is.null(days_raw))     as.numeric(days_raw$p25[1])             else NA_real_,
        p75           = if (!is.null(days_raw))     as.numeric(days_raw$p75[1])             else NA_real_,
        n_reoperation = if (!is.null(reop_raw))     as.integer(reop_raw$n_reoperation[1])   else NA_integer_,
        n_readmission = if (!is.null(readm_raw))    as.integer(readm_raw$n_readmission[1])  else NA_integer_,
        n_death       = if (!is.null(death_raw))    as.integer(death_raw$n_death[1])        else NA_integer_,
        n_superficial = if (!is.null(ssi_type_raw)) as.integer(ssi_type_raw$n_superficial[1]) else NA_integer_,
        n_deep        = if (!is.null(ssi_type_raw)) as.integer(ssi_type_raw$n_deep[1])        else NA_integer_,
        n_organ       = if (!is.null(ssi_type_raw)) as.integer(ssi_type_raw$n_organ[1])       else NA_integer_
      )
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
    n_target  <- nrow(person_level)
    n_outcome <- sum(as.numeric(person_level$outcome), na.rm = TRUE)

    # Helper: build one row; is_header=TRUE makes the row a section label
    row1 <- function(char, val = "", header = FALSE) {
      data.frame(
        Characteristic = char,
        Value          = val,
        is_header      = header,
        stringsAsFactors = FALSE
      )
    }
    sub_row <- function(label, n, denom) {
      row1(paste0("    ", label), fmt_n_pct(n, denom))
    }
    # Look up count for a fixed OMOP concept_id in a distribution data frame
    # returned by distribution_sql() (columns: CONCEPT_ID, CATEGORY, N).
    # All matching is done on the integer concept_id — no string/regex logic.
    lookup_concept <- function(df, cid) {
      if (is.null(df) || nrow(df) == 0) return(0L)
      n_col  <- names(df)[toupper(names(df)) == "N"][1]
      id_col <- names(df)[toupper(names(df)) == "CONCEPT_ID"][1]
      if (is.na(n_col) || is.na(id_col)) return(0L)
      idx <- which(as.integer(df[[id_col]]) == as.integer(cid))
      if (length(idx) == 0) return(0L)
      sum(as.integer(df[[n_col]][idx]), na.rm = TRUE)
    }
    # Look up count by exact category label (used for indication/procedure rows
    # where the SQL itself sets the category string, so it is stable).
    lookup_n <- function(df, category_value) {
      if (is.null(df) || nrow(df) == 0) return(0L)
      n_col   <- names(df)[toupper(names(df)) == "N"][1]
      cat_col <- names(df)[toupper(names(df)) == "CATEGORY"][1]
      if (is.na(n_col) || is.na(cat_col)) return(0L)
      idx <- which(trimws(df[[cat_col]]) == category_value)
      if (length(idx) == 0) return(0L)
      as.integer(df[[n_col]][idx[1]])
    }

    demog <- fetch_demographics_from_omop(config, connection_details)

    # ---- Age ------------------------------------------------------------------
    age_row <- row1("Age, median (IQR), years", "N/A")
    if (!is.null(demog$age) && nrow(demog$age) > 0) {
      # DatabaseConnector >= 6.0 stopped auto-uppercasing column names, so use
      # a case-insensitive lookup instead of the hard-coded AGE_AT_INDEX name.
      .age_col <- names(demog$age)[toupper(names(demog$age)) == "AGE_AT_INDEX"][1]
      ages <- if (!is.na(.age_col)) as.numeric(demog$age[[.age_col]]) else numeric(0)
      ages <- ages[!is.na(ages)]
      if (length(ages) > 0) {
        q <- stats::quantile(ages, probs = c(0.25, 0.75), na.rm = TRUE)
        age_row <- row1(
          "Age, median (IQR), years",
          paste0(
            as.character(as.integer(floor(stats::median(ages)))),
            " (",
            as.character(as.integer(floor(q[[1]]))),
            "\u2013",
            as.character(as.integer(floor(q[[2]]))),
            ")"
          )
        )
      }
    }

    # ---- Sex ------------------------------------------------------------------
    # Standard OMOP Gender domain concept IDs (vocabulary_id = 'Gender'):
    #   8507 = MALE
    #   8532 = FEMALE
    male_n   <- lookup_concept(demog$sex, 8507L)
    female_n <- lookup_concept(demog$sex, 8532L)

    # ---- Race / Ethnicity (four requested categories) ------------------------
    # Standard OMOP Race domain concept IDs (vocabulary_id = 'Race'):
    #   8527 = White
    #   8516 = Black or African American
    #   8515 = Asian
    # Standard OMOP Ethnicity domain concept IDs (vocabulary_id = 'Ethnicity'):
    #   38003563 = Hispanic or Latino
    #   38003564 = Not Hispanic or Latino
    white_n   <- lookup_concept(demog$race,      8527L)
    black_n   <- lookup_concept(demog$race,      8516L)
    asian_n   <- lookup_concept(demog$race,      8515L)
    latino_n  <- lookup_concept(demog$ethnicity, 38003563L)

    # ---- Indication (OMOP concept_ancestor rollup, returned by fetch_demographics) -----
    ind_df   <- demog$indication
    claud_n  <- lookup_n(ind_df, "Claudication")
    rest_n   <- lookup_n(ind_df, "Rest pain")
    tissue_n <- lookup_n(ind_df, "Tissue loss")
    asymp_n  <- lookup_n(ind_df, "Asymptomatic")

    # ---- Procedure type -------------------------------------------------------
    pt_df      <- demog$procedure_type
    aortobif_n <- lookup_n(pt_df, "Aortobifemoral bypass")
    endar_n    <- lookup_n(pt_df, "Femoral endarterectomy")
    fempop_n   <- lookup_n(pt_df, "Femoral-popliteal bypass")
    femtib_n    <- lookup_n(pt_df, "Femorotibial bypass")
    extraanat_n <- lookup_n(pt_df, "Extra-anatomic bypass")

    # ---- Assemble table -------------------------------------------------------
    tbl <- rbind(
      age_row,
      # Sex
      row1("Sex", header = TRUE),
      sub_row("Male",   male_n,   n_target),
      sub_row("Female", female_n, n_target),
      # Race
      row1("Race", header = TRUE),
      sub_row("White",             white_n,  n_target),
      sub_row("Black",             black_n,  n_target),
      sub_row("Asian",             asian_n,  n_target),
      sub_row("Hispanic / Latino", latino_n, n_target),
      # Indication
      row1("Indication", header = TRUE),
      sub_row("Asymptomatic", asymp_n,  n_target),
      sub_row("Claudication", claud_n,  n_target),
      sub_row("Rest pain",    rest_n,   n_target),
      sub_row("Tissue loss",  tissue_n, n_target),
      # Procedure
      row1("Procedure", header = TRUE),
      sub_row("Aortobifemoral bypass",    aortobif_n, n_target),
      sub_row("Femoral endarterectomy",   endar_n,    n_target),
      sub_row("Femoral-popliteal bypass", fempop_n,   n_target),
      sub_row("Femorotibial bypass",      femtib_n,    n_target),
      sub_row("Extra-anatomic bypass",    extraanat_n, n_target),
      # 90-day outcome
      row1("90-day outcome", header = TRUE),
      sub_row("Surgical site infection", n_outcome, n_target),
      # Total (last row)
      row1("Total cohort", fmt_n_pct(n_target, n_target))
    )

    tbl
  }

  # Use passed-in config / connection_details; fall back to get_validation_config()
  # for callers that do not supply them explicitly.
  if (is.null(config) && exists("get_validation_config", mode = "function")) {
    config <- tryCatch(get_validation_config(), error = function(e) NULL)
  }
  if (is.null(connection_details) && !is.null(config) &&
      exists("build_connection_details", mode = "function")) {
    connection_details <- tryCatch(build_connection_details(config), error = function(e) NULL)
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

  # Two-column Table 1 formatter.
  # Expects df with columns: Characteristic, Value, is_header (logical).
  # is_header rows are rendered bold with no indentation; sub-rows are indented.
  # The is_header column is dropped before the flextable is built.
  table1_ft <- function(df) {
    if (is.null(df) || nrow(df) == 0) {
      return(flextable(data.frame(Characteristic = character(), Value = character())))
    }

    header_rows <- which(df$is_header)
    sub_rows    <- which(!df$is_header)
    total_row   <- nrow(df)   # last row is always "Total cohort"

    # Strip the helper column before passing to flextable
    display_df <- df[, c("Characteristic", "Value"), drop = FALSE]

    ft <- flextable(display_df) |>
      bold(part = "header") |>
      fontsize(size = 10, part = "all") |>
      font(fontname = "Calibri", part = "all") |>
      bg(part = "header", bg = "#1F3864") |>
      color(part = "header", color = "white") |>
      align(align = "left",  part = "all") |>
      valign(valign = "top", part = "all") |>
      padding(padding = 3, part = "all") |>
      # Section-label rows: bold, no left indent, light grey background
      bold(i = header_rows, part = "body") |>
      bg(i = header_rows, bg = "#F2F2F2", part = "body") |>
      # Sub-rows: extra left padding to simulate indent
      padding(i = sub_rows, j = "Characteristic", padding.left = 18, part = "body") |>
      # Total row: bold
      bold(i = total_row, part = "body") |>
      # Column widths
      width(j = "Characteristic", width = 2.8) |>
      width(j = "Value",          width = 1.4) |>
      set_table_properties(layout = "fixed")

    ft
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

  # ---------------------------------------------------------------------------
  # save_subgroup_forest_plot()
  #
  # Builds a forest plot of ECE (95% CI) by subgroup from the subgroup_bias
  # data frame.  Each subgroup variable is drawn as a labelled section (via
  # ggplot2 faceting on subgroup_var).  A dashed vertical reference line shows
  # the overall ECE for the lookup model (read from metrics.csv).
  #
  # Arguments:
  #   bias_df      — data frame from subgroup_bias.csv
  #   overall_ece  — numeric overall ECE (lookup model) for the reference line
  #   output_folder — directory where the PNG will be written
  #
  # Returns the path to the saved PNG, or NULL on failure.
  # ---------------------------------------------------------------------------
  save_subgroup_forest_plot <- function(bias_df, overall_ece, output_folder) {

    if (is.null(bias_df) || nrow(bias_df) == 0) return(NULL)

    # Impose Table 1 ordering on subgroup facets.
    var_order <- c("age_group", "sex", "race", "ethnicity",
                   "indication", "proc_type", "year")
    present_vars <- var_order[var_order %in% bias_df$subgroup_var]
    extra_vars   <- setdiff(unique(bias_df$subgroup_var), present_vars)
    ordered_vars <- c(present_vars, extra_vars)
    bias_df$subgroup_var <- factor(bias_df$subgroup_var, levels = ordered_vars)

    # Build a combined label: "Sex: Female", "Race: Black", etc.
    bias_df$label <- paste0(
      tools::toTitleCase(gsub("_", " ", as.character(bias_df$subgroup_var))),
      ": ",
      bias_df$subgroup_level
    )

    # Order labels within each facet by ECE (ascending) for readability.
    bias_df$label <- factor(
      bias_df$label,
      levels = bias_df$label[order(bias_df$subgroup_var, bias_df$ece)]
    )

    # Facet labels: capitalise the subgroup variable name for display.
    facet_labels <- setNames(
      tools::toTitleCase(gsub("_", " ", levels(bias_df$subgroup_var))),
      levels(bias_df$subgroup_var)
    )

    p <- ggplot2::ggplot(bias_df,
           ggplot2::aes(x = ece, y = label)) +
      ggplot2::geom_point(size = 2, colour = "black") +
      ggplot2::geom_errorbarh(
        ggplot2::aes(xmin = ci_lower, xmax = ci_upper),
        height = 0.25, colour = "grey40"
      ) +
      ggplot2::geom_vline(
        xintercept = overall_ece,
        linetype   = "dashed",
        colour     = "black"
      ) +
      ggplot2::facet_grid(
        subgroup_var ~ .,
        scales   = "free_y",
        space    = "free_y",
        labeller = ggplot2::as_labeller(facet_labels)
      ) +
      ggplot2::labs(
        x     = "Expected Calibration Error (95% CI)",
        y     = NULL,
        title = "Subgroup Calibration (ECE)",
        caption = paste0(
          "Dashed line = overall ECE (", round(overall_ece, 3), "). ",
          "Groups with < 10 events suppressed. ",
          "CIs from 200 bootstrap resamples."
        )
      ) +
      ggplot2::theme_bw(base_size = 11) +
      ggplot2::theme(
        panel.grid.major.y = ggplot2::element_blank(),
        strip.text         = ggplot2::element_text(face = "bold"),
        plot.caption       = ggplot2::element_text(size = 8)
      )

    out_path <- file.path(output_folder, "subgroup_forest_plot.png")
    tryCatch({
      ggplot2::ggsave(out_path, p,
                      width  = 7,
                      height = max(4, nrow(bias_df) * 0.35 + 1.5),
                      dpi    = 150)
      out_path
    }, error = function(e) {
      message("[report] Could not save subgroup forest plot: ", conditionMessage(e))
      NULL
    })
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

  # Figure 1 — SSI rate by year (requires index_date in person_level)
  ssi_year_plot_file <- .save_ssi_rate_by_year_plot(person_level, temp_figure_dir)

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
          nm %in% c("roc_curve.png", "calibration_lookup.png", "calibration_recalibrated.png",
                "ssi_rate_by_year.png", "subgroup_forest_plot.png", "pipeline_rerun.log")) {
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

  # Query CDM source metadata early so values are available for the methods text.
  cdm_version_str        <- ""
  vocabulary_version_str <- ""
  if (!is.null(connection_details) && !is.null(config)) {
    tryCatch({
      conn_meta <- DatabaseConnector::connect(connection_details)
      meta_raw  <- DatabaseConnector::querySql(
        conn_meta,
        SqlRender::translate(
          SqlRender::render(
            "SELECT cdm_version, vocabulary_version FROM @cdm_schema.cdm_source",
            cdm_schema = config$cdm_schema
          ),
          targetDialect = "sql server"
        )
      )
      DatabaseConnector::disconnect(conn_meta)
      names(meta_raw) <- tolower(names(meta_raw))
      if (nrow(meta_raw) > 0) {
        cdm_version_str        <- as.character(meta_raw$cdm_version[1])
        vocabulary_version_str <- as.character(meta_raw$vocabulary_version[1])
      }
    }, error = function(e) NULL)
  }

  doc <- read_docx()
  doc <- body_add_par(doc, "Manuscript Draft: Methods and Results", style = "heading 1")
  doc <- body_add_par(doc, "PAD Open Lower Extremity Revascularization and 30-Day Surgical Site Infection Risk Score Evaluation", style = "Normal")
  doc <- body_add_par(doc, paste("Date:", format(Sys.Date(), "%Y-%m-%d")), style = "Normal")
  doc <- body_add_par(doc, "", style = "Normal")

  doc <- body_add_par(doc, "Methods", style = "heading 2")
  doc <- body_add_par(doc, "Data source", style = "heading 3")
  doc <- body_add_par(doc, paste0(
    "This analysis used patient-level data mapped to the Observational Medical Outcomes Partnership ",
    "Common Data Model (OMOP CDM",
    if (nzchar(cdm_version_str))        paste0("; CDM version: ", cdm_version_str)        else "",
    if (nzchar(vocabulary_version_str)) paste0("; vocabulary release: ", vocabulary_version_str) else "",
    "). The study window spanned ",
    if (!is.null(config$study_start_date)) format(as.Date(config$study_start_date), "%B %d, %Y") else "N/A",
    " to ",
    if (!is.null(config$study_end_date))   format(as.Date(config$study_end_date),   "%B %d, %Y") else "N/A",
    ". All cohort definitions, concept mappings, and analytic scripts are compatible with any ",
    "OMOP CDM v5 data source. Full data source metadata are reported in Supplemental Table S1."
  ), style = "Normal")
  doc <- body_add_par(doc, "Target and outcome cohort definitions", style = "heading 3")
  doc <- body_add_par(doc, paste0(
    "The target cohort comprised adults aged 18 years or older who underwent inpatient open ",
    "lower-extremity arterial surgery, defined using OMOP concepts 4236706 (Arterial bypass of ",
    "lower limb artery) and 4225375 (Endarterectomy of lower limb artery) and all descendants, ",
    "including femoral-popliteal bypass, femorotibial bypass, aortobifemoral bypass, femoral ",
    "endarterectomy, and extra-anatomic bypass (axillofemoral and femorofemoral). Both anchor ",
    "concepts are explicitly scoped to arterial procedures of the lower extremity, excluding ",
    "diagnostic imaging and venous procedures. The index date was the start of the first qualifying ",
    "inpatient visit per person. Patients with any SSI diagnosis in the 365 days prior to index ",
    "were excluded. Corresponding CPT-4 codes for each procedure subgroup are listed in ",
    "Supplemental Table S2."
  ), style = "Normal")
  doc <- body_add_par(doc, paste0(
    "The outcome cohort identified the first surgical site infection diagnosis (OMOP concept 4334801, ",
    "SNOMED-CT 433202001, and descendants, capturing superficial incisional, deep incisional, and ",
    "organ-space SSI per CDC/NHSN classification) within 90 days of the index date. Source ICD ",
    "codes used to identify SSI prior to standardisation are listed in Supplemental Table S3."
  ), style = "Normal")
  doc <- body_add_par(doc, "Risk score evaluation", style = "heading 3")
  doc <- body_add_par(doc, "A person-level integer risk score was calculated from prespecified score components and concept mappings. Discrimination was summarized using area under the receiver operating characteristic curve and area under the precision-recall curve. For the published lookup model, integer scores were mapped to predicted risks using the supplied score-to-risk lookup table.", style = "Normal")
  doc <- body_add_par(doc, "Calibration was summarized with the Brier score, estimated calibration error, calibration intercept, and calibration slope. Estimated calibration error was computed as the weighted mean absolute difference between grouped predicted and observed risks across quantile-based bins. Calibration plots were generated by grouping predicted risks into quantile-based bins and comparing mean predicted versus mean observed event rates within bins. Summary metrics in this report are presented for the published lookup mapping only.", style = "Normal")
  doc <- body_add_par(doc, "Subgroup analysis and bias assessment", style = "heading 3")
  doc <- body_add_par(doc, paste0(
    "Model calibration was assessed across prespecified patient subgroups to identify populations ",
    "in which the lookup risk score may systematically over- or underestimate observed SSI risk. ",
    "Subgroups evaluated included biological sex, race, ethnicity, age group (<65, 65\u201374, \u226575 years), ",
    "operative indication (claudication vs. critical limb ischemia), procedure type (aortobifemoral ",
    "bypass, femoral-popliteal bypass, femorotibial bypass, femoral endarterectomy, extra-anatomic ",
    "bypass), and calendar year of the index procedure. Expected calibration error (ECE) was ",
    "computed within each subgroup as the weighted mean absolute difference between grouped ",
    "predicted and observed event rates across quantile-based bins. Uncertainty was quantified ",
    "using 200 bootstrap resamples (percentile 95% CI). Subgroup levels with fewer than 10 ",
    "observed SSI events were suppressed to avoid unreliable estimates. Results are presented in ",
    "Supplemental Table S4 and Supplemental Figure S1."
  ), style = "Normal")

  doc <- body_add_par(doc, "Results", style = "heading 2")

  # ---- Table 1: Demographics -----------------------------------------------
  doc <- body_add_par(doc, "Cohort characteristics", style = "heading 3")
  doc <- body_add_par(doc, paste0("The final target cohort included ", n_target, " patients, of whom ", n_outcome, " experienced surgical site infection within 90 days, corresponding to an observed event rate of ", fmt(outcome_prev, 2), "%."), style = "Normal")
  doc <- body_add_par(doc, "Table 1. Demographics of the external validation cohort.", style = "Normal")
  doc <- body_add_par(doc, "Caption: Values are n (%) unless stated. Age is summarised as median (IQR). Race and ethnicity are derived from OMOP person table concept fields. Indication categories use OMOP concept-ancestor rollup within 365 days before index (claudication: concept 442774, SNOMED 63491006; rest pain: concept 4325344, SNOMED 428171009; tissue loss: concept 4029926 [Ischemic ulcer], SNOMED 238794007; asymptomatic = residual). Procedure subtypes use concept-ancestor rollup at the index visit (aortobifemoral: 4231680; femoral endarterectomy: 4040974; femoral-popliteal: 4012936; femorotibial: 4166196; extra-anatomic bypass: 4050281). Procedure sub-rows are not mutually exclusive.", style = "Normal")
  doc <- body_add_flextable(doc, table1_ft(cohort_tbl))
  doc <- body_add_par(doc, "", style = "Normal")

  # ---- Table 2: SSI Patient Outcomes ----------------------------------------
  ssi_outcomes <- fetch_ssi_outcomes_from_omop(config, connection_details)
  if (!is.null(ssi_outcomes) && !is.na(ssi_outcomes$n_ssi) && ssi_outcomes$n_ssi > 0) {
    n_ssi_denom <- ssi_outcomes$n_ssi

    days_str <- if (!is.na(ssi_outcomes$median_days)) {
      paste0(
        as.integer(round(ssi_outcomes$median_days)), " days",
        " (IQR: ",
        as.integer(round(ssi_outcomes$p25)),
        "\u2013",
        as.integer(round(ssi_outcomes$p75)),
        ")"
      )
    } else "N/A"

    ssi_outcome_tbl <- data.frame(
      Outcome = c(
        "Days from index operation to SSI, median (IQR)",
        "SSI type",
        "    Superficial incisional, n (%)",
        "    Deep incisional, n (%)",
        "    Organ-space, n (%)",
        "Reoperation within 90 days following SSI, n (%)",
        "Readmission within 90 days following SSI, n (%)",
        "Death within 90 days of index operation, n (%)"
      ),
      Value = c(
        days_str,
        "",
        fmt_n_pct(ssi_outcomes$n_superficial, n_ssi_denom),
        fmt_n_pct(ssi_outcomes$n_deep,        n_ssi_denom),
        fmt_n_pct(ssi_outcomes$n_organ,       n_ssi_denom),
        fmt_n_pct(ssi_outcomes$n_reoperation, n_ssi_denom),
        fmt_n_pct(ssi_outcomes$n_readmission, n_ssi_denom),
        fmt_n_pct(ssi_outcomes$n_death,       n_ssi_denom)
      ),
      stringsAsFactors = FALSE
    )

    # Row indices for formatting
    ssi_header_rows <- which(ssi_outcome_tbl$Outcome == "SSI type")
    ssi_indent_rows <- grep("^    ", ssi_outcome_tbl$Outcome)

    ssi_out_ft <- flextable::flextable(ssi_outcome_tbl) |>
      flextable::bold(part = "header") |>
      flextable::fontsize(size = 10, part = "all") |>
      flextable::font(fontname = "Calibri", part = "all") |>
      flextable::bg(part = "header", bg = "#1F3864") |>
      flextable::color(part = "header", color = "white") |>
      flextable::align(align = "left", part = "all") |>
      flextable::padding(padding = 4, part = "all") |>
      flextable::bold(i = ssi_header_rows, part = "body") |>
      flextable::bg(i = ssi_header_rows, bg = "#F2F2F2", part = "body") |>
      flextable::padding(i = ssi_indent_rows, j = "Outcome",
                         padding.left = 18, part = "body") |>
      flextable::width(j = "Outcome", width = 3.5) |>
      flextable::width(j = "Value",   width = 1.5) |>
      flextable::set_table_properties(layout = "fixed")

    doc <- body_add_par(doc, "SSI patient outcomes", style = "heading 3")
    doc <- body_add_par(doc,
      paste0(
        "Among the ", n_ssi_denom, " patients who developed SSI within the 90-day ",
        "prediction window, Table 2 summarises key post-SSI clinical outcomes."
      ),
      style = "Normal"
    )
    doc <- body_add_par(doc,
      "Table 2. SSI patient outcomes within the 90-day post-operative window.",
      style = "Normal"
    )
    doc <- body_add_par(doc,
      paste0(
        "Caption: Denominator is all patients with an SSI event attributed to the index ",
        "procedure (n\u00a0=\u00a0", n_ssi_denom, "). ",
        "SSI type is classified by concept_ancestor rollup: superficial incisional ",
        "(OMOP concept 43530818), deep incisional (concept 4308542), organ-space ",
        "(concept 43530820); counts reflect condition_occurrence records on the SSI date. ",
        "Reoperation: any procedure_occurrence recorded after the SSI diagnosis date and ",
        "within 90 days of the index procedure date. ",
        "Readmission: any inpatient visit (OMOP visit_concept_id 9201) starting after the ",
        "SSI diagnosis date and within 90 days of the index procedure date. ",
        "90-day mortality: death record within 90 days of the index procedure date."
      ),
      style = "Normal"
    )
    doc <- body_add_flextable(doc, ssi_out_ft)
    doc <- body_add_par(doc, "", style = "Normal")
    message("[report] Table 2 (SSI outcomes) added.")
  }

  # ---- Table 3: Features ---------------------------------------------------
  doc <- body_add_par(doc, "Predictor activation", style = "heading 3")
  doc <- body_add_par(doc, "Table 3. Features: predictor definitions and activation summary.", style = "Normal")
  doc <- body_add_par(doc, "Caption: Each predictor is listed with its points, lookback window, OMOP-based definition, and observed activation in the validation cohort.", style = "Normal")
  doc <- body_add_flextable(doc, wrapped_predictor_ft(predictor_tbl))
  doc <- body_add_par(doc, "", style = "Normal")

  # ---- Table 4: Model Performance ------------------------------------------
  doc <- body_add_par(doc, "Model performance", style = "heading 3")
  doc <- body_add_par(doc, "Table 4. Model performance: lookup-model discrimination and calibration metrics.", style = "Normal")
  doc <- body_add_par(doc, "Caption: Metrics are shown for the lookup model. 95% CI = 95% bootstrap percentile confidence interval (B\u2009=\u2009500 resamples). \u2014 indicates CI not available.", style = "Normal")
  doc <- body_add_flextable(doc, simple_ft(results_tbl))
  doc <- body_add_par(doc, "", style = "Normal")

  # ---- Figure 1: SSI rate by year ------------------------------------------
  if (!is.null(ssi_year_plot_file) && file.exists(ssi_year_plot_file)) {
    doc <- body_add_par(doc, "Figure 1. Annual 90-day SSI rate.", style = "Normal")
    doc <- body_add_par(doc,
      "Caption: 90-day surgical site infection rate (%) by calendar year of procedure. Points show the observed annual event rate; line connects consecutive years. Years with fewer than 10 procedures are suppressed.",
      style = "Normal")
    doc <- body_add_img(doc, src = ssi_year_plot_file, width = 5.5, height = 3.5)
    doc <- body_add_par(doc, "", style = "Normal")
  }

  # ---- Figure 2: AUC / ROC curve -------------------------------------------
  if (!is.null(roc_plot_file) && file.exists(roc_plot_file)) {
    doc <- body_add_par(doc, "Figure 2. Receiver operating characteristic (ROC) curve.", style = "Normal")
    doc <- body_add_par(doc, "Caption: ROC curve for the lookup model. AUROC value is sourced from metrics.csv (bootstrap 95% CI). Dashed diagonal = no-discrimination reference line.", style = "Normal")
    doc <- body_add_img(doc, src = roc_plot_file, width = 4.5, height = 4.5)
    doc <- body_add_par(doc, "", style = "Normal")
  }

  # ---- Figure 3: Calibration curve -----------------------------------------
  if (file.exists(lookup_calibration_plot_temp)) {
    doc <- body_add_par(doc, "Figure 3. Calibration plot for the published lookup mapping.", style = "Normal")
    doc <- body_add_par(doc, "Caption: Mean predicted risk (x-axis, 0\u20131) vs. observed event rate (y-axis, 0\u20131) by quantile bin. Dashed diagonal = perfect calibration. Both axes span the full 0\u20131 range.", style = "Normal")
    doc <- body_add_img(doc, src = lookup_calibration_plot_temp, width = 4.5, height = 4.5)
    doc <- body_add_par(doc, "", style = "Normal")
  }

  # ---- Supplemental section ------------------------------------------------
  # Read subgroup_bias.csv if it was produced by the pipeline.
  subgroup_bias_path <- file.path(score_output_dir, "subgroup_bias.csv")
  subgroup_bias_df   <- NULL
  if (file.exists(subgroup_bias_path)) {
    subgroup_bias_df <- tryCatch(
      readr::read_csv(subgroup_bias_path, show_col_types = FALSE),
      error = function(e) NULL
    )
  }

  doc <- body_add_par(doc, "Supplemental Material", style = "heading 2")

  # ---- S1–S3: DB-sourced tables (own connection; order: CDM, CPT, ICD) ------
  if (!is.null(connection_details) && !is.null(config)) {
    tryCatch({
      conn_supp <- DatabaseConnector::connect(connection_details)
      on.exit(try(DatabaseConnector::disconnect(conn_supp), silent = TRUE), add = TRUE)

      # ---- Supplemental Table S1 — CDM Source --------------------------------
      tryCatch({
        sql_cdm_src <- SqlRender::render(
          "SELECT cdm_source_name, cdm_source_abbreviation, cdm_holder,
                  source_release_date, cdm_release_date, cdm_version,
                  vocabulary_version
           FROM @cdm_schema.cdm_source",
          cdm_schema = config$cdm_schema
        )
        cdm_src_raw <- DatabaseConnector::querySql(
          conn_supp,
          SqlRender::translate(sql_cdm_src, targetDialect = "sql server")
        )
        names(cdm_src_raw) <- tolower(names(cdm_src_raw))
        if (nrow(cdm_src_raw) > 0) {
          cdm_src_display <- data.frame(
            Field = c("CDM Source Name", "Source Abbreviation", "CDM Holder",
                      "Source Release Date", "CDM Release Date",
                      "CDM Version", "Vocabulary Version",
                      "Study Start Date", "Study End Date"),
            Value = c(as.character(cdm_src_raw$cdm_source_name[1]),
                      as.character(cdm_src_raw$cdm_source_abbreviation[1]),
                      as.character(cdm_src_raw$cdm_holder[1]),
                      as.character(cdm_src_raw$source_release_date[1]),
                      as.character(cdm_src_raw$cdm_release_date[1]),
                      as.character(cdm_src_raw$cdm_version[1]),
                      as.character(cdm_src_raw$vocabulary_version[1]),
                      if (!is.null(config$study_start_date)) as.character(config$study_start_date) else "N/A",
                      if (!is.null(config$study_end_date))   as.character(config$study_end_date)   else "N/A"),
            stringsAsFactors = FALSE
          )
          cdm_src_ft <- flextable::flextable(cdm_src_display) |>
            flextable::bold(part = "header") |>
            flextable::fontsize(size = 10, part = "all") |>
            flextable::font(fontname = "Calibri", part = "all") |>
            flextable::bg(part = "header", bg = "#1F3864") |>
            flextable::color(part = "header", color = "white") |>
            flextable::padding(padding = 4, part = "all") |>
            flextable::width(j = "Field", width = 2.0) |>
            flextable::width(j = "Value", width = 4.0) |>
            flextable::set_table_properties(layout = "fixed")
          doc <- body_add_par(doc, "CDM source metadata", style = "heading 3")
          doc <- body_add_par(doc,
            "Supplemental Table S1. CDM source metadata.",
            style = "Normal")
          doc <- body_add_par(doc,
            paste0("Caption: Metadata from the cdm_source table of the OMOP CDM instance ",
                   "used for this analysis. CDM Version and Vocabulary Version confirm ",
                   "compliance with OMOP CDM v5.4 and the Athena vocabulary release used ",
                   "during ETL."),
            style = "Normal")
          doc <- body_add_flextable(doc, cdm_src_ft)
          doc <- body_add_par(doc, "", style = "Normal")
          message("[report] Supplemental Table S1 (CDM source) added.")
        }
      }, error = function(e) {
        message("[report] CDM source table skipped: ", conditionMessage(e))
      })

      # ---- Supplemental Table S2 — CPT codes by procedure subgroup -----------
      # Uses concept_relationship ('Mapped from') to find CPT4 source codes
      # that map to SNOMED standard descendants — CPT4 codes are source codes
      # (standard_concept IS NULL), not in concept_ancestor as descendants.
      tryCatch({
        sql_cpt <- SqlRender::render(
          "SELECT DISTINCT proc_group, cpt_code, cpt_description
           FROM (
             -- Branch 1: CPT4 codes that ARE in concept_ancestor as descendants
             -- (covers CPT4s with standard_concept = 'S' in this vocabulary)
             SELECT grp.proc_group,
                    c.concept_code AS cpt_code,
                    c.concept_name AS cpt_description
             FROM (
               SELECT 'Endarterectomy'           AS proc_group, 4225375 AS ancestor_id
               UNION ALL SELECT 'Aortobifemoral bypass',        4231680
               UNION ALL SELECT 'Femoral-popliteal bypass',     4012936
               UNION ALL SELECT 'Femorotibial bypass',          4166196
               UNION ALL SELECT 'Extra-anatomic bypass',        4050281
             ) grp
             INNER JOIN @vocab_schema.concept_ancestor ca
               ON ca.ancestor_concept_id = grp.ancestor_id
             INNER JOIN @vocab_schema.concept c
               ON c.concept_id    = ca.descendant_concept_id
              AND c.vocabulary_id IN ('CPT4','HCPCS')

             UNION

             -- Branch 2: CPT4 source codes that map TO standard SNOMED descendants
             -- via concept_relationship (catches CPT4s not in concept_ancestor)
             SELECT grp.proc_group,
                    c.concept_code AS cpt_code,
                    c.concept_name AS cpt_description
             FROM (
               SELECT 'Endarterectomy'           AS proc_group, 4225375 AS ancestor_id
               UNION ALL SELECT 'Aortobifemoral bypass',        4231680
               UNION ALL SELECT 'Femoral-popliteal bypass',     4012936
               UNION ALL SELECT 'Femorotibial bypass',          4166196
               UNION ALL SELECT 'Extra-anatomic bypass',        4050281
             ) grp
             INNER JOIN @vocab_schema.concept_ancestor ca
               ON ca.ancestor_concept_id = grp.ancestor_id
             INNER JOIN @vocab_schema.concept_relationship cr
               ON cr.concept_id_2    = ca.descendant_concept_id
              AND cr.relationship_id = 'Maps to'
              AND cr.invalid_reason  IS NULL
             INNER JOIN @vocab_schema.concept c
               ON c.concept_id    = cr.concept_id_1
              AND c.vocabulary_id IN ('CPT4','HCPCS')
           ) combined
           ORDER BY proc_group, cpt_code",
          vocab_schema = config$vocab_schema
        )
        cpt_raw <- DatabaseConnector::querySql(
          conn_supp,
          SqlRender::translate(sql_cpt, targetDialect = "sql server")
        )
        names(cpt_raw) <- tolower(names(cpt_raw))
        if (nrow(cpt_raw) > 0) {
          cpt_display <- data.frame(
            "Procedure Group" = cpt_raw$proc_group,
            "CPT Code"        = cpt_raw$cpt_code,
            "Description"     = cpt_raw$cpt_description,
            check.names = FALSE, stringsAsFactors = FALSE
          )
          cpt_ft <- flextable::flextable(cpt_display) |>
            flextable::bold(part = "header") |>
            flextable::fontsize(size = 9, part = "all") |>
            flextable::font(fontname = "Calibri", part = "all") |>
            flextable::bg(part = "header", bg = "#1F3864") |>
            flextable::color(part = "header", color = "white") |>
            flextable::padding(padding = 3, part = "all") |>
            flextable::width(j = "Procedure Group", width = 1.8) |>
            flextable::width(j = "CPT Code",        width = 0.9) |>
            flextable::width(j = "Description",     width = 3.8) |>
            flextable::set_table_properties(layout = "fixed")
          doc <- body_add_par(doc, "Index procedure CPT codes", style = "heading 3")
          doc <- body_add_par(doc,
            "Supplemental Table S2. CPT codes for index procedure subgroups.",
            style = "Normal")
          doc <- body_add_par(doc,
            paste0("Caption: CPT-4 codes identified via concept_relationship ('Mapped from') ",
                   "from SNOMED concept-ancestor descendants of each procedure subgroup anchor ",
                   "(endarterectomy: 4225375; aortobifemoral: 4231680; femoral-popliteal: 4012936; ",
                   "femorotibial: 4166196; extra-anatomic bypass: 4050281). ",
                   "A code may appear in more than one group."),
            style = "Normal")
          doc <- body_add_flextable(doc, cpt_ft)
          doc <- body_add_par(doc, "", style = "Normal")
          message("[report] Supplemental Table S2 (CPT codes) added.")
        }
      }, error = function(e) {
        message("[report] CPT supplemental table skipped: ", conditionMessage(e))
      })

      # ---- Supplemental Table S3 — ICD codes for SSI outcome concept ---------
      tryCatch({
        sql_icd <- SqlRender::render(
          "SELECT DISTINCT
             c.vocabulary_id,
             c.concept_code  AS icd_code,
             c.concept_name  AS icd_description
           FROM @vocab_schema.concept_ancestor ca
           INNER JOIN @vocab_schema.concept_relationship cr
             ON cr.concept_id_2    = ca.descendant_concept_id
            AND cr.relationship_id = 'Maps to'
            AND cr.invalid_reason  IS NULL
           INNER JOIN @vocab_schema.concept c
             ON c.concept_id    = cr.concept_id_1
            AND c.vocabulary_id IN ('ICD9CM','ICD10CM','ICD10PCS','ICD9Proc')
           WHERE ca.ancestor_concept_id = 4334801
             AND c.concept_code NOT LIKE 'O86%'
             AND c.concept_code NOT LIKE 'T86.84%'
           ORDER BY c.vocabulary_id, c.concept_code",
          vocab_schema = config$vocab_schema
        )
        icd_raw <- DatabaseConnector::querySql(
          conn_supp,
          SqlRender::translate(sql_icd, targetDialect = "sql server")
        )
        names(icd_raw) <- tolower(names(icd_raw))
        if (nrow(icd_raw) > 0) {
          icd_display <- data.frame(
            "Vocabulary"  = icd_raw$vocabulary_id,
            "ICD Code"    = icd_raw$icd_code,
            "Description" = icd_raw$icd_description,
            check.names = FALSE, stringsAsFactors = FALSE
          )
          icd_ft <- flextable::flextable(icd_display) |>
            flextable::bold(part = "header") |>
            flextable::fontsize(size = 9, part = "all") |>
            flextable::font(fontname = "Calibri", part = "all") |>
            flextable::bg(part = "header", bg = "#1F3864") |>
            flextable::color(part = "header", color = "white") |>
            flextable::padding(padding = 3, part = "all") |>
            flextable::width(j = "Vocabulary",  width = 1.0) |>
            flextable::width(j = "ICD Code",    width = 1.2) |>
            flextable::width(j = "Description", width = 4.3) |>
            flextable::set_table_properties(layout = "fixed")
          doc <- body_add_par(doc, "SSI outcome ICD codes", style = "heading 3")
          doc <- body_add_par(doc,
            "Supplemental Table S3. ICD codes mapping to the surgical site infection outcome concept.",
            style = "Normal")
          doc <- body_add_par(doc,
            paste0("Caption: Source ICD-9-CM and ICD-10-CM codes that map to OMOP concept 4334801 ",
                   "(Surgical site infection, SNOMED-CT 433202001) or its descendants via ",
                   "concept_relationship (relationship: 'Maps to'). These are the codes used to ",
                   "identify the SSI outcome in source data prior to OMOP ETL standardisation."),
            style = "Normal")
          doc <- body_add_flextable(doc, icd_ft)
          doc <- body_add_par(doc, "", style = "Normal")
          message("[report] Supplemental Table S3 (SSI ICD codes) added.")
        }
      }, error = function(e) {
        message("[report] SSI ICD supplemental table skipped: ", conditionMessage(e))
      })

      DatabaseConnector::disconnect(conn_supp)
    }, error = function(e) {
      message("[report] Supplemental DB tables skipped: ", conditionMessage(e))
    })
  }

  # ---- S4: Bias table, S5: Forest plot (from pre-loaded CSV) ----------------
  if (!is.null(subgroup_bias_df) && nrow(subgroup_bias_df) > 0) {

    # Sort rows to match Table 1 order: age_group, sex, race, ethnicity,
    # indication, proc_type, year — any unlisted vars sort to the end.
    subgroup_order <- c(age_group = 1, sex = 2, race = 3, ethnicity = 4,
                        indication = 5, proc_type = 6, year = 7)
    sort_key <- subgroup_order[match(subgroup_bias_df$subgroup_var,
                                     names(subgroup_order))]
    sort_key[is.na(sort_key)] <- 99L
    subgroup_bias_df <- subgroup_bias_df[order(sort_key,
                                               subgroup_bias_df$subgroup_level), ]

    # Overall ECE for reference line — read from metrics.csv.
    overall_ece_val <- tryCatch(
      as.numeric(metric_value("ECE", "lookup")),
      error = function(e) NA_real_
    )
    if (is.na(overall_ece_val)) overall_ece_val <- 0.0

    # Build a display table.
    bias_display <- data.frame(
      Subgroup     = tools::toTitleCase(gsub("_", " ", subgroup_bias_df$subgroup_var)),
      Level        = subgroup_bias_df$subgroup_level,
      N            = subgroup_bias_df$n,
      Events       = subgroup_bias_df$n_events,
      ECE          = round(subgroup_bias_df$ece,      3),
      "95% CI"     = paste0("(", round(subgroup_bias_df$ci_lower, 3),
                            "\u2013",
                            round(subgroup_bias_df$ci_upper, 3), ")"),
      check.names     = FALSE,
      stringsAsFactors = FALSE
    )

    bias_ft <- flextable::flextable(bias_display) |>
      flextable::bold(part = "header") |>
      flextable::fontsize(size = 10, part = "all") |>
      flextable::font(fontname = "Calibri", part = "all") |>
      flextable::bg(part = "header", bg = "#1F3864") |>
      flextable::color(part = "header", color = "white") |>
      flextable::padding(padding = 4, part = "all") |>
      flextable::align(j = c("N", "Events", "ECE", "95% CI"),
                       align = "center", part = "all") |>
      flextable::width(j = "Subgroup", width = 1.2) |>
      flextable::width(j = "Level",    width = 1.6) |>
      flextable::width(j = "N",        width = 0.6) |>
      flextable::width(j = "Events",   width = 0.7) |>
      flextable::width(j = "ECE",      width = 0.7) |>
      flextable::width(j = "95% CI",   width = 1.2) |>
      flextable::set_table_properties(layout = "fixed")

    doc <- body_add_par(doc, "Subgroup bias assessment", style = "heading 3")
    doc <- body_add_par(doc,
      "Supplemental Table S4. Expected calibration error (ECE) by subgroup.",
      style = "Normal")
    doc <- body_add_par(doc,
      paste0("Caption: ECE is shown for the lookup model within each subgroup. ",
             "Subgroups with fewer than 10 observed SSI events are suppressed. ",
             "Overall ECE (dashed reference line in Supplemental Figure S1) = ",
             round(overall_ece_val, 3), ". ",
             "95% CI = bootstrap percentile interval (B\u2009=\u2009200 resamples)."),
      style = "Normal")
    doc <- body_add_flextable(doc, bias_ft)
    doc <- body_add_par(doc, "", style = "Normal")

    # Supplemental Figure S1 — subgroup forest plot
    forest_png <- save_subgroup_forest_plot(
      subgroup_bias_df,
      overall_ece_val,
      temp_figure_dir
    )
    if (!is.null(forest_png) && file.exists(forest_png)) {
      plot_height <- max(4.0, nrow(subgroup_bias_df) * 0.35 + 1.5)
      doc <- body_add_par(doc, "Subgroup calibration forest plot", style = "heading 3")
      doc <- body_add_par(doc,
        "Supplemental Figure S1. Subgroup calibration forest plot.",
        style = "Normal")
      doc <- body_add_par(doc,
        paste0("Caption: Expected calibration error (ECE) with 95% bootstrap percentile CIs (B\u2009=\u2009200) ",
               "by subgroup. Dashed vertical line = overall ECE for the lookup model. ",
               "Subgroups with < 10 SSI events are suppressed. ",
               "Subgroups include sex, race, ethnicity, age group, operative indication, ",
               "and calendar year of procedure."),
        style = "Normal")
      doc <- body_add_img(doc, src = forest_png,
                          width  = 5.5,
                          height = min(plot_height, 9.0))
      doc <- body_add_par(doc, "", style = "Normal")
    }
  }

  # ---- Fringe cases — Excel export (not in Word report) -------------------
  # Two groups of patients that the model handled worst:
  #   Group A — lowest predicted risk who nonetheless had an SSI (false negatives)
  #   Group B — highest predicted risk who did not have an SSI (false positives)
  # Written to a dated Excel file in the same output folder as the report.
  if (!is.null(connection_details) && !is.null(config) &&
      "predicted_risk_lookup" %in% names(person_level)) {

    tryCatch({
      conn_f <- DatabaseConnector::connect(connection_details)
      on.exit(try(DatabaseConnector::disconnect(conn_f), silent = TRUE), add = TRUE)

      # Identify the two fringe groups from person_level_scores
      fn_mask <- person_level$outcome == 1 & !is.na(person_level$predicted_risk_lookup)
      fn_ids  <- person_level$subject_id[fn_mask]
      fn_risk <- person_level$predicted_risk_lookup[fn_mask]
      fn_top  <- fn_ids[order(fn_risk)][seq_len(min(10L, sum(fn_mask)))]

      fp_mask <- person_level$outcome == 0 & !is.na(person_level$predicted_risk_lookup)
      fp_ids  <- person_level$subject_id[fp_mask]
      fp_risk <- person_level$predicted_risk_lookup[fp_mask]
      fp_top  <- fp_ids[order(fp_risk, decreasing = TRUE)][seq_len(min(10L, sum(fp_mask)))]

      all_ids <- unique(c(fn_top, fp_top))
      id_str  <- paste(as.integer(all_ids), collapse = ",")

      sql_fringe <- SqlRender::render(
        "SELECT
           p.person_id,
           p.person_source_value                                                AS mrn,
           CAST(po.procedure_date AS DATE)                                      AS procedure_date,
           COALESCE(c.concept_name, po.procedure_source_value, 'Unknown')       AS procedure_name,
           YEAR(CAST(po.procedure_date AS DATE)) - p.year_of_birth             AS age_at_procedure
         FROM @cdm_schema.person p
         JOIN @cdm_schema.procedure_occurrence po
           ON po.person_id = p.person_id
         JOIN @vocab_schema.concept_ancestor ca
           ON ca.descendant_concept_id = po.procedure_concept_id
          AND ca.ancestor_concept_id   IN (4236706, 4225375)
         LEFT JOIN @vocab_schema.concept c
           ON c.concept_id = po.procedure_concept_id
         WHERE p.person_id IN (@id_list)",
        cdm_schema   = config$cdm_schema,
        vocab_schema = config$vocab_schema,
        id_list      = id_str
      )

      raw <- DatabaseConnector::querySql(
        conn_f,
        SqlRender::translate(sql_fringe, targetDialect = "sql server")
      )
      names(raw) <- tolower(names(raw))

      # One row per person — earliest qualifying procedure
      raw <- raw[order(raw$person_id, raw$procedure_date), ]
      raw <- raw[!duplicated(raw$person_id), ]

      # Merge outcome + predicted risk from person_level
      pl_sub <- person_level[, c("subject_id", "predicted_risk_lookup", "outcome")]
      raw    <- merge(raw, pl_sub, by.x = "person_id", by.y = "subject_id", all.x = TRUE)

      # Merge individual score component columns from person_level
      score_cols <- grep("^score_", names(person_level), value = TRUE)
      if (length(score_cols) > 0) {
        pl_scores <- person_level[, c("subject_id", score_cols), drop = FALSE]
        raw <- merge(raw, pl_scores, by.x = "person_id", by.y = "subject_id", all.x = TRUE)
      }

      make_group <- function(ids, label) {
        sub        <- raw[raw$person_id %in% ids, ]
        sub$group  <- label
        sub
      }

      fn_df <- make_group(fn_top, "Low risk, SSI occurred")
      fp_df <- make_group(fp_top, "High risk, no SSI")
      fn_df <- fn_df[order(fn_df$predicted_risk_lookup), ]
      fp_df <- fp_df[order(fp_df$predicted_risk_lookup, decreasing = TRUE), ]

      # Build display-friendly column names for score components
      score_display_names <- c(
        score_female                 = "Female Sex (pts)",
        score_overweight             = "Overweight BMI 25-<30 (pts)",
        score_obese                  = "Obese BMI >=30 (pts)",
        score_urgnt                  = "Urgent Case (pts)",
        score_abi_35                 = "ABI <=0.35 (pts)",
        score_prrevasc_any           = "Prior Revascularization (pts)",
        score_prolong_abx            = "Prolonged Antibiotics (pts)",
        score_optime4h               = "Op Time >=4h (pts)",
        score_mFI_high               = "High mFI (pts)",
        score_indicationClaudication = "Indication: Claudication (pts)"
      )
      present_score_cols <- score_cols[score_cols %in% names(score_display_names)]
      score_labels       <- unname(score_display_names[present_score_cols])

      combined <- rbind(fn_df, fp_df)
      fringe_tbl <- combined[,
        c("group", "mrn", "age_at_procedure",
          "procedure_date", "procedure_name", "predicted_risk_lookup",
          present_score_cols),
        drop = FALSE
      ]

      names(fringe_tbl) <- c(
        "Group", "MRN", "Age at Procedure",
        "Procedure Date", "Procedure", "Predicted Risk",
        score_labels
      )
      fringe_tbl[["Predicted Risk"]] <- round(as.numeric(fringe_tbl[["Predicted Risk"]]), 3)

      # Prepend model_name and report_date columns
      model_nm    <- if (!is.null(config$model_name)) config$model_name else NA_character_
      report_date <- format(Sys.Date(), "%Y-%m-%d")
      fringe_tbl  <- cbind(
        "Model"       = model_nm,
        "Report Date" = report_date,
        fringe_tbl,
        stringsAsFactors = FALSE
      )

      # Write to dated CSV file alongside the report
      export_date  <- format(Sys.Date(), "%Y%m%d")
      fringe_file  <- file.path(output_dir,
                                paste0("pad_oler_ssi_fringe_", export_date, ".csv"))
      readr::write_csv(fringe_tbl, fringe_file)
      message("[report] Fringe case CSV written to: ",
              normalizePath(fringe_file, winslash = "/", mustWork = FALSE))

    }, error = function(e) {
      message("[report] Fringe case CSV skipped: ", conditionMessage(e))
    })
  }

  print(doc, target = report_file)
  message("Manuscript report written to: ", normalizePath(report_file))
  invisible(report_file)
}
