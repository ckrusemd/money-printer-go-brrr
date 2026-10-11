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

  # Exercise the real capture/comparator and the render's actual coverage gate.
  # Synthetic caret models only; no chapter edits, providers or mirrored logic.
  benchmark <- new.env(parent = globalenv())
  sys.source("scripts/benchmark_book.R", envir = benchmark)
  model_targets <- c("DFF", "DGS2", "DGS10", "MORTGAGE30US", "DK_Short", "DK_Long",
                     "CPIAUCSL", "CSUSHPINSA", "M2SL", "UMCSENT", "USREC", "DF")
  prediction_names <- c(paste0("model_predictions_", model_targets),
                        "model_predictions_DGS2_on_DFF", "model_predictions_DGS10_on_DFF",
                        "model_predictions_MORTGAGE30US_on_DFF", "model_predictions_DK_Long_on_DK_Short")
  model_environment <- new.env(parent = globalenv())
  prediction_baseline <- file.path(scratch, "prediction-baseline")
  capture_to <- function(envir, destination) {
    fresh_runtime()
    Sys.setenv(BOOK_RESULTS_DIR = destination)
    book_capture_results(envir)
  }
  check_coverage <- function(directory) {
    expressions <- as.list(body(benchmark$book_benchmark_render))
    start <- which(vapply(expressions, function(expression) {
      is.call(expression) && identical(expression[[1L]], as.name("<-")) &&
        identical(expression[[2L]], as.name("required"))
    }, logical(1)))
    stopifnot(length(start) == 1L)
    validation <- new.env(parent = globalenv())
    validation$config <- list(numeric = directory)
    for (index in seq.int(start, start + 2L)) eval(expressions[[index]], validation)
    stopifnot(all(prediction_names %in% validation$required))
  }

  probe("all twelve fitted targets and shared diagnostic domains capture complete tables", {
    fresh_runtime()
    RNGkind("Mersenne-Twister", "Inversion", "Rejection")
    set.seed(1971)
    features <- data.frame(x = seq_len(32), z = sin(seq_len(32)))
    fit <- caret::train(x = features, y = features$x / 2 + features$z,
                        method = "rf", tuneGrid = data.frame(mtry = 2), ntree = 10,
                        trControl = caret::trainControl(method = "none"))
    for (target in model_targets) {
      data <- data.frame(date = as.Date("2020-01-01") + seq_len(32),
                         value = c(seq_len(31), NA_real_), features)
      if (target == "DF") names(data)[1:2] <- c("obstime", "obsvalue")
      if (target %in% c("DK_Long", "CPIAUCSL")) data <- data[32:1, ]
      assign(paste0("df_predict_", target), data, model_environment)
      assign(paste0("fit_", target), fit, model_environment)
    }
    for (variable in c("df_ccfs", "rf_backtest", "rf_metrics", "rf_regime_metrics",
                       "rf_live_forecast", "dff_rf_has_skill")) {
      assign(variable, data.frame(value = 1), model_environment)
    }
    before <- .Random.seed
    capture_to(model_environment, prediction_baseline)
    stopifnot(identical(.Random.seed, before))
    check_coverage(prediction_baseline)
    for (target in model_targets) {
      table <- readRDS(file.path(prediction_baseline, paste0("model_predictions_", target, "-001.rds")))
      input <- get(paste0("df_predict_", target), model_environment)
      stopifnot(nrow(table) == nrow(input),
                identical(table[names(input)], input),
                identical(table[[paste0("pred_", target)]], as.numeric(stats::predict(fit, input))))
    }
    files <- list.files(prediction_baseline)
    book_capture_results(model_environment)
    stopifnot(identical(files, list.files(prediction_baseline)), identical(.Random.seed, before))
  })

  probe("mutating any previously omitted model fails the real numeric comparison", {
    stopifnot(length(list.files(prediction_baseline)) == 22L)
    for (target in model_targets) {
      changed <- list2env(as.list(model_environment), parent = globalenv())
      fit <- get(paste0("fit_", target), changed)
      fit$finalModel$forest$nodepred <- fit$finalModel$forest$nodepred + 999
      assign(paste0("fit_", target), fit, changed)
      directory <- file.path(scratch, paste0("prediction-mutated-", target))
      capture_to(changed, directory)
      check_coverage(directory)
      differences <- benchmark$book_compare_numeric(prediction_baseline, directory)
      stopifnot(any(grepl(paste0("model_predictions_", target, "-001.rds"), differences, fixed = TRUE)))
      for (file in list.files(prediction_baseline, pattern = "^(rf_|dff_)")) {
        stopifnot(identical(readRDS(file.path(prediction_baseline, file)), readRDS(file.path(directory, file))))
      }
    }
  })

  probe("baseline/optimized capture names and values ignore model timing metadata", {
    optimized <- list2env(as.list(model_environment), parent = globalenv())
    for (target in model_targets) {
      fit <- get(paste0("fit_", target), optimized)
      fit$times <- list(everything = 999)
      assign(paste0("fit_", target), fit, optimized)
    }
    directory <- file.path(scratch, "prediction-optimized-metadata")
    capture_to(optimized, directory)
    check_coverage(directory)
    stopifnot(identical(list.files(prediction_baseline), list.files(directory)),
              !length(benchmark$book_compare_numeric(prediction_baseline, directory)))
  })

  probe("benchmark rejects the old subset and every missing prediction-table capture", {
    old_subset <- file.path(scratch, "old-rf-subset")
    dir.create(old_subset)
    files <- list.files(prediction_baseline, full.names = TRUE)
    stopifnot(all(file.copy(files[!grepl("model_predictions_", basename(files))], old_subset)))
    expect_error(check_coverage(old_subset))
    for (variable in prediction_names) {
      directory <- file.path(scratch, paste0("prediction-missing-", variable))
      dir.create(directory)
      keep <- basename(files) != paste0(variable, "-001.rds")
      stopifnot(all(file.copy(files[keep], directory)))
      expect_error(check_coverage(directory))
      stopifnot(length(benchmark$book_compare_numeric(prediction_baseline, directory)) > 0L)
    }
  })

  probe("changed features invalidate captures; empty prediction inputs fail closed", {
    directory <- file.path(scratch, "prediction-input-mutation")
    capture_to(model_environment, directory)
    changed <- list2env(as.list(model_environment), parent = globalenv())
    changed$df_predict_DK_Short$x[1L] <- 999
    book_capture_results(changed)
    stopifnot(file.exists(file.path(directory, "model_predictions_DK_Short-002.rds")),
              file.exists(file.path(directory, "model_predictions_DK_Long_on_DK_Short-002.rds")))
    changed$df_predict_DK_Short <- changed$df_predict_DK_Short[FALSE, ]
    expect_error(book_capture_results(changed))
  })

  probe("unchanged model references skip prediction/hash work and preserve RNG kind", {
    local({
      fresh_runtime()
      Sys.setenv(BOOK_RESULTS_DIR = file.path(scratch, "cheap-prediction-capture"))
      calls <- hashes <- 0L
      method_name <- "predict.book_review_model"
      original_hash <- book_hash
      on.exit({
        rm(list = method_name, envir = .GlobalEnv)
        assign("book_hash", original_hash, .GlobalEnv)
      }, add = TRUE)
      assign(method_name, function(object, newdata, ...) {
        calls <<- calls + 1L
        RNGkind("Super-Duper", "Inversion", "Rejection")
        runif(2)
        rep(object$prediction, nrow(newdata))
      }, .GlobalEnv)
      assign("book_hash", function(value) {
        hashes <<- hashes + 1L
        original_hash(value)
      }, .GlobalEnv)
      envir <- new.env(parent = globalenv())
      envir$fit_fixture <- structure(list(prediction = 2), class = "book_review_model")
      envir$df_predict_fixture <- data.frame(date = as.Date("2020-01-01") + 1:3, value = 1:3)
      RNGkind("Mersenne-Twister", "Inversion", "Rejection")
      set.seed(1971)
      kind <- RNGkind()
      seed <- .Random.seed
      book_capture_results(envir)
      stopifnot(calls == 1L, hashes == 1L, identical(RNGkind(), kind), identical(.Random.seed, seed))
      for (chunk in seq_len(50)) book_capture_results(envir)
      stopifnot(calls == 1L, hashes == 1L, identical(RNGkind(), kind), identical(.Random.seed, seed))
      envir$fit_fixture$prediction <- 999
      book_capture_results(envir)
      envir$df_predict_fixture$value[1L] <- 10L
      book_capture_results(envir)
      stopifnot(calls == 3L, hashes == 3L, identical(RNGkind(), kind), identical(.Random.seed, seed))
      rm(".Random.seed", envir = .GlobalEnv)
      envir$fit_fixture$prediction <- 5
      book_capture_results(envir)
      stopifnot(identical(RNGkind(), kind), !exists(".Random.seed", .GlobalEnv, inherits = FALSE))
    })
  })

  cat(sprintf("Runtime review: %d probes; %d failures\n", probe_count, length(failures)))
  if (length(failures)) stop("Review regressions: ", paste(failures, collapse = "; "), call. = FALSE)
})
