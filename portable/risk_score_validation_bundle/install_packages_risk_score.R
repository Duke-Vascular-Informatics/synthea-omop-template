# Install only packages required for the portable OMOP risk score bundle.
# Use in a fresh R session.

options(repos = c(CRAN = "https://archive.linux.duke.edu/cran/"))

required_packages <- c(
  "DatabaseConnector",
  "SqlRender",
  "dplyr",
  "ggplot2",
  "pROC",
  "PRROC",
  "readr"
)

if (!requireNamespace("renv", quietly = TRUE)) {
  stop("Package 'renv' is required. Install renv first, then rerun this script.")
}

renv::install(required_packages)
