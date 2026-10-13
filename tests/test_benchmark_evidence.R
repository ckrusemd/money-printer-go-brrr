# Full staged verification with tiny inputs and the REAL independent CCF oracle.
source("scripts/benchmark_book.R")
source("scripts/analysis/correlations.R")

local({
  root <- tempfile("benchmark-evidence-tests-")
  dir.create(root)
  on.exit(unlink(root, recursive = TRUE), add = TRUE)
  receipt <- c(schema = "1", repository = "ckrusemd/money-printer-go-brrr",
    source_sha = paste(rep("a", 40), collapse = ""), baseline_sha = paste(rep("b", 40), collapse = ""),
    image = paste0("ghcr.io/ckrusemd/money-printer-go-brrr-r@sha256:", paste(rep("c", 64), collapse = "")),
    snapshot_run_id = "12", benchmark_run_id = "34", mode = "fresh",
    snapshot_artifact_id = "56", snapshot_artifact_digest = paste0("sha256:", paste(rep("d", 64), collapse = "")))
  write_receipt <- function(value, path) write.dcf(matrix(value, nrow = 1L, dimnames = list(NULL, names(value))), path, width = 1000)
  observations <- do.call(rbind, lapply(c("ETF", "A", "B", "flat"), function(id) {
    value <- switch(id, ETF = sin(1:12), A = cos(1:12), B = (1:12)^2, flat = rep(1, 12))
    data.frame(series_id = id, date = as.Date("2000-01-01") + 1:12, value = value)
  }))
  raw <- rbind(observations, observations[observations$series_id == "ETF", ])
  records <- lapply(c("baseline", "optimized"), function(version) {
    input <- if (version == "baseline") raw else observations
    lapply(book_benchmark_namespaces, function(namespace) list(schema = 1L, namespace = namespace,
      observations = input, etf_ids = "ETF", output = book_correlation_original(input, namespace,
        retain_undefined = version != "baseline")))
  })
  make_fixture <- function() {
    case <- tempfile("case-", root)
    dir.create(case)
    evidence <- file.path(case, "evidence")
    snapshots <- file.path(case, "snapshots")
    dir.create(evidence)
    dir.create(snapshots)
    provenance <- file.path(case, "provenance.dcf")
    write_receipt(receipt, provenance)
    file.copy(provenance, file.path(evidence, "provenance.dcf"))
    writeLines("2026-10-11", file.path(snapshots, "as-of.txt"))
    saveRDS(list(schema_version = 1L, as_of = as.Date("2026-10-11"), requests = list(), failures = list()),
            file.path(snapshots, "manifest.rds"))
    saveRDS(list(value = 1), file.path(snapshots, "fixture.rds"))
    saveRDS(tools::md5sum(list.files(snapshots, full.names = TRUE)), file.path(evidence, "snapshot-hashes.rds"))
    writeLines("2026-10-11", file.path(evidence, "as-of.txt"))
    results <- expand.grid(version = c("baseline", "optimized"), run = 0:3, stringsAsFactors = FALSE)
    results$warmup <- results$run == 0L
    results$elapsed_seconds <- ifelse(results$version == "baseline", 100, 60)
    results$max_rss_kb <- ifelse(results$version == "baseline", 100, 90)
    # Cold measurements must not influence the warm acceptance statistics.
    results$elapsed_seconds[results$warmup] <- c(5, 500)
    results$max_rss_kb[results$warmup] <- c(5, 500)
    results$exit_status <- 0L
    for (i in seq_len(nrow(results))) {
      version <- results$version[[i]]
      path <- file.path(evidence, paste0(version, "-", results$run[[i]]))
      numeric <- file.path(path, "numeric")
      dir.create(file.path(numeric, "correlations"), recursive = TRUE)
      saveRDS(list(version = version, as_of = "2026-10-11", snapshots = "/project/snapshots",
        root = paste0("/scratch/", version), derived = paste0("/scratch/", version, "/.cache/book-derived")),
        file.path(path, "config.rds"))
      writeLines(paste(results$elapsed_seconds[[i]], results$max_rss_kb[[i]], sep = ","), file.path(path, "time.csv"))
      writeLines("Bookdown output checked: 13 pages and local dependencies", file.path(path, "render.log"))
      writeLines("R version 4.3.3", file.path(path, "session-info.txt"))
      writeLines("time,kind,namespace,key,seconds,bytes,status", file.path(path, "book-metrics.csv"))
      for (domain in setdiff(book_benchmark_required(), "df_ccfs")) {
        saveRDS(data.frame(prediction = c(1, 2, 3)), file.path(numeric, paste0(domain, "-001.rds")))
      }
      for (j in seq_along(book_benchmark_namespaces)) {
        record <- records[[match(version, c("baseline", "optimized"))]][[j]]
        saveRDS(record, file.path(numeric, "correlations", paste0(record$namespace, ".rds")))
        saveRDS(record$output, file.path(numeric, sprintf("df_ccfs-%03d.rds", j)))
      }
    }
    utils::write.csv(results, file.path(evidence, "runs.csv"), row.names = FALSE)
    list(evidence = evidence, snapshots = snapshots, provenance = provenance,
         proofs = file.path(case, "proofs"), output = file.path(case, "summary"))
  }
  validate <- function(case) book_validate_evidence(case$evidence, case$snapshots, case$provenance)
  verify <- function(case) book_benchmark_verify(case$evidence, case$snapshots, case$provenance, case$proofs)
  audit <- function(case, namespace) book_benchmark_audit(case$evidence, case$snapshots,
    case$provenance, case$proofs, namespace)
  aggregate <- function(case) book_benchmark_aggregate(case$evidence, case$snapshots,
    case$provenance, case$output, case$proofs)
  expect_error <- function(code) {
    error <- tryCatch({ force(code); NULL }, error = identity)
    stopifnot(inherits(error, "error"))
  }
  runs_mutation <- function(mutate) {
    case <- make_fixture()
    path <- file.path(case$evidence, "runs.csv")
    results <- read.csv(path, stringsAsFactors = FALSE)
    write.csv(mutate(results), path, row.names = FALSE)
    expect_error(validate(case))
  }
  runs_mutation(function(x) x[-8L, ])
  runs_mutation(function(x) { x[8L, ] <- x[7L, ]; x })
  runs_mutation(function(x) { x$run[8L] <- 4L; x })
  runs_mutation(function(x) { x$exit_status[8L] <- 1L; x })
  runs_mutation(function(x) { x$warmup[8L] <- TRUE; x })
  for (invalid in c(0, -1, Inf, -Inf, NA_real_, NaN)) {
    runs_mutation(function(x) { x$elapsed_seconds[8L] <- invalid; x })
    runs_mutation(function(x) { x$max_rss_kb[8L] <- invalid; x })
  }
  for (relative in c("optimized-3/time.csv", "optimized-3/session-info.txt",
                    "optimized-3/numeric/model_predictions_DK_Long_on_DK_Short-001.rds",
                    "optimized-3/numeric/correlations/indicators-correlations.rds")) {
    case <- make_fixture()
    unlink(file.path(case$evidence, relative))
    expect_error(validate(case))
  }
  case <- make_fixture()
  writeLines("60,91", file.path(case$evidence, "optimized-3/time.csv"))
  expect_error(validate(case))
  case <- make_fixture()
  writeLines("2026-10-10", file.path(case$evidence, "as-of.txt"))
  expect_error(validate(case))
  case <- make_fixture()
  saveRDS(list(value = 2), file.path(case$snapshots, "fixture.rds"))
  expect_error(validate(case))
  for (field in c("schema", "namespace")) {
    case <- make_fixture()
    path <- file.path(case$evidence, "optimized-3/numeric/correlations/indicators-correlations.rds")
    record <- readRDS(path)
    record[[field]] <- if (field == "schema") 2L else "unapproved"
    saveRDS(record, path)
    expect_error(validate(case))
  }
  for (field in c("source_sha", "image")) {
    case <- make_fixture()
    altered <- receipt
    altered[[field]] <- if (field == "source_sha") paste(rep("e", 40), collapse = "") else
      paste0("ghcr.io/ckrusemd/money-printer-go-brrr-r@sha256:", paste(rep("e", 64), collapse = ""))
    write_receipt(altered, case$provenance)
    expect_error(validate(case))
  }
  case <- make_fixture()
  unlink(file.path(case$evidence, "provenance.dcf"))
  expect_error(validate(case))
  archive_fixture <- function(case) {
    archive <- file.path(dirname(case$provenance), "evidence.zip")
    previous <- setwd(case$evidence)
    on.exit(setwd(previous), add = TRUE)
    utils::zip(archive, list.files(recursive = TRUE, all.files = TRUE, no.. = TRUE), flags = "-q")
    authenticated <- c(receipt, archive_path = basename(archive),
      archive_digest = paste0("sha256:", digest::digest(file = archive, algo = "sha256")))
    write_receipt(authenticated, case$provenance)
    archive
  }
  archived <- make_fixture()
  archive <- archive_fixture(archived)
  key <- validate(archived)$proof_key
  relocated <- file.path(dirname(archived$provenance), "relocated")
  dir.create(relocated)
  stopifnot(file.copy(c(archived$provenance, archive), relocated))
  stopifnot(identical(key, book_validate_evidence(archived$evidence, archived$snapshots,
    file.path(relocated, basename(archived$provenance)))$proof_key))
  writeLines("extra", file.path(archived$evidence, "unexpected.txt"))
  expect_error(validate(archived))
  unlink(file.path(archived$evidence, "unexpected.txt"))
  writeLines("altered", file.path(archived$evidence, "baseline-0/session-info.txt"))
  expect_error(validate(archived))
  archived <- make_fixture()
  archive <- archive_fixture(archived)
  writeLines("not the authenticated archive", archive)
  expect_error(validate(archived))
  case <- make_fixture()
  saveRDS(data.frame(prediction = c(1, 2, 3 + 1e-6)),
    file.path(case$evidence, "optimized-3/numeric/model_predictions_DFF-001.rds"))
  expect_error(verify(case))
  case <- make_fixture()
  path <- file.path(case$evidence, "optimized-3/numeric/correlations/indicators-correlations.rds")
  record <- readRDS(path)
  record$observations$value[1L] <- 999
  saveRDS(record, path)
  expect_error(verify(case))

  # Complete path: actual independent original/raw/clean audits, full undefined
  # pair coverage, exact ETF-only correction and authenticated aggregation.
  good <- make_fixture()
  stopifnot(length(book_benchmark_required()) == 22L, nrow(validate(good)$results) == 8L)
  verify(good)
  audit(good, "indicators-correlations")
  expect_error(aggregate(good))  # missing second namespace never accepted
  audit(good, "etf-correlations")
  summary <- aggregate(good)
  stopifnot(summary$target_met, summary$correlations_audited, summary$reduction == 0.4,
            summary$rss_peak_target_met, summary$rss_median_target_met,
            file.exists(file.path(good$output, "correlation-audit.csv")))
  parity_path <- file.path(good$proofs, "parity.rds")
  parity <- readRDS(parity_path)
  for (field in c("schema", "proof_key", "model_results_equal", "correlation_parity_runs",
                  "historical_correlation_differences")) {
    bad <- parity
    bad[[field]] <- switch(field, schema = 2L, proof_key = "wrong", model_results_equal = FALSE,
                          correlation_parity_runs = 7L, historical_correlation_differences = NULL)
    saveRDS(bad, parity_path)
    expect_error(aggregate(good))
  }
  saveRDS(parity, parity_path)
  proof_path <- file.path(good$proofs, "etf-correlations.rds")
  proof <- readRDS(proof_path)
  for (field in c("schema", "proof_key", "source_sha", "image", "namespace")) {
    bad <- proof
    bad[[field]] <- if (field == "schema") 2L else "wrong"
    saveRDS(bad, proof_path)
    expect_error(aggregate(good))
  }
  for (field in c("pairs", "rows", "max_coefficient_error", "tolerance")) {
    bad <- proof
    bad$report[[field]] <- if (field == "max_coefficient_error") Inf else bad$report[[field]] + 1
    saveRDS(bad, proof_path)
    expect_error(aggregate(good))
  }
  saveRDS(proof, proof_path)
  # Successful proofs become invalid after any evidence change.
  writeLines("changed session", file.path(good$evidence, "optimized-3/session-info.txt"))
  expect_error(aggregate(good))
  # Approved max-RSS outlier case: median passes, maximum fails.
  memory <- make_fixture()
  path <- file.path(memory$evidence, "runs.csv")
  measurements <- read.csv(path, stringsAsFactors = FALSE)
  measurements$max_rss_kb[measurements$version == "optimized" & measurements$run == 3L] <- 150
  write.csv(measurements, path, row.names = FALSE)
  writeLines("60,150", file.path(memory$evidence, "optimized-3/time.csv"))
  verify(memory)
  for (namespace in book_benchmark_namespaces) audit(memory, namespace)
  expect_error(aggregate(memory))
  failed <- read.csv(file.path(memory$output, "summary.csv"))
  stopifnot(failed$rss_median_target_met, !failed$rss_peak_target_met, !failed$target_met)
  for (seconds in c(70, 71)) {
    runtime <- make_fixture()
    path <- file.path(runtime$evidence, "runs.csv")
    measurements <- read.csv(path, stringsAsFactors = FALSE)
    warm_optimized <- measurements$version == "optimized" & !measurements$warmup
    measurements$elapsed_seconds[warm_optimized] <- seconds
    write.csv(measurements, path, row.names = FALSE)
    for (run in 1:3) writeLines(paste0(seconds, ",90"),
      file.path(runtime$evidence, paste0("optimized-", run), "time.csv"))
    verify(runtime)
    for (namespace in book_benchmark_namespaces) audit(runtime, namespace)
    if (seconds == 70) stopifnot(aggregate(runtime)$target_met) else {
      expect_error(aggregate(runtime))
      failed <- read.csv(file.path(runtime$output, "summary.csv"))
      stopifnot(!failed$runtime_target_met, failed$rss_target_met, !failed$target_met)
    }
  }
  cat("PASS: strict eight-run evidence, provenance, all model domains, both independent namespace audits and aggregation\n")
})
