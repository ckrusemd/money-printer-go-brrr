# One runtime per render. Source repeatedly without discarding observations.
if (!exists(".book_runtime", envir = .GlobalEnv, inherits = FALSE)) {
  .book_runtime <- new.env(parent = emptyenv())
  .book_runtime$observations <- new.env(parent = emptyenv())
  .book_runtime$manifest <- list()
  .book_runtime$failures <- list()
  .book_runtime$memory_order <- character()
  .book_runtime$result_hashes <- list()
  .book_runtime$result_counts <- list()
  .book_runtime$mode <- Sys.getenv("BOOK_SNAPSHOT_MODE", "live")
  stopifnot(.book_runtime$mode %in% c("live", "record", "replay"))
  .book_runtime$snapshots <- Sys.getenv("BOOK_SNAPSHOT_DIR", ".cache/book-inputs")
  .book_runtime$derived <- Sys.getenv("BOOK_DERIVED_DIR", ".cache/book-derived")
  .book_runtime$metrics <- Sys.getenv("BOOK_METRICS_FILE", ".cache/book-metrics.csv")
  as_of <- Sys.getenv("BOOK_AS_OF", "")
  manifest_path <- file.path(.book_runtime$snapshots, "manifest.rds")
  if (!nzchar(as_of) && .book_runtime$mode == "replay" && file.exists(manifest_path)) {
    as_of <- as.character(readRDS(manifest_path)$as_of)
  }
  if (!nzchar(as_of)) as_of <- as.character(as.Date(Sys.time(), tz = "Europe/Copenhagen"))
  .book_runtime$as_of <- as.Date(as_of)
  if (is.na(.book_runtime$as_of)) stop("BOOK_AS_OF must be an ISO date")
  # Independent chapter kernels share only responses from this invocation.
  run_id <- Sys.getenv("BOOK_RUN_ID", "")
  .book_runtime$run_id <- run_id
  if (.book_runtime$mode == "record" && nzchar(run_id) && file.exists(manifest_path)) {
    previous <- readRDS(manifest_path)
    if (!identical(previous$run_id, run_id) || !identical(previous$as_of, .book_runtime$as_of)) {
      stop("Refusing source responses from a different notebook build")
    }
    .book_runtime$manifest <- previous$requests
    .book_runtime$failures <- previous$failures
  }
  options(timeout = 30)
}

book_date <- function() .book_runtime$as_of

# All observed Finans Danmark year/week keys agree with the ISO calendar
# (including week 53); its publication page specifies weekly rates, not an
# explicit ISO schema. Preserve the chapters' Monday observation convention.
# %U is Sunday-based and yields shifted dates or NA for these ISO week keys.
book_iso_week_monday <- function(year, week) {
  year <- suppressWarnings(as.numeric(as.character(year)))
  week <- suppressWarnings(as.numeric(as.character(week)))
  if (length(year) != length(week) || anyNA(year) || anyNA(week) ||
      any(!is.finite(year)) || any(!is.finite(week)) ||
      any(year != floor(year) | year < 1 | year > 9999) ||
      any(week != floor(week) | week < 1 | week > 53)) {
    stop("Finans Danmark requires valid integer ISO years and weeks", call. = FALSE)
  }
  if (!length(year)) return(as.Date(character()))
  january_four <- as.Date(sprintf("%04d-01-04", as.integer(year)))
  monday <- january_four - (as.integer(format(january_four, "%u")) - 1L) + (week - 1L) * 7L
  valid <- as.integer(format(monday, "%G")) == year & as.integer(format(monday, "%V")) == week
  if (anyNA(monday) || anyNA(valid) || !all(valid)) {
    stop("Finans Danmark has an invalid ISO week for its year", call. = FALSE)
  }
  monday
}

book_hash <- function(value) {
  if (!requireNamespace("digest", quietly = TRUE)) stop("Missing locked dependency: digest")
  digest::digest(value, algo = "sha256", serialize = TRUE)
}

book_metric <- function(kind, namespace, key, seconds = 0, bytes = 0, status = "ok") {
  path <- .book_runtime$metrics
  dir.create(dirname(path), recursive = TRUE, showWarnings = FALSE)
  row <- data.frame(time = format(Sys.time(), tz = "UTC", usetz = TRUE),
                    kind = kind, namespace = namespace, key = key,
                    seconds = seconds, bytes = bytes, status = status)
  utils::write.table(row, path, sep = ",", row.names = FALSE,
                     col.names = !file.exists(path), append = file.exists(path))
  invisible(row)
}

book_save_rds <- function(value, path) {
  dir.create(dirname(path), recursive = TRUE, showWarnings = FALSE)
  temporary <- tempfile("book-", tmpdir = dirname(path))
  on.exit(unlink(temporary))
  saveRDS(value, temporary, compress = FALSE)
  if (!file.rename(temporary, path)) stop("Cannot save cache: ", path)
  invisible(path)
}

book_latest_observation <- function(value) {
  dates <- if (inherits(value,"dst_bundle")) {
    as.character(value$data$period_start)
  } else if (is.data.frame(value)) {
    field <- intersect(c("date", "Date", "TID", "timestamp", "obstime"), names(value))
    if (length(field)) as.character(value[[field[1L]]]) else character()
  } else if (inherits(value, "xts")) {
    as.character(zoo::index(value))
  } else character()
  dates <- dates[!is.na(dates)]
  if (length(dates)) max(dates) else NA_character_
}

book_redact_text <- function(text) {
  text <- gsub("(https?://)[^/@[:space:]]+@", "\\1[redacted]@", text, perl = TRUE)
  gsub("([?&](?:api[_-]?key|access[_-]?token|token|secret|password|authorization)=)[^&#[:space:]]*",
       "\\1[redacted]", text, perl = TRUE, ignore.case = TRUE)
}

book_redact_parameters <- function(parameters) {
  if (!is.list(parameters)) {
    if (is.character(parameters)) return(book_redact_text(parameters))
    return(parameters)
  }
  result <- parameters
  for (i in seq_along(result)) {
    name <- names(parameters)[i]
    if (!is.null(name) && !is.na(name) &&
        grepl("api.?key|token|secret|password|authorization|credential", name, ignore.case = TRUE)) {
      result[i] <- list("[redacted]")
    } else result[i] <- list(book_redact_parameters(result[[i]]))
  }
  result
}

book_replay_manifest <- function() {
  manifest <- .book_runtime$replay_manifest
  if (is.null(manifest)) {
    path <- file.path(.book_runtime$snapshots, "manifest.rds")
    if (!file.exists(path)) stop("Replay requires a completed input manifest")
    manifest <- readRDS(path)
    if (!is.list(manifest) || !identical(manifest$schema_version, 1L) ||
        !is.list(manifest$requests) || !identical(manifest$as_of, book_date())) {
      stop("Invalid snapshot manifest or analytical date mismatch")
    }
    .book_runtime$replay_manifest <- manifest
  }
  manifest
}

book_fetch <- function(provider, parameters, fetcher, attempts = 3L) {
  stopifnot(is.function(fetcher), attempts >= 1L, attempts <= 4L)
  key <- book_hash(list(provider = provider, parameters = parameters))
  safe_parameters <- book_redact_parameters(parameters)
  if (.book_runtime$mode == "replay") {
    manifest <- book_replay_manifest()
    if (!key %in% names(manifest$requests)) {
      failure <- manifest$failures[[key]]
      if (!is.null(failure)) .book_runtime$failures[[key]] <- failure
      stop("Request absent from successful snapshot manifest: ", provider, ": ", key)
    }
  }
  if (exists(key, .book_runtime$observations, inherits = FALSE)) {
    .book_runtime$memory_order <- c(setdiff(.book_runtime$memory_order, key), key)
    book_metric("request", provider, key, status = "memory-hit")
    return(get(key, .book_runtime$observations, inherits = FALSE))
  }
  path <- file.path(.book_runtime$snapshots, paste0(key, ".rds"))
  start <- proc.time()[["elapsed"]]
  if (.book_runtime$mode == "replay" ||
      (.book_runtime$mode == "record" && key %in% names(.book_runtime$manifest))) {
    if (!file.exists(path)) stop("Missing snapshot for ", provider, ": ", key)
    record <- readRDS(path)
    if (!is.list(record) || !identical(record$schema_version, 1L) ||
        !identical(record$provider, provider) || !identical(record$parameters, safe_parameters) ||
        is.null(record$value) || ((is.data.frame(record$value) || is.matrix(record$value)) && !nrow(record$value))) {
      stop("Snapshot request mismatch: ", key)
    }
    value <- record$value
    status <- "snapshot-hit"
  } else {
    failure <- NULL
    for (attempt in seq_len(attempts)) {
      result <- tryCatch(list(value = fetcher()), error = function(e) e)
      if (!inherits(result, "error")) break
      failure <- result
      if (attempt < attempts) Sys.sleep(min(2 ^ (attempt - 1L), 4L))
    }
    if (inherits(result, "error")) {
      .book_runtime$failures[[key]] <- list(provider = provider, parameters = safe_parameters,
                                           message = book_redact_text(conditionMessage(failure)))
      book_write_manifest()
      book_metric("request", provider, key, proc.time()[["elapsed"]] - start, status = "failed")
      stop("Current data unavailable from ", provider, ": ", conditionMessage(failure))
    }
    value <- result$value
    if (is.null(value) || ((is.data.frame(value) || is.matrix(value)) && !nrow(value))) {
      .book_runtime$failures[[key]] <- list(provider = provider, parameters = safe_parameters,
                                           message = "Empty current data")
      book_write_manifest()
      book_metric("request", provider, key, proc.time()[["elapsed"]] - start, status = "failed")
      stop("Empty current data from ", provider)
    }
    record <- list(schema_version = 1L, provider = provider, parameters = safe_parameters,
                   retrieved_at = format(Sys.time(), tz = "UTC", usetz = TRUE),
                   latest_observation = book_latest_observation(value), value = value)
    if (.book_runtime$mode == "record") book_save_rds(record, path)
    status <- "fetched"
    .book_runtime$failures[[key]] <- NULL
  }
  assign(key, value, .book_runtime$observations)
  .book_runtime$memory_order <- c(setdiff(.book_runtime$memory_order, key), key)
  repeat {
    keys <- ls(.book_runtime$observations)
    bytes <- sum(vapply(keys, function(k) as.numeric(object.size(get(k, .book_runtime$observations))), numeric(1)))
    if (bytes <= 256 * 1024 ^ 2 || !length(.book_runtime$memory_order)) break
    oldest <- .book_runtime$memory_order[1L]
    rm(list = oldest, envir = .book_runtime$observations)
    .book_runtime$memory_order <- .book_runtime$memory_order[-1L]
  }
  .book_runtime$manifest[[key]] <- record[c("provider", "parameters", "retrieved_at", "latest_observation")]
  book_write_manifest()
  book_metric("request", provider, key, proc.time()[["elapsed"]] - start,
              as.numeric(object.size(value)), status)
  value
}

book_fred <- function(series_id, ...) {
  parameters <- c(list(series_id = series_id), list(...))
  book_fetch("FRED observations", parameters, function() {
    httr::with_config(httr::timeout(30), do.call(fredr::fredr, parameters))
  })
}

book_fred_metadata <- function(endpoint, ...) {
  stopifnot(endpoint %in% c("fredr_tags_series", "fredr_series"))
  parameters <- list(...)
  if (length(parameters) && (is.null(names(parameters)) || !nzchar(names(parameters)[1L]))) {
    names(parameters)[1L] <- if (endpoint == "fredr_series") "series_id" else "tag_names"
  }
  book_fetch(paste("FRED", endpoint), parameters, function() {
    httr::with_config(httr::timeout(30), do.call(getExportedValue("fredr", endpoint), parameters))
  })
}

book_ecb_data <- function(key, filter = NULL, ..., attempts = 4L) {
  parameters <- c(list(key = as.character(key), filter = filter), list(...))
  book_fetch("ECB observations", parameters, function() {
    httr::with_config(httr::timeout(30), do.call(ecb::get_data, parameters))
  }, attempts = attempts)
}

book_yahoo <- function(ticker, ..., env = NULL, attempts = 3L) {
  if (!is.null(env)) stop("book_yahoo returns prices directly; env must be NULL")
  parameters <- c(list(Symbols = ticker, env = NULL, src = "yahoo"), list(...))
  book_fetch("Yahoo Finance", parameters, function() {
    quantmod::getSymbols(Symbols = ticker, env = NULL, src = "yahoo", ...)
  }, attempts = attempts)
}

book_dst_bundle <- function(table, query, lang="da") {
  parameters <- list(table=table, query=query, lang=lang, model="dstcollect-1")
  book_fetch("Statistics Denmark", parameters, function() {
    meta <- dstcollect::dst_metadata(table,lang=lang)
    # Compatibility boundary only: resolve old exact labels to stable codes.
    for (id in names(query)) {
      categories <- meta$categories[toupper(meta$categories$dimension_id)==toupper(id),]
      query[[id]] <- vapply(as.character(query[[id]]),function(value) {
        if (value %in% categories$category_code || value=="*") return(value)
        matches <- categories$category_code[categories$label==value |
          paste(categories$category_code,categories$label)==value]
        if (length(matches)!=1L) stop("Unknown or ambiguous legacy DST selection: ",id,"=",value)
        matches[[1L]]
      },character(1))
    }
    dstcollect::dst_collect(table,selection=query,lang=lang,metadata=meta)
  })
}

book_dst <- function(table, ..., lang="da", presentation=c("legacy","labels")) {
  presentation <- match.arg(presentation); query <- list(...)
  bundle <- book_dst_bundle(table,query,lang)
  out <- dstcollect::dst_legacy_data(bundle,names(query),code_labels=presentation=="legacy")
  attr(out,"series_id") <- NULL
  out
}

book_dst_metadata <- function(...) {
  parameters <- list(...)
  parameters$model <- "dstcollect-1"
  bundle <- book_fetch("Statistics Denmark metadata", parameters, function() {
    dstcollect::dst_metadata(parameters$table,lang=parameters$lang %or_dst% "da")
  })
  dstcollect::dst_legacy_metadata(bundle)
}

`%or_dst%` <- function(x,y) if (is.null(x)) y else x

book_workbook <- function(url, ...) {
  parameters <- c(list(url = url), list(...))
  book_fetch("Finans Danmark workbook", parameters, function() {
    file <- tempfile(fileext = ".xlsx")
    on.exit(unlink(file))
    response <- httr::GET(url, httr::timeout(30), httr::write_disk(file, overwrite = TRUE))
    httr::stop_for_status(response)
    do.call(openxlsx::read.xlsx, c(list(xlsxFile = file), list(...)))
  })
}

book_finansdanmark_url <- function(url) {
  book_fetch("Finans Danmark link", list(url = url), function() {
    response <- httr::GET(url, httr::timeout(30))
    httr::stop_for_status(response)
    page <- xml2::read_html(httr::content(response, as = "raw"))
    hrefs <- rvest::html_attr(rvest::html_elements(page, "a[href$='.xlsx']"), "href")
    hrefs <- unique(hrefs[!is.na(hrefs) & nzchar(hrefs)])
    if (length(hrefs) != 1L) stop("Expected one mortgage-rate XLSX link")
    xml2::url_absolute(hrefs, url)
  })
}

book_prune_cache <- function(limit = 1024 ^ 3) {
  paths <- list.files(.book_runtime$derived, "\\.rds$", full.names = TRUE)
  if (!length(paths)) return(invisible(NULL))
  info <- file.info(paths)
  order <- order(info$mtime, decreasing = TRUE)
  used <- 0
  for (i in order) {
    if (is.na(info$size[i]) || info$size[i] > limit - used) unlink(paths[i])
    else used <- used + info$size[i]
  }
  invisible(NULL)
}

book_cache_derived <- function(namespace, inputs, compute, packages = character(), code = NULL) {
  stopifnot(is.function(compute))
  # Box-Muller keeps an extra normal variate outside .Random.seed. R does not
  # expose that state; recomputation preserves its continuation faithfully.
  if (RNGkind()[2L] == "Box-Muller" || any(grepl("user", RNGkind()))) return(compute())
  rng_before <- if (exists(".Random.seed", .GlobalEnv, inherits = FALSE)) get(".Random.seed", .GlobalEnv) else NULL
  versions <- setNames(lapply(packages, function(p) as.character(utils::packageVersion(p))), packages)
  key <- book_hash(list(schema = 1L, namespace = namespace, inputs = inputs,
                        code = if (is.null(code)) list(formals(compute), body(compute)) else code,
                        versions = versions, R = as.character(getRversion()), rng = rng_before,
                        rng_kind = RNGkind()))
  path <- file.path(.book_runtime$derived, paste0(key, ".rds"))
  cached <- if (file.exists(path)) tryCatch(readRDS(path), error = function(e) NULL) else NULL
  if (is.list(cached) && identical(cached$key, key)) {
    if (!is.null(cached$rng_kind_after)) do.call(RNGkind, as.list(cached$rng_kind_after))
    if (is.null(cached$rng_after)) {
      if (exists(".Random.seed", .GlobalEnv, inherits = FALSE)) rm(".Random.seed", envir = .GlobalEnv)
    } else assign(".Random.seed", cached$rng_after, .GlobalEnv)
    Sys.setFileTime(path, Sys.time())
    book_metric("derived", namespace, key, status = "cache-hit")
    return(cached$value)
  }
  start <- proc.time()[["elapsed"]]
  value <- compute()
  rng_after <- if (exists(".Random.seed", .GlobalEnv, inherits = FALSE)) get(".Random.seed", .GlobalEnv) else NULL
  if (RNGkind()[2L] != "Box-Muller" && !any(grepl("user", RNGkind()))) {
    book_save_rds(list(key = key, value = value, rng_after = rng_after,
                       rng_kind_after = RNGkind()), path)
  }
  book_metric("derived", namespace, key, proc.time()[["elapsed"]] - start,
              as.numeric(object.size(value)), "computed")
  book_prune_cache()
  value
}

book_load_packages <- function(...) {
  arguments <- as.list(substitute(list(...)))[-1L]
  packages <- unique(unlist(lapply(arguments, function(x) {
    if (is.symbol(x)) as.character(x) else eval(x, parent.frame())
  }), use.names = FALSE))
  missing <- packages[!vapply(packages, requireNamespace, logical(1), quietly = TRUE)]
  if (length(missing)) stop("Missing locked publication dependencies: ", paste(missing, collapse = ", "))
  for (package in packages) suppressPackageStartupMessages(library(package, character.only = TRUE))
  invisible(packages)
}

book_write_manifest <- function() {
  if (.book_runtime$mode == "record") {
    book_save_rds(list(schema_version = 1L, as_of = book_date(),
                       run_id = .book_runtime$run_id,
                       requests = .book_runtime$manifest, failures = .book_runtime$failures),
                   file.path(.book_runtime$snapshots, "manifest.rds"))
  }
  invisible(.book_runtime$manifest)
}

book_source_status <- function() {
  if (.book_runtime$mode == "replay") {
    manifest <- book_replay_manifest()
    .book_runtime$manifest <- manifest$requests
    .book_runtime$failures <- manifest$failures
  }
  describe <- function(parameters) {
    value <- parameters$series_id
    if (is.null(value)) value <- parameters$Symbols
    if (is.null(value)) value <- parameters$table
    if (is.null(value)) value <- parameters$url
    if (is.null(value)) value <- paste(vapply(seq_along(parameters), function(i) {
      name <- names(parameters)[i]
      if (is.null(name) || is.na(name) || !nzchar(name)) name <- as.character(i)
      paste0(name, "=", paste(parameters[[i]], collapse = ","))
    }, character(1)), collapse = "; ")
    paste(value, collapse = ", ")
  }
  available <- lapply(.book_runtime$manifest, function(record) {
    data.frame(Provider = record$provider, Request = describe(record$parameters),
               Retrieved = record$retrieved_at,
               `Latest observation` = record$latest_observation,
               Status = "Available", check.names = FALSE)
  })
  failed <- lapply(.book_runtime$failures, function(record) {
    data.frame(Provider = record$provider, Request = describe(record$parameters),
               Retrieved = NA_character_, `Latest observation` = NA_character_,
               Status = "Unavailable; excluded from this build", check.names = FALSE)
  })
  rows <- c(available, failed)
  if (!length(rows)) return(data.frame())
  result <- do.call(rbind, rows)
  rownames(result) <- NULL
  result[order(result$Provider, result$Request), ]
}

book_capture_results <- function(envir) {
  path <- Sys.getenv("BOOK_RESULTS_DIR", "")
  if (!nzchar(path)) return(invisible(NULL))
  variables <- c("df_ccfs", "rf_backtest", "rf_metrics", "rf_regime_metrics",
                 "rf_live_forecast", "dff_rf_has_skill")
  capture <- function(variable, value) {
    key <- book_hash(value)
    if (identical(.book_runtime$result_hashes[[variable]], key)) return(invisible(NULL))
    count <- .book_runtime$result_counts[[variable]]
    count <- if (is.null(count)) 1L else count + 1L
    book_save_rds(value, file.path(path, sprintf("%s-%03d.rds", variable, count)))
    .book_runtime$result_counts[[variable]] <- count
    .book_runtime$result_hashes[[variable]] <- key
  }
  for (variable in variables) {
    if (exists(variable, envir, inherits = FALSE)) {
      capture(variable, get(variable, envir, inherits = FALSE))
    }
  }

  # Discover the historical and optimized chapter's identical model/input
  # names, without serializing caret environments or changing chapter code.
  targets <- sub("^fit_", "", ls(envir, pattern = "^fit_"))
  targets <- targets[vapply(paste0("df_predict_", targets), exists, logical(1),
                            envir = envir, inherits = FALSE)]
  rng_kind <- RNGkind()
  had_seed <- exists(".Random.seed", .GlobalEnv, inherits = FALSE)
  seed <- if (had_seed) get(".Random.seed", .GlobalEnv) else NULL
  on.exit({
    if (!identical(RNGkind(), rng_kind)) do.call(RNGkind, as.list(rng_kind))
    if (had_seed) assign(".Random.seed", seed, .GlobalEnv)
    else if (exists(".Random.seed", .GlobalEnv, inherits = FALSE)) rm(".Random.seed", envir = .GlobalEnv)
  }, add = TRUE)
  for (target in targets) {
    fit <- get(paste0("fit_", target), envir, inherits = FALSE)
    # US and Danish plots also predict other targets on a common input table.
    # Preserve those full domains as well as each target's own feature table.
    domains <- target
    if (target %in% c("DGS2", "DGS10", "MORTGAGE30US")) domains <- c(domains, "DFF")
    if (target == "DK_Long") domains <- c(domains, "DK_Short")
    for (domain in domains) {
      input <- paste0("df_predict_", domain)
      if (!exists(input, envir, inherits = FALSE)) next
      data <- get(input, envir, inherits = FALSE)
      if (!is.data.frame(data) || !nrow(data)) stop("Empty model prediction input: ", input)
      variable <- paste0("model_predictions_", target,
                         if (domain != target) paste0("_on_", domain) else "")
      # Keep copy-on-write references rather than serialize large forests at
      # every chunk boundary or repeat predictions. These objects already live
      # in the chapter environment; identical() is fast for unchanged references.
      inputs <- list(fit = fit, data = data)
      if (identical(.book_runtime$result_inputs[[variable]], inputs)) next
      value <- as.data.frame(data)
      prediction <- stats::predict(fit, data)
      if (!is.numeric(prediction) || length(prediction) != nrow(data)) {
        stop("Incomplete model predictions: ", variable)
      }
      value[[paste0("pred_", target)]] <- as.numeric(prediction)
      capture(variable, value)
      .book_runtime$result_inputs[[variable]] <- inputs
    }
  }
  invisible(NULL)
}

if (requireNamespace("knitr", quietly = TRUE)) {
  knitr::opts_hooks$set(book_timing = function(options) {
    options$.book_start <- proc.time()[["elapsed"]]
    options
  })
  knitr::knit_hooks$set(book_timing = function(before, options, envir) {
    if (!before) {
      book_metric("chunk", options$label, "", proc.time()[["elapsed"]] - options$.book_start)
      book_write_manifest()
      book_capture_results(envir)
    }
    invisible(NULL)
  })
  knitr::opts_chunk$set(book_timing = TRUE, error = FALSE)
}

# Compatibility names used by the existing chapters; no theme-local cache.
fredr_cached <- book_fred
fredr_cached_many <- function(series_ids, ...) dplyr::bind_rows(lapply(series_ids, book_fred, ...))
finansdanmark_xlsx_url <- book_finansdanmark_url
