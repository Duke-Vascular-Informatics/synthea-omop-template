#!/usr/bin/env Rscript
# =============================================================================
# install_packages.R — PAD/OLER SSI Validation Bundle — PRCC edition
#
# Installs all R packages required to run the integer risk score pipeline and
# generate the manuscript-format Word report.
#
# PREREQUISITES — run these in the shell BEFORE launching this script:
#
#   conda activate openjdk          # puts conda JDK on PATH and sets JAVA_HOME
#   Rscript install_packages.R       # run from the bundle directory
#
# WHY conda activate FIRST:
#   rJava must be compiled against the JDK headers.  If JAVA_HOME is not set
#   (or points to the wrong JDK) before this script runs, rJava compilation
#   will fail with "jni.h: No such file or directory".  Activating the conda
#   openjdk environment sets JAVA_HOME correctly.  This script then calls
#   R CMD javareconf to register that JDK with R before any packages are
#   installed.
#
# WHAT IS INSTALLED:
#   Core pipeline  : DatabaseConnector, SqlRender, dplyr, ggplot2, pROC,
#                    PRROC, readr
#   Report support : officer, flextable, writexl  (optional but recommended)
#
# WHAT IS *NOT* INSTALLED (and why):
#   rJava      — installed automatically as a hard dependency of DatabaseConnector.
#                It does not need to be listed here.
#   RPostgres  — a *suggested* (optional) dependency of DatabaseConnector for
#                PostgreSQL connections.  We use SQL Server only; installing it
#                would require libpq system headers that are not available on
#                PRCC compute nodes.
#   ssh        — another *suggested* dependency of DatabaseConnector for tunnel
#                connections.  Not needed for our direct Kerberos JDBC approach;
#                installing it would require libssh2 system headers.
#
#   Both RPostgres and ssh are excluded by using
#     dependencies = c("Depends", "Imports", "LinkingTo")
#   instead of dependencies = TRUE (which installs Suggests as well).
#
# Uses the Duke CRAN mirror (archive.linux.duke.edu/cran) which is accessible
# from PRCC nodes without an external internet connection.
# =============================================================================

options(repos = c(CRAN = "https://archive.linux.duke.edu/cran/"))

message("Installing R packages for PAD/OLER SSI validation bundle ...")
message("CRAN mirror: ", getOption("repos")["CRAN"])

# ---------------------------------------------------------------------------
# Step 1 — Verify JAVA_HOME and reconfigure R's Java integration
#
# R stores the location of the JDK at install time.  When a new JDK is
# activated via conda (conda activate openjdk), R does not automatically
# pick it up.  Running `R CMD javareconf` updates R's Java configuration
# (stored in $(R RHOME)/etc/javaconf) to point at the currently active JDK.
# This must happen before rJava is compiled; otherwise the compiler cannot
# find jni.h and rJava installation fails.
# ---------------------------------------------------------------------------
java_home <- Sys.getenv("JAVA_HOME")

if (nchar(trimws(java_home)) == 0) {
  stop(
    "JAVA_HOME is not set.\n\n",
    "Please activate the conda openjdk environment BEFORE running this script:\n",
    "  conda activate openjdk\n",
    "  Rscript install_packages.R\n\n",
    "If you already ran 'conda activate openjdk' and still see this error,\n",
    "check that the environment is active with: echo $JAVA_HOME"
  )
}

message("JAVA_HOME: ", java_home)
message("Running R CMD javareconf to register JDK with R ...")

# R CMD javareconf updates R's internal javaconf so that rJava compilation
# picks up the correct JDK headers and libraries.
# The JAVA_HOME= argument makes the reconfiguration explicit even if
# the shell environment is inherited differently by the subprocess.
javareconf_cmd <- paste0("R CMD javareconf JAVA_HOME=", shQuote(java_home))
javareconf_ret <- system(javareconf_cmd)

if (javareconf_ret != 0) {
  warning(
    "R CMD javareconf returned a non-zero exit code (", javareconf_ret, ").\n",
    "rJava compilation may still succeed if JAVA_HOME is set correctly.\n",
    "Continuing ..."
  )
} else {
  message("R CMD javareconf completed successfully.")
}

# ---------------------------------------------------------------------------
# Step 2 — Define required packages
#
# dependencies = c("Depends", "Imports", "LinkingTo") installs only the
# *hard* dependencies of each package — those listed under Depends, Imports,
# or LinkingTo in DESCRIPTION.  It deliberately excludes Suggests, which
# would pull in RPostgres (needs libpq) and ssh (needs libssh2), neither of
# which are available as compiled system libraries on PRCC compute nodes and
# neither of which are needed for our SQL Server / Kerberos workflow.
# ---------------------------------------------------------------------------
core_packages <- c(
  "DatabaseConnector",   # OMOP CDM query via JDBC (pulls in rJava as a hard dep)
  "SqlRender",           # SQL parameterisation and dialect translation
  "dplyr",               # data manipulation
  "ggplot2",             # calibration and ROC plots
  "pROC",                # AUROC computation
  "PRROC",               # AUPRC computation
  "readr"                # CSV I/O
)

report_packages <- c(
  "officer",             # Word document generation (.docx)
  "flextable",           # formatted tables inside Word document
  "writexl"              # fringe-case Excel export (.xlsx); pure R, no system libs
)

all_packages <- c(core_packages, report_packages)

# ---------------------------------------------------------------------------
# Step 3 — Install missing packages
# ---------------------------------------------------------------------------
missing_packages <- all_packages[
  !sapply(all_packages, requireNamespace, quietly = TRUE)
]

if (length(missing_packages) == 0) {
  message("All packages already installed — nothing to do.")
} else {
  message("Installing ", length(missing_packages), " package(s): ",
          paste(missing_packages, collapse = ", "))

  # Use only hard dependencies (Depends/Imports/LinkingTo).
  # This prevents RPostgres and ssh from being pulled in as Suggests of
  # DatabaseConnector, both of which require unavailable system libraries.
  install.packages(
    missing_packages,
    dependencies = c("Depends", "Imports", "LinkingTo")
  )
}

# ---------------------------------------------------------------------------
# Step 4 — Verify all packages load successfully
# ---------------------------------------------------------------------------
failed <- all_packages[
  !sapply(all_packages, requireNamespace, quietly = TRUE)
]

if (length(failed) > 0) {
  stop(
    "The following package(s) failed to install or load:\n",
    paste("  -", failed, collapse = "\n"), "\n\n",
    "Common causes on PRCC:\n",
    "  - rJava: JAVA_HOME not set before running this script.\n",
    "           Fix: exit R, run 'conda activate openjdk', re-run this script.\n",
    "  - Any package: network issue reaching the Duke CRAN mirror.\n",
    "           Fix: check VPN / PRCC internet access and retry.\n",
    "  - DatabaseConnector: rJava failed, so it could not be compiled.\n",
    "           Fix: resolve rJava first (see above), then retry."
  )
}

message("")
message("All ", length(all_packages), " packages installed and verified.")
message("rJava version: ", as.character(packageVersion("rJava")))
message("DatabaseConnector version: ", as.character(packageVersion("DatabaseConnector")))
message("")
message("Next steps:")
message("  1. Edit config.R — fill in server, database, and schema names.")
message("  2. Run: export KRB5CCNAME=FILE:~/krb5cc_java && kinit")
message("  3. Run: Rscript run_analysis.R")
