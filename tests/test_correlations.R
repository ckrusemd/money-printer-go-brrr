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

# Frozen literal oracle before pre-indexing. Keep independent of every new
# preparation/alignment/maxima/input-equality helper and retain all columns.
literal_correlation_original <- function(observations, namespace, retain_undefined = TRUE) {
  observations <- as.data.frame(observations)
  observations$series_id <- as.character(observations$series_id)
  ids <- unique(observations$series_id)
  columns <- as.vector(rbind(paste0("best_corr_time_", c(30L, 365L, 1825L)),
                            paste0("best_corr_value_", c(30L, 365L, 1825L))))
  empty <- data.frame(x1 = character(), x2 = character())
  for (column in columns) empty[[column]] <- numeric()
  result <- list()
  for (x1 in ids) for (x2 in ids) {
    if (x1 == x2) next
    x <- observations[observations$series_id == x1, , drop = FALSE]
    y <- observations[observations$series_id == x2, , drop = FALSE]
    x$.book_x_row <- seq_len(nrow(x))
    y$.book_y_row <- seq_len(nrow(y))
    x$series_id <- y$series_id <- NULL
    joined <- merge(x, y, by = "date", suffixes = c(".x", ".y"), sort = FALSE)
    joined <- joined[order(joined$.book_x_row, joined$.book_y_row), , drop = FALSE]
    joined$date <- joined$.book_x_row <- joined$.book_y_row <- NULL
    joined <- stats::na.omit(joined)
    undefined <- nrow(joined) < 2L ||
      all(joined$value.x == joined$value.x[1L]) || all(joined$value.y == joined$value.y[1L])
    if (undefined) {
      if (!retain_undefined) next
      peaks <- as.data.frame(setNames(rep(list(NA_real_), length(columns)), columns))
    } else {
      peaks <- list()
      for (horizon in c(30L, 365L, 1825L)) {
        ccf <- stats::ccf(joined$value.x, joined$value.y, lag.max = horizon, plot = FALSE)
        best <- which(abs(ccf$acf) == max(abs(ccf$acf)))
        peaks[[paste0("best_corr_time_", horizon)]] <- ccf$lag[best]
        peaks[[paste0("best_corr_value_", horizon)]] <- ccf$acf[best]
      }
      peaks <- as.data.frame(peaks)
    }
    result[[length(result) + 1L]] <- cbind(data.frame(x1 = x1, x2 = x2), peaks)
  }
  output <- if (length(result)) do.call(rbind, result) else empty
  rownames(output) <- NULL
  if (namespace == "etf-correlations") {
    output$best_corr_time <- output$best_corr_time_365
    output$best_corr_value <- output$best_corr_value_365
  }
  output
}

run_original_oracle_tests <- function(scope) {
  t <- 1:96
  clean <- rbind(make_series("ETF", t, sin(t / 7) + t / 80),
                 make_series("MACRO", t, cos(t / 11) - t / 100),
                 make_series("OTHER", t, sin(t / 13) + cos(t / 9)))
  raw <- rbind(clean, clean[clean$series_id == "ETF", ])
  ancillary <- raw
  ancillary$value[c(8, 100)] <- NA_real_
  ancillary$note <- factor(rep(c("a", "b"), length.out = nrow(ancillary)))
  ancillary$note[c(3, 44, 291, 332)] <- NA
  attr(ancillary$value, "units") <- "fixture units"
  attr(ancillary, "provider") <- "literal-oracle fixture"
  undefined <- rbind(make_series("constant", 1:4, rep(7, 4)), make_series("short", 1, 2),
                      make_series("missing", 1:4, rep(NA_real_, 4)),
                      make_series("disjoint", 10:13, 1:4),
                      make_series("variable", 1:4, c(1, 3, 2, 5)))
  x <- y <- numeric(1900L)
  x[100:101] <- c(1, -1)
  y[200:201] <- c(1, -1)
  ties <- rbind(make_series("impulse-x", 1:1900, x), make_series("impulse-y", 1:1900, y))
  frames <- list(clean = clean, duplicated = raw, ancillary_NA = ancillary,
                 unsorted = clean[c(96:1, 193:288, 97:192), ],
                 reversed = clean[nrow(clean):1, ], undefined = undefined, ties = ties,
                 reordered_columns = ancillary[c("note", "value", "date", "series_id")],
                 empty = clean[FALSE, ], singleton = clean[clean$series_id == "ETF", ])
  # Empty symbol names must not become a fragile named-list lookup.
  frames$empty_series_name <- clean
  frames$empty_series_name$series_id[frames$empty_series_name$series_id == "ETF"] <- ""
  for (namespace in c("indicators-correlations", "etf-correlations")) {
    for (retain in c(TRUE, FALSE)) for (label in names(frames)) {
      expected <- literal_correlation_original(frames[[label]], namespace, retain)
      actual <- scope$book_correlation_original(frames[[label]], namespace, retain)
      stopifnot(identical(actual, expected),
                identical(serialize(actual, NULL, version = 3), serialize(expected, NULL, version = 3)))
      assert_equal(actual, expected, paste("literal oracle", namespace, retain, label))
    }
  }

  reordered <- clean[c("date", "value", "series_id")]
  stopifnot(scope$book_correlation_inputs_identical(clean, clean),
            scope$book_correlation_inputs_identical(clean, reordered))
  cases <- list(row_order = clean[nrow(clean):1, ],
                column_removed = clean[c("series_id", "date")], ancillary = clean,
                frame_attribute = clean, column_attribute = clean, type = clean, row_names = clean,
                date_class = clean, duplicated_names = clean)
  cases$ancillary$note <- NA_real_
  attr(cases$frame_attribute, "provider") <- "different"
  attr(cases$column_attribute$value, "units") <- "different"
  cases$type$series_id <- factor(cases$type$series_id)
  cases$date_class$date <- as.numeric(cases$date_class$date)
  rownames(cases$row_names) <- paste0("row-", seq_len(nrow(clean)))
  cases$duplicated_names$extra <- clean$value
  names(cases$duplicated_names)[4] <- "value"
  for (case in cases) stopifnot(!scope$book_correlation_inputs_identical(clean, case))
  # Even identical duplicate names cannot qualify for reuse, and changing the
  # second duplicate column must never be hidden by name-based subsetting.
  duplicate <- cases$duplicated_names
  stopifnot(!scope$book_correlation_inputs_identical(duplicate, duplicate))
  changed_duplicate <- duplicate
  changed_duplicate[[4]][1] <- NA_real_
  stopifnot(!scope$book_correlation_inputs_identical(duplicate, changed_duplicate))
  changed_ancillary <- ancillary
  changed_ancillary$note[1] <- NA
  stopifnot(!scope$book_correlation_inputs_identical(ancillary, changed_ancillary))

  # Exercise the actual audit branch, counting calls rather than relying only
  # on the equality predicate. Cosmetic column order uses two oracles; changed
  # rows/attributes/ancillary inputs and duplicate names require a third.
  original <- scope$book_correlation_original
  calls <- 0L
  scope$book_correlation_original <- function(...) { calls <<- calls + 1L; original(...) }
  on.exit({ scope$book_correlation_original <- original }, add = TRUE)
  for (namespace in c("indicators-correlations", "etf-correlations")) {
    baseline <- list(schema = 1L, namespace = namespace, observations = raw, etf_ids = "ETF",
                      output = literal_correlation_original(raw, namespace, FALSE))
    optimized <- list(schema = 1L, namespace = namespace, observations = reordered, etf_ids = "ETF",
                       output = literal_correlation_original(clean, namespace))
    calls <- 0L
    scope$book_audit_correlation_record(baseline, optimized)
    stopifnot(calls == 2L)
    for (mutation in c("row_order", "frame_attribute", "ancillary", "duplicated_names")) {
      bad <- optimized
      bad$observations <- clean
      if (mutation == "row_order") bad$observations <- clean[c(193:288, 97:192, 1:96), ]
      if (mutation == "frame_attribute") attr(bad$observations, "provider") <- "different"
      if (mutation == "ancillary") bad$observations$note <- 1
      if (mutation == "duplicated_names") {
        bad$observations$note <- 1
        bad$observations$other_note <- 2
        names(bad$observations)[5] <- "note"
      }
      calls <- 0L
      if (mutation == "duplicated_names") {
        notices <- character()
        withCallingHandlers(scope$book_audit_correlation_record(baseline, bad),
          warning = function(warning) {
            message <- conditionMessage(warning)
            stopifnot(grepl("column names", message, fixed = TRUE),
                      grepl("are duplicated in the result", message, fixed = TRUE))
            notices <<- c(notices, message)
            invokeRestart("muffleWarning")
          })
        stopifnot(length(notices) == 6L)
      } else {
        scope$book_audit_correlation_record(baseline, bad)
      }
      stopifnot(calls == 3L)
    }
    bad <- optimized
    bad$observations <- clean
    bad$observations$note <- 1
    bad$observations$note[c(3, 44)] <- NA_real_
    calls <- 0L
    assert_error(scope$book_audit_correlation_record(baseline, bad), "optimized complete pairs")
    stopifnot(calls == 3L)
  }
  cat("PASS: indexed independent oracle byte-identical to literal oracle across 44 namespace/NA-policy fixtures; exact full-input reuse rejects row/type/attribute/ancillary/duplicate-name changes and audits them independently\n")
}

run_correlation_audit_tests <- function(scope) {
  t <- 1:96
  clean <- rbind(make_series("ETF", t, sin(t / 7) + t / 80),
                 make_series("MACRO", t, cos(t / 11) - t / 100),
                 make_series("OTHER", t, sin(t / 13) + cos(t / 9)))
  raw <- rbind(clean, clean[clean$series_id == "ETF", ])
  root <- tempfile("correlation-audit-")
  dir.create(root)
  on.exit(unlink(root, recursive = TRUE), add = TRUE)
  directories <- file.path(root, c("baseline", "optimized"))
  records <- list()
  for (namespace in c("indicators-correlations", "etf-correlations")) {
    old <- canonical(legacy_join(raw))
    new <- scope$book_correlations_aligned(clean)
    if (namespace == "etf-correlations") {
      old$best_corr_time <- old$best_corr_time_365
      old$best_corr_value <- old$best_corr_value_365
      new$best_corr_time <- new$best_corr_time_365
      new$best_corr_value <- new$best_corr_value_365
    }
    baseline <- list(schema = 1L, namespace = namespace, observations = raw,
                      etf_ids = "ETF", output = old)
    optimized <- list(schema = 1L, namespace = namespace, observations = clean,
                       etf_ids = "ETF", output = new)
    audit <- scope$book_audit_correlation_record(baseline, optimized)
    stopifnot(audit$pairs == 6L, audit$removed_exact_etf_rows == 96L,
              audit$max_coefficient_error <= 1e-8)
    cosmetic <- optimized
    cosmetic$observations <- clean[c(193:288, 97:192, 1:96), ]
    scope$book_audit_correlation_record(baseline, cosmetic)
    for (mutation in c("coefficient", "pair", "lag", "observation")) {
      bad <- optimized
      if (mutation == "coefficient") bad$output$best_corr_value_30[1L] <- bad$output$best_corr_value_30[1L] + 1e-4
      if (mutation == "pair") bad$output <- bad$output[-1L, ]
      if (mutation == "lag") bad$output$best_corr_time_365[1L] <- bad$output$best_corr_time_365[1L] + 1
      if (mutation == "observation") bad$observations$value[1L] <- bad$observations$value[1L] + 1
      assert_error(scope$book_audit_correlation_record(baseline, bad),
                   "inputs changed|optimized complete pairs")
    }
    bad <- baseline
    bad$output$best_corr_value_30[1L] <- bad$output$best_corr_value_30[1L] + 1e-4
    assert_error(scope$book_audit_correlation_record(bad, optimized), "baseline capture differs")
    bad <- baseline
    bad$observations <- rbind(raw, clean[clean$series_id == "ETF", ])
    assert_error(scope$book_audit_correlation_record(bad, optimized), "unapproved duplicate")
    bad$observations <- rbind(raw, clean[clean$series_id == "MACRO", ])
    assert_error(scope$book_audit_correlation_record(bad, optimized), "unapproved duplicate")
    bad$observations <- rbind(clean, clean[1L, ])
    assert_error(scope$book_audit_correlation_record(bad, optimized), "partial ETF")
    bad <- baseline
    bad$observations$ancillary <- 1
    bad$observations$ancillary[c(3L, 44L, 291L, 332L)] <- NA_real_
    bad$output <- scope$book_correlation_original(bad$observations, namespace, retain_undefined = FALSE)
    assert_error(scope$book_audit_correlation_record(bad, optimized), "optimized complete pairs")

    count <- length(records) + 1L
    for (i in seq_along(directories)) {
      record <- if (i == 1L) baseline else optimized
      scope$book_capture_correlation(namespace, record$observations, record$output,
                                     record$etf_ids, directory = directories[i])
      saveRDS(record$output, file.path(directories[i], sprintf("df_ccfs-%03d.rds", count)))
    }
    records[[namespace]] <- list(baseline = baseline, optimized = optimized)
  }
  audit <- scope$book_audit_correlation_captures(directories[1L], directories[2L])
  stopifnot(nrow(audit) == 2L, all(audit$max_coefficient_error <= 1e-8))
  scope$book_compare_correlation_captures(directories[2L], directories[2L])
  extra <- file.path(directories[2L], "df_ccfs-003.rds")
  saveRDS(data.frame(unrelated = 99), extra)
  assert_error(scope$book_audit_correlation_captures(directories[1L], directories[2L]), "Unaudited df_ccfs")
  unlink(extra)
  record_path <- file.path(directories[2L], "correlations", "indicators-correlations.rds")
  bad <- readRDS(record_path)
  bad$observations$value[1L] <- bad$observations$value[1L] + 1
  saveRDS(bad, record_path)
  assert_error(scope$book_compare_correlation_captures(directories[1L], directories[2L]), "captures changed")
  assert_error(scope$book_audit_correlation_captures(directories[1L], directories[2L]), "inputs changed")
  saveRDS(records[[1L]]$optimized, record_path)
  cat("PASS: both namespace audits reject coefficient/lag/pair/input mutations, non-ETF/partial/triple duplicates, ancillary NA filtering changes and unrelated anonymous captures\n")
  if (!requireNamespace("knitr", quietly = TRUE)) {
    cat("SKIP: legacy knitr capture integration (knitr unavailable locally)\n")
    return(invisible(TRUE))
  }

  # Real knitr execution of a historical chapter with no correlation helper.
  # Namespace-only adaptation and a separate hook survive runtime re-sourcing.
  harness <- new.env(parent = globalenv())
  sys.source("scripts/benchmark_book.R", envir = harness)
  options_before <- knitr::opts_chunk$get()
  hooks_before <- knitr::knit_hooks$get()
  on.exit({ knitr::opts_chunk$restore(options_before); knitr::knit_hooks$restore(hooks_before) }, add = TRUE)
  variables <- c("BOOK_RESULTS_DIR", "BOOK_METRICS_FILE", "BOOK_DERIVED_DIR", "BOOK_SNAPSHOT_DIR", "BOOK_SNAPSHOT_MODE")
  previous <- setNames(Sys.getenv(variables, unset = NA_character_), variables)
  on.exit({
    Sys.unsetenv(variables[is.na(previous)])
    if (any(!is.na(previous))) do.call(Sys.setenv, as.list(previous[!is.na(previous)]))
  }, add = TRUE)
  legacy_directory <- file.path(root, "legacy-knitr")
  Sys.setenv(BOOK_RESULTS_DIR = legacy_directory, BOOK_METRICS_FILE = file.path(root, "metrics.csv"),
             BOOK_DERIVED_DIR = file.path(root, "derived"), BOOK_SNAPSHOT_DIR = file.path(root, "inputs"),
             BOOK_SNAPSHOT_MODE = "live")
  harness$book_install_correlation_capture(list(version = "baseline",
    correlation_helper = normalizePath("scripts/analysis/correlations.R")))
  environment <- new.env(parent = globalenv())
  environment$observations <- raw
  environment$original_output <- records[[1L]]$baseline$output
  text <- c("```{r setup}",
    paste0("source(", encodeString(normalizePath("scripts/book_runtime.R"), quote = '"'), ", local=TRUE)"),
    "```", "```{r correlation}", "df_all <- observations", 'df_etfs <- data.frame(Ticker="ETF")',
    "df_ccfs <- original_output", "```")
  text <- harness$book_correlation_namespace_setup(text, "indicators-correlations")
  knitr::knit(text = text, envir = environment, quiet = TRUE)
  captured <- readRDS(file.path(legacy_directory, "correlations", "indicators-correlations.rds"))
  stopifnot(identical(captured$observations, raw),
            identical(captured$output, records[[1L]]$baseline$output),
            !exists("book_capture_correlation", environment, inherits = FALSE))
  cat("PASS: historical helper-free chapter captures full df_all/results after CCF via namespace adapter, surviving runtime hook reinstallation\n")
}

run_mortgage_date_tests <- function(scope) {
  # Evaluate the actual pure runtime helpers without initializing providers or
  # changing knitr hooks. They require only base R, including diagnostic RDS.
  runtime <- new.env(parent = globalenv())
  definitions <- Filter(function(expression) {
    is.call(expression) && length(expression) >= 3L &&
      as.character(expression[[1L]]) %in% c("<-", "=") &&
      is.symbol(expression[[2L]]) &&
      as.character(expression[[2L]]) %in% c("book_iso_week_monday", "book_save_rds")
  }, as.list(parse("scripts/book_runtime.R")))
  stopifnot(length(definitions) == 2L)
  for (definition in definitions) eval(definition, runtime)
  year <- c(1998, 2009, 2015, 2020, 2019, 2020, 2021, 2026)
  week <- c(53, 53, 53, 53, 1, 1, 1, 40)
  expected <- as.Date(c("1998-12-28", "2009-12-28", "2015-12-28", "2020-12-28",
                        "2018-12-31", "2019-12-30", "2021-01-04", "2026-09-28"))
  assert_equal(runtime$book_iso_week_monday(year, week), expected, "ISO Monday boundaries")
  assert_equal(runtime$book_iso_week_monday(as.character(year), as.character(week)),
               expected, "workbook character years")
  stopifnot(all(is.na(suppressWarnings(as.Date(paste(year[1:4], week[1:4], 1, sep="-"),
                                                "%Y-%U-%u")))))
  # A four-row-only fallback would collide with the old week 52 Mondays.
  old_52 <- suppressWarnings(as.Date(paste(year[1:4], 52, 1, sep="-"), "%Y-%U-%u"))
  stopifnot(all(old_52 == expected[1:4]),
            all(runtime$book_iso_week_monday(year[1:4], rep(52, 4)) < expected[1:4]))
  for (bad_week in c(0, 54, 1.5, NA_real_, Inf)) {
    assert_error(runtime$book_iso_week_monday(2021, bad_week), "valid integer ISO")
  }
  assert_error(runtime$book_iso_week_monday(2021, 53), "invalid ISO week")
  assert_error(runtime$book_iso_week_monday(NA_real_, 1), "valid integer ISO")
  assert_error(runtime$book_iso_week_monday(c(2020, 2021), 1), "valid integer ISO")
  assert_equal(runtime$book_iso_week_monday(integer(), integer()), as.Date(character()),
               "empty ISO input")
  # Every published affected chapter uses precisely the same normalization.
  for (chapter in c("Chapters/01_Indicators/1_Indicators.Rmd", "Chapters/05_ETFs/ETFs.Rmd",
                    "Chapters/03_InterestRates/InterestRates.Rmd")) {
    assignments <- Filter(function(expression) {
      is.call(expression) && length(expression) >= 3L &&
        identical(expression[[2L]], quote(df_interest$Date))
    }, chapter_expressions(chapter))
    stopifnot(length(assignments) == 1L,
              identical(assignments[[1L]][[3L]], quote(book_iso_week_monday(df_interest$År, df_interest$Uge))))
  }

  directory <- tempfile("invalid-correlation-input-")
  previous <- Sys.getenv("BOOK_RESULTS_DIR", unset = NA_character_)
  on.exit({
    if (is.na(previous)) Sys.unsetenv("BOOK_RESULTS_DIR") else Sys.setenv(BOOK_RESULTS_DIR = previous)
    unlink(directory, recursive = TRUE)
    scope$book_save_rds <- NULL
  }, add = TRUE)
  invalid <- data.frame(series_id = c("Kort.rente", "Kort.rente", NA_character_),
                        date = as.Date(c(NA_character_, NA_character_, "2020-12-28")),
                        value = c(4.07, 1.74, 5.19), provider_note = c("a", "b", "c"))
  Sys.unsetenv("BOOK_RESULTS_DIR")
  scope$book_save_rds <- function(...) stop("Unconfigured capture must not write")
  assert_error(scope$book_prepare_correlations(invalid, "indicators-correlations"),
                "indicators-correlations.*3 invalid rows; missing series_id=1, missing date=2.*Kort.rente=2")
  stopifnot(!dir.exists(directory))
  scope$book_save_rds <- runtime$book_save_rds
  Sys.setenv(BOOK_RESULTS_DIR = directory)
  assert_error(scope$book_prepare_correlations(invalid, "indicators-correlations"), "must not be missing")
  record <- readRDS(file.path(directory, "invalid-correlation-inputs-indicators-correlations.rds"))
  stopifnot(identical(record$invalid_rows, invalid), identical(record$row_indices, 1:3),
            identical(record$namespace, "indicators-correlations"),
            record$missing_series_id == 1L, record$missing_date == 2L,
            sum(record$series_counts$rows) == 3L)
  cat("PASS: ISO week 53/year boundaries, consistent three-chapter dates, invalid weeks rejected, strict missing-key diagnostics and configured-only full-row capture\n")
}

run_correlations_tests <- function() {
  scope <- correlation_scope
  run_mortgage_date_tests(scope)
  run_original_oracle_tests(scope)
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
  optional$book_yahoo <- function(ticker, attempts = 3L) {
    stopifnot(identical(attempts, 1L))
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
  run_correlation_audit_tests(scope)
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
