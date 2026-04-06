# =============================================================================
# R/connection.R — PRCC bundle edition
#
# Configures Java and builds a DatabaseConnector connectionDetails object for
# the Duke PRCC (OMOP SQL Server) environment using Kerberos authentication.
#
# Authentication model:
#   - The user runs `kinit` in the shell before starting R (setup_prcc_env.sh
#     handles this). The Kerberos ticket is stored in ~/krb5cc_java.
#   - The JDBC URL uses integratedSecurity=true + authenticationScheme=JavaKerberos
#     so that the MSSQL JDBC driver picks up the OS-level Kerberos credential.
#   - No username or password is embedded in the script.
#
# Java model:
#   - Java comes from the conda openjdk environment (miniforge on PRCC).
#   - JAVA_HOME must be set before starting R (conda activate openjdk sets it).
#   - This file reads JAVA_HOME from config$java_home (resolved in config.R).
#
# Differences from the Windows dev bundle:
#   - No Windows auth DLL (mssql-jdbc-auth-*.dll) — not needed on Linux.
#   - No NativeAuthentication / NTLM — replaced by JavaKerberos.
#   - java.parameters uses -Xmx4g heap + -Djava.home; no -Djava.library.path.
# =============================================================================

# ---------------------------------------------------------------------------
# configure_java_prcc()
#
# Sets JAVA_HOME and PATH from config$java_home, then sets JVM startup options
# (heap size and java.home property) via options(java.parameters).
#
# Must be called BEFORE library(DatabaseConnector) / library(rJava) because
# the JVM is initialized at the moment rJava is first loaded and cannot be
# reconfigured afterwards.
# ---------------------------------------------------------------------------
configure_java_prcc <- function(config) {
  java_home <- config$java_home

  if (is.null(java_home) || nchar(trimws(java_home)) == 0) {
    stop(
      "java_home is empty in config. Activate the conda openjdk environment\n",
      "before starting R:\n",
      "  conda activate openjdk\n",
      "  Rscript run_analysis.R"
    )
  }

  Sys.setenv(JAVA_HOME = java_home)

  # Prepend <java_home>/bin to PATH so the correct java binary is first.
  java_bin <- file.path(java_home, "bin")
  Sys.setenv(PATH = paste(java_bin, Sys.getenv("PATH"), sep = ":"))

  # JVM startup options (must be set before rJava is loaded).
  # -Xmx4g  : allow up to 4 GB heap for large JDBC result sets.
  # -Djava.home : explicitly confirm java.home for rJava's JVM launch.
  # Do NOT set -Djava.library.path here — no auth DLL is needed on Linux.
  options(java.parameters = c(
    paste0("-Djava.home=", normalizePath(java_home, mustWork = FALSE)),
    "-Xmx4g"
  ))

  # Tell DatabaseConnector where to scan for the JDBC JAR.
  Sys.setenv(DATABASECONNECTOR_JAR_FOLDER =
               normalizePath(config$jdbc_runtime_dir, mustWork = FALSE))

  message("Java configured: ", java_home)
  invisible(config)
}

# ---------------------------------------------------------------------------
# build_connection_details()
#
# Assembles the JDBC connection string for Kerberos authentication and returns
# a DatabaseConnector ConnectionDetails object.
#
# The connection string format follows the Duke PRCC documentation:
#   jdbc:sqlserver://<server>
#     ;databaseName=<database>
#     ;integratedSecurity=true
#     ;authenticationScheme=JavaKerberos
#     ;trustServerCertificate=true
#     ;serverSpn=MSSQLSvc/<spn_host>
#
# config$spn_host is usually identical to config$server (the SQL Server
# hostname). If connections fail with Kerberos errors, open a ticket with
# DHTS/SOM-HPC to confirm the correct SPN.
#
# Prerequisites (enforced by this function):
#   1. KRB5CCNAME env var points to the Kerberos credential cache.
#   2. A valid Kerberos ticket is present (run `kinit` first).
#   3. configure_java_prcc() has been called (JVM options set).
# ---------------------------------------------------------------------------
build_connection_details <- function(config) {
  ensure_jdbc_bundle(config)
  configure_java_prcc(config)

  # Validate Kerberos ticket is present.
  # KRB5CCNAME must point to the file cache written by setup_prcc_env.sh.
  krb5 <- Sys.getenv("KRB5CCNAME")
  if (nchar(krb5) == 0) {
    warning(
      "KRB5CCNAME is not set. Kerberos authentication may fail.\n",
      "Run setup_prcc_env.sh (or manually: export KRB5CCNAME=FILE:~/krb5cc_java && kinit)\n",
      "before starting R."
    )
  }

  # Check that the Kerberos ticket cache file actually exists.
  krb5_file <- sub("^FILE:", "", krb5)
  if (nchar(krb5_file) > 0 && !file.exists(krb5_file)) {
    warning(
      "Kerberos ticket cache file not found: ", krb5_file, "\n",
      "Run `kinit` in the shell before starting R to obtain a fresh ticket."
    )
  }

  # Build the full JDBC connection URL.
  conn_string <- paste0(
    "jdbc:sqlserver://", config$server,
    ";databaseName=",     config$database,
    ";integratedSecurity=true",
    ";authenticationScheme=JavaKerberos",
    ";trustServerCertificate=true",
    ";serverSpn=MSSQLSvc/", config$spn_host
  )

  message("Building connection: ", config$server, " / ", config$database,
          " (Kerberos SPN: MSSQLSvc/", config$spn_host, ")")

  DatabaseConnector::createConnectionDetails(
    dbms             = "sql server",
    connectionString = conn_string,
    pathToDriver     = config$jdbc_runtime_dir
  )
}
