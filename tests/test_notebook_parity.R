source("scripts/notebooks/parity.R")

local({
  root <- tempfile("notebook-parity-")
  dir.create(root)
  on.exit(unlink(root, recursive = TRUE))
  legacy <- file.path(root, "legacy")
  notebooks <- file.path(root, "notebooks")
  for (directory in c(legacy, notebooks)) {
    dir.create(file.path(directory, "correlations"), recursive = TRUE)
    for (domain in book_benchmark_required()) {
      saveRDS(data.frame(value = rep(1000000, 1000)),
              file.path(directory, paste0(domain, "-001.rds")))
    }
    for (namespace in book_benchmark_namespaces) {
      saveRDS(list(namespace = namespace, observations = data.frame(value = 1:3),
                   output = data.frame(value = c(0.1, 0.2))),
              file.path(directory, "correlations", paste0(namespace, ".rds")))
    }
  }
  expect_failure <- function(pattern) {
    error <- tryCatch({ book_notebook_parity(legacy, notebooks); NULL }, error = identity)
    stopifnot(inherits(error, "error"), grepl(pattern, conditionMessage(error)))
  }
  stopifnot(book_notebook_parity(legacy, notebooks))
  path <- file.path(notebooks, "model_predictions_DFF-001.rds")
  value <- readRDS(path)
  value$value[[1000L]] <- value$value[[1000L]] + 0.001
  # Average relative comparison passes, but the single changed forecast must fail.
  stopifnot(isTRUE(all.equal(readRDS(file.path(legacy, basename(path))), value, tolerance = 1e-8)))
  saveRDS(value, path)
  expect_failure("Numerical parity failed")
  file.copy(file.path(legacy, basename(path)), path, overwrite = TRUE)
  unlink(path)
  expect_failure("Missing numerical capture domains")
  file.copy(file.path(legacy, basename(path)), path)
  path <- file.path(notebooks, "correlations/indicators-correlations.rds")
  value <- readRDS(path)
  value$observations$value[[1L]] <- 100
  saveRDS(value, path)
  expect_failure("Correlation input/output parity failed")
})
cat("Notebook parity rejects missing domains, individual forecast errors and changed inputs\n")
