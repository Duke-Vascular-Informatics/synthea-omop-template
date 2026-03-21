# R/report.R
# Generates a Word-format output report for the PAD / OLER SSI risk score
# external validation study.
#
# Dependencies: officer, flextable  (installed via renv)
# Entry point:  run_report.R

library(officer)
library(flextable)

# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

.component_table_data <- function() {
  data.frame(
    variable = c(
      "Female sex",
      "Overweight (BMI 25 to <30)",
      "Obese (BMI \u226530)",
      "Urgent / emergency case",
      "Low ankle-brachial index (ABI \u22640.35)",
      "Prior revascularization (any)",
      "Prolonged antibiotic exposure",
      "Operative time \u22654 hours",
      "High modified Frailty Index (mFI)",
      "Indication: claudication"
    ),
    points = c(
      "+1", "+1", "+3", "+1", "+1",
      "+1", "+2", "+1", "+1", "\u22121"
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
      # female
      paste0(
        "Concept 8532 (Female) matched to person.gender_concept_id. ",
        "No lookback required; demographic attribute."
      ),
      # overweight
      paste0(
        "OMOP measurements: weight concept 3025315 and height concept 3036277. ",
        "BMI computed as weight (kg) / height (m)\u00b2. ",
        "Flagged when 25 \u2264 BMI < 30."
      ),
      # obese
      paste0(
        "Same weight (3025315) and height (3036277) measurements as Overweight. ",
        "Flagged when BMI \u2265 30. Mutually exclusive with Overweight."
      ),
      # urgnt
      paste0(
        "Concepts 4158569 (Emergency procedure) and 4250892 (Urgent procedure), ",
        "plus all descendants via concept_ancestor, in procedure_occurrence or ",
        "observation within 30 days before or on the index date."
      ),
      # abi_35
      paste0(
        "Concepts 40489833 and 46237026 (ABI measurement), plus descendants, in ",
        "the measurement table. Record is counted when value_as_number < 0.35."
      ),
      # prrevasc_any
      paste0(
        "Concept 4159960 (lower-extremity revascularization procedure) and all ",
        "descendants in procedure_occurrence. Captures any prior endovascular or ",
        "open revascularisation within a 10-year lookback."
      ),
      # prolong_abx
      paste0(
        "Concept 21603553 (systemic antibiotic agent) and descendants in ",
        "drug_exposure. Counted when drug_exposure_start_date \u2264 index \u2212 1 day ",
        "and total exposure duration > 2 days (non-prophylactic heuristic)."
      ),
      # optime4h
      paste0(
        "Operative duration derived from procedure_occurrence: ",
        "DATEDIFF(MINUTE, procedure_start_datetime, procedure_end_datetime) > 240. ",
        "Supplemented by measurement-table operative-time concepts when available."
      ),
      # mFI_high
      paste0(
        "Composite index of 5 sub-components: diabetes (201820), COPD (255573), ",
        "congestive heart failure (316139), hypertension (316866), and functional ",
        "status impairment (4215267), each with descendants in condition_occurrence. ",
        "Flagged when \u22652 conditions are present (mFI score > 0.25)."
      ),
      # indicationClaudication
      paste0(
        "Concept 442774 (Intermittent claudication) and descendants in ",
        "condition_occurrence. Negative point value \u2014 claudication as the ",
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

# ---------------------------------------------------------------------------
# Public function
# ---------------------------------------------------------------------------

#' Generate the Word validation report
#'
#' @param output_dir  Path to write the .docx file (created if absent).
#' @return Invisibly returns the output file path.
generate_word_report <- function(output_dir = "output/risk_score_eval") {

  if (!dir.exists(output_dir)) dir.create(output_dir, recursive = TRUE)

  doc <- read_docx()

  # ---- Title ---------------------------------------------------------------
  doc <- body_add_par(doc, "PAD / OLER \u2014 Surgical Site Infection Risk Score",
                      style = "heading 1")
  doc <- body_add_par(doc, "External Validation Report", style = "heading 1")
  doc <- body_add_par(doc, "", style = "Normal")

  # ---- 1. Project Summary --------------------------------------------------
  doc <- body_add_par(doc, "1.  Project Summary", style = "heading 2")
  doc <- body_add_par(doc,
    paste0(
      "This report presents the external validation of an integer-based surgical site ",
      "infection (SSI) prediction model in patients with peripheral arterial disease (PAD) ",
      "undergoing lower-extremity vascular surgery. The model was originally developed from ",
      "retrospective administrative data and assigns integer point values to ten pre-operative ",
      "and intra-operative risk factors. The sum of these points maps to a published 30-day ",
      "SSI probability via a risk-lookup table."
    ),
    style = "Normal"
  )
  doc <- body_add_par(doc,
    paste0(
      "Validation was performed against a Synthea-generated OMOP CDM v5 SQL Server database ",
      "(\u2018omop_synth\u2019, schema \u2018cdm_synthea\u2019) using the OHDSI PatientLevelPrediction ",
      "framework (v6.4.0). Bespoke risk-score extraction functions were built on top of ",
      "DatabaseConnector and SqlRender to map each model component to its corresponding OMOP ",
      "standard concepts."
    ),
    style = "Normal"
  )
  doc <- body_add_par(doc, "", style = "Normal")

  # ---- 2. Methods ----------------------------------------------------------
  doc <- body_add_par(doc, "2.  Methods", style = "heading 2")

  doc <- body_add_par(doc, "2.1  Study Population", style = "heading 3")
  doc <- body_add_par(doc,
    paste0(
      "The target cohort consisted of adults (\u226518 years) with a recorded diagnosis of ",
      "peripheral arterial disease who underwent a lower-extremity vascular procedure as ",
      "captured in the OMOP CDM. The outcome cohort identified 30-day post-operative SSI ",
      "events using OMOP condition-occurrence concepts. Both cohort definitions are stored ",
      "under \u2018cohorts/\u2019 as SqlRender-parameterised SQL templates compatible with OMOP CDM v5."
    ),
    style = "Normal"
  )

  doc <- body_add_par(doc, "2.2  Risk Score Computation", style = "heading 3")
  doc <- body_add_par(doc,
    paste0(
      "Each component of the risk score was extracted from the OMOP CDM using standard ",
      "concept IDs with optional descendant expansion via the concept_ancestor table. ",
      "Component event counts were aggregated per person over component-specific lookback ",
      "windows relative to the index procedure date. A person meeting the minimum event ",
      "threshold for a component received the full point value for that component; those ",
      "below the threshold received zero. Missing component data (no matching records in the ",
      "OMOP CDM) was treated as zero evidence. The total risk score is the arithmetic sum of ",
      "all component point values and can range from \u22121 to +12."
    ),
    style = "Normal"
  )

  doc <- body_add_par(doc, "2.3  Performance Evaluation", style = "heading 3")
  doc <- body_add_par(doc,
    paste0(
      "Discrimination was assessed using the area under the receiver operating characteristic ",
      "curve (AUROC) and the area under the precision-recall curve (AUPRC). Calibration was ",
      "evaluated using two probability scales: (1) lookup-based probabilities from the ",
      "published score-to-risk table, and (2) recalibrated probabilities derived from a ",
      "logistic regression of total score on observed 30-day outcome. Calibration-in-the-large ",
      "and calibration plots are included as supplementary outputs."
    ),
    style = "Normal"
  )
  doc <- body_add_par(doc, "", style = "Normal")

  # ---- 3. Table 1 ----------------------------------------------------------
  doc <- body_add_par(doc, "3.  Risk Model Variables", style = "heading 2")
  doc <- body_add_par(doc,
    paste0(
      "Table 1 lists the ten components of the PAD SSI integer risk score, the point value ",
      "assigned to each, the lookback window applied, and the OMOP concept-based derivation ",
      "method used in this validation."
    ),
    style = "Normal"
  )
  doc <- body_add_par(doc,
    "Table 1.  PAD SSI risk score components, point values, and OMOP CDM derivation.",
    style = "Normal"
  )
  doc <- body_add_flextable(doc, .build_table1(.component_table_data()))

  # ---- Write output --------------------------------------------------------
  out_path <- file.path(output_dir, "ssi_validation_report.docx")
  print(doc, target = out_path)
  message("Report written to: ", normalizePath(out_path))
  invisible(out_path)
}
