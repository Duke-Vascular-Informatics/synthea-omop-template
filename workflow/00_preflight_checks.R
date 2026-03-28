#!/usr/bin/env Rscript
# Deprecated compatibility shim.
#
# Step 00 has been deprecated. Package-install validation and DB preflight now
# run as part of Step 01.

bootstrap_path <- local({
  file_arg <- grep("^--file=", commandArgs(trailingOnly = FALSE), value = TRUE)
  if (length(file_arg) > 0) {
    normalizePath(
      file.path(dirname(sub("^--file=", "", file_arg[1])), "workflow_bootstrap.R"),
      winslash = "/",
      mustWork = FALSE
    )
  } else {
    "workflow/workflow_bootstrap.R"
  }
})
source(bootstrap_path)
set_workflow_root()

message("Step 00 is deprecated and now delegates to Step 01.")
message("Running workflow/01_setup_synthea_etl_qc_env.R ...")

args <- commandArgs(trailingOnly = TRUE)
cmd <- c("workflow/01_setup_synthea_etl_qc_env.R", args)
status <- system2(file.path(R.home("bin"), "Rscript.exe"), args = cmd)
if (!identical(status, 0L)) {
  stop("Delegated Step 01 setup failed.")
}

cat("Step 00 compatibility shim complete.\n")
