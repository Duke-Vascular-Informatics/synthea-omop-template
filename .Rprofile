source("renv/activate.R")

# Load .env if present — institution-specific settings (never committed)
local({
  env_file <- file.path(getwd(), ".env")
  if (file.exists(env_file)) {
    lines <- readLines(env_file, warn = FALSE)
    lines <- lines[!grepl("^\\s*#", lines) & nchar(trimws(lines)) > 0]
    for (line in lines) {
      eq <- regexpr("=", line, fixed = TRUE)
      if (eq < 2L) next
      key <- trimws(substr(line, 1L, eq - 1L))
      val <- trimws(substr(line, eq + 1L, nchar(line)))
      val <- gsub('^["\']|["\']$', "", val)  # strip optional surrounding quotes
      do.call(Sys.setenv, setNames(list(val), key))
    }
  }
})

# CRAN mirror — reads CRAN_MIRROR from .env / environment; falls back to cloud.r-project.org
options(repos = c(CRAN = Sys.getenv("CRAN_MIRROR", unset = "https://cloud.r-project.org")))
