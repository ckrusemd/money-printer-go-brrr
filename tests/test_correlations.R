# From the repository root: Rscript --vanilla tests/test_correlations.R
# Add --benchmark for a representative 48-series cold/warm timing comparison.
correlation_scope <- new.env(parent = globalenv())
sys.source("scripts/analysis/correlations.R", envir = correlation_scope)

assert_equal <- function(actual, expected, label, tolerance = 1e-8) {
  comparison <- all.equal(actual, expected, tolerance = tolerance,
                          check.attributes = TRUE)
  if (!isTRUE(comparison)) stop(label, ": ", paste(comparison, collapse = "; "))
}

assert_error <- function(expression, pattern) {
  error <- tryCatch({ force(expression); NULL }, error = identity)
  stopifnot(inherits(error, "error"), grepl(pattern, conditionMessage(error)))
}

# Independent original statistic: three ccf calls and exact-equality maxima.
legacy_maxima <- function(x, y) {
  columns <- list()
  for (horizon in c(30L, 365L, 1825L)) {
    result <- stats::ccf(x, y, lag.max = horizon, plot = FALSE)
    best <- which(abs(result$acf) == max(abs(result$acf)))
    columns[[paste0("best_corr_time_", horizon)]] <- result$lag[best]
    columns[[paste0("best_corr_value_", horizon)]] <- result$acf[best]
  }
  as.data.frame(columns)
}

# Use the chapters' original expand.grid / two inner joins / group / do when
# dplyr is installed. The base reference supports package-poor R installations.
legacy_join <- function(data, batch_size = 2000L) {
  ids <- unique(data$series_id)
  pairs <- expand.grid(x1 = ids, x2 = ids, stringsAsFactors = FALSE)
  pairs <- pairs[pairs$x1 != pairs$x2, , drop = FALSE]
  batches <- split(pairs, seq_len(nrow(pairs)) %/% batch_size)
  if (requireNamespace("dplyr", quietly = TRUE)) {
    return(as.data.frame(do.call(rbind, lapply(batches, function(batch) {
      # These deliberately expanded joins have the expected many-to-many shape.
      joined <- suppressWarnings(dplyr::inner_join(batch, data, by = c(x1 = "series_id")))
      joined <- suppressWarnings(dplyr::inner_join(joined, data,
                                  by = c(x2 = "series_id", date = "date")))
      joined <- stats::na.omit(dplyr::select(joined, -date))
      dplyr::do(dplyr::group_by(joined, x1, x2),
                legacy_maxima(.$value.x, .$value.y))
    }))))
  }
  do.call(rbind, lapply(batches, function(batch) {
    x <- data.frame(x1 = data$series_id, date = data$date,
                    value.x = data$value, row_x = seq_len(nrow(data)))
    y <- data.frame(x2 = data$series_id, date = data$date, value.y = data$value)
    joined <- merge(merge(batch, x, by = "x1", sort = FALSE), y,
                    by = c("x2", "date"), sort = FALSE)
    joined <- joined[stats::complete.cases(joined), , drop = FALSE]
    groups <- split(joined, interaction(joined$x1, joined$x2, drop = TRUE))
    do.call(rbind, lapply(groups, function(group) {
      group <- group[order(group$row_x), , drop = FALSE]
      cbind(group[1L, c("x1", "x2"), drop = FALSE],
            legacy_maxima(group$value.x, group$value.y))
    }))
  }))
}

canonical <- function(data) {
  data <- as.data.frame(data)
  data$x1 <- as.character(data$x1)
  data$x2 <- as.character(data$x2)
  data <- data[order(data$x1, data$x2, data$best_corr_time_30,
                     data$best_corr_time_365, data$best_corr_time_1825), ]
  rownames(data) <- NULL
  data
}

make_series <- function(id, dates, values) {
  data.frame(series_id = id, date = as.Date("2000-01-01") + dates, value = values)
}

chapter_expressions <- function(path) {
  active <- FALSE
  code <- character()
  for (line in readLines(path)) {
    if (grepl("^```\\{r", line)) { active <- TRUE; next }
    if (active && grepl("^```", line)) { active <- FALSE; next }
    if (active) code <- c(code, line)
  }
  as.list(parse(text = code))
}

run_correlations_tests <- function() {
  scope <- correlation_scope
  horizons <- c(30L, 365L, 1825L)
  max_error <- 0
  # Execute the chapter's actual failure path with no network or retry sleeps.
  chapters <- c("Chapters/01_Indicators/1_Indicators.Rmd", "Chapters/05_ETFs/ETFs.Rmd")
  expressions <- lapply(chapters, chapter_expressions)
  optional <- new.env(parent = globalenv())
  getter <- Filter(function(expression) {
    is.call(expression) && length(expression) >= 3L &&
      identical(expression[[2L]], as.name("get_yahoo_value"))
  }, expressions[[2L]])
  stopifnot(length(getter) == 1L)
  eval(getter[[1L]], optional)
  requests <- character()
  optional$book_yahoo <- function(ticker) {
    requests <<- c(requests, ticker)
    stop("Current fixture data unavailable")
  }
  optional$Sys.sleep <- function(...) invisible(NULL)
  for (ticker in c("^W5000", "LQD")) {
    warnings <- character()
    result <- withCallingHandlers(optional$get_yahoo_value(ticker, attempts = 2L),
      warning = function(warning) {
        warnings <<- c(warnings, conditionMessage(warning))
        invokeRestart("muffleWarning")
      })
    stopifnot(is.null(result), length(warnings) == 1L,
              grepl(ticker, warnings, fixed = TRUE), sum(requests == ticker) == 2L)
  }
  for (chapter in expressions) {
    guard <- Filter(function(expression) {
      is.call(expression) && identical(expression[[1L]], as.name("if")) &&
        any(grepl("No current ETF price observations", deparse(expression), fixed = TRUE))
    }, chapter)
    stopifnot(length(guard) == 1L)
    optional$df_etf_yahoo <- data.frame()
    assert_error(eval(guard[[1L]], optional), "No current ETF")
    optional$df_etf_yahoo <- data.frame(value = c(NA_real_, NA_real_))
    assert_error(eval(guard[[1L]], optional), "No current ETF")
    optional$df_etf_yahoo <- data.frame(value = c(NA_real_, 1))
    stopifnot(is.null(eval(guard[[1L]], optional)))
  }
  cat("PASS: optional Yahoo warnings/NULL after retries, including ^W5000; both chapters fail only when the entire ETF dataset is unavailable\n")

  for (n in c(2L, 3L, 30L, 31L, 32L, 365L, 366L, 367L, 1825L, 1826L, 1900L)) {
    t <- seq_len(n)
    x <- sin(t * 0.17) + cos(t * 0.07) + t / n
    y <- cos(t * 0.11) - sin(t * 0.31) + (t %% 13) / 17
    maximum <- stats::ccf(x, y, lag.max = 1825, plot = FALSE)
    for (horizon in horizons) {
      separate <- stats::ccf(x, y, lag.max = horizon, plot = FALSE)
      keep <- abs(maximum$lag) <= horizon
      stopifnot(identical(as.vector(separate$lag), as.vector(maximum$lag[keep])))
      error <- max(abs(separate$acf - maximum$acf[keep]))
      stopifnot(error <= 1e-8)
      max_error <- max(max_error, error)
    }
    assert_equal(scope$book_ccf_maxima(x, y), legacy_maxima(x, y),
                 paste("three horizons at length", n))
    assert_equal(scope$book_ccf_maxima(y, x), legacy_maxima(y, x),
                 paste("reverse three horizons at length", n))
  }

  # Numeric goldens: two exactly tied signed peaks, in original lag order.
  x <- c(-1, 0, 1)
  y <- c(1, -2, 1)
  expected <- data.frame(best_corr_time_30 = c(-1, 1),
                         best_corr_value_30 = c(1, -1) / sqrt(3),
                         best_corr_time_365 = c(-1, 1),
                         best_corr_value_365 = c(1, -1) / sqrt(3),
                         best_corr_time_1825 = c(-1, 1),
                         best_corr_value_1825 = c(1, -1) / sqrt(3))
  assert_equal(scope$book_ccf_maxima(x, y), expected, "numeric tie golden")
  expected[c(2, 4, 6)] <- -expected[c(2, 4, 6)]
  assert_equal(scope$book_ccf_maxima(y, x), expected, "numeric reverse tie golden")
  assert_equal(scope$book_ccf_maxima(c(0, 1), c(1, 0)),
                 data.frame(best_corr_time_30 = 0, best_corr_value_30 = -1,
                            best_corr_time_365 = 0, best_corr_value_365 = -1,
                            best_corr_time_1825 = 0, best_corr_value_1825 = -1),
                 "two-observation numeric golden")
  # A 61-way zero tie inside 30 lags and one peak in each wider horizon.
  # The legacy data.frame recycles those wider maxima across all 61 rows.
  x <- y <- numeric(1900L)
  x[100:101] <- c(1, -1)
  y[200:201] <- c(1, -1)
  recycled <- scope$book_ccf_maxima(x, y)
  assert_equal(recycled, legacy_maxima(x, y), "ties recycled across horizons")
  stopifnot(nrow(recycled) == 61L,
            identical(recycled$best_corr_time_30, as.numeric(-30:30)),
            all(recycled$best_corr_value_30 == 0),
            all(recycled$best_corr_time_365 == -100),
            all(abs(recycled$best_corr_value_365 - 1) < 1e-8))

  # Sparse, NA and deliberately unsorted dates compare with the original joins.
  t <- seq_len(1900L)
  fixture <- rbind(
    make_series("daily", t, sin(t / 11) + t / 700),
    make_series("gapped", t[-c(1, 25, 28, 300)],
                (cos(t / 17) + t / 1900)[-c(1, 25, 28, 300)]),
    make_series("weekly", t[t %% 7 == 0], sin(t[t %% 7 == 0] / 29)),
    make_series("reverse-order", rev(t), cos(rev(t) / 19)))
  fixture$value[c(8, 12, 2100)] <- NA_real_
  prepared <- scope$book_prepare_correlations(fixture)
  actual <- scope$book_correlations_aligned(prepared)
  assert_equal(canonical(actual), canonical(legacy_join(fixture)),
                 "materialized directed join regression on clean data")
  stopifnot(nrow(unique(actual[c("x1", "x2")])) == 12L,
            all(actual$x1 != actual$x2))

  duplicates <- rbind(fixture, fixture[fixture$series_id == "daily", ])
  assert_equal(scope$book_prepare_correlations(duplicates), prepared,
                 "ETF observations appended twice are deduplicated")
  assert_equal(scope$book_correlations_aligned(scope$book_prepare_correlations(duplicates)),
                 actual, "duplicate ETF append cannot alter optimized results")
  buggy <- canonical(suppressWarnings(legacy_join(duplicates)))
  clean <- canonical(actual)
  stopifnot(!isTRUE(all.equal(buggy, clean, tolerance = 1e-8)))
  bug_delta <- max(abs(buggy$best_corr_value_365 - clean$best_corr_value_365))
  cat(sprintf("PASS: duplicate-append bug separately changes legacy 365-horizon coefficients by up to %.6g; fixed output equals clean baseline\n", bug_delta))

  conflict <- fixture[1L, ]
  conflict$value <- conflict$value + 1
  assert_error(scope$book_prepare_correlations(rbind(fixture, conflict)),
                "Conflicting.*daily.*2000-01-02")
  conflict$value <- NA_real_
  assert_error(scope$book_prepare_correlations(rbind(fixture, conflict)), "Conflicting")
  assert_error(scope$book_prepare_correlations(fixture[c("date", "value")]), "requires")
  invalid <- fixture
  invalid$date[1L] <- NA
  assert_error(scope$book_prepare_correlations(invalid), "must not be missing")
  invalid <- fixture
  invalid$value[1L] <- Inf
  assert_error(scope$book_prepare_correlations(invalid), "finite or NA")

  edge_cases <- rbind(make_series("constant", 1:4, rep(7, 4)),
                      make_series("short", 1, 2),
                      make_series("missing", 1:4, rep(NA_real_, 4)),
                      make_series("disjoint", 10:13, 1:4),
                      make_series("variable", 1:4, c(1, 3, 2, 5)))
  edge_result <- scope$book_correlations_aligned(scope$book_prepare_correlations(edge_cases))
  stopifnot(nrow(edge_result) == 20L, all(is.na(edge_result[-c(1, 2)])))
  empty <- scope$book_correlations_aligned(prepared[FALSE, ])
  single <- scope$book_correlations_aligned(prepared[prepared$series_id == "daily", ])
  stopifnot(nrow(empty) == 0L, nrow(single) == 0L,
            identical(names(empty), names(actual)))
  cat(sprintf("PASS: numeric fixtures, directed pairs, ties, reverse, sparse/NA/constant/short cases; maximum CCF difference %.3g\n", max_error))

  # Inspect the integration contract without depending on the runtime file.
  request <- NULL
  scope$book_cache_derived <- function(namespace, inputs, compute, packages, code) {
    request <<- list(namespace = namespace, inputs = inputs, packages = packages, code = code)
    stopifnot(is.function(compute), length(formals(compute)) == 0L)
    compute()
  }
  assert_equal(scope$book_correlations(fixture, "fixture-correlations"), actual,
                 "cache compute contract")
  stopifnot(identical(request$namespace, "fixture-correlations"),
            identical(request$inputs$observations, prepared),
            identical(request$inputs$horizons, horizons),
            identical(request$packages, "stats"), length(request$code) == 3L)

  if (file.exists("scripts/book_runtime.R")) {
    runtime <- new.env(parent = globalenv())
    sys.source("scripts/book_runtime.R", envir = runtime)
    cache_directory <- tempfile("correlation-cache-")
    dir.create(cache_directory)
    on.exit(unlink(cache_directory, recursive = TRUE), add = TRUE)
    runtime$.book_runtime <- new.env(parent = emptyenv())
    runtime$.book_runtime$derived <- file.path(cache_directory, "derived")
    runtime$.book_runtime$metrics <- file.path(cache_directory, "metrics.csv")
    scope$book_cache_derived <- runtime$book_cache_derived
    seed_before <- if (exists(".Random.seed", globalenv(), inherits = FALSE)) .Random.seed else NULL
    on.exit({
      if (is.null(seed_before)) {
        if (exists(".Random.seed", globalenv(), inherits = FALSE)) rm(".Random.seed", envir = globalenv())
      } else assign(".Random.seed", seed_before, globalenv())
    }, add = TRUE)
    set.seed(812)
    initial_seed <- .Random.seed
    cold <- scope$book_correlations(fixture, "fixture-real-cache")
    warm <- scope$book_correlations(fixture, "fixture-real-cache")
    assert_equal(cold, warm, "real cache hit")
    stopifnot(identical(.Random.seed, initial_seed))
    metrics <- read.csv(runtime$.book_runtime$metrics)
    stopifnot(identical(tail(metrics$status, 2L), c("computed", "cache-hit")))
    changed <- fixture
    changed$value[1L] <- changed$value[1L] + 10
    scope$book_correlations(changed, "fixture-real-cache")
    scope$book_correlations(fixture, "other-chapter-cache")
    set.seed(813)
    scope$book_correlations(fixture, "fixture-real-cache")
    # Each helper body must invalidate the cache with an unchanged caller.
    for (helper in c("book_prepare_correlations", "book_ccf_maxima", "book_correlations_aligned")) {
      original <- scope[[helper]]
      replacement <- original
      body(replacement) <- substitute({ invisible(NULL); ORIGINAL_BODY },
                                       list(ORIGINAL_BODY = body(original)))
      scope[[helper]] <- replacement
      assert_equal(scope$book_correlations(fixture, "fixture-real-cache"), actual,
                   paste("helper code invalidation", helper))
      scope[[helper]] <- original
    }
    metrics <- read.csv(runtime$.book_runtime$metrics)
    stopifnot(all(tail(metrics$status, 6L) == "computed"))
    assert_error(scope$book_correlations(rbind(fixture, conflict), "fixture-real-cache"),
                  "Conflicting")
    cat("PASS: shared cache hits, content/namespace/RNG/helper-code invalidation, RNG preservation, conflict checks before cache lookup\n")

    if ("--benchmark" %in% commandArgs(trailingOnly = TRUE)) {
      t <- seq_len(1000L)
      benchmark <- do.call(rbind, lapply(seq_len(48L), function(i) {
        make_series(sprintf("series-%02d", i), t,
                     sin(t / (7 + i)) + cos(t / (31 + i)) + t / (900 + i))
      }))
      baseline <- legacy_join(benchmark)
      optimized <- scope$book_correlations_aligned(benchmark)
      assert_equal(canonical(optimized), canonical(baseline),
                   "48-series clean numerical equivalence")
      stopifnot(nrow(unique(optimized[c("x1", "x2")])) == 48L * 47L)
      coefficients <- paste0("best_corr_value_", horizons)
      coefficient_error <- max(abs(as.matrix(canonical(optimized)[coefficients]) -
                                     as.matrix(canonical(baseline)[coefficients])))
      stopifnot(coefficient_error <= 1e-8)
      cat(sprintf("PASS: 48-series clean baseline, all %d directed pairs and three published horizons; maximum coefficient difference %.3g\n",
                  48L * 47L, coefficient_error))
      elapsed <- function(compute, repetitions = 3L) {
        median(replicate(repetitions, system.time(compute())[["elapsed"]]))
      }
      old <- elapsed(function() legacy_join(benchmark))
      aligned <- elapsed(function() scope$book_correlations_aligned(benchmark))
      scope$book_correlations(benchmark, "benchmark-correlations")
      warm <- elapsed(function() scope$book_correlations(benchmark, "benchmark-correlations"), 7L)
      engine <- if (requireNamespace("dplyr", quietly = TRUE)) "original dplyr" else "base materialized join reference"
      cat(sprintf("BENCHMARK (%s; 48 series x 1000 observations; median): join %.3fs, aligned %.3fs, warm %.3fs; cold reduction %.1f%%, warm reduction %.1f%%\n",
                  engine, old, aligned, warm, 100 * (1 - aligned / old), 100 * (1 - warm / old)))
      stopifnot(warm <= old * 0.7)
      cat(sprintf("STORAGE: %d source rows vs %d expanded matched pair rows; pair buffers bounded to %d observations\n",
                  nrow(benchmark), 48L * 47L * 1000L, 1000L))
    }
  } else {
    cat("SKIP: real shared-runtime cache checks (coordinator runtime not yet present)\n")
  }
  invisible(TRUE)
}

run_correlations_tests()
