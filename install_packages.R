# =============================================================================
# install_packages.R
# Install PatientLevelPrediction and all OHDSI / CRAN dependencies needed for
# the SSI external-validation pipeline.  Also provisions the Microsoft JDBC
# driver bundle into the project-local drivers/ folder so this project is
# fully self-contained and does not require any companion projects.
#
# Run ONCE in a fresh R session BEFORE running run_validation.R.
# Usage: source("install_packages.R")
# =============================================================================

# --- Java configuration (must be set before rJava / DatabaseConnector load) ---
java_home <- "C:\\Program Files\\Eclipse Adoptium\\jdk-17.0.18.8-hotspot"
java_bin  <- file.path(java_home, "bin")

Sys.setenv(JAVA_HOME = java_home)
Sys.setenv(PATH = paste(
  normalizePath(java_bin, winslash = "\\", mustWork = FALSE),
  Sys.getenv("PATH"), sep = .Platform$path.sep
))
options(java.parameters = paste0(
  "-Djava.home=",
  normalizePath(java_home, winslash = "/", mustWork = FALSE)
))

if (!dir.exists(java_home)) {
  stop("Configured JAVA_HOME does not exist: ", java_home)
}

# --- Activate renv (creates library in project directory) ---------------------
if (file.exists("renv/activate.R")) source("renv/activate.R")

# --- CRAN mirror --------------------------------------------------------------
options(repos = c(CRAN = "https://cran.duke.edu/"))

# --- Ensure remotes / pak are available for GitHub installs ------------------
if (!requireNamespace("remotes", quietly = TRUE)) install.packages("remotes")
if (!requireNamespace("rJava",   quietly = TRUE)) install.packages("rJava")

# --- CRAN packages ------------------------------------------------------------
cran_packages <- c(
  # OHDSI CRAN-listed packages
  "SqlRender",           # SQL dialect translation
  "DatabaseConnector",   # JDBC database connectivity (>= 6.0)
  "Andromeda",           # Disk-based data frames for large cohort data
  "ParallelLogger",      # Logging framework used across OHDSI tools
  "CirceR",              # Cohort expression evaluation
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
  "languageserver"       # IDE language server support
)

installed <- rownames(installed.packages())
for (pkg in cran_packages) {
  if (!pkg %in% installed) {
    message("Installing ", pkg, " ...")
    install.packages(pkg)
  }
}

# --- OHDSI GitHub packages ----------------------------------------------------
# Install in dependency order.

github_packages <- list(
  list(repo = "OHDSI/FeatureExtraction",        ref = "v3.6.0"),
  list(repo = "OHDSI/CohortGenerator",          ref = "v0.9.0"),
  list(repo = "OHDSI/PatientLevelPrediction",   ref = "v6.4.0")
)

installed <- rownames(installed.packages())

for (p in github_packages) {
  pkg_name <- basename(p$repo)
  # Normalise ETL-Synthea → ETLSyntheaBuilder style name mismatches
  if (!pkg_name %in% installed) {
    message("Installing ", pkg_name, " @ ", p$ref, " from GitHub ...")
    remotes::install_github(p$repo, ref = p$ref, upgrade = "never")
  } else {
    message(pkg_name, " already installed – skipping.")
  }
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
