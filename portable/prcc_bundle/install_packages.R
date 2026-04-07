# =============================================================================
# install_packages.R — PAD/OLER SSI Validation Bundle — PRCC edition
#
# Installs all R packages required to run the integer risk score pipeline and
# generate the manuscript-format Word report.
#
# Run from the bundle directory AFTER activating the openjdk conda env:
#   source activate openjdk
#   Rscript install_packages.R
#
# Uses the Duke CRAN mirror (archive.linux.duke.edu/cran) which is accessible
# from PRCC nodes without an external internet connection.
# =============================================================================

options(repos = c(CRAN = "https://archive.linux.duke.edu/cran/"))

message("Installing R packages for PAD/OLER SSI validation bundle ...")
message("CRAN mirror: ", getOption("repos")["CRAN"])

# ---------------------------------------------------------------------------
# Core pipeline packages
# ---------------------------------------------------------------------------
core_packages <- c(
  "DatabaseConnector",   # OMOP CDM query via JDBC
  "SqlRender",           # SQL parameterisation and dialect translation
  "dplyr",               # data manipulation
  "ggplot2",             # calibration and ROC plots
  "pROC",                # AUROC computation
  "PRROC",               # AUPRC computation
  "readr"                # CSV I/O
)

# ---------------------------------------------------------------------------
# Report generation packages
# ---------------------------------------------------------------------------
report_packages <- c(
  "officer",             # Word document generation (.docx)
  "flextable",           # formatted tables inside Word document
  "writexl"              # fringe-case Excel export (.xlsx)
)

all_packages <- c(core_packages, report_packages)

# Install missing packages only (skip already-installed ones).
missing_packages <- all_packages[
  !sapply(all_packages, requireNamespace, quietly = TRUE)
]

if (length(missing_packages) == 0) {
  message("All packages already installed.")
} else {
  message("Installing ", length(missing_packages), " package(s): ",
          paste(missing_packages, collapse = ", "))
  install.packages(missing_packages, dependencies = TRUE)
}

# ---------------------------------------------------------------------------
# Verify all packages loaded successfully
# ---------------------------------------------------------------------------
failed <- all_packages[
  !sapply(all_packages, requireNamespace, quietly = TRUE)
]

if (length(failed) > 0) {
  stop(
    "The following package(s) could not be loaded after installation:\n",
    paste("  -", failed, collapse = "\n"), "\n",
    "Check PRCC internet access and try again, or contact the study coordinator."
  )
}

message("All ", length(all_packages), " packages verified.")
message("Next step: edit config.R, then run: Rscript run_analysis.R")
