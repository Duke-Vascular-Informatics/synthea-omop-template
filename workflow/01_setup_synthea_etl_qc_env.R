#!/usr/bin/env Rscript
# Step 1: Install packages and initialize environment for Synthea generation, ETL, and data checks.

# -----------------------------------------------------------------------------
# Chunk 1: Resolve and load shared workflow bootstrap helper.
# Purpose:
# - Ensure this step can be launched from any working directory.
# - Resolve repository root consistently before sourcing project-relative files.
# Outcome:
# - `set_workflow_root()` sets the working directory to repo root.
# -----------------------------------------------------------------------------

bootstrap_path <- local({
  # Prefer `--file=...` when script is executed via Rscript.
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
# Chunk 2: Run environment setup and load runtime helpers.
# Purpose:
# - Initialize renv and install required packages (CRAN-first, GitHub fallback)
#   via the canonical setup scripts.
# - Load config + DB/JDBC helper functions needed for the DB preflight.
# Outcome:
# - Package environment and helper APIs are ready for validation checks below.
# -----------------------------------------------------------------------------

source("setup/setup_renv.R")
source("setup/install_packages.R")
source("config.R")
source("R/drivers.R")
source("R/connection.R")

# -----------------------------------------------------------------------------
# Chunk 2b: Clone synthea-pad repo into external/synthea if not already present.
# Purpose:
# - Ensure the Synthea checkout required by Steps 3 and 4 is available locally.
# - Safe to run repeatedly: skips clone if external/synthea already exists and
#   is a valid git repository.
# Outcome:
# - external/synthea contains the synthea-pad repo.
# -----------------------------------------------------------------------------

synthea_dir <- file.path(getwd(), "external", "synthea")
synthea_git <- file.path(synthea_dir, ".git")
synthea_repo_url <- "https://github.com/adam-mdmph/synthea-pad.git"

if (dir.exists(synthea_git)) {
  message("Synthea repo already present at: ", synthea_dir, " — skipping clone.")
} else {
  if (dir.exists(synthea_dir)) {
    message("external/synthea exists but is not a git repo — removing and re-cloning ...")
    unlink(synthea_dir, recursive = TRUE)
  }
  message("Cloning synthea-pad into external/synthea ...")
  ret <- system2("git", c("clone", synthea_repo_url, synthea_dir), stdout = TRUE, stderr = TRUE)
  if (!is.null(attr(ret, "status")) && attr(ret, "status") != 0) {
    stop("git clone failed:\n", paste(ret, collapse = "\n"))
  }
  message("Synthea repo cloned to: ", synthea_dir)
}

# -----------------------------------------------------------------------------
# Chunk 3: Ensure DatabaseConnector is available.
# Purpose:
# - Guard against edge cases where setup scripts complete but
#   DatabaseConnector is still unavailable in the active library.
# - Keep installation path reproducible by using renv and approved CRAN mirror.
# Outcome:
# - DatabaseConnector is installed or script exits with a clear error.
# -----------------------------------------------------------------------------

if (!requireNamespace("DatabaseConnector", quietly = TRUE)) {
  if (!requireNamespace("renv", quietly = TRUE)) {
    stop("DatabaseConnector is missing and renv is unavailable to install it.")
  }
  options(repos = c(CRAN = "https://archive.linux.duke.edu/cran/"))
  message("DatabaseConnector not found after setup; installing via renv::install('DatabaseConnector') ...")
  renv::install("DatabaseConnector")
}

# -----------------------------------------------------------------------------
# Chunk 4: Validate required package set for downstream workflow steps.
# Purpose:
# - Confirm core packages needed for ETL and quality checks are installed
#   before expensive work begins.
# Outcome:
# - Hard stop listing any missing packages.
# -----------------------------------------------------------------------------

required <- c("DatabaseConnector", "SqlRender", "jsonlite", "data.table")
missing <- required[!vapply(required, requireNamespace, logical(1), quietly = TRUE)]
if (length(missing) > 0) {
  stop("Missing required packages after setup: ", paste(missing, collapse = ", "))
}

# -----------------------------------------------------------------------------
# Chunk 5: Run unit tests.
# Purpose:
# - Verify pure pipeline logic (scoring maths, domain mappings, spec parsing,
#   retry classification) before any database work is attempted.
# - Catch regressions in helper functions introduced since the last run.
# Outcome:
# - Hard stop if any test fails; all 43 tests must pass to proceed.
# -----------------------------------------------------------------------------

if (requireNamespace("testthat", quietly = TRUE) && requireNamespace("withr", quietly = TRUE)) {
  message("Running unit tests ...")
  withr::with_dir(getwd(), {
    results <- testthat::test_dir("tests/testthat", reporter = "progress", stop_on_failure = TRUE)
  })
  message("All unit tests passed.")
} else {
  message("Skipping unit tests: 'testthat' or 'withr' not installed.")
}

# -----------------------------------------------------------------------------
# Chunk 7: Execute database connectivity preflight.
# Purpose:
# - Verify JDBC provisioning, Java runtime settings, credentials, and SQL Server
#   reachability before subsequent workflow steps are attempted.
# - Require multiple consecutive successes to avoid transient false positives.
# Outcome:
# - Fails fast if DB cannot be reached reliably.
# -----------------------------------------------------------------------------

config <- get_validation_config()
connection_details <- build_connection_details(config)
run_db_preflight(
  connection_details = connection_details,
  required_successes = 3L,
  max_attempts = 10L,
  delay_seconds = 2
)

# -----------------------------------------------------------------------------
# Chunk 8: Final completion message.
# Purpose:
# - Provide an explicit success signal for automation logs and interactive users.
# -----------------------------------------------------------------------------

cat("Step 1 complete: environment and packages are ready, and database connectivity preflight passed.\n")
