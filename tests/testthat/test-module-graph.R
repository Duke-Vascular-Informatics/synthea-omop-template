# Unit tests for R/module_validation.R (added with the Step 3 graph check).
source(file.path(.PROJ_ROOT, "R", "module_validation.R"))

good <- list(
  Initial = list(type = "Initial", direct_transition = "Branch"),
  Branch  = list(type = "Simple", distributed_transition = list(
    list(distribution = 0.3, transition = "A"), list(distribution = 0.7, transition = "Terminal"))),
  A       = list(type = "Simple", direct_transition = "Terminal"),
  Terminal = list(type = "Terminal"))

test_that("a sound graph reports no problems", {
  expect_identical(validate_module_graph(good), character(0))
})

test_that("a transition to a nonexistent state is reported", {
  bad <- good; bad$A$direct_transition <- "Nowhere"
  e <- validate_module_graph(bad)
  expect_true(any(grepl("nonexistent state.*Nowhere", e)))
})

test_that("an unreachable state is reported", {
  bad <- good; bad$Orphan <- list(type = "Simple", direct_transition = "Terminal")
  expect_true(any(grepl("Unreachable.*Orphan", validate_module_graph(bad))))
})

test_that("a distribution that does not sum to 1 is reported", {
  bad <- good; bad$Branch$distributed_transition[[1]]$distribution <- 0.5
  expect_true(any(grepl("sums to 1.2", validate_module_graph(bad), fixed = TRUE)))
})

test_that("conditional and complex transitions are followed", {
  g <- good
  g$Branch <- list(type = "Simple", conditional_transition = list(
    list(condition = list(condition_type = "Gender", gender = "F"), transition = "A"), list(transition = "Terminal")))
  expect_identical(validate_module_graph(g), character(0))
  g$Branch <- list(type = "Simple", complex_transition = list(
    list(condition = list(), distributions = list(list(distribution = 1, transition = "A"))), list(transition = "Terminal")))
  expect_identical(validate_module_graph(g), character(0))
})
