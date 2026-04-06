# =============================================================================
# R/connection.R
# Build a DatabaseConnector connectionDetails object for the OMOP SQL Server
# instance.  The JDBC driver is provisioned locally by R/drivers.R and does
# not depend on any external project.
# =============================================================================

# Set Java environment variables and load the JDBC auth DLL required for
# Windows Integrated Security (Kerberos / NTLM).
configure_java <- function(config) {
  if (!dir.exists(config$java_home)) {
    stop("JAVA_HOME directory not found: ", config$java_home,
         "\nUpdate java_home in config.R to match your JDK installation.")
  }

  Sys.setenv(JAVA_HOME = config$java_home)
  Sys.setenv(PATH = paste(
    normalizePath(config$java_bin, winslash = "\\", mustWork = FALSE),
    Sys.getenv("PATH"),
    sep = .Platform$path.sep
  ))

  # Point Java to the JDBC auth DLL folder for integrated-security connections.
  if (dir.exists(config$jdbc_auth_dir)) {
    options(java.parameters = paste0(
      "-Djava.library.path=",
      normalizePath(config$jdbc_auth_dir, winslash = "/")
    ))
    Sys.setenv(PATH = paste(
      normalizePath(config$jdbc_auth_dir, winslash = "\\"),
      Sys.getenv("PATH"),
      sep = .Platform$path.sep
    ))
  } else {
    options(java.parameters = paste0(
      "-Djava.home=",
      normalizePath(config$java_home, winslash = "/", mustWork = FALSE)
    ))
  }

  # Tell DatabaseConnector where the JDBC jar lives.
  Sys.setenv(DATABASECONNECTOR_JAR_FOLDER = config$jdbc_runtime_dir)

  invisible(config)
}

# Build a DatabaseConnector connectionDetails object using Windows Integrated
# Security (no username / password embedded in the script).
build_connection_details <- function(config) {
  # Download and stage the JDBC bundle on first run; no-op on subsequent runs.
  ensure_jdbc_bundle(config)
  configure_java(config)

  DatabaseConnector::createConnectionDetails(
    dbms         = config$dbms,
    server       = config$server,
    user         = "",
    password     = "",
    pathToDriver = config$jdbc_runtime_dir,
    extraSettings = paste0(
      "database=", config$database,
      ";integratedSecurity=true",
      ";authenticationScheme=NativeAuthentication",
      ";trustServerCertificate=true",
      ";portNumber=", config$sql_server_port
    )
  )
}
