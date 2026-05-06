# =============================================================================
# R/report_descriptive.R
#
# Placeholder for the descriptive / cohort characterization report template.
#
# Entry point: .report_descriptive(output_dir, connection_details, config)
#
# To implement:
#   1. Source R/report_helpers.R for shared helper functions.
#   2. Define .report_descriptive() with the body below replaced by real logic.
#   3. Uncomment source("R/report_descriptive.R") in R/report_extended.R.
#
# Typical sections for a descriptive report:
#   - Title page
#   - Methods (data source, cohort definition, analysis period)
#   - Table 1: Cohort demographics (use .build_table1() from report_helpers.R)
#   - Supplemental tables (covariate distributions, ICD/CPT prevalence)
#
# TODO [TEMPLATE]: implement for study_design = "descriptive" or "cohort_characterization"
# =============================================================================

# .report_descriptive()
#
# Not yet implemented — fires an informative error when called.
# Replace stop() with the real report body when ready.
.report_descriptive <- function(output_dir,
                                connection_details = NULL,
                                config             = NULL) {
  stop(
    "Descriptive report template is not yet implemented.\n",
    "  Implement .report_descriptive() in R/report_descriptive.R to enable this path.\n",
    "  See the file header for guidance."
  )
}
