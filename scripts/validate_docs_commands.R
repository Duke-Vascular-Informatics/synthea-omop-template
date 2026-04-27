#!/usr/bin/env Rscript
# =============================================================================
# scripts/validate_docs_commands.R
#
# Validates command/path references in documentation files.
# Fails with exit code 1 if known-bad patterns are found, referenced local
# scripts/workflow paths do not exist, or step/heading governance rules fail.
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
    ".github/pull_request_template.md",
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

escape_regex <- function(x) {
  gsub("([][{}()+*^$.|?\\\\])", "\\\\\\\\\\1", x)
}

parse_step_map <- function(path) {
  if (!file.exists(path)) {
    return(data.frame(step = integer(0), title = character(0), anchor = character(0), stringsAsFactors = FALSE))
  }

  lines <- readLines(path, warn = FALSE)
  idx <- grep("^\\s*-\\s*step:\\s*[0-9]+\\s*$", lines, perl = TRUE)
  if (length(idx) == 0) {
    return(data.frame(step = integer(0), title = character(0), anchor = character(0), stringsAsFactors = FALSE))
  }

  rows <- lapply(seq_along(idx), function(i) {
    start <- idx[i]
    end <- if (i < length(idx)) idx[i + 1] - 1 else length(lines)
    block <- lines[start:end]

    step_line <- block[grep("^\\s*-\\s*step:\\s*[0-9]+\\s*$", block, perl = TRUE)][1]
    title_line <- block[grep("^\\s*title:\\s*.+$", block, perl = TRUE)][1]
    anchor_line <- block[grep("^\\s*anchor:\\s*.+$", block, perl = TRUE)][1]

    step <- as.integer(sub("^\\s*-\\s*step:\\s*([0-9]+)\\s*$", "\\1", step_line, perl = TRUE))
    title <- trimws(sub("^\\s*title:\\s*(.+)$", "\\1", title_line, perl = TRUE))
    anchor <- trimws(sub("^\\s*anchor:\\s*(.+)$", "\\1", anchor_line, perl = TRUE))

    if (is.na(step) || !nzchar(title) || !nzchar(anchor)) {
      return(NULL)
    }

    data.frame(step = step, title = title, anchor = anchor, stringsAsFactors = FALSE)
  })

  rows <- rows[!vapply(rows, is.null, logical(1))]
  if (length(rows) == 0) {
    return(data.frame(step = integer(0), title = character(0), anchor = character(0), stringsAsFactors = FALSE))
  }

  do.call(rbind, rows)
}

normalize_h2 <- function(line) {
  heading <- trimws(sub("^##\\s+", "", line))
  heading <- tolower(heading)
  heading <- gsub("`", "", heading)
  heading
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

required_refs <- list(
  list(path = "README.md", pattern = "docs/COMMANDS\\.md", message = "Link to docs/COMMANDS.md as canonical command index."),
  list(path = "CHECKLIST.md", pattern = "docs/COMMANDS\\.md", message = "Link to docs/COMMANDS.md instead of duplicating command tables."),
  list(path = "docs/README.md", pattern = "COMMANDS\\.md", message = "Include docs/COMMANDS.md in docs index.")
)

path_pattern <- "(workflow/[A-Za-z0-9_./-]+\\.(R|sh|ps1)|scripts/[A-Za-z0-9_./-]+\\.R)"

heading_map <- list()

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
      hit_idx <- grep(escape_regex(ref), lines, perl = TRUE)
      line_no <- if (length(hit_idx) > 0) hit_idx[1] else 1
      issues <- add_issue(issues, path, line_no, paste0("Referenced path does not exist: ", ref))
    }
  }

  h2_idx <- grep("^##\\s+", lines)
  if (length(h2_idx) > 0) {
    h2_vals <- vapply(lines[h2_idx], normalize_h2, character(1))
    dup_vals <- unique(h2_vals[duplicated(h2_vals)])
    if (length(dup_vals) > 0) {
      for (dup_val in dup_vals) {
        first_line <- h2_idx[which(h2_vals == dup_val)[1]]
        issues <- add_issue(
          issues,
          path,
          first_line,
          paste0("Duplicate H2 heading in file: ", dup_val)
        )
      }
    }
    heading_map[[path]] <- data.frame(line = h2_idx, heading = h2_vals, stringsAsFactors = FALSE)
  }
}

for (req in required_refs) {
  if (file.exists(req$path)) {
    lines <- readLines(req$path, warn = FALSE)
    if (!any(grepl(req$pattern, lines, perl = TRUE))) {
      issues <- add_issue(issues, req$path, 1, req$message)
    }
  }
}

top_docs <- intersect(c("README.md", "docs/README.md", "CHECKLIST.md"), names(heading_map))
if (length(top_docs) > 1) {
  all_top <- do.call(rbind, lapply(top_docs, function(path) {
    data.frame(path = path, heading = heading_map[[path]]$heading, line = heading_map[[path]]$line, stringsAsFactors = FALSE)
  }))

  allow_cross_file <- c("scope")
  cross_counts <- table(all_top$heading)
  repeated <- names(cross_counts[cross_counts > 1])
  repeated <- repeated[!(repeated %in% allow_cross_file)]
  repeated <- repeated[!grepl("^phase\\s+[0-9]+:", repeated)]

  if (length(repeated) > 0) {
    for (heading in repeated) {
      hit <- all_top[all_top$heading == heading, , drop = FALSE][1, ]
      issues <- add_issue(
        issues,
        hit$path,
        hit$line,
        paste0("H2 heading reused across top docs: ", heading)
      )
    }
  }
}

step_map_path <- "docs/workflow_steps.yaml"
steps <- parse_step_map(step_map_path)

if (nrow(steps) == 0) {
  issues <- add_issue(issues, step_map_path, 1, "Step map is missing or malformed.")
} else {
  steps <- steps[order(steps$step), ]
  expected <- seq_len(nrow(steps))
  if (!identical(steps$step, expected)) {
    issues <- add_issue(issues, step_map_path, 1, "Step numbers must be sequential starting at 1.")
  }

  gs_path <- "docs/GETTING_STARTED.md"
  if (file.exists(gs_path)) {
    gs_lines <- readLines(gs_path, warn = FALSE)
    gs_idx <- grep("^## Step [0-9]+:", gs_lines)

    if (length(gs_idx) != nrow(steps)) {
      issues <- add_issue(
        issues,
        gs_path,
        if (length(gs_idx) > 0) gs_idx[1] else 1,
        paste0("Step heading count (", length(gs_idx), ") does not match step map (", nrow(steps), ").")
      )
    }

    parsed <- lapply(gs_lines[gs_idx], function(x) {
      m <- regexec("^## Step ([0-9]+):\\s*(.+)$", x, perl = TRUE)
      parts <- regmatches(x, m)[[1]]
      if (length(parts) != 3) {
        return(NULL)
      }
      step_num <- as.integer(parts[2])
      title_full <- trimws(parts[3])
      title_core <- trimws(sub("\\s*\\(.*$", "", title_full))
      list(step = step_num, title = title_core)
    })

    parsed <- parsed[!vapply(parsed, is.null, logical(1))]
    if (length(parsed) == nrow(steps)) {
      for (i in seq_len(nrow(steps))) {
        if (parsed[[i]]$step != steps$step[i] || parsed[[i]]$title != steps$title[i]) {
          issues <- add_issue(
            issues,
            gs_path,
            gs_idx[i],
            paste0(
              "Step heading mismatch for step ",
              steps$step[i],
              ": expected '",
              steps$title[i],
              "'."
            )
          )
        }
      }
    }
  }

  checklist_path <- "CHECKLIST.md"
  if (file.exists(checklist_path)) {
    cl_lines <- readLines(checklist_path, warn = FALSE)
    for (i in seq_len(nrow(steps))) {
      pattern <- paste0("Step\\s+", steps$step[i], "(\\b|\\.)")
      if (!any(grepl(pattern, cl_lines, perl = TRUE))) {
        issues <- add_issue(
          issues,
          checklist_path,
          1,
          paste0("Checklist is missing a reference to Step ", steps$step[i], ".")
        )
      }
    }
  }
}

if (length(issues) > 0) {
  cat("Documentation command/path validation FAILED:\n\n")
  cat(paste0("- ", issues, collapse = "\n"), "\n")
  quit(status = 1)
}

cat("Documentation command/path validation passed.\n")
