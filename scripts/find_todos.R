#!/usr/bin/env Rscript
# =============================================================================
# scripts/find_todos.R
#
# Lists every TODO placeholder that still needs to be filled in before running
# Step 8.  Works on Windows, macOS, and Linux (no shell grep required).
#
# Usage (from project root):
#   Rscript scripts/find_todos.R
# =============================================================================

targets <- c(
  "config.R",
  list.files("cohorts",   pattern = "\\.sql$", full.names = TRUE, recursive = TRUE),
  list.files("covariates", pattern = "\\.csv$|.R$", full.names = TRUE, recursive = TRUE),
  list.files("workflow",  pattern = "^02|^07|^08", full.names = TRUE)
)
targets <- targets[file.exists(targets)]

found <- 0L
for (path in targets) {
  lines <- tryCatch(readLines(path, warn = FALSE), error = function(e) character(0))
  hits  <- grep("TODO \\[", lines)
  for (i in hits) {
    cat(sprintf("%s:%d: %s\n", path, i, trimws(lines[i])))
    found <- found + 1L
  }
}

if (found == 0L) {
  message("No TODO placeholders found — ready to run Step 8.")
} else {
  message(sprintf("\n%d TODO placeholder(s) remaining.", found))
}
