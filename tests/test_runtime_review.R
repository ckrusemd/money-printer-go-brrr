# Offline regression probes from the bounded runtime review.
# Run in the publication image with --network none and a read-only repo mount.
# Each failed assertion names a defect; all probes run before the final failure.
local({
  runtime_file <- normalizePath("scripts/book_runtime.R", mustWork = TRUE)
  scratch <- tempfile("runtime-review-")
  dir.create(scratch)
  on.exit(unlink(scratch, recursive = TRUE), add = TRUE)
  failures <- character()
  counter <- 0L
  probe_count <- 0L

  restart_runtime <- function(mode) {
    if (exists(".book_runtime", .GlobalEnv, inherits = FALSE)) {
      rm(".book_runtime", envir = .GlobalEnv)
    }
    Sys.setenv(BOOK_SNAPSHOT_MODE = mode)
    source(runtime_file, local = .GlobalEnv)
  }
  fresh_runtime <- function(mode = "record") {
    counter <<- counter + 1L
    directory <- file.path(scratch, as.character(counter))
    Sys.setenv(BOOK_SNAPSHOT_DIR = file.path(directory, "inputs"),
               BOOK_DERIVED_DIR = file.path(directory, "derived"),
               BOOK_METRICS_FILE = file.path(directory, "metrics.csv"),
               BOOK_AS_OF = "2026-10-11", BOOK_RESULTS_DIR = "")
    restart_runtime(mode)
  }
  probe <- function(name, expression) {
    probe_count <<- probe_count + 1L
    result <- tryCatch({ force(expression); NULL }, error = identity)
    if (is.null(result)) {
      cat("PASS:", name, "\n")
    } else {
      failures <<- c(failures, name)
      cat("FAIL:", name, "--", conditionMessage(result), "\n")
    }
  }
  expect_error <- function(expression) {
    stopifnot(inherits(tryCatch(force(expression), error = identity), "error"))
  }
  fixture <- function() data.frame(date = as.Date("2026-10-10"), value = 7)
  network_forbidden <- function() stop("NETWORK PROBE MUST NOT RUN")
  request_key <- function(parameters) book_hash(list(provider = "fixture", parameters = parameters))
  snapshot_path <- function(parameters) {
    file.path(.book_runtime$snapshots, paste0(request_key(parameters), ".rds"))
  }
  record_fixture <- function() {
    fresh_runtime("record")
    invisible(book_fetch("fixture", list(id = "recorded"), fixture))
    book_write_manifest()
  }

  probe("record/replay avoids executing the fetcher; missing replay fails closed", {
    record_fixture()
    restart_runtime("replay")
    stopifnot(identical(book_fetch("fixture", list(id = "recorded"), network_forbidden), fixture()))
    expect_error(book_fetch("fixture", list(id = "missing"), network_forbidden))
  })

  probe("failed live retrieval never falls back to recorded data", {
    record_fixture()
    restart_runtime("live")
    expect_error(book_fetch("fixture", list(id = "recorded"), network_forbidden, attempts = 1L))
    stopifnot(length(.book_runtime$observations) == 0L)
  })

  for (corruption in c("schema", "empty")) {
    probe(paste("replay rejects", corruption, "snapshot corruption"), {
      record_fixture()
      path <- snapshot_path(list(id = "recorded"))
      record <- readRDS(path)
      if (corruption == "schema") record$schema_version <- 999L else record$value <- NULL
      saveRDS(record, path)
      restart_runtime("replay")
      expect_error(book_fetch("fixture", list(id = "recorded"), network_forbidden))
    })
  }

  probe("replay rejects leftover files outside the recorded manifest", {
    record_fixture()
    record <- readRDS(snapshot_path(list(id = "recorded")))
    record$parameters <- list(id = "leftover")
    book_save_rds(record, snapshot_path(record$parameters))
    restart_runtime("replay")
    expect_error(book_fetch("fixture", list(id = "leftover"), network_forbidden))
  })

  probe("replay rejects a different analytical date from its manifest", {
    record_fixture()
    Sys.setenv(BOOK_AS_OF = "2026-10-12")
    expect_error({
      restart_runtime("replay")
      book_fetch("fixture", list(id = "recorded"), network_forbidden)
    })
  })

  probe("default Inversion RNG continuation and declared code/input invalidation", {
    fresh_runtime()
    RNGkind("Mersenne-Twister", "Inversion", "Rejection")
    calls <- 0L
    compute <- function() { calls <<- calls + 1L; runif(3) }
    set.seed(1971)
    cold <- book_cache_derived("review-default-rng", list(x = 1), compute)
    continuation <- runif(2)
    set.seed(1971)
    warm <- book_cache_derived("review-default-rng", list(x = 1), compute)
    stopifnot(identical(cold, warm), identical(continuation, runif(2)), calls == 1L)
    set.seed(1971)
    invisible(book_cache_derived("review-default-rng", list(x = 2), compute))
    set.seed(1971)
    invisible(book_cache_derived("review-default-rng", list(x = 1), compute, code = "new revision"))
    stopifnot(calls == 3L)
  })

  probe("Box-Muller RNG continuation is identical on a cache hit", {
    fresh_runtime()
    RNGkind("Mersenne-Twister", "Box-Muller", "Rejection")
    compute <- function() rnorm(1)
    set.seed(42)
    cold <- book_cache_derived("review-box-muller", list(x = 1), compute)
    continuation <- rnorm(1)
    set.seed(42)
    warm <- book_cache_derived("review-box-muller", list(x = 1), compute)
    warm_continuation <- rnorm(1)
    stopifnot(identical(cold, warm))
    if (!identical(continuation, warm_continuation)) {
      stop(sprintf("cold continuation %.9f; warm continuation %.9f", continuation, warm_continuation))
    }
  })

  probe("explicit helper code dependencies invalidate derived results", {
    fresh_runtime()
    RNGkind("Mersenne-Twister", "Inversion", "Rejection")
    set.seed(1971)
    helper <- function(x) x + 1
    compute <- function() helper(1)
    first <- book_cache_derived("review-helper", 1, compute, code = body(helper))
    helper <- function(x) x + 2
    second <- book_cache_derived("review-helper", 1, compute, code = body(helper))
    stopifnot(identical(first, 2), identical(second, 3))
  })

  probe("source status and stored metadata redact credentials", {
    fresh_runtime()
    sentinel <- "SYNTHETIC_REVIEW_TOKEN"
    parameters <- setNames(
      list(paste0("https://example.invalid/data?", "api_key", "=", sentinel), sentinel),
      c("url", "api_key")
    )
    invisible(book_fetch("fixture", parameters, fixture))
    book_write_manifest()
    status_leaks <- any(grepl(sentinel, book_source_status()$Request, fixed = TRUE))
    records <- lapply(list.files(.book_runtime$snapshots, full.names = TRUE), readRDS)
    disk_leaks <- any(vapply(records, function(record) {
      grepl(sentinel, paste(capture.output(str(record)), collapse = "\n"), fixed = TRUE)
    }, logical(1)))
    if (status_leaks || disk_leaks) {
      stop(sprintf("published status leaks: %s; snapshot metadata leaks: %s", status_leaks, disk_leaks))
    }
  })

  probe("oversized derived entry does not evict every smaller reusable entry", {
    fresh_runtime()
    small <- file.path(.book_runtime$derived, "small.rds")
    large <- file.path(.book_runtime$derived, "large.rds")
    book_save_rds(1L, small)
    book_save_rds(raw(256), large)
    Sys.setFileTime(small, Sys.time() - 120)
    stopifnot(file.info(small)$size < 100, file.info(large)$size > 100)
    book_prune_cache(limit = 100)
    stopifnot(file.exists(small), !file.exists(large))
  })

  cat(sprintf("Runtime review: %d probes; %d failures\n", probe_count, length(failures)))
  if (length(failures)) stop("Review regressions: ", paste(failures, collapse = "; "), call. = FALSE)
})
