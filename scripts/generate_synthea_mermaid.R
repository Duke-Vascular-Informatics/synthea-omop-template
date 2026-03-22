#!/usr/bin/env Rscript

# Generate a Mermaid flowchart from a Synthea GMF module JSON.
# Usage:
#   Rscript scripts/generate_synthea_mermaid.R <input_json> <output_mmd>

args <- commandArgs(trailingOnly = TRUE)
if (length(args) != 2) {
  stop("Usage: Rscript scripts/generate_synthea_mermaid.R <input_json> <output_mmd>")
}

input_json <- args[[1]]
output_mmd <- args[[2]]

if (!file.exists(input_json)) {
  stop(sprintf("Input module not found: %s", input_json))
}

if (!requireNamespace("jsonlite", quietly = TRUE)) {
  stop("Package 'jsonlite' is required. Install with: renv::install('jsonlite')")
}

module <- jsonlite::fromJSON(input_json, simplifyVector = FALSE)
states <- module$states
if (is.null(states) || length(states) == 0) {
  stop("No states found in module JSON.")
}

state_names <- names(states)
node_ids <- sprintf("n%03d", seq_along(state_names))
names(node_ids) <- state_names

escape_mermaid <- function(x) {
  x <- gsub('"', "'", x, fixed = TRUE)
  x <- gsub("\\[", "(", x)
  x <- gsub("\\]", ")", x)
  x <- gsub("\\n", " ", x)
  trimws(x)
}

short_percent <- function(x) {
  pct <- 100 * as.numeric(x)
  txt <- sprintf("%.1f", pct)
  txt <- sub("\\.0$", "", txt)
  paste0(txt, "%")
}

node_lines <- character(0)
edge_lines <- character(0)

format_condition_label <- function(cond) {
  if (is.null(cond) || length(cond) == 0) {
    return("else")
  }

  parts <- character(0)
  if (!is.null(cond$condition_type)) {
    parts <- c(parts, cond$condition_type)
  }

  if (!is.null(cond$codes) && length(cond$codes) > 0) {
    first_code <- cond$codes[[1]]
    if (!is.null(first_code$display)) {
      parts <- c(parts, first_code$display)
    }
  }

  if (!is.null(cond$operator) && !is.null(cond$value)) {
    parts <- c(parts, paste(cond$operator, cond$value))
  }

  if (length(parts) == 0) {
    return("condition")
  }

  paste(parts, collapse = ": ")
}

for (state_name in state_names) {
  state <- states[[state_name]]
  node_id <- node_ids[[state_name]]

  label <- gsub("_", " ", state_name, fixed = TRUE)
  label <- escape_mermaid(label)
  node_lines <- c(node_lines, sprintf("  %s[\"%s\"]", node_id, label))

  if (!is.null(state$direct_transition)) {
    to_name <- state$direct_transition
    if (!is.null(node_ids[[to_name]])) {
      edge_lines <- c(edge_lines, sprintf("  %s --> %s", node_id, node_ids[[to_name]]))
    }
  }

  if (!is.null(state$distributed_transition) && length(state$distributed_transition) > 0) {
    for (tr in state$distributed_transition) {
      if (is.null(tr$transition) || is.null(node_ids[[tr$transition]])) {
        next
      }
      lbl <- ""
      if (!is.null(tr$distribution)) {
        lbl <- short_percent(tr$distribution)
      }
      if (nzchar(lbl)) {
        edge_lines <- c(edge_lines, sprintf("  %s -- %s --> %s", node_id, escape_mermaid(lbl), node_ids[[tr$transition]]))
      } else {
        edge_lines <- c(edge_lines, sprintf("  %s --> %s", node_id, node_ids[[tr$transition]]))
      }
    }
  }

  if (!is.null(state$conditional_transition) && length(state$conditional_transition) > 0) {
    for (tr in state$conditional_transition) {
      if (is.null(tr$transition) || is.null(node_ids[[tr$transition]])) {
        next
      }
      cond_label <- format_condition_label(tr$condition)
      edge_lines <- c(edge_lines, sprintf("  %s -- %s --> %s", node_id, escape_mermaid(cond_label), node_ids[[tr$transition]]))
    }
  }
}

mermaid_lines <- c(
  "flowchart TD",
  node_lines,
  "",
  edge_lines
)

out_dir <- dirname(output_mmd)
if (!dir.exists(out_dir)) {
  dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)
}

writeLines(mermaid_lines, con = output_mmd, useBytes = TRUE)
cat(sprintf("Wrote Mermaid diagram: %s\n", output_mmd))

if (grepl("\\.mmd$", output_mmd, ignore.case = TRUE)) {
  output_mermaid <- sub("\\.mmd$", ".mermaid", output_mmd, ignore.case = TRUE)
  output_md <- sub("\\.mmd$", ".diagram.md", output_mmd, ignore.case = TRUE)

  writeLines(mermaid_lines, con = output_mermaid, useBytes = TRUE)
  cat(sprintf("Wrote Mermaid source : %s\n", output_mermaid))

  md_lines <- c(
    "# Synthea Module Diagram",
    "",
    "```mermaid",
    mermaid_lines,
    "```"
  )
  writeLines(md_lines, con = output_md, useBytes = TRUE)
  cat(sprintf("Wrote Markdown wrapper: %s\n", output_md))
}
