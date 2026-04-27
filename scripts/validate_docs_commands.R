#!/usr/bin/env Rscript
# =============================================================================
# scripts/validate_docs_commands.R
#
# Validates command/path references in documentation files.
# Fails with exit code 1 if known-bad patterns are found or referenced local
# scripts/workflow paths do not exist.
# =============================================================================

args_full <- commandArgs(trailingOnly = FALSE)
file_arg <- grep("^--file=", args_full, value = TRUE)
if (length(file_arg) > 0) {
  script_dir <- dirname(normalizePath(sub("^--file=", "", file_arg[1]), winslash = "/"))
  proj_root <- dirname(script_dir)
} else {
  proj_root <- getwd()
}
setwd(proj_root)

collect_docs <- function() {
  docs <- c(
    "README.md",
    "CHECKLIST.md",
    "workflow/README.md",
    "setup/README.md",
    "scripts/README.md",
    "cohorts/README.md",
    "R/README.md",
    "drivers/README.md",
    "tests/README.md",
    "dist/README.md",
    list.files("docs", pattern = "\\.md$", full.names = TRUE),
    list.files("scripts", pattern = "README\\.md$", full.names = TRUE, recursive = TRUE)
  )
  unique(docs[file.exists(docs)])
}

add_issue <- function(issues, path, line_no, message) {
  c(issues, sprintf("%s:%d: %s", path, line_no, message))
}

doc_files <- collect_docs()
issues <- character(0)

known_bad_patterns <- list(
  list(
    pattern = "workflow/09_create_transportable_bundle\\.R",
    message = "Use workflow/09_build_portable_analysis_bundle.sh or .ps1 instead."
  ),
  list(
    pattern = "Rscript\\s+workflow/04_generate_synthea_csv\\.(sh|ps1)",
    message = "Use bash for .sh and powershell -File for .ps1."
  ),
  list(
    pattern = "setup/setup_omop_vocab_schema\\.R",
    message = "Use scripts/setup_omop_vocab_schema.R."
  )
)

path_pattern <- "(workflow/[A-Za-z0-9_./-]+\\.(R|sh|ps1)|scripts/[A-Za-z0-9_./-]+\\.R)"

for (path in doc_files) {
  lines <- readLines(path, warn = FALSE)

  for (rule in known_bad_patterns) {
    hit_idx <- grep(rule$pattern, lines, perl = TRUE)
    if (length(hit_idx) > 0) {
      for (i in hit_idx) {
        issues <- add_issue(issues, path, i, rule$message)
      }
    }
  }

  refs <- regmatches(lines, gregexpr(path_pattern, lines, perl = TRUE))
  refs <- unique(unlist(refs, use.names = FALSE))
  refs <- refs[nzchar(refs)]

  for (ref in refs) {
    if (!file.exists(ref)) {
      hit_idx <- grep(gsub("([.|()\\^{}+$*?]|\\[|\\])", "\\\\\\1", ref), lines)
      line_no <- if (length(hit_idx) > 0) hit_idx[1] else 1
      issues <- add_issue(issues, path, line_no, paste0("Referenced path does not exist: ", ref))
    }
  }
}

if (length(issues) > 0) {
  cat("Documentation command/path validation FAILED:\n\n")
  cat(paste0("- ", issues, collapse = "\n"), "\n")
  quit(status = 1)
}

cat("Documentation command/path validation passed.\n")
