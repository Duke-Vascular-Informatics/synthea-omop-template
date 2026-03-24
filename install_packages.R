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
options(repos = c(CRAN = "https://archive.linux.duke.edu/cran/"))

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
# Strategy:
# 1) Prefer internal prebuilt binaries in internal_repo/bin/windows/contrib/<R>.
# 2) If missing, fall back to GitHub install (for online bootstrap only).

github_packages <- list(
  list(package = "FeatureExtraction",      repo = "OHDSI/FeatureExtraction",      ref = "v3.6.0"),
  list(package = "CohortGenerator",        repo = "OHDSI/CohortGenerator",        ref = "v0.9.0"),
  list(package = "PatientLevelPrediction", repo = "OHDSI/PatientLevelPrediction", ref = "v6.4.0")
)

r_ver <- paste(R.version$major, sub("\\..*$", "", R.version$minor), sep = ".")
internal_repo <- file.path(getwd(), "internal_repo", "bin", "windows", "contrib", r_ver)

install_from_internal_binary <- function(pkg_name, repo_path) {
  if (!dir.exists(repo_path)) return(FALSE)

  # Match package zip regardless of version suffix.
  zip_files <- list.files(
    repo_path,
    pattern = paste0("^", pkg_name, "_.*\\.zip$"),
    full.names = TRUE
  )
  if (length(zip_files) == 0) return(FALSE)

  zip_files <- zip_files[order(file.info(zip_files)$mtime, decreasing = TRUE)]
  zip_file <- zip_files[[1]]
  message("Installing ", pkg_name, " from internal binary: ", basename(zip_file))
  install.packages(zip_file, repos = NULL, type = "win.binary")
  TRUE
}

installed <- rownames(installed.packages())

for (p in github_packages) {
  pkg_name <- p$package

  if (pkg_name %in% installed) {
    message(pkg_name, " already installed – skipping.")
    next
  }

  installed_from_internal <- install_from_internal_binary(pkg_name, internal_repo)
  if (isTRUE(installed_from_internal)) {
    next
  }

  message(
    "No internal binary found for ", pkg_name,
    " in ", internal_repo, ". Falling back to GitHub install ..."
  )
  remotes::install_github(p$repo, ref = p$ref, upgrade = "never")
}

# --- ETLSyntheaBuilder (Synthea CSV -> OMOP ETL) -----------------------------
if (!"ETLSyntheaBuilder" %in% rownames(installed.packages())) {
  message("Installing ETLSyntheaBuilder from OHDSI/ETL-Synthea ...")
  # ETLSyntheaBuilder is distributed from the ETL-Synthea repository.
  # Use renv::install for reproducible project-local installation.
  renv::install("OHDSI/ETL-Synthea")
}

if (!requireNamespace("ETLSyntheaBuilder", quietly = TRUE)) {
  stop("ETLSyntheaBuilder installation failed or package unavailable after install.")
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
message("IMPORTANT: The Synthea->OMOP ETL path now uses EtlSyntheaBuilder.")
message("If missing, install via renv::install(<EtlSyntheaBuilder package source>) and run renv::snapshot().")
message("Next step: source('run_validation.R') to run the pipeline.")
