# =============================================================================
# install_packages.R
# Install the R packages needed to GENERATE and QC synthetic data (Synthea ETL,
# consumer-study QC, module coverage, Achilles/DQD).  This is deliberately NOT
# the full HADES analysis stack: analysis lives in Strategus repos.  Also provisions the Microsoft JDBC driver bundle into the
# project-local drivers/ folder so the project is fully self-contained.
#
# Run ONCE in a fresh R session (workflow/01 does this for you).
# Usage: Rscript setup/install_packages.R
# =============================================================================

# --- Java configuration (must be set before rJava / DatabaseConnector load) ---
# JAVA_HOME is read from the environment (set automatically in the dev container).
# Falls back to the Windows path for legacy Windows runs.
JAVA_HOME <- Sys.getenv("JAVA_HOME",
               unset = "C:\\Program Files\\Eclipse Adoptium\\jdk-17.0.18.8-hotspot")
java_bin  <- file.path(JAVA_HOME, "bin")

if (!dir.exists(JAVA_HOME)) {
  stop("Configured JAVA_HOME does not exist: ", JAVA_HOME,
       "\nSet the JAVA_HOME environment variable to your JDK 17 installation.")
}

Sys.setenv(JAVA_HOME = JAVA_HOME)
Sys.setenv(PATH = paste(
  normalizePath(java_bin, winslash = "/", mustWork = FALSE),
  Sys.getenv("PATH"), sep = .Platform$path.sep
))

# On Windows: add the JDBC auth DLL directory to java.library.path.
# On Linux/macOS: SQL auth is used; no DLL needed.
java_params <- paste0("-Djava.home=", normalizePath(JAVA_HOME, winslash = "/", mustWork = FALSE))
if (.Platform$OS.type == "windows") {
  auth_dll_dir <- normalizePath(
    file.path(getwd(), "drivers", "sqljdbc_13.2", "enu", "auth", "x64"),
    winslash = "/", mustWork = FALSE
  )
  if (dir.exists(auth_dll_dir)) {
    java_params <- c(java_params, paste0("-Djava.library.path=", auth_dll_dir))
    Sys.setenv(PATH = paste(
      normalizePath(auth_dll_dir, winslash = "/", mustWork = FALSE),
      Sys.getenv("PATH"), sep = .Platform$path.sep
    ))
  }
}
options(java.parameters = java_params)

# --- Activate renv (creates library in project directory) ---------------------
if (file.exists("renv/activate.R")) source("renv/activate.R")

# --- CRAN mirror --------------------------------------------------------------
options(repos = c(CRAN = Sys.getenv("CRAN_MIRROR", unset = "https://cloud.r-project.org")))

# --- Ensure rJava is available (DatabaseConnector needs it) -----------------
# GitHub installs below go through renv::install(), which needs no extra package.
if (!requireNamespace("rJava", quietly = TRUE)) renv::install("rJava")

# --- Install R package dependencies -------------------------------------------
# If renv.lock already exists (every repo created from this template ships
# one), RESTORE the exact pinned versions it records instead of re-resolving
# package names against whatever CRAN/GitHub happen to serve today. Before
# this branch existed, install_packages.R ignored a repo's own renv.lock
# entirely -- it always ran the by-name loop below and re-snapshotted
# afterward, so renv.lock recorded what happened to install on THIS run, not
# a reproducible spec two people running setup a month apart would both land
# on. A cold renv::restore() of the full HADES stack takes real time (the CI
# renv-validate job's own comment notes 30+ minutes), but that cost belongs
# here -- the one point in the workflow where a long install is already
# expected -- not hidden behind a lockfile that never gets read.
#
# The by-name / GitHub install path below now runs ONLY the first time a repo
# has no renv.lock at all (e.g. this template itself, before its own first
# snapshot). It resolves current package versions once, then snapshots them
# into the lockfile every subsequent setup will restore from.
if (file.exists("renv.lock")) {
  message("renv.lock found -- restoring the exact pinned environment ...")
  renv::restore(prompt = FALSE)
} else {
  message("No renv.lock found -- resolving current package versions for the first time ...")

  # --- CRAN packages ------------------------------------------------------------
  cran_packages <- c(
    # OHDSI CRAN-listed packages
    "SqlRender",           # SQL dialect translation
    "DatabaseConnector",   # JDBC database connectivity (>= 6.0)
    "ParallelLogger",      # Logging framework used across OHDSI tools
    "CirceR",              # circe cohort JSON -> SQL (consumer-study QC, module coverage)
    "CohortGenerator",     # Instantiates consuming studies' cohorts for QC
    # General
    "jsonlite",            # Synthea module JSON and circe cohort JSON
    "yaml",                # consumers.yaml / study_params.yaml parsing
    "data.table",          # Fast CSV reads in the ETL and vocabulary loader
    # Tests
    "RSQLite",             # Throwaway CDM fixtures in the unit tests
    "testthat",
    "withr"
  )

  installed <- rownames(installed.packages())
  for (pkg in cran_packages) {
    if (!pkg %in% installed) {
      message("Installing ", pkg, " from CRAN ...")
      renv::install(pkg)
    }
  }

  # --- OHDSI GitHub-only packages -----------------------------------------------
  # Keep this list limited to packages that are not available on CRAN.

  github_packages <- list(
    list(package = "ETLSyntheaBuilder",      repo = "OHDSI/ETL-Synthea",            ref = "v2.1.0"),
    list(package = "Achilles",               repo = "OHDSI/Achilles",               ref = "main"),
    list(package = "DataQualityDashboard",   repo = "OHDSI/DataQualityDashboard",   ref = "main")
  )

  for (p in github_packages) {
    pkg_name <- p$package

    # Use renv::install() with the "owner/repo@ref" specifier so renv records
    # the GitHub source in its metadata and renv::snapshot() can track it.
    # This is intentionally not skipped even if already installed, because a
    # prior binary install may have left the package with an "unknown source"
    # that would cause renv::snapshot() to abort.
    message("Installing ", pkg_name, " from GitHub via renv (", p$repo, " @ ", p$ref, ") ...")
    renv::install(paste0(p$repo, "@", p$ref))
  }

  # --- Snapshot environment ----------------------------------------------------
  # Only on the first-install path -- restoring an existing lockfile above
  # must NOT be followed by a re-snapshot, or it would just re-record
  # whatever version drift renv::restore() was supposed to prevent.
  if (requireNamespace("renv", quietly = TRUE)) {
    renv::snapshot(prompt = FALSE)
  }
}

# --- Provision JDBC driver bundle --------------------------------------------
# Downloads mssql-jdbc-13.2.1.zip from Microsoft and stages the jar + auth DLL
# into drivers/ if not already present.  Safe to call repeatedly.
message("\nProvisioning JDBC driver ...")
source("config.R")
source("R/drivers.R")
ensure_jdbc_bundle(get_validation_config())
message("JDBC driver provisioned.")

message("\nAll packages installed and JDBC driver ready.")
message("Next step: Rscript workflow/02_define_omop_cohort_outcome_covariates.R")
