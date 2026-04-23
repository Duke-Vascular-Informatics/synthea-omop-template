#!/usr/bin/env Rscript
# =============================================================================
# install_packages.R — PAD/OLER SSI Validation Bundle — PRCC edition
#
# Installs all R packages required to run the integer risk score pipeline and
# generate the manuscript-format Word report.
#
# Do not run this directly — use the wrapper shell script instead:
#   bash install_r_packages.sh
#
# That script activates the openjdk conda environment (setting JAVA_HOME)
# and sets R_LIBS_USER before calling this script, both of which are required
# for rJava to compile correctly into a user-writable library.
#
# WHY NO R CMD javareconf:
#   R CMD javareconf writes to $(R RHOME)/etc/javaconf, which is a system-wide
#   R installation directory.  On PRCC, R is installed system-wide and users
#   do not have write access there — javareconf will fail with a permissions
#   error.  It is also unnecessary: rJava's own configure script reads
#   JAVA_HOME directly from the environment at compile time.  As long as
#   JAVA_HOME is set (via conda activate openjdk) when install.packages() is
#   called, rJava will find jni.h and compile correctly without javareconf.
#
# WHAT IS INSTALLED:
#   Core pipeline  : DatabaseConnector, SqlRender, dplyr, ggplot2, pROC,
#                    PRROC, readr
#   Report support : officer, flextable, writexl  (optional but recommended)
#
# WHAT IS *NOT* INSTALLED (and why):
#   rJava      — installed automatically as a hard dependency of DatabaseConnector.
#                It does not need to be listed explicitly here.
#   RPostgres  — a *suggested* (optional) dependency of DatabaseConnector for
#                PostgreSQL connections.  We use SQL Server only; installing it
#                would require libpq system headers unavailable on PRCC nodes.
#   ssh        — another *suggested* dependency of DatabaseConnector for tunnel
#                connections.  Not needed for our direct Kerberos JDBC approach;
#                installing it would require libssh2 system headers.
#
#   Both RPostgres and ssh are excluded by using
#     dependencies = c("Depends", "Imports", "LinkingTo")
#   instead of dependencies = TRUE (which installs Suggests as well).
#
# CRAN mirror is read from the CRAN_MIRROR environment variable (set in .env
# or exported in your shell).  Falls back to cloud.r-project.org if unset.
# Use your institution's local mirror if nodes lack external internet access.
# =============================================================================

options(repos = c(CRAN = Sys.getenv("CRAN_MIRROR", unset = "https://cloud.r-project.org")))

message("Installing R packages for PAD/OLER SSI validation bundle ...")
message("CRAN mirror: ", getOption("repos")["CRAN"])

# ---------------------------------------------------------------------------
# Step 1 — Verify JAVA_HOME and that jni.h is present
#
# rJava's configure script compiles a small C program that includes jni.h.
# If JAVA_HOME is not set, or if the JDK headers are not present under
# $JAVA_HOME/include/, the compilation will fail immediately.
#
# We check for jni.h explicitly here so that the error message is clear
# rather than buried in compiler output.
# ---------------------------------------------------------------------------
java_home <- Sys.getenv("JAVA_HOME")

if (nchar(trimws(java_home)) == 0) {
  stop(
    "JAVA_HOME is not set.\n\n",
    "Do not run install_packages.R directly.\n",
    "Use the wrapper script instead:\n",
    "  bash install_r_packages.sh\n\n",
    "That script activates conda activate openjdk which sets JAVA_HOME."
  )
}

message("JAVA_HOME: ", java_home)

# Check that jni.h exists — this is the header rJava needs to compile.
# It lives under $JAVA_HOME/include/ in standard JDK installations.
jni_header <- file.path(java_home, "include", "jni.h")
if (!file.exists(jni_header)) {
  stop(
    "JDK header not found: ", jni_header, "\n\n",
    "The openjdk conda environment may not include JDK development headers.\n",
    "Verify the environment with:\n",
    "  conda activate openjdk\n",
    "  find $JAVA_HOME/include -name 'jni.h'\n\n",
    "If jni.h is missing, the conda openjdk package may need to be reinstalled:\n",
    "  conda install -n openjdk conda-forge::openjdk --force-reinstall"
  )
}

message("JDK headers found: ", jni_header)

# Also confirm the user library path is writable — packages must go somewhere
# the current user can write to.  R_LIBS_USER is set by install_r_packages.sh.
lib_path <- .libPaths()[1]
message("Package library: ", lib_path)
if (!file.access(lib_path, mode = 2) == 0) {
  stop(
    "R package library is not writable: ", lib_path, "\n\n",
    "Do not run install_packages.R directly.\n",
    "Use the wrapper script instead:\n",
    "  bash install_r_packages.sh\n\n",
    "That script sets R_LIBS_USER to a user-writable directory before\n",
    "calling this script."
  )
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
    dependencies = c("Depends", "Imports", "LinkingTo"),
    lib          = lib_path
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
    "  - rJava: JAVA_HOME not set or jni.h not found.\n",
    "           Fix: use 'bash install_r_packages.sh' (not Rscript directly).\n",
    "  - Any package: network issue reaching the Duke CRAN mirror.\n",
    "           Fix: check PRCC internet access and retry.\n",
    "  - DatabaseConnector: rJava failed, so it could not load.\n",
    "           Fix: resolve rJava first (see above), then retry."
  )
}

message("")
message("All ", length(all_packages), " packages installed and verified.")
message("rJava version: ", as.character(packageVersion("rJava")))
message("DatabaseConnector version: ", as.character(packageVersion("DatabaseConnector")))
message("Package library: ", lib_path)
message("")
message("Next steps:")
message("  1. Edit config.R — fill in server, database, and schema names.")
message("  2. Ensure Kerberos ticket is valid: klist")
message("     If expired: export KRB5CCNAME=FILE:~/krb5cc_java && kinit")
message("  3. Run: conda activate openjdk")
message("         export KRB5CCNAME=FILE:~/krb5cc_java && kinit")
message("         bash run_analysis.sh")
