#!/usr/bin/env Rscript
# Step 3: Generate disease-specific Synthea module artifacts (diagram and validation checks).
#
# PURPOSE
# -------
# Validates the Synthea GMF module (synthea/modules/pad_ssi.json) and regenerates the
# HTML state-diagram viewer. The HTML file is the primary artefact for SME review —
# open it in any browser to inspect every state, its type, and its clinical codes.
#
# CLINICAL SME REVIEW WORKFLOW
# -----------------------------
# The JSON module encodes both the simulation logic and all clinical code assignments.
# Reviewers should work through the following questions with a vascular surgery /
# infectious disease SME before data generation is finalised:
#
#   1. STATE FLOW
#      - Does the pathway order (PAD onset → comorbidities → workup → index surgery →
#        post-op delay → SSI risk check → SSI management) reflect real clinical practice?
#      - Are the branching probabilities (claudication 70%, smoking 35%, diabetes 30%,
#        obesity 40%, SSI high/moderate/baseline 12/10/6%) defensible from the
#        literature or institutional data?
#      - Should the urgent-case branch (25%) influence SSI risk probability?
#
#   2. CONDITION / PROCEDURE CODES
#      - PAD          : SNOMED 399957001  "Peripheral arterial occlusive disease"
#      - Claudication : SNOMED 266261006  "Intermittent claudication"
#      - Diabetes T2  : SNOMED 44054006   "Diabetes mellitus type 2"
#      - Hypertension : SNOMED 38341003   "Hypertensive disorder, systemic arterial"
#      - COPD         : SNOMED 13645005   "Chronic obstructive lung disease"
#      - CHF          : SNOMED 84114007   "Heart failure"
#      - Impaired mob.: SNOMED 129839007  "Impaired mobility"
#      - Index proc.  : SNOMED 232723009  "Bypass of femoral artery to popliteal artery"
#      - SSI          : SNOMED 76844004   "Infection of surgical wound"
#      - Debridement  : SNOMED 118294005  "Debridement"
#      Are these the correct OMOP standard concept codes for your institution's CDM?
#      If additional procedure variants (aortofemoral bypass SNOMED 174814006,
#      femoral endarterectomy SNOMED 85356008) should be included, add them to
#      the module and re-run this step.
#
#   3. OBSERVATION / MEASUREMENT CODES
#      - ABI           : LOINC  59574-4   "Ankle-brachial index" (range 0.30–0.85)
#      - Smoking status: LOINC  72166-2   "Tobacco smoking status"
#        - Current smoker value : SNOMED 449868002
#        - Never smoked value   : SNOMED 266919005
#      - BMI           : LOINC  39156-5   "Body Mass Index"
#      - Height        : LOINC  8302-2    "Body height"
#      - Weight        : LOINC  29463-7   "Body weight"
#      - Wound culture : LOINC  6463-4    "Bacteria identified in Wound by Culture"
#        - Organism value       : SNOMED 112283007 "Escherichia coli"
#      - Urgency flag  : SNOMED 25876001  "Emergency operation"
#      Confirm value ranges and vocabulary mappings are consistent with your CDM.
#
#   4. MEDICATION CODES
#      - Prophylactic cefazolin : RxNorm 20496  "cefazolin"
#      - SSI treatment cephalexin: RxNorm 2673  "cephalexin"
#        (pre-index non-prophylaxis antibiotic uses the same RxNorm code)
#      Confirm these map to your institution's drug concepts.
#
#   5. TIMING PARAMETERS
#      - Pre-surgical workup delay and prior-revasc recovery are currently 0 days
#        (same-encounter modelling). Adjust range in the JSON if your CDM requires
#        distinct encounter dates for workup vs. index surgery.
#      - SSI onset window: 5–25 days post-discharge (8–32 days post-surgery).
#        Verify this is compatible with the 30-day outcome window in the cohort definition.
#
# HOW TO REVISE
# -------------
#   1. Edit synthea/modules/pad_ssi.json directly (state types, codes, probabilities,
#      timing ranges) based on SME feedback.
#   2. Re-run this step to regenerate the diagram:
#        Rscript workflow/03_generate_synthea_module_artifacts.R
#   3. Open synthea/modules/pad_ssi.diagram.html in a browser to review the updated flow.
#   4. Repeat until the SME signs off on the module.
#   5. Proceed to Step 4 (generate Synthea CSV) only after sign-off.

# -----------------------------------------------------------------------------
# Chunk 1 - Workflow bootstrap
# Purpose:
# Resolve and source the shared workflow bootstrap helper, then normalize the
# working directory to the repository root.
# Code path notes:
# - If script is executed via Rscript, parse --file= to resolve helper path.
# - If sourced interactively, fall back to project-relative helper path.
# -----------------------------------------------------------------------------
bootstrap_path <- local({
  file_arg <- grep("^--file=", commandArgs(trailingOnly = FALSE), value = TRUE)
  if (length(file_arg) > 0) {
    normalizePath(
      file.path(dirname(sub("^--file=", "", file_arg[1])), "workflow_bootstrap.R"),
      winslash = "/",
      mustWork = FALSE
    )
  } else {
    "workflow/workflow_bootstrap.R"
  }
})
source(bootstrap_path)
set_workflow_root()

# -----------------------------------------------------------------------------
# Chunk 2 - Dependency guard for jsonlite
# Purpose:
# Ensure the JSON parser package is present before attempting to read the module
# artifact. This is a hard stop because all downstream logic depends on it.
# Code path notes:
# - Success: continue.
# - Failure: stop immediately with install guidance.
# -----------------------------------------------------------------------------
if (!requireNamespace("jsonlite", quietly = TRUE)) {
  stop("Package 'jsonlite' is required. Install via renv first.")
}

# -----------------------------------------------------------------------------
# Chunk 3 - Module artifact existence and structural checks
# Purpose:
# Validate the core input artifact and confirm the expected Synthea structure.
# Code path notes:
# - Missing file: stop with path-specific error.
# - Empty / malformed states collection: stop (cannot run coverage checks).
# - Valid structure: proceed to concept coverage evaluation.
# -----------------------------------------------------------------------------
module_path <- "synthea/modules/pad_ssi.json"
if (!file.exists(module_path)) {
  stop("Missing module file: ", module_path)
}

module <- jsonlite::fromJSON(module_path, simplifyVector = FALSE)
if (is.null(module$states) || length(module$states) == 0) {
  stop("Synthea module has no states: ", module_path)
}

# ---------------------------------------------------------------------------
# COHORT / COVARIATE COVERAGE CHECK
# ---------------------------------------------------------------------------
# Verify that every concept required by the cohort definitions and risk-score
# covariate spec is represented by at least one state in the module JSON.
# Failures are printed as warnings so the script still completes (allowing the
# HTML to be generated for SME review), but a summary count of missing concepts
# is reported so nothing is silently skipped.
#
# Required concepts come from three sources:
#   1. cohorts/target_surgery.sql  — index procedure (SNOMED 232723009)
#   2. cohorts/outcome_ssi.sql     — SSI condition  (SNOMED 76844004)
#   3. risk_score/component_concepts.csv — score covariates mapped back to
#      the source vocabularies used in pad_ssi.json (SNOMED-CT / LOINC / RxNorm)
#      Note: component_concepts.csv stores OMOP standard concept_ids; the table
#      below translates each back to the source code actually written in the JSON.

# -----------------------------------------------------------------------------
# Chunk 4 - Required concept manifest
# Purpose:
# Define the expected concept coverage list for target cohort, outcome cohort,
# and risk-score covariates. Each row is a required concept-system-code triple.
# Code path notes:
# - This table is the contract checked against module JSON contents.
# - Update this manifest when phenotype definitions change.
# -----------------------------------------------------------------------------
required_concepts <- data.frame(
  stringsAsFactors = FALSE,
  description = c(
    # --- Target cohort ---
    "Index procedure: open LE revascularization",
    # --- Outcome cohort ---
    "Outcome: SSI / infection of surgical wound",
    # --- Covariates: BMI / anthropometrics ---
    "BMI observation (obese / overweight covariate)",
    "Height observation (BMI calculation)",
    "Weight observation (BMI calculation)",
    # --- Covariates: urgency ---
    "Urgent/emergency case flag",
    # --- Covariates: ABI ---
    "Ankle-brachial index measurement",
    # --- Covariates: prior revascularization ---
    "Prior revascularization procedure",
    # --- Covariates: prolonged antibiotic exposure ---
    "Pre-index antibiotic (prolonged exposure covariate)",
    # --- Covariates: mFI components ---
    "mFI: diabetes mellitus type 2",
    "mFI: COPD",
    "mFI: CHF / heart failure",
    "mFI: hypertension",
    "mFI: functional impairment / impaired mobility",
    # --- Covariates: claudication indication ---
    "Indication: intermittent claudication",
    # --- Covariates: smoking (risk factor) ---
    "Tobacco smoking status observation"
  ),
  system = c(
    "SNOMED-CT", "SNOMED-CT",
    "LOINC", "LOINC", "LOINC",
    "SNOMED-CT",
    "LOINC",
    "SNOMED-CT",
    "RxNorm",
    "SNOMED-CT", "SNOMED-CT", "SNOMED-CT", "SNOMED-CT", "SNOMED-CT",
    "SNOMED-CT",
    "LOINC"
  ),
  code = c(
    "232723009", "76844004",
    "39156-5", "8302-2", "29463-7",
    "25876001",
    "59574-4",
    "232723009",
    "2673",
    "44054006", "13645005", "84114007", "38341003", "129839007",
    "266261006",
    "72166-2"
  )
)

# -----------------------------------------------------------------------------
# Chunk 5 - Helper: collect all coded entries from Synthea states
# Purpose:
# Traverse every state and gather all (system, code) pairs from both:
# - state-level codes[]
# - Observation value_code payloads
# Code path notes:
# - Duplicates are collapsed with unique() before matching checks.
# - Missing code fields are skipped safely.
# -----------------------------------------------------------------------------
# Collect every (system, code) pair that appears anywhere in the module states,
# including value_code fields on Observation states.
collect_module_codes <- function(states) {
  found <- data.frame(system = character(), code = character(),
                      stringsAsFactors = FALSE)
  for (st in states) {
    if (!is.null(st$codes)) {
      for (cd in st$codes) {
        if (!is.null(cd$system) && !is.null(cd$code)) {
          found <- rbind(found, data.frame(system = cd$system,
                                           code   = as.character(cd$code),
                                           stringsAsFactors = FALSE))
        }
      }
    }
    if (!is.null(st$value_code)) {
      vc <- st$value_code
      if (!is.null(vc$system) && !is.null(vc$code)) {
        found <- rbind(found, data.frame(system = vc$system,
                                         code   = as.character(vc$code),
                                         stringsAsFactors = FALSE))
      }
    }
  }
  unique(found)
}

module_codes <- collect_module_codes(module$states)

# -----------------------------------------------------------------------------
# Chunk 6 - Coverage evaluation and warning path
# Purpose:
# Compare required concept manifest to collected module concepts and emit
# warnings for any missing entries.
# Code path notes:
# - Match found: continue silently for that concept.
# - Match missing: emit warning and increment missing count.
# - Warnings are non-fatal so the HTML diagram still gets generated for review.
# -----------------------------------------------------------------------------
n_missing <- 0L
for (i in seq_len(nrow(required_concepts))) {
  req_sys  <- required_concepts$system[i]
  req_code <- required_concepts$code[i]
  req_desc <- required_concepts$description[i]

  hit <- any(module_codes$system == req_sys & module_codes$code == req_code)
  if (!hit) {
    warning(sprintf(
      "[coverage] MISSING: %s  (%s %s)",
      req_desc, req_sys, req_code
    ), call. = FALSE)
    n_missing <- n_missing + 1L
  }
}

# -----------------------------------------------------------------------------
# Chunk 7 - Coverage summary branch
# Purpose:
# Provide a concise pass/fail summary after all concept checks complete.
# Code path notes:
# - n_missing == 0: print PASS summary.
# - n_missing > 0: print NOT FOUND summary and remediation hint.
# -----------------------------------------------------------------------------
if (n_missing == 0L) {
  cat(sprintf(
    "Coverage check PASSED: all %d required concepts found in module JSON.\n",
    nrow(required_concepts)
  ))
} else {
  cat(sprintf(
    "Coverage check: %d of %d required concept(s) NOT FOUND in module JSON.\n",
    n_missing, nrow(required_concepts)
  ))
  cat("Review the warnings above and update synthea/modules/pad_ssi.json accordingly.\n")
}

# -----------------------------------------------------------------------------
# Chunk 8 - Diagram regeneration subprocess
# Purpose:
# Rebuild the HTML state-diagram artifact from the validated module JSON.
# Code path notes:
# - status == 0: generation succeeded; continue to completion message.
# - status != 0: hard stop because downstream SME review artifact is missing.
# -----------------------------------------------------------------------------
# Regenerate the HTML diagram viewer from the module JSON.
args <- c("scripts/synthea/generate_synthea_mermaid.R", module_path, "synthea/modules/pad_ssi.diagram.html")
status <- system2(file.path(R.home("bin"), "Rscript.exe"), args = args)
if (!identical(status, 0L)) {
  stop("Failed to generate Synthea diagram HTML.")
}

# -----------------------------------------------------------------------------
# Chunk 9 - Completion banner
# Purpose:
# Confirm that validation paths completed and the review artifact was generated.
# -----------------------------------------------------------------------------
cat("Step 3 complete: module validated and diagram HTML generated.\n")
