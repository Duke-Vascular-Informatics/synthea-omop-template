# =============================================================================
# install_packages.R
# Install PatientLevelPrediction and all OHDSI / CRAN dependencies needed for
# the SSI external-validation pipeline.  Also provisions the Microsoft JDBC
# driver bundle into the project-local drivers/ folder so this project is
# fully self-contained and does not require any companion projects.
#
# Run ONCE in a fresh R session BEFORE running run_validation.R.
# Usage: source("setup/install_packages.R")
# =============================================================================

# --- Java configuration (must be set before rJava / DatabaseConnector load) ---
JAVA_HOME <- "C:\\Program Files\\Eclipse Adoptium\\jdk-17.0.18.8-hotspot"
java_bin  <- file.path(JAVA_HOME, "bin")

Sys.setenv(JAVA_HOME = JAVA_HOME)
Sys.setenv(PATH = paste(
  normalizePath(java_bin, winslash = "\\", mustWork = FALSE),
  Sys.getenv("PATH"), sep = .Platform$path.sep
))

# Build java.parameters list. -Djava.library.path must include the JDBC Windows
# auth DLL directory so the JVM can load it for integrated security.  This must
# be set before requireNamespace("rJava") starts the JVM.
auth_dll_dir <- normalizePath(
  file.path(getwd(), "drivers", "sqljdbc_13.2", "enu", "auth", "x64"),
  winslash = "/", mustWork = FALSE
)
java_params <- paste0("-Djava.home=", normalizePath(JAVA_HOME, winslash = "/", mustWork = FALSE))
if (dir.exists(auth_dll_dir)) {
  java_params <- c(java_params, paste0("-Djava.library.path=", auth_dll_dir))
  Sys.setenv(PATH = paste(
    normalizePath(auth_dll_dir, winslash = "\\", mustWork = FALSE),
    Sys.getenv("PATH"), sep = .Platform$path.sep
  ))
}
options(java.parameters = java_params)

if (!dir.exists(JAVA_HOME)) {
  stop("Configured JAVA_HOME does not exist: ", JAVA_HOME)
}

# --- Activate renv (creates library in project directory) ---------------------
if (file.exists("renv/activate.R")) source("renv/activate.R")

# --- CRAN mirror --------------------------------------------------------------
options(repos = c(CRAN = "https://archive.linux.duke.edu/cran/"))

# --- Ensure remotes / rJava are available for GitHub installs ----------------
if (!requireNamespace("remotes", quietly = TRUE)) renv::install("remotes")
if (!requireNamespace("rJava", quietly = TRUE)) renv::install("rJava")

# --- CRAN packages ------------------------------------------------------------
cran_packages <- c(
  # OHDSI CRAN-listed packages
  "SqlRender",           # SQL dialect translation
  "DatabaseConnector",   # JDBC database connectivity (>= 6.0)
  "Andromeda",           # Disk-based data frames for large cohort data
  "ParallelLogger",      # Logging framework used across OHDSI tools
  "CirceR",              # Cohort expression evaluation
  "FeatureExtraction",   # Feature engineering package used by PLP
  "CohortGenerator",     # Cohort generation helpers
  "PatientLevelPrediction", # External validation framework
  # ML backend packages (used by various PLP model types)
  "glmnet",              # Regularised regression (LASSO / Ridge / EN)
  "xgboost",             # Gradient boosted trees
  "randomForest",        # Random forest (optional)
  "pROC",                # AUC / ROC metrics
  "ggplot2",             # Plotting
  "dplyr",               # Data manipulation
  "tibble",
  "tidyr",
  "readr",
  # Dev / housekeeping
  "remotes",
  "languageserver",
  "devtools"       # IDE language server support
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

available_cran <- tryCatch(rownames(available.packages()), error = function(e) character(0))

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
if (requireNamespace("renv", quietly = TRUE)) {
  renv::snapshot(prompt = FALSE)
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
message("Next step: source('run_validation.R') to run the pipeline.")
