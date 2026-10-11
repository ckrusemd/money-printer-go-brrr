# Usage: Rscript --vanilla scripts/benchmark_book.R BASELINE OPTIMIZED SNAPSHOTS [ARTIFACT_DIR]
# Both checkouts must have the shared replay-capable runtime. No source files are
# changed: even packages.bib and generated figures are confined to scratch copies.

book_numeric_equal <- function(left, right, tolerance = 1e-8) {
  if (identical(left, right)) return(TRUE)
  attributes_sorted <- function(x) {
    values <- attributes(x)
    values[sort(names(values))]
  }
  if (!identical(attributes_sorted(left), attributes_sorted(right))) return(FALSE)
  if (is.numeric(left) && is.numeric(right)) {
    if (length(left) != length(right) || !identical(is.na(left), is.na(right))) return(FALSE)
    valid <- !is.na(left)
    a <- left[valid]
    b <- right[valid]
    finite <- is.finite(a) & is.finite(b)
    # Check every value individually; an average error could conceal a bad
    # prediction among thousands of unchanged values.
    return(identical(a[!finite], b[!finite]) && all(abs(a[finite] - b[finite]) <= tolerance))
  }
  if (is.list(left) && is.list(right) && length(left) == length(right)) {
    return(all(vapply(seq_along(left), function(i) {
      book_numeric_equal(left[[i]], right[[i]], tolerance)
    }, logical(1))))
  }
  FALSE
}

book_benchmark_rss <- function(results) {
  warm <- results[!results$warmup, , drop = FALSE]
  statistic <- function(version, warmup, fun) {
    values <- results$max_rss_kb[results$version == version & results$warmup == warmup]
    if (!length(values)) return(NA_real_)
    fun(values)
  }
  baseline_median <- statistic("baseline", FALSE, median)
  optimized_median <- statistic("optimized", FALSE, median)
  baseline_peak <- statistic("baseline", FALSE, max)
  optimized_peak <- statistic("optimized", FALSE, max)
  valid <- all(c("baseline", "optimized") %in% warm$version) &&
    all(is.finite(warm$max_rss_kb) & warm$max_rss_kb > 0)
  median_met <- valid && isTRUE(optimized_median <= baseline_median)
  peak_met <- valid && isTRUE(optimized_peak <= baseline_peak)
  data.frame(baseline_median_max_rss_kb = baseline_median,
             optimized_median_max_rss_kb = optimized_median,
             baseline_warm_peak_rss_kb = baseline_peak,
             optimized_warm_peak_rss_kb = optimized_peak,
             baseline_warmup_peak_rss_kb = statistic("baseline", TRUE, max),
             optimized_warmup_peak_rss_kb = statistic("optimized", TRUE, max),
             rss_measurements_valid = valid,
             rss_median_target_met = median_met,
             rss_peak_target_met = peak_met,
             rss_target_met = median_met && peak_met)
}

book_install_correlation_capture <- function(config) {
  source(config$correlation_helper, local = TRUE)
  # Runtime/theme sourcing can reinstall book_timing; use an independent hook.
  knitr::knit_hooks$set(book_correlation_capture = function(before, options, envir) {
    assigned <- grepl("(?m)^\\s*df_ccfs\\s*(=|<-)",
                      paste(options$code, collapse = "\n"), perl = TRUE)
    if (!before && identical(config$version, "baseline") && assigned) {
      if (!exists("book_correlation_namespace", envir, inherits = FALSE)) {
        stop("Missing chapter correlation namespace")
      }
      book_capture_correlation(get("book_correlation_namespace", envir),
                               get("df_all", envir), get("df_ccfs", envir),
                               get("df_etfs", envir)$Ticker)
    }
    invisible(NULL)
  })
  knitr::opts_chunk$set(book_correlation_capture = TRUE)
  invisible(NULL)
}

book_correlation_namespace_setup <- function(text, namespace) {
  if (any(grepl("^book_correlation_namespace\\s*(=|<-)", text))) return(text)
  first <- which(grepl("^```\\{r", text))[1L]
  if (is.na(first)) stop("No setup chunk for baseline correlation namespace")
  append(text, paste0("book_correlation_namespace <- ", encodeString(namespace, quote = '"')),
         after = first)
}

book_benchmark_render <- function(config_path) {
  config <- readRDS(config_path)
  setwd(config$root)
  Sys.setenv(BOOK_SNAPSHOT_MODE = "replay", BOOK_SNAPSHOT_DIR = config$snapshots,
             BOOK_AS_OF = config$as_of, BOOK_DERIVED_DIR = config$derived,
             BOOK_METRICS_FILE = config$metrics, BOOK_RESULTS_DIR = config$numeric, TZ = "UTC")
  set.seed(1971)
  dir.create(config$numeric, recursive = TRUE, showWarnings = FALSE)
  # Install the shared hook before rendering either version. BOOK_RESULTS_DIR
  # stores complete correlation and model outputs, not samples or summaries.
  source("scripts/book_runtime.R")
  if (!is.null(config$correlation_helper)) {
    book_install_correlation_capture(config)
  }
  # Isolate helper/config variables from the environment used by the book.
  book_environment <- new.env(parent = globalenv())
  bookdown::render_book("index.Rmd", output_dir = "_book", envir = book_environment,
                        clean = TRUE)
  source(config$validator, local = TRUE)
  expected <- book_expected_pages
  if (!any(grepl("Data_Status.Rmd", readLines("_bookdown.yml", warn = FALSE), fixed = TRUE))) {
    expected <- setdiff(expected, "data-status.html")
  }
  check_bookdown_output("_book", expected_pages = expected,
                        check_chart_alt = !identical(config$version, "baseline"))
  if (!length(list.files(config$numeric, "\\.rds$"))) stop("No numeric chunk captures produced")
  required <- c("df_ccfs", "rf_backtest", "rf_metrics", "rf_regime_metrics",
                "rf_live_forecast", "dff_rf_has_skill",
                "model_predictions_DFF", "model_predictions_DGS2",
                "model_predictions_DGS10", "model_predictions_MORTGAGE30US",
                "model_predictions_DK_Short", "model_predictions_DK_Long",
                "model_predictions_CPIAUCSL", "model_predictions_CSUSHPINSA",
                "model_predictions_M2SL", "model_predictions_UMCSENT",
                "model_predictions_USREC", "model_predictions_DF",
                "model_predictions_DGS2_on_DFF", "model_predictions_DGS10_on_DFF",
                "model_predictions_MORTGAGE30US_on_DFF", "model_predictions_DK_Long_on_DK_Short")
  present <- sub("-[0-9]+\\.rds$", "", list.files(config$numeric, "\\.rds$"))
  if (!all(required %in% present)) stop("Missing full analysis outputs: ",
                                       paste(setdiff(required, present), collapse = ", "))
  writeLines(capture.output(sessionInfo()), file.path(dirname(config$numeric), "session-info.txt"))
}

book_compare_numeric <- function(baseline, optimized, tolerance = 1e-8,
                                 correlations = FALSE) {
  left <- list.files(baseline, "\\.rds$")
  right <- list.files(optimized, "\\.rds$")
  select <- function(files) files[grepl("^df_ccfs-", files) == correlations]
  left <- select(left)
  right <- select(right)
  if (!identical(left, right) || !length(left)) return("Numeric result coverage differs or is empty")
  differences <- character()
  for (file in left) {
    a <- readRDS(file.path(baseline, file))
    b <- readRDS(file.path(optimized, file))
    if (!book_numeric_equal(a, b, tolerance)) {
      detail <- all.equal(a, b, tolerance = 0, check.attributes = TRUE)
      differences <- c(differences, paste(file, paste(detail, collapse = "; ")))
    }
  }
  differences
}

benchmark_book <- function(baseline, optimized, snapshots,
                           artifacts = ".cache/book-benchmark", as_of = NULL) {
  roots <- c(baseline = normalizePath(baseline, mustWork = TRUE),
             optimized = normalizePath(optimized, mustWork = TRUE))
  snapshots <- normalizePath(snapshots, mustWork = TRUE)
  if (!length(list.files(snapshots, "\\.rds$", recursive = TRUE))) stop("No provider snapshots supplied")
  date_path <- file.path(snapshots, "as-of.txt")
  if (is.null(as_of)) {
    if (!file.exists(date_path)) stop("Snapshot artifact lacks as-of.txt; supply its recorded BOOK_AS_OF")
    as_of <- trimws(readLines(date_path, warn = FALSE)[[1L]])
  }
  if (length(as_of) != 1L || is.na(as.Date(as_of))) stop("Invalid benchmark as-of date")
  if (file.exists(date_path) && !identical(as.character(as.Date(as_of)),
                                        trimws(readLines(date_path, warn = FALSE)[[1L]]))) {
    stop("BOOK_AS_OF differs from the snapshot recording date")
  }
  # Only artifact directories are writable; reject a source root or arbitrary
  # tracked destination before creating anything.
  # Resolve the existing ancestor first: normalizePath() alone leaves a missing
  # relative destination unresolved and can bypass the checkout guard.
  absolute_destination <- if (grepl("^(/|[A-Za-z]:[/\\\\])", artifacts)) artifacts else file.path(getwd(), artifacts)
  ancestor <- absolute_destination
  suffix <- character()
  while (!file.exists(ancestor)) {
    suffix <- c(basename(ancestor), suffix)
    ancestor <- dirname(ancestor)
  }
  destination <- normalizePath(ancestor, mustWork = TRUE)
  for (component in suffix) {
    if (component == "..") destination <- dirname(destination)
    else if (!component %in% c(".", "")) destination <- file.path(destination, component)
  }
  if (identical(destination, snapshots) || startsWith(destination, paste0(snapshots, "/"))) {
    stop("Benchmark artifacts must not be written into provider snapshots")
  }
  for (root in roots) {
    if (identical(destination, root) ||
        (startsWith(destination, paste0(root, "/")) &&
         !startsWith(destination, paste0(root, "/.cache/")))) {
      stop("Benchmark artifacts inside a checkout must be under .cache/")
    }
    if (!file.exists(file.path(root, "scripts/book_runtime.R"))) {
      stop("Both versions must include the replay-capable scripts/book_runtime.R: ", root)
    }
  }
  if (dir.exists(artifacts) && length(list.files(artifacts, all.files = TRUE, no.. = TRUE))) {
    stop("Use an empty artifact directory; existing benchmark evidence will not be overwritten")
  }
  if (!file.exists("/usr/bin/time")) {
    stop("Full-book benchmark acceptance requires /usr/bin/time for finite peak RSS; rebuild the publication image")
  }
  dir.create(destination, recursive = TRUE, showWarnings = FALSE)
  artifacts <- normalizePath(destination, mustWork = TRUE)
  scratch <- tempfile("book-benchmark-")
  dir.create(scratch)
  on.exit(unlink(scratch, recursive = TRUE), add = TRUE)
  snapshot_files <- list.files(snapshots, recursive = TRUE, full.names = TRUE)
  snapshot_hash <- tools::md5sum(snapshot_files)
  saveRDS(snapshot_hash, file.path(artifacts, "snapshot-hashes.rds"))
  writeLines(as_of, file.path(artifacts, "as-of.txt"))
  validator <- file.path(roots[["optimized"]], "scripts/check_bookdown_output.R")
  correlation_helper <- file.path(roots[["optimized"]], "scripts/analysis/correlations.R")
  if (!file.exists(correlation_helper)) stop("Missing independent correlation audit helper")
  source(correlation_helper, local = TRUE)
  harness <- normalizePath("scripts/benchmark_book.R", mustWork = TRUE)
  runner <- file.path(artifacts, "render-child.R")
  writeLines(c("args <- commandArgs(trailingOnly = TRUE)",
               "source(args[[1L]])", "book_benchmark_render(args[[2L]])"), runner)
  work <- setNames(file.path(scratch, names(roots)), names(roots))
  for (version in names(roots)) {
    dir.create(work[[version]])
    files <- list.files(roots[[version]], all.files = TRUE, recursive = TRUE,
                        full.names = TRUE, no.. = TRUE)
    relative <- substring(files, nchar(roots[[version]]) + 2L)
    keep <- !grepl("^(\\.git(/|$)|\\.cache/|_book/|renv/(library|cache|staging)/)", relative)
    for (i in which(keep)) {
      target <- file.path(work[[version]], relative[[i]])
      dir.create(dirname(target), recursive = TRUE, showWarnings = FALSE)
      if (!file.copy(files[[i]], target)) stop("Cannot copy benchmark input: ", files[[i]])
    }
    if (version == "baseline") {
      chapters <- c("Chapters/01_Indicators/1_Indicators.Rmd" = "indicators-correlations",
                    "Chapters/05_ETFs/ETFs.Rmd" = "etf-correlations")
      for (chapter in names(chapters)) {
        path <- file.path(work[[version]], chapter)
        text <- readLines(path, warn = FALSE)
        writeLines(book_correlation_namespace_setup(text, chapters[[chapter]]), path)
      }
    }
  }
  results <- data.frame(version = character(), run = integer(), warmup = logical(),
                        elapsed_seconds = double(), max_rss_kb = double(), exit_status = integer())
  rscript <- file.path(R.home("bin"), "Rscript")
  # Prime each version once; interleave the three measured pairs to reduce drift.
  for (run in 0:3) for (version in names(roots)) {
    output <- file.path(artifacts, paste0(version, "-", run))
    dir.create(output)
    config <- list(root = work[[version]], version = version, snapshots = snapshots, as_of = as_of,
                   derived = file.path(work[[version]], ".cache/book-derived"),
                   metrics = file.path(output, "book-metrics.csv"),
                   numeric = file.path(output, "numeric"), validator = validator,
                   correlation_helper = correlation_helper)
    config_path <- file.path(output, "config.rds")
    saveRDS(config, config_path)
    log <- file.path(output, "render.log")
    timing <- file.path(output, "time.csv")
    args <- c("--vanilla", runner, harness, config_path)
    start <- proc.time()[["elapsed"]]
    if (file.exists("/usr/bin/time")) {
      status <- system2("/usr/bin/time", c("-f", shQuote("%e,%M"), "-o", shQuote(timing),
                                          shQuote(rscript), vapply(args, shQuote, character(1))),
                        stdout = log, stderr = log)
      measurement <- if (file.exists(timing)) {
        tail(readLines(timing, warn = FALSE), 1L)
      } else "NA,NA"
      numbers <- suppressWarnings(as.numeric(strsplit(measurement, ",", fixed = TRUE)[[1L]]))
      elapsed <- numbers[[1L]]
      rss <- numbers[[2L]]
    } else {
      status <- system2(rscript, vapply(args, shQuote, character(1)), stdout = log, stderr = log)
      elapsed <- proc.time()[["elapsed"]] - start
      rss <- NA_real_
    }
    results <- rbind(results, data.frame(version = version, run = run, warmup = run == 0L,
                                        elapsed_seconds = elapsed, max_rss_kb = rss, exit_status = status))
    utils::write.csv(results, file.path(artifacts, "runs.csv"), row.names = FALSE)
    cat(version, "run", run, ":", elapsed, "seconds;", rss, "KB RSS; status", status, "\n")
    if (status != 0L) stop("Benchmark render failed; see ", log)
  }
  if (!identical(snapshot_hash, tools::md5sum(snapshot_files))) stop("Provider snapshots changed during benchmark")
  differences <- correlation_differences <- character()
  correlation_audits <- NULL
  correlation_parity_runs <- 0L
  reference <- file.path(artifacts, "baseline-1/numeric")
  for (version in names(roots)) for (run in 0:3) {
    differences <- c(differences, book_compare_numeric(reference,
                        file.path(artifacts, paste0(version, "-", run), "numeric")))
  }
  for (version in names(roots)) for (run in 0:3) {
    # Reproducibility alone does not excuse cross-version regressions. The full
    # independent namespace audit below must prove the exact ETF correction.
    own <- file.path(artifacts, paste0(version, "-1"), "numeric")
    differences <- c(differences, book_compare_numeric(own,
                        file.path(artifacts, paste0(version, "-", run), "numeric"), correlations = TRUE))
    if (version == "optimized") {
      correlation_differences <- c(correlation_differences, book_compare_numeric(reference,
                            file.path(artifacts, paste0(version, "-", run), "numeric"), correlations = TRUE))
    }
    directory <- file.path(artifacts, paste0(version, "-", run), "numeric")
    # Exact full input/output parity propagates the independent audit to all
    # repeated runs, without recomputing the expensive oracle eight times.
    parity <- tryCatch(book_compare_correlation_captures(own, directory), error = identity)
    if (inherits(parity, "error")) {
      differences <- c(differences, paste(version, run, conditionMessage(parity)))
    } else {
      correlation_parity_runs <- correlation_parity_runs + 1L
    }
  }
  audited <- tryCatch(book_audit_correlation_captures(reference,
                        file.path(artifacts, "optimized-1/numeric")), error = identity)
  if (inherits(audited, "error")) {
    differences <- c(differences, conditionMessage(audited))
  } else {
    correlation_audits <- audited
    utils::write.csv(correlation_audits,
                     file.path(artifacts, "correlation-audit.csv"), row.names = FALSE)
  }
  writeLines(if (length(differences)) unique(differences) else "All full numeric captures match (tolerance 1e-8).",
             file.path(artifacts, "numeric-comparison.txt"))
  writeLines(if (length(correlation_differences)) unique(correlation_differences) else "Correlations match.",
             file.path(artifacts, "historical-correlation-differences.txt"))
  medians <- tapply(results$elapsed_seconds[!results$warmup], results$version[!results$warmup], median)
  rss_summary <- book_benchmark_rss(results)
  reduction <- 1 - medians[["optimized"]] / medians[["baseline"]]
  rss_met <- isTRUE(rss_summary$rss_target_met)
  summary <- cbind(data.frame(baseline_median_seconds = medians[["baseline"]],
                             optimized_median_seconds = medians[["optimized"]], reduction = reduction),
                   rss_summary,
                   data.frame(
                        model_results_equal = !length(differences),
                        correlations_audited = !is.null(correlation_audits) && correlation_parity_runs == 8L,
                        historical_correlation_differences = length(unique(correlation_differences)),
                        runtime_target_met = is.finite(reduction) && reduction >= 0.30,
                        target_met = !length(differences) && is.finite(reduction) && reduction >= 0.30 && rss_met))
  utils::write.csv(summary, file.path(artifacts, "summary.csv"), row.names = FALSE)
  if (length(differences)) stop("Numeric analysis differs; see numeric-comparison.txt")
  if (!is.finite(reduction) || reduction < 0.30) stop("Warm runtime reduction below 30%; see summary.csv")
  if (!rss_met) stop("Warm peak RSS must be finite and positive; optimized median and maximum must not exceed baseline; see summary.csv")
  invisible(summary)
}

if (sys.nframe() == 0L) {
  args <- commandArgs(trailingOnly = TRUE)
  if (length(args) < 3L || length(args) > 4L) {
    stop("Usage: benchmark_book.R BASELINE OPTIMIZED SNAPSHOTS [ARTIFACT_DIR]")
  }
  benchmark_book(args[[1L]], args[[2L]], args[[3L]],
                 if (length(args) == 4L) args[[4L]] else ".cache/book-benchmark")
}
