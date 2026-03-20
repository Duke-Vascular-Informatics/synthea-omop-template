# =============================================================================
# setup_renv.R
# One-time renv initialisation for the SSI validation project.
#
# Run this FIRST in a fresh R session, then run install_packages.R.
# Usage: source("setup_renv.R")
# =============================================================================

options(repos = c(CRAN = "https://archive.linux.duke.edu/cran/"))

# Install renv if not present
if (!requireNamespace("renv", quietly = TRUE)) {
  install.packages("renv")
}

# Initialise renv only if not already done (preserves existing lock file)
if (!file.exists("renv.lock")) {
  renv::init(bare = TRUE)   # bare = TRUE: set up renv without auto-installing
} else {
  renv::activate()
}

message("renv initialised.")
message("Next step: source('install_packages.R') to install PLP and dependencies.")
