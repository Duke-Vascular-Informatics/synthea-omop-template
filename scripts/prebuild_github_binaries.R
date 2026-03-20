# =============================================================================
# scripts/prebuild_github_binaries.R
# Build internal Windows binary packages (.zip) for GitHub-only OHDSI packages
# so install_packages.R can run without GitHub access.
#
# Usage (from project root):
#   Rscript scripts/prebuild_github_binaries.R
#
# Output:
#   internal_repo/bin/windows/contrib/<R_major.minor>/*.zip
#   internal_repo/bin/windows/contrib/<R_major.minor>/PACKAGES*
# =============================================================================

if (file.exists("renv/activate.R")) source("renv/activate.R")
options(repos = c(CRAN = "https://archive.linux.duke.edu/cran/"))

# Keep Java configured for subprocesses (R CMD build / INSTALL) because
# FeatureExtraction and PatientLevelPrediction load DatabaseConnector/rJava.
java_home <- "C:/Program Files/Eclipse Adoptium/jdk-17.0.18.8-hotspot"
java_bin <- file.path(java_home, "bin")
Sys.setenv(JAVA_HOME = java_home)
Sys.setenv(
  PATH = paste(
    normalizePath(java_bin, winslash = "\\", mustWork = FALSE),
    Sys.getenv("PATH"),
    sep = .Platform$path.sep
  )
)

# R CMD INSTALL --build needs a `zip` command on PATH. On minimal Windows
# setups this is often absent, so create a small wrapper using PowerShell
# Compress-Archive and point R_ZIPCMD to it.
configure_zip_command <- function() {
  zip_candidates <- c(
    "C:/Program Files/Git/usr/bin/zip.exe",
    "C:/Program Files/Git/bin/zip.exe"
  )
  zip_candidates <- zip_candidates[file.exists(zip_candidates)]

  if (length(zip_candidates) > 0) {
    zip_path <- normalizePath(zip_candidates[[1]], winslash = "/", mustWork = TRUE)
    Sys.setenv(R_ZIPCMD = zip_path)
    Sys.setenv(ZIP = zip_path)
    return(invisible(TRUE))
  }

  wrapper_dir <- file.path(tempdir(), "zip-wrapper")
  dir.create(wrapper_dir, recursive = TRUE, showWarnings = FALSE)

  ps1 <- file.path(wrapper_dir, "zip-wrapper.ps1")
  cmd <- file.path(wrapper_dir, "zip.cmd")

  writeLines(c(
    "param([Parameter(ValueFromRemainingArguments=$true)][string[]]$Args)",
    "$filtered = @()",
    "foreach ($a in $Args) { if (-not $a.StartsWith('-')) { $filtered += $a } }",
    "if ($filtered.Count -lt 2) { throw 'zip-wrapper: expected destination and at least one input path.' }",
    "$dest = $filtered[0]",
    "$inputs = $filtered[1..($filtered.Count - 1)]",
    "if (Test-Path $dest) { Remove-Item -Force $dest }",
    "Compress-Archive -Path $inputs -DestinationPath $dest -Force"
  ), ps1)

  writeLines(c(
    "@echo off",
    "powershell -NoProfile -ExecutionPolicy Bypass -File \"%~dp0zip-wrapper.ps1\" %*"
  ), cmd)

  cmd_path <- normalizePath(cmd, winslash = "/", mustWork = TRUE)
  Sys.setenv(R_ZIPCMD = cmd_path)
  Sys.setenv(ZIP = cmd_path)
  Sys.setenv(
    PATH = paste(
      normalizePath(wrapper_dir, winslash = "\\", mustWork = TRUE),
      Sys.getenv("PATH"),
      sep = .Platform$path.sep
    )
  )
  invisible(TRUE)
}

configure_zip_command()

if (!requireNamespace("remotes", quietly = TRUE)) {
  install.packages("remotes")
}

github_packages <- list(
  list(package = "FeatureExtraction",      repo = "OHDSI/FeatureExtraction",      ref = "v3.6.0"),
  list(package = "CohortGenerator",        repo = "OHDSI/CohortGenerator",        ref = "v0.9.0"),
  list(package = "PatientLevelPrediction", repo = "OHDSI/PatientLevelPrediction", ref = "v6.4.0")
)

r_ver <- paste(R.version$major, sub("\\..*$", "", R.version$minor), sep = ".")
repo_dir <- file.path("internal_repo", "bin", "windows", "contrib", r_ver)
dir.create(repo_dir, recursive = TRUE, showWarnings = FALSE)

r_bin <- file.path(R.home("bin"), "Rcmd.exe")
if (!file.exists(r_bin)) {
  stop("Rcmd.exe not found at: ", r_bin)
}

build_root <- file.path(tempdir(), "ohdsi_github_build")
dir.create(build_root, recursive = TRUE, showWarnings = FALSE)

message("Building GitHub package binaries into: ", normalizePath(repo_dir, winslash = "/", mustWork = FALSE))

for (p in github_packages) {
  message("\n--- ", p$package, " (", p$repo, " @ ", p$ref, ") ---")

  # Install once from GitHub to guarantee dependencies and a clean source build.
  remotes::install_github(
    repo = p$repo,
    ref = p$ref,
    upgrade = "never",
    dependencies = TRUE,
    build = TRUE,
    quiet = FALSE
  )

  # Build source tarball from checked-out GitHub source.
  src_dir <- file.path(build_root, p$package)
  if (dir.exists(src_dir)) unlink(src_dir, recursive = TRUE, force = TRUE)

  # remotes has no stable exported downloader, so use git clone by tag.
  clone_ref <- sub("^v", "", p$ref)
  clone_url <- paste0("https://github.com/", p$repo, ".git")

  system2("git", c("clone", "--depth", "1", "--branch", p$ref, clone_url, src_dir), stdout = TRUE, stderr = TRUE)

  build_out <- system2(
    r_bin,
    c("build", src_dir, "--no-manual", "--no-build-vignettes"),
    stdout = TRUE,
    stderr = TRUE
  )
  cat(paste(build_out, collapse = "\n"), "\n")

  tar_pattern <- paste0("^", p$package, "_.*\\.tar\\.gz$")
  tar_files <- list.files(getwd(), pattern = tar_pattern, full.names = TRUE)
  if (length(tar_files) == 0) {
    stop("Could not find source tarball for ", p$package, " after R CMD build.")
  }
  tar_file <- tar_files[[which.max(file.info(tar_files)$mtime)]]

  # Build Windows binary zip from the source tarball.
  install_out <- system2(
    r_bin,
    c("INSTALL", "--build", tar_file),
    stdout = TRUE,
    stderr = TRUE
  )
  cat(paste(install_out, collapse = "\n"), "\n")

  zip_pattern <- paste0("^", p$package, "_.*\\.zip$")
  zip_files <- list.files(getwd(), pattern = zip_pattern, full.names = TRUE)
  if (length(zip_files) == 0) {
    stop("Could not find built zip for ", p$package, " after R CMD INSTALL --build.")
  }
  zip_file <- zip_files[[which.max(file.info(zip_files)$mtime)]]

  target_zip <- file.path(repo_dir, basename(zip_file))
  file.copy(zip_file, target_zip, overwrite = TRUE)
  message("Saved binary: ", normalizePath(target_zip, winslash = "/", mustWork = FALSE))
}

tools::write_PACKAGES(dir = repo_dir, type = "win.binary")
message("\nInternal binary repository metadata generated.")
message("Repository path: ", normalizePath(repo_dir, winslash = "/", mustWork = FALSE))
message("Done.")
