#!/usr/bin/env Rscript
# Step 3: Generate disease-specific Synthea module artifacts (diagram and validation checks).

resolve_script_path <- function() {
  file_arg <- grep("^--file=", commandArgs(trailingOnly = FALSE), value = TRUE)
  if (length(file_arg) > 0) {
    return(normalizePath(sub("^--file=", "", file_arg[1]), winslash = "/", mustWork = FALSE))
  }

  if (!is.null(sys.frames()[[1]]$ofile)) {
    return(normalizePath(sys.frames()[[1]]$ofile, winslash = "/", mustWork = FALSE))
  }

  NA_character_
}

script_path <- resolve_script_path()
if (!is.na(script_path)) {
  setwd(normalizePath(file.path(dirname(script_path), ".."), winslash = "/", mustWork = FALSE))
}

if (!requireNamespace("jsonlite", quietly = TRUE)) {
  stop("Package 'jsonlite' is required. Install via renv first.")
}

module_path <- "synthea/modules/pad_ssi.json"
if (!file.exists(module_path)) {
  stop("Missing module file: ", module_path)
}

module <- jsonlite::fromJSON(module_path, simplifyVector = FALSE)
if (is.null(module$states) || length(module$states) == 0) {
  stop("Synthea module has no states: ", module_path)
}

# Regenerate Mermaid artifacts from the module JSON.
args <- c("scripts/synthea/generate_synthea_mermaid.R", module_path, "synthea/modules/pad_ssi.mmd")
status <- system2(file.path(R.home("bin"), "Rscript.exe"), args = args)
if (!identical(status, 0L)) {
  stop("Failed to generate Synthea Mermaid artifacts.")
}

cat("Step 3 complete: module validated and diagram artifacts generated.\n")
