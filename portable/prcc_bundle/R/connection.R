# =============================================================================
# R/connection.R — PRCC bundle edition
#
# Configures Java and connects to SQL Server via Kerberos authentication on
# Duke PRCC, following the approach provided by Duke SOM-HPC.
#
# Authentication model:
#   - The user runs `kinit` (via setup_prcc_env.sh) before starting R.
#     The Kerberos ticket is stored at ~/krb5cc_java.
#   - A JAAS config (drivers/jaas.conf) is written at runtime pointing the
#     MSSQL JDBC driver at the Krb5LoginModule and ticket cache.
#   - The JVM is explicitly initialised via rJava::.jinit() BEFORE
#     library(DatabaseConnector) is called — this is required so that
#     java.parameters (including the JAAS path) take effect.
#   - Two JARs are added to the classpath:
#       1. prcc-jdbc-mssql-1.0-SNAPSHOT.jar  (Duke SOM-HPC wrapper, ~/drivers/)
#       2. mssql-jdbc-13.2.1.jre11.jar       (bundled in drivers/)
#   - The JDBC URL uses integratedSecurity=true + authenticationScheme=JavaKerberos.
#   - No username or password is embedded in the script.
#
# Call order (enforced by run_analysis.R):
#   1. source("config.R")          — resolves java_home, prcc_jar, jdbc_runtime_dir
#   2. configure_java_prcc(config) — sets java.parameters, writes jaas.conf,
#                                    calls .jinit(), adds JARs to classpath
#   3. library(DatabaseConnector)  — JVM already running; picks up classpath
#   4. build_connection_details()  — constructs JDBC URL, returns ConnectionDetails
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
# Sets JAVA_HOME and PATH, writes jaas.conf, sets java.parameters, then
# explicitly initialises the JVM via rJava::.jinit() and adds both JDBC JARs
# to the classpath.
#
# MUST be called BEFORE library(DatabaseConnector) — run_analysis.R does this.
# Once the JVM is running, java.parameters cannot be changed.
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

  # Write jaas.conf to drivers/ and capture its absolute path.
  jaas_conf_path <- normalizePath(
    file.path(config$jdbc_runtime_dir, "jaas.conf"),
    mustWork = FALSE
  )
  write_jaas_conf(jaas_conf_path)

  # Set JVM startup options BEFORE the JVM is initialised.
  # -Djava.home                       : confirm java.home for rJava.
  # -Djava.security.auth.login.config : JAAS config for Kerberos login module.
  # -Xmx4g                            : 4 GB heap for large JDBC result sets.
  options(java.parameters = c(
    paste0("-Djava.home=",                       normalizePath(java_home, mustWork = FALSE)),
    paste0("-Djava.security.auth.login.config=", jaas_conf_path),
    "-Xmx4g"
  ))

  # Explicitly initialise the JVM now (before library(DatabaseConnector) loads
  # rJava implicitly) so the java.parameters above are honoured.
  library(rJava)
  rJava::.jinit()

  # Add both JDBC JARs to the running JVM's classpath:
  #   1. Duke SOM-HPC Kerberos wrapper — required for authentication on PRCC.
  #   2. Standard MSSQL JDBC driver   — bundled in drivers/.
  prcc_jar     <- normalizePath(config$prcc_jar,     mustWork = FALSE)
  bundled_jar  <- normalizePath(
    file.path(config$jdbc_runtime_dir,
              "mssql-jdbc-13.2.1.jre11.jar"),
    mustWork = FALSE
  )

  if (!file.exists(prcc_jar)) {
    stop(
      "PRCC custom JAR not found: ", prcc_jar, "\n",
      "Expected at ~/drivers/prcc-jdbc-mssql-1.0-SNAPSHOT.jar on PRCC.\n",
      "Contact Duke SOM-HPC to obtain this file."
    )
  }
  if (!file.exists(bundled_jar)) {
    stop("Bundled MSSQL JDBC JAR not found: ", bundled_jar)
  }

  rJava::.jaddClassPath(prcc_jar)
  rJava::.jaddClassPath(bundled_jar)
  message("Classpath: ", basename(prcc_jar), " + ", basename(bundled_jar))

  # Tell DatabaseConnector where to scan for JDBC JARs (fallback).
  Sys.setenv(DATABASECONNECTOR_JAR_FOLDER =
               normalizePath(config$jdbc_runtime_dir, mustWork = FALSE))

  message("Java configured: ", java_home)
  invisible(config)
}

# ---------------------------------------------------------------------------
# build_connection_details()
#
# Builds a DatabaseConnector ConnectionDetails object using the full JDBC URL
# approach confirmed by Duke SOM-HPC for Kerberos authentication on PRCC:
#
#   jdbc:sqlserver://<server>;databaseName=<db>;integratedSecurity=true;
#     authenticationScheme=JavaKerberos;trustServerCertificate=true
#
# configure_java_prcc() must have been called before this function (and before
# library(DatabaseConnector)) so the JVM is already running with the correct
# classpath and JAAS config.
#
# Prerequisites:
#   1. configure_java_prcc(config) called before library(DatabaseConnector).
#   2. KRB5CCNAME set and a valid Kerberos ticket obtained via kinit.
# ---------------------------------------------------------------------------
build_connection_details <- function(config) {
  ensure_jdbc_bundle(config)

  # Validate Kerberos ticket is present.
  krb5 <- Sys.getenv("KRB5CCNAME")
  if (nchar(krb5) == 0) {
    warning(
      "KRB5CCNAME is not set. Kerberos authentication may fail.\n",
      "Run: export KRB5CCNAME=FILE:~/krb5cc_java && kinit"
    )
  }

  # Check that the ticket cache file exists.
  krb5_file <- path.expand(sub("^FILE:", "", krb5))
  if (nchar(krb5_file) > 0 && !file.exists(krb5_file)) {
    warning(
      "Kerberos ticket cache not found: ", krb5_file, "\n",
      "Run `kinit` before starting R."
    )
  }

  # Full JDBC URL — matches the approach confirmed by Duke SOM-HPC.
  jdbc_url <- paste0(
    "jdbc:sqlserver://", config$server,
    ";databaseName=",         config$database,
    ";integratedSecurity=true",
    ";authenticationScheme=JavaKerberos",
    ";trustServerCertificate=true"
  )

  message("Building connection: ", config$server, " / ", config$database,
          " (JavaKerberos)")

  DatabaseConnector::createConnectionDetails(
    dbms             = "sql server",
    connectionString = jdbc_url,
    pathToDriver     = config$jdbc_runtime_dir
  )
}
