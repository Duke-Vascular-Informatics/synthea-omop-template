#!/usr/bin/env Rscript
# Step 8: Perform analysis and generate manuscript-format report.

run_script <- function(script) {
  status <- system2(file.path(R.home("bin"), "Rscript.exe"), args = c("--vanilla", script))
  if (!identical(status, 0L)) {
    stop("Script failed: ", script)
  }
}

run_script("run_risk_score_pipeline.R")
run_script("run_report.R")

cat("Step 8 complete: analysis executed and manuscript report generated.\n")
