# Ensure working directory is the project root when tests run.
# testthat changes CWD to the test directory before sourcing files;
# this helper (auto-sourced first) moves it back to the project root
# so that source("R/...") calls in test files resolve correctly.
if (!file.exists("R/connection.R")) {
  setwd("../..")
}
