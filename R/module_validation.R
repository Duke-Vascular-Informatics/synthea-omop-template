# =============================================================================
# R/module_validation.R
#
# Pure functions for checking a Synthea module's state graph. Sourced by
# workflow/03 and unit-tested in tests/testthat/test-module-graph.R.
# =============================================================================

`%||%` <- function(a, b) if (is.null(a)) b else a

#' Targets (and, for distributed transitions, the probability sum) of one state.
#'
#' @param st One element of `module$states`.
#' @return list(targets, sums) or NULL for Terminal / an unsupported transition style.
state_targets <- function(st) {
  if (!is.null(st$direct_transition)) return(list(targets = st$direct_transition, sums = NULL))
  if (!is.null(st$distributed_transition)) {
    d <- st$distributed_transition
    return(list(targets = vapply(d, function(x) as.character(x$transition), ""),
                sums = sum(vapply(d, function(x) as.numeric(x$distribution %||% NA_real_), 0))))
  }
  if (!is.null(st$conditional_transition)) {
    return(list(targets = vapply(st$conditional_transition, function(x) as.character(x$transition), ""), sums = NULL))
  }
  if (!is.null(st$complex_transition)) {
    t <- unlist(lapply(st$complex_transition, function(x) {
      if (!is.null(x$transition)) x$transition else vapply(x$distributions, function(y) as.character(y$transition), "")
    }))
    return(list(targets = as.character(t), sums = NULL))
  }
  NULL
}

#' Find structural mistakes Synthea accepts silently.
#'
#' Reports (1) a transition to a state that does not exist, (2) a state nothing
#' reaches (its codes would never be generated), (3) a distributed_transition whose
#' probabilities do not sum to 1. `Initial` is the only state exempt from (2).
#'
#' @param states `module$states` (named list).
#' @return Character vector of problems; `character(0)` when the graph is sound.
validate_module_graph <- function(states) {
  errs <- character(0)
  all_names <- names(states)
  reached <- "Initial"
  for (nm in all_names) {
    tr <- state_targets(states[[nm]])
    if (is.null(tr)) next
    missing_t <- setdiff(tr$targets, all_names)
    if (length(missing_t) > 0L) errs <- c(errs,
      sprintf("State '%s' transitions to nonexistent state(s): %s", nm, paste(missing_t, collapse = ", ")))
    if (!is.null(tr$sums) && !is.na(tr$sums) && abs(tr$sums - 1) > 1e-6) errs <- c(errs,
      sprintf("State '%s' distributed_transition sums to %.6f, not 1", nm, tr$sums))
    reached <- union(reached, tr$targets)
  }
  unreachable <- setdiff(all_names, reached)
  if (length(unreachable) > 0L) errs <- c(errs,
    sprintf("Unreachable state(s) (no transition leads to them): %s", paste(unreachable, collapse = ", ")))
  errs
}
