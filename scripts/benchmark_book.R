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

book_benchmark_required <- function() {
  c("df_ccfs", "rf_backtest", "rf_metrics", "rf_regime_metrics",
    "rf_live_forecast", "dff_rf_has_skill",
    paste0("model_predictions_", c("DFF", "DGS2", "DGS10", "MORTGAGE30US",
      "DK_Short", "DK_Long", "CPIAUCSL", "CSUSHPINSA", "M2SL", "UMCSENT",
      "USREC", "DF", "DGS2_on_DFF", "DGS10_on_DFF", "MORTGAGE30US_on_DFF",
      "DK_Long_on_DK_Short")))
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
  required <- book_benchmark_required()
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

book_benchmark_namespaces <- c("indicators-correlations", "etf-correlations")

book_read_provenance <- function(path) {
  fields <- c("schema", "repository", "source_sha", "baseline_sha", "image",
              "snapshot_run_id", "benchmark_run_id", "mode",
              "snapshot_artifact_id", "snapshot_artifact_digest")
  value <- read.dcf(path)
  if (nrow(value) != 1L || !all(fields %in% colnames(value))) stop("Incomplete provenance receipt")
  value <- as.list(value[1L, ])
  if (!identical(value$schema, "1") ||
      !identical(value$repository, "ckrusemd/money-printer-go-brrr") ||
      !value$mode %in% c("fresh", "legacy") ||
      !grepl("^[0-9a-f]{40}$", value$source_sha) ||
      !grepl("^[0-9a-f]{40}$", value$baseline_sha) ||
      !grepl("^ghcr\\.io/ckrusemd/money-printer-go-brrr-r@sha256:[0-9a-f]{64}$", value$image) ||
      !grepl("^sha256:[0-9a-f]{64}$", value$snapshot_artifact_digest) ||
      any(!vapply(value[c("snapshot_run_id", "benchmark_run_id", "snapshot_artifact_id")],
                  function(x) grepl("^[1-9][0-9]*$", x), logical(1)))) stop("Invalid provenance receipt")
  value
}

book_check_archive_contents <- function(directory, provenance) {
  if (is.null(provenance$archive_path) || is.null(provenance$archive_digest) ||
      !file.exists(provenance$archive_path) ||
      !identical(paste0("sha256:", digest::digest(file = provenance$archive_path, algo = "sha256")),
                 provenance$archive_digest)) stop("Authenticated archive digest mismatch")
  entries <- utils::unzip(provenance$archive_path, list = TRUE)
  entries <- entries[!endsWith(entries$Name, "/"), , drop = FALSE]
  files <- sort(list.files(directory, recursive = TRUE, full.names = TRUE, all.files = TRUE, no.. = TRUE))
  relative <- substring(files, nchar(normalizePath(directory)) + 2L)
  if (anyDuplicated(entries$Name) || !setequal(relative, entries$Name)) stop("Extracted archive coverage mismatch")
  for (i in seq_len(nrow(entries))) {
    entry <- entries$Name[[i]]
    connection <- unz(provenance$archive_path, entry, open = "rb")
    bytes <- tryCatch(readBin(connection, "raw", n = entries$Length[[i]]), finally = close(connection))
    if (length(bytes) != entries$Length[[i]] ||
        !identical(digest::digest(bytes, algo = "md5", serialize = FALSE),
                   unname(tools::md5sum(file.path(directory, entry))))) stop("Extracted archive content mismatch: ", entry)
  }
  invisible(TRUE)
}

book_evidence_key <- function(directory, provenance) {
  files <- sort(list.files(directory, recursive = TRUE, full.names = TRUE,
                           all.files = TRUE, no.. = TRUE))
  hashes <- tools::md5sum(files)
  names(hashes) <- substring(names(hashes), nchar(normalizePath(directory)) + 2L)
  digest::digest(list(hashes = hashes, provenance = provenance), algo = "sha256")
}

# Read evidence only. Never execute artifact scripts or re-use vanished scratch
# roots from config.rds. All eight successful child processes already ran the
# full publication validator (strict alt on optimized, explicit legacy mode).
book_validate_evidence <- function(directory, snapshots, provenance_path) {
  directory <- normalizePath(directory, mustWork = TRUE)
  snapshots <- normalizePath(snapshots, mustWork = TRUE)
  provenance <- book_read_provenance(provenance_path)
  authenticated <- provenance
  if (!is.null(authenticated$archive_path) &&
      !grepl("^(/|[A-Za-z]:[/\\\\])", authenticated$archive_path)) {
    authenticated$archive_path <- file.path(dirname(normalizePath(provenance_path, mustWork = TRUE)),
                                          authenticated$archive_path)
  }
  saved_path <- file.path(directory, "provenance.dcf")
  if (file.exists(saved_path)) {
    saved <- book_read_provenance(saved_path)
    if (!identical(saved, provenance[names(saved)])) stop("Source/image provenance mismatch")
  } else {
    # The sole legacy artifact is independently authenticated by the fixed-repo
    # API, its archive SHA256, and original runner logs in benchmark_provenance.py.
    legacy <- c(benchmark_run_id = "38169256067",
      source_sha = "0e4d1110188a68f203a3fa17efdfd0010b1a96a4",
      baseline_sha = "b7e08934877da8a88b4b2393a3745b994f8bff48",
      snapshot_run_id = "38166191755", snapshot_artifact_id = "11712094467",
      snapshot_artifact_digest = "sha256:1109864ee6b096cc5e6fd6662790d39d8e3263f7a5122542917f5ff5600df668",
      image = "ghcr.io/ckrusemd/money-printer-go-brrr-r@sha256:89a9b02fd62a3cbca56bb06519dabfc321117ac69fd2432dc7c8b3cbaf17a5db",
      archive_digest = "sha256:cfc889b82604bc9a58a54e02311ad9c074f56c8ced670add17da43fd33f2ad41")
    if (!identical(provenance$mode, "legacy") ||
        !identical(unlist(provenance[names(legacy)]), legacy) ||
        is.null(authenticated$archive_path) || !file.exists(authenticated$archive_path) ||
        is.null(provenance$logs_digest) ||
        !grepl("^sha256:[0-9a-f]{64}$", provenance$logs_digest)) {
      stop("Missing authenticated legacy provenance")
    }
  }
  if (!is.null(authenticated$archive_path)) book_check_archive_contents(directory, authenticated)
  results <- utils::read.csv(file.path(directory, "runs.csv"), stringsAsFactors = FALSE)
  columns <- c("version", "run", "warmup", "elapsed_seconds", "max_rss_kb", "exit_status")
  keys <- paste(results$version, results$run, sep = "-")
  expected <- as.vector(outer(c("baseline", "optimized"), 0:3, paste, sep = "-"))
  if (!identical(names(results), columns) || nrow(results) != 8L ||
      anyDuplicated(keys) || !setequal(keys, expected) || anyNA(results) ||
      !is.logical(results$warmup) || !identical(results$warmup, results$run == 0L) ||
      any(results$exit_status != 0L) ||
      any(!is.finite(results$elapsed_seconds) | results$elapsed_seconds <= 0) ||
      any(!is.finite(results$max_rss_kb) | results$max_rss_kb <= 0)) stop("Incomplete/invalid eight-run evidence")
  as_of <- trimws(readLines(file.path(directory, "as-of.txt"), warn = FALSE))
  if (length(as_of) != 1L || !grepl("^[0-9]{4}-[0-9]{2}-[0-9]{2}$", as_of) ||
      is.na(as.Date(as_of)) || !identical(as_of, trimws(readLines(file.path(snapshots, "as-of.txt"), warn = FALSE)))) {
    stop("Snapshot as-of mismatch")
  }
  saved_hashes <- readRDS(file.path(directory, "snapshot-hashes.rds"))
  snapshot_files <- sort(list.files(snapshots, recursive = TRUE, full.names = TRUE))
  current_hashes <- tools::md5sum(snapshot_files)
  names(saved_hashes) <- basename(names(saved_hashes))
  names(current_hashes) <- basename(names(current_hashes))
  if (!length(saved_hashes) || anyNA(saved_hashes) || anyDuplicated(names(saved_hashes)) ||
      anyDuplicated(names(current_hashes)) ||
      !identical(saved_hashes[order(names(saved_hashes))], current_hashes[order(names(current_hashes))])) {
    stop("Snapshot content hashes mismatch")
  }
  manifest <- readRDS(file.path(snapshots, "manifest.rds"))
  if (!is.list(manifest) || !identical(manifest$schema_version, 1L) ||
      !identical(manifest$as_of, as.Date(as_of)) || !is.list(manifest$requests)) stop("Snapshot manifest schema/date mismatch")
  source("scripts/analysis/correlations.R", local = TRUE)
  coverage <- NULL
  configurations <- list()
  for (i in seq_len(nrow(results))) {
    path <- file.path(directory, keys[[i]])
    timing <- scan(file.path(path, "time.csv"), sep = ",", quiet = TRUE)
    if (length(timing) != 2L || !identical(as.numeric(timing),
        c(results$elapsed_seconds[[i]], as.numeric(results$max_rss_kb[[i]])))) stop("Run timing mismatch: ", keys[[i]])
    config <- readRDS(file.path(path, "config.rds"))
    if (!identical(config$version, results$version[[i]]) || !identical(config$as_of, as_of) ||
        !is.character(config$snapshots) || length(config$snapshots) != 1L ||
        !nzchar(config$snapshots)) stop("Run configuration mismatch: ", keys[[i]])
    configurations[[keys[[i]]]] <- config
    log <- readLines(file.path(path, "render.log"), warn = FALSE)
    if (!any(grepl("Bookdown output checked:", log, fixed = TRUE)) ||
        any(grepl("Execution halted|Quitting from lines", log)) ||
        !file.exists(file.path(path, "session-info.txt")) ||
        !file.exists(file.path(path, "book-metrics.csv"))) stop("Missing successful render evidence: ", keys[[i]])
    numeric <- file.path(path, "numeric")
    files <- sort(list.files(numeric, "\\.rds$"))
    if (any(!grepl("^[A-Za-z0-9_]+-[0-9]{3}\\.rds$", files))) stop("Invalid numeric capture filename")
    domains <- sub("-[0-9]+\\.rds$", "", files)
    if (!all(book_benchmark_required() %in% domains)) stop("Missing numeric domains: ", keys[[i]])
    for (domain in unique(domains)) {
      actual <- files[domains == domain]
      if (!identical(actual, sprintf("%s-%03d.rds", domain, seq_along(actual)))) stop("Numeric capture sequence gap")
    }
    if (is.null(coverage)) coverage <- files
    if (!identical(coverage, files)) stop("Numeric capture coverage mismatch")
    records <- book_load_correlation_captures(numeric)
    for (j in seq_along(records)) {
      record <- records[[j]]
      if (!identical(record$schema, 1L) || !identical(record$namespace, book_benchmark_namespaces[[j]]) ||
          !is.data.frame(record$observations) || !is.data.frame(record$output) ||
          !all(c("series_id", "date", "value") %in% names(record$observations))) stop("Correlation capture schema/namespace mismatch")
    }
  }
  if (length(unique(vapply(configurations, `[[`, character(1), "snapshots"))) != 1L) stop("Run snapshot paths differ")
  for (version in c("baseline", "optimized")) {
    configs <- configurations[paste0(version, "-", 0:3)]
    for (field in c("root", "derived")) {
      if (length(unique(vapply(configs, `[[`, character(1), field))) != 1L) stop("Run scratch/cache configuration differs")
    }
  }
  list(results = results, as_of = as_of, provenance = provenance,
       proof_key = book_evidence_key(directory, provenance))
}

book_benchmark_verify <- function(directory, snapshots, provenance, output) {
  evidence <- book_validate_evidence(directory, snapshots, provenance)
  source("scripts/analysis/correlations.R", local = TRUE)
  differences <- historical <- character()
  reference <- file.path(directory, "baseline-1/numeric")
  for (version in c("baseline", "optimized")) for (run in 0:3) {
    current <- file.path(directory, paste0(version, "-", run), "numeric")
    own <- file.path(directory, paste0(version, "-1"), "numeric")
    differences <- c(differences, book_compare_numeric(reference, current),
                     book_compare_numeric(own, current, correlations = TRUE))
    book_compare_correlation_captures(own, current)
    if (version == "optimized") historical <- c(historical,
      book_compare_numeric(reference, current, correlations = TRUE))
  }
  dir.create(output, recursive = TRUE, showWarnings = FALSE)
  writeLines(if (length(differences)) unique(differences) else "All full numeric captures match (tolerance 1e-8).",
             file.path(output, "numeric-comparison.txt"))
  writeLines(if (length(historical)) unique(historical) else "Correlations match.",
             file.path(output, "historical-correlation-differences.txt"))
  if (length(differences)) stop("Numeric analysis differs; see numeric-comparison.txt")
  proof <- list(schema = 1L, proof_key = evidence$proof_key,
                model_results_equal = TRUE, correlation_parity_runs = 8L,
                historical_correlation_differences = length(unique(historical)))
  saveRDS(proof, file.path(output, "parity.rds"))
  invisible(proof)
}

book_benchmark_audit <- function(directory, snapshots, provenance, output, namespace) {
  if (length(namespace) != 1L || !namespace %in% book_benchmark_namespaces) stop("Unapproved audit namespace")
  evidence <- book_validate_evidence(directory, snapshots, provenance)
  source("scripts/analysis/correlations.R", local = TRUE)
  records <- lapply(c("baseline", "optimized"), function(version) {
    book_load_correlation_captures(file.path(directory, paste0(version, "-1/numeric")))
  })
  index <- match(namespace, book_benchmark_namespaces)
  cat("Starting full independent oracle:", namespace, "\n")
  report <- book_audit_correlation_record(records[[1L]][[index]], records[[2L]][[index]], tolerance = 1e-8)
  proof <- list(schema = 1L, proof_key = evidence$proof_key, namespace = namespace,
                source_sha = evidence$provenance$source_sha, image = evidence$provenance$image,
                report = report)
  dir.create(output, recursive = TRUE, showWarnings = FALSE)
  utils::write.csv(report, file.path(output, paste0(namespace, ".csv")), row.names = FALSE)
  saveRDS(proof, file.path(output, paste0(namespace, ".rds")))
  cat("Full independent oracle passed:", namespace, "\n")
  invisible(proof)
}

book_benchmark_aggregate <- function(directory, snapshots, provenance, output, proofs) {
  evidence <- book_validate_evidence(directory, snapshots, provenance)
  parity <- readRDS(file.path(proofs, "parity.rds"))
  if (!identical(parity$schema, 1L) || !identical(parity$proof_key, evidence$proof_key) ||
      !identical(parity$model_results_equal, TRUE) || !identical(parity$correlation_parity_runs, 8L) ||
      !is.integer(parity$historical_correlation_differences) ||
      length(parity$historical_correlation_differences) != 1L ||
      is.na(parity$historical_correlation_differences) ||
      parity$historical_correlation_differences < 0L) stop("Incomplete/mismatched numeric parity proof")
  reports <- lapply(book_benchmark_namespaces, function(namespace) {
    proof <- readRDS(file.path(proofs, paste0(namespace, ".rds")))
    report <- proof$report
    if (!identical(proof$schema, 1L) || !identical(proof$proof_key, evidence$proof_key) ||
        !identical(proof$namespace, namespace) ||
        !identical(proof$source_sha, evidence$provenance$source_sha) ||
        !identical(proof$image, evidence$provenance$image) ||
        !is.data.frame(report) || nrow(report) != 1L ||
        !identical(names(report), c("namespace", "pairs", "rows", "removed_exact_etf_rows", "max_coefficient_error", "tolerance")) ||
        !identical(report$namespace, namespace) || anyNA(report) ||
        report$tolerance != 1e-8 || !is.finite(report$max_coefficient_error) ||
        report$max_coefficient_error < 0 || report$max_coefficient_error > 1e-8 ||
        report$pairs < 1 || report$rows < report$pairs || report$removed_exact_etf_rows < 0) stop("Incomplete/mismatched independent audit proof: ", namespace)
    record <- readRDS(file.path(directory, "optimized-1/numeric/correlations", paste0(namespace, ".rds")))
    baseline <- readRDS(file.path(directory, "baseline-1/numeric/correlations", paste0(namespace, ".rds")))
    if (report$rows != nrow(record$output) || report$pairs != nrow(unique(record$output[c("x1", "x2")])) ||
        report$removed_exact_etf_rows != nrow(baseline$observations) - nrow(record$observations)) stop("Audit report coverage mismatch")
    report
  })
  results <- evidence$results
  medians <- tapply(results$elapsed_seconds[!results$warmup], results$version[!results$warmup], median)
  reduction <- 1 - medians[["optimized"]] / medians[["baseline"]]
  rss <- book_benchmark_rss(results)
  summary <- cbind(data.frame(baseline_median_seconds = medians[["baseline"]],
    optimized_median_seconds = medians[["optimized"]], reduction = reduction), rss,
    data.frame(model_results_equal = TRUE, correlations_audited = TRUE,
      historical_correlation_differences = parity$historical_correlation_differences,
      runtime_target_met = is.finite(reduction) && reduction >= 0.30,
      target_met = is.finite(reduction) && reduction >= 0.30 && isTRUE(rss$rss_target_met)))
  dir.create(output, recursive = TRUE, showWarnings = FALSE)
  utils::write.csv(do.call(rbind, reports), file.path(output, "correlation-audit.csv"), row.names = FALSE)
  utils::write.csv(summary, file.path(output, "summary.csv"), row.names = FALSE)
  if (!isTRUE(summary$target_met)) stop("Benchmark runtime/RSS acceptance gate failed; see summary.csv")
  invisible(summary)
}

benchmark_book <- function(baseline, optimized, snapshots,
                           artifacts = ".cache/book-benchmark", as_of = NULL,
                           render_only = FALSE, provenance = NULL) {
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
  if (!is.null(provenance)) {
    book_read_provenance(provenance)
    if (!file.copy(provenance, file.path(artifacts, "provenance.dcf"))) stop("Cannot record provenance")
  }
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
  if (render_only) return(invisible(results))
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
  if (length(args) && args[[1L]] %in% c("render-only", "verify", "audit", "aggregate")) {
    phase <- args[[1L]]
    args <- args[-1L]
    expected <- switch(phase, "render-only" = 5L, verify = 4L, audit = 5L, aggregate = 5L)
    if (length(args) != expected) stop("Invalid argument count for benchmark phase: ", phase)
    switch(phase,
      "render-only" = benchmark_book(args[[1L]], args[[2L]], args[[3L]], args[[4L]],
                                    render_only = TRUE, provenance = args[[5L]]),
      verify = book_benchmark_verify(args[[1L]], args[[2L]], args[[3L]], args[[4L]]),
      audit = book_benchmark_audit(args[[1L]], args[[2L]], args[[3L]], args[[4L]], args[[5L]]),
      aggregate = book_benchmark_aggregate(args[[1L]], args[[2L]], args[[3L]], args[[4L]], args[[5L]]))
  } else {
    if (length(args) < 3L || length(args) > 4L) {
    stop("Usage: benchmark_book.R BASELINE OPTIMIZED SNAPSHOTS [ARTIFACT_DIR]")
    }
    benchmark_book(args[[1L]], args[[2L]], args[[3L]],
                   if (length(args) == 4L) args[[4L]] else ".cache/book-benchmark")
  }
}
