# Compare notebook model captures with a completed legacy Bookdown capture.
# Usage: Rscript --vanilla scripts/notebooks/parity.R LEGACY_RESULTS NOTEBOOK_RESULTS
source("scripts/benchmark_book.R", local = TRUE)

book_notebook_parity <- function(legacy_directory, notebook_directory, tolerance = 1e-8) {
  captures <- function(directory) {
    files <- list.files(directory, "\\.rds$", recursive = TRUE, full.names = TRUE)
    prefixes <- c("df_ccfs-", "rf_backtest-", "rf_metrics-", "rf_regime_metrics-",
                  "rf_live_forecast-", "dff_rf_has_skill-", "model_predictions_")
    files[vapply(basename(files), function(path) any(startsWith(path, prefixes)), logical(1))]
  }
  legacy <- captures(legacy_directory)
  notebooks <- captures(notebook_directory)
  domain <- function(path) sub("-[0-9]+\\.rds$", "", basename(path))
  for (files in list(legacy, notebooks)) {
    missing <- setdiff(book_benchmark_required(), vapply(files, domain, ""))
    if (length(missing)) stop("Missing numerical capture domains: ", paste(missing, collapse = ", "))
  }
  if (!setequal(vapply(legacy, domain, ""), vapply(notebooks, domain, ""))) {
    stop("Legacy/notebook numerical domains differ")
  }
  # Match all intermediate captures in both directions, allowing chapter-local
  # counters. Compare every value at an absolute tolerance; all.equal's average
  # relative error could conceal one incorrect value in a large prediction table.
  for (pair in list(list(legacy, notebooks), list(notebooks, legacy))) {
    for (path in pair[[1L]]) {
      candidates <- pair[[2L]][vapply(pair[[2L]], domain, "") == domain(path)]
      expected <- readRDS(path)
      matched <- vapply(candidates, function(candidate) book_numeric_equal(
        expected, readRDS(candidate), tolerance = tolerance), logical(1))
      if (!any(matched)) stop("Numerical parity failed: ", path)
    }
  }
  for (namespace in book_benchmark_namespaces) {
    records <- lapply(c(legacy_directory, notebook_directory), function(directory) {
      files <- list.files(directory, "\\.rds$", recursive = TRUE, full.names = TRUE)
      files <- files[basename(files) == paste0(namespace, ".rds")]
      if (length(files) != 1L) stop("Missing or ambiguous correlation capture: ", namespace)
      readRDS(files[[1L]])
    })
    if (!book_numeric_equal(records[[1L]], records[[2L]], tolerance)) {
      stop("Correlation input/output parity failed: ", namespace)
    }
  }
  cat("Complete numerical capture parity passed at absolute tolerance ", tolerance, "\n", sep = "")
  invisible(TRUE)
}

if (sys.nframe() == 0L) {
  args <- commandArgs(trailingOnly = TRUE)
  if (length(args) != 2L) stop("Expected legacy and notebook results directories")
  book_notebook_parity(args[[1L]], args[[2L]])
}
