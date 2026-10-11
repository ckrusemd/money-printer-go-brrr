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
                "rf_live_forecast", "dff_rf_has_skill")
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
                   numeric = file.path(output, "numeric"), validator = validator)
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
  reference <- file.path(artifacts, "baseline-1/numeric")
  for (version in names(roots)) for (run in 0:3) {
    differences <- c(differences, book_compare_numeric(reference,
                        file.path(artifacts, paste0(version, "-", run), "numeric")))
  }
  for (version in names(roots)) for (run in 0:3) {
    # Correlations must be reproducible within each version. Historical ETF
    # duplicates are the approved bug fix, so cross-version differences are
    # retained in a separate report and do not excuse any model changes.
    own <- file.path(artifacts, paste0(version, "-1"), "numeric")
    differences <- c(differences, book_compare_numeric(own,
                        file.path(artifacts, paste0(version, "-", run), "numeric"), correlations = TRUE))
    if (version == "optimized") {
      correlation_differences <- c(correlation_differences, book_compare_numeric(reference,
                            file.path(artifacts, paste0(version, "-", run), "numeric"), correlations = TRUE))
    }
  }
  writeLines(if (length(differences)) unique(differences) else "All full numeric captures match (tolerance 1e-8).",
             file.path(artifacts, "numeric-comparison.txt"))
  writeLines(if (length(correlation_differences)) unique(correlation_differences) else "Correlations match.",
             file.path(artifacts, "historical-correlation-differences.txt"))
  medians <- tapply(results$elapsed_seconds[!results$warmup], results$version[!results$warmup], median)
  rss_medians <- tapply(results$max_rss_kb[!results$warmup], results$version[!results$warmup], median)
  reduction <- 1 - medians[["optimized"]] / medians[["baseline"]]
  rss_met <- all(is.finite(results$max_rss_kb[!results$warmup])) &&
    rss_medians[["optimized"]] <= rss_medians[["baseline"]]
  summary <- data.frame(baseline_median_seconds = medians[["baseline"]],
                        optimized_median_seconds = medians[["optimized"]], reduction = reduction,
                        baseline_median_max_rss_kb = rss_medians[["baseline"]],
                        optimized_median_max_rss_kb = rss_medians[["optimized"]],
                        model_results_equal = !length(differences),
                        historical_correlation_differences = length(unique(correlation_differences)),
                        runtime_target_met = is.finite(reduction) && reduction >= 0.30,
                        rss_target_met = rss_met,
                        target_met = !length(differences) && is.finite(reduction) && reduction >= 0.30 && rss_met)
  utils::write.csv(summary, file.path(artifacts, "summary.csv"), row.names = FALSE)
  if (length(differences)) stop("Numeric analysis differs; see numeric-comparison.txt")
  if (!is.finite(reduction) || reduction < 0.30) stop("Warm runtime reduction below 30%; see summary.csv")
  if (!rss_met) stop("Peak RSS must be finite and optimized median must not exceed baseline; see summary.csv")
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
