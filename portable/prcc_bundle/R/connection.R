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
#   - A JAAS config file (jaas.conf) is written at runtime and passed to the JVM
#     via -Djava.security.auth.login.config so the MSSQL JDBC driver can locate
#     the Kerberos login module and ticket cache.
#   - No username or password is embedded in the script.
#
# Java model:
#   - Java comes from the conda openjdk environment (miniforge on PRCC).
#   - JAVA_HOME must be set before starting R (source activate openjdk sets it).
#   - This file reads JAVA_HOME from config$java_home (resolved in config.R).
#
# Differences from the Windows dev bundle:
#   - No Windows auth DLL (mssql-jdbc-auth-*.dll) — not needed on Linux.
#   - No NativeAuthentication / NTLM — replaced by JavaKerberos.
#   - java.parameters uses -Xmx4g heap + -Djava.home +
#     -Djava.security.auth.login.config; no -Djava.library.path.
# =============================================================================

# ---------------------------------------------------------------------------
# write_jaas_conf()
#
# Generates a JAAS (Java Authentication and Authorization Service) config file
# at jaas_path and returns its absolute path.
#
# The MSSQL JDBC driver requires a JAAS config when using JavaKerberos
# authentication so the JVM knows which Kerberos login module to use.
# The generated file points the driver at the Krb5LoginModule and tells it
# to use the existing ticket cache obtained by `kinit` (doNotPrompt=true).
#
# The ticketCache path is taken from the KRB5CCNAME environment variable
# (set by setup_prcc_env.sh as FILE:~/krb5cc_java) with the FILE: prefix
# stripped and ~ expanded.  If KRB5CCNAME is unset the ticketCache line is
# omitted and the JVM falls back to its default cache location.
#
# The file is (re)written every time configure_java_prcc() is called so the
# path is always current; this is safe because configure_java_prcc() must
# run before rJava is loaded.
# ---------------------------------------------------------------------------
write_jaas_conf <- function(jaas_path) {

  # Resolve Kerberos ticket cache path from the environment variable set by
  # setup_prcc_env.sh: KRB5CCNAME=FILE:~/krb5cc_java
  krb5_env  <- Sys.getenv("KRB5CCNAME")
  krb5_file <- path.expand(sub("^FILE:", "", krb5_env))

  # Standard JAAS stanza for the MSSQL JDBC Kerberos login module.
  # SQLJDBCDriver is the entry name the MSSQL JDBC driver looks up by default.
  # JAAS syntax requires the semicolon to terminate the LAST option line —
  # it cannot appear on its own line or the JVM will fail to parse the stanza.
  if (nchar(krb5_file) > 0) {
    # ticketCache is the last line — semicolon appended to it.
    last_line <- paste0('   ticketCache="', krb5_file, '";\n')
    middle    <- "   useTicketCache=true\n"
  } else {
    # useTicketCache is the last line when no explicit cache path is available.
    last_line <- "   useTicketCache=true;\n"
    middle    <- ""
  }

  jaas_content <- paste0(
    "SQLJDBCDriver {\n",
    "   com.sun.security.auth.module.Krb5LoginModule required\n",
    "   doNotPrompt=true\n",
    middle,
    last_line,
    "};\n"
  )

  writeLines(jaas_content, jaas_path)
  message("JAAS config written: ", jaas_path)
  invisible(jaas_path)
}

# ---------------------------------------------------------------------------
# configure_java_prcc()
#
# Sets JAVA_HOME and PATH from config$java_home, writes jaas.conf, then sets
# JVM startup options via options(java.parameters).
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
      "  source activate openjdk\n",
      "  Rscript run_analysis.R"
    )
  }

  Sys.setenv(JAVA_HOME = java_home)

  # Prepend <java_home>/bin to PATH so the correct java binary is first.
  java_bin <- file.path(java_home, "bin")
  Sys.setenv(PATH = paste(java_bin, Sys.getenv("PATH"), sep = ":"))

  # Write jaas.conf to the drivers/ directory alongside the JDBC JAR and
  # capture its absolute path.  This must happen before options(java.parameters)
  # so the path is available when the JVM parameters are set.
  jaas_conf_path <- normalizePath(
    file.path(config$jdbc_runtime_dir, "jaas.conf"),
    mustWork = FALSE
  )
  write_jaas_conf(jaas_conf_path)

  # JVM startup options (must be set before rJava is loaded).
  # -Djava.home                      : confirm java.home for rJava's JVM launch.
  # -Djava.security.auth.login.config: JAAS config for Kerberos login module.
  # -Xmx4g                           : allow up to 4 GB heap for large result sets.
  # Do NOT set -Djava.library.path here — no auth DLL is needed on Linux.
  options(java.parameters = c(
    paste0("-Djava.home=", normalizePath(java_home, mustWork = FALSE)),
    paste0("-Djava.security.auth.login.config=", jaas_conf_path),
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
# Builds a DatabaseConnector ConnectionDetails object for Kerberos
# authentication on PRCC using the extraSettings approach recommended in the
# DatabaseConnector vignette "Connecting with Windows authentication from a
# non-windows machine":
#
#   createConnectionDetails(
#     dbms          = "sql server",
#     server        = "<host>/<database>",
#     extraSettings = "authenticationScheme=JavaKerberos"
#   )
#
# authenticationScheme=JavaKerberos tells the MSSQL JDBC driver to use the
# Kerberos ticket cache obtained by `kinit` rather than prompting for a
# username/password.
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

  # server argument format for DatabaseConnector SQL Server:
  # "<hostname>/<database>" — DatabaseConnector constructs the JDBC URL from this.
  server_arg <- paste0(config$server, "/", config$database)

  message("Building connection: ", config$server, " / ", config$database,
          " (authenticationScheme=JavaKerberos)")

  DatabaseConnector::createConnectionDetails(
    dbms          = "sql server",
    server        = server_arg,
    extraSettings = "authenticationScheme=JavaKerberos",
    pathToDriver  = config$jdbc_runtime_dir
  )
}
