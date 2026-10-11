# Match observations on date without expanding every pair into a joined table.
# Keep source order: the original joins fed each x series' order to stats::ccf.
book_prepare_correlations <- function(data) {
  required <- c("series_id", "date", "value")
  if (!all(required %in% names(data))) {
    stop("Correlation data requires series_id, date and value", call. = FALSE)
  }
  data <- as.data.frame(data)[required]
  data$series_id <- as.character(data$series_id)
  if (anyNA(data$series_id) || anyNA(data$date)) {
    stop("Correlation series_id and date must not be missing", call. = FALSE)
  }
  if (!is.numeric(data$value)) {
    stop("Correlation values must be numeric", call. = FALSE)
  }
  if (any(!is.finite(data$value) & !is.na(data$value))) {
    stop("Correlation values must be finite or NA", call. = FALSE)
  }
  # Identical repeated observations are harmless; conflicting observations are
  # not averaged, selected arbitrarily, or allowed to multiply the join rows.
  data <- data[!duplicated(data), , drop = FALSE]
  conflict <- which(duplicated(data[c("series_id", "date")]))
  if (length(conflict)) {
    row <- conflict[1L]
    stop(sprintf("Conflicting correlation observations for series %s on %s",
                 data$series_id[row], as.character(data$date[row])),
         call. = FALSE)
  }
  rownames(data) <- NULL
  data
}

book_ccf_maxima <- function(x, y) {
  horizons <- c(30L, 365L, 1825L)
  columns <- as.vector(rbind(paste0("best_corr_time_", horizons),
                            paste0("best_corr_value_", horizons)))
  # CCF is undefined for fewer than two paired observations or zero variance.
  # Retain an explicit NA row so these directed comparisons keep their coverage.
  if (length(x) < 2L || all(x == x[1L]) || all(y == y[1L])) {
    return(as.data.frame(setNames(rep(list(NA_real_), length(columns)), columns)))
  }
  # stats::acf uses the same centering and normalization at every lag.max.
  # Fixtures compare every retained lag against three separate ccf calls.
  result <- stats::ccf(x, y, lag.max = max(horizons), plot = FALSE)
  lag <- as.vector(result$lag)
  acf <- as.vector(result$acf)
  peaks <- unlist(lapply(horizons, function(horizon) {
    keep <- which(abs(lag) <= horizon)
    best <- keep[which(abs(acf[keep]) == max(abs(acf[keep])))]
    list(lag[best], acf[best])
  }), recursive = FALSE)
  # Preserve the original exact equality ties, negative-to-positive lag order,
  # and data.frame recycling across horizons (no arbitrary single winner).
  as.data.frame(setNames(peaks, columns))
}

book_correlations_aligned <- function(data) {
  ids <- unique(data$series_id)
  empty <- data.frame(x1 = character(), x2 = character())
  for (horizon in c(30L, 365L, 1825L)) {
    empty[[paste0("best_corr_time_", horizon)]] <- numeric()
    empty[[paste0("best_corr_value_", horizon)]] <- numeric()
  }
  if (length(ids) < 2L) return(empty)

  # Sparse per-series vectors require O(observations) storage. Only one aligned
  # pair is materialized at a time, plus the small published results table.
  series <- split(seq_len(nrow(data)), factor(data$series_id, levels = ids))
  series <- lapply(series, function(rows) {
    list(date = data$date[rows], value = data$value[rows])
  })
  output <- vector("list", length(ids) * (length(ids) - 1L))
  pair <- 0L
  for (i in seq_along(ids)) {
    x <- series[[i]]
    for (j in seq_along(ids)) {
      if (i == j) next
      y <- series[[j]]
      matched <- match(x$date, y$date)
      complete <- !is.na(matched) & !is.na(x$value) & !is.na(y$value[matched])
      peaks <- book_ccf_maxima(x$value[complete], y$value[matched[complete]])
      pair <- pair + 1L
      output[[pair]] <- cbind(data.frame(x1 = ids[i], x2 = ids[j]), peaks)
    }
  }
  result <- do.call(rbind, output)
  rownames(result) <- NULL
  result
}

book_correlations <- function(data, namespace) {
  data <- book_prepare_correlations(data)
  book_cache_derived(
    namespace = namespace,
    inputs = list(observations = data, horizons = c(30L, 365L, 1825L)),
    compute = function() book_correlations_aligned(data),
    packages = "stats",
    code = list(prepare = body(book_prepare_correlations),
                maxima = body(book_ccf_maxima),
                aligned = body(book_correlations_aligned))
  )
}

# Full evidence for live/replay renders, independent of model capture hooks.
# Audits run after timing; neither captured inputs nor outputs are summarized.
book_capture_correlation <- function(namespace, observations, output, etf_ids,
                                     directory = Sys.getenv("BOOK_RESULTS_DIR", "")) {
  if (!nzchar(directory)) return(invisible(NULL))
  if (!namespace %in% c("indicators-correlations", "etf-correlations")) {
    stop("Unapproved correlation capture namespace: ", namespace)
  }
  path <- file.path(directory, "correlations", paste0(namespace, ".rds"))
  record <- list(schema = 1L, namespace = namespace,
                 observations = as.data.frame(observations),
                 etf_ids = sort(unique(as.character(etf_ids))), output = output)
  if (file.exists(path) && !identical(readRDS(path), record)) {
    stop("Correlation capture changed within namespace: ", namespace)
  }
  dir.create(dirname(path), recursive = TRUE, showWarnings = FALSE)
  saveRDS(record, path)
  invisible(path)
}

book_correlation_canonical <- function(data) {
  data <- as.data.frame(data)
  data$x1 <- as.character(data$x1)
  data$x2 <- as.character(data$x2)
  data <- data[do.call(order, unname(data)), , drop = FALSE]
  rownames(data) <- NULL
  data
}

book_correlation_equal <- function(actual, expected, tolerance = 1e-8) {
  if (!is.data.frame(actual) || !is.data.frame(expected) ||
      !identical(names(actual), names(expected))) return(FALSE)
  actual <- book_correlation_canonical(actual)
  expected <- book_correlation_canonical(expected)
  if (!identical(dim(actual), dim(expected))) return(FALSE)
  for (column in names(expected)) {
    a <- actual[[column]]
    b <- expected[[column]]
    if (is.numeric(a) && is.numeric(b)) {
      if (!identical(is.na(a), is.na(b))) return(FALSE)
      valid <- !is.na(a)
      if (any(!is.finite(a[valid])) || any(!is.finite(b[valid])) ||
          any(abs(a[valid] - b[valid]) > tolerance)) return(FALSE)
    } else if (!identical(a, b)) return(FALSE)
  }
  TRUE
}

book_correlation_input_canonical <- function(data) {
  data <- data[c("series_id", "date", "value")]
  data <- data[order(data$series_id, data$date), , drop = FALSE]
  rownames(data) <- NULL
  data
}

# Validation oracle: actual original pairwise inner joins, NA omission, and
# THREE stats::ccf calls. Do not call optimized preparation/alignment/maxima.
# Retain ancillary source columns: the historical na.omit examined these too.
book_correlation_original <- function(observations, namespace, retain_undefined = TRUE) {
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

book_audit_correlation_record <- function(baseline, optimized, tolerance = 1e-8) {
  namespaces <- c("indicators-correlations", "etf-correlations")
  namespace <- baseline$namespace
  if (!identical(baseline$schema, 1L) || !identical(optimized$schema, 1L) ||
      length(namespace) != 1L || !namespace %in% namespaces ||
      !identical(namespace, optimized$namespace)) stop("Correlation capture namespace/schema mismatch")
  if (!identical(baseline$etf_ids, optimized$etf_ids)) stop(namespace, ": ETF coverage changed")
  raw <- as.data.frame(baseline$observations)
  current <- as.data.frame(optimized$observations)
  required <- c("series_id", "date", "value")
  if (!all(required %in% names(raw)) || !all(required %in% names(current))) {
    stop(namespace, ": incomplete captured observations")
  }
  raw$series_id <- as.character(raw$series_id)
  current$series_id <- as.character(current$series_id)
  if (anyNA(raw$series_id) || anyNA(raw$date) ||
      anyNA(current$series_id) || anyNA(current$date)) stop(namespace, ": missing series/date")
  # Only exact repeated ETF observations may be removed. Require two copies,
  # never conflicting values, three copies, non-ETF duplicates or new filling.
  duplicated_row <- duplicated(raw[required])
  clean <- raw[!duplicated_row, , drop = FALSE]
  duplicate_ids <- unique(raw$series_id[duplicated_row])
  if (any(!duplicate_ids %in% baseline$etf_ids) ||
      anyDuplicated(clean[c("series_id", "date")]) ||
      anyDuplicated(raw[duplicated_row, required, drop = FALSE]) ||
      anyDuplicated(current[c("series_id", "date")])) {
    stop(namespace, ": unapproved duplicate/conflicting series/date correction")
  }
  # A second ETF append repeats the entire available series, not chosen dates.
  for (id in duplicate_ids) {
    original <- clean[clean$series_id == id, required, drop = FALSE]
    repeated <- raw[duplicated_row & raw$series_id == id, required, drop = FALSE]
    if (!identical(book_correlation_input_canonical(original),
                   book_correlation_input_canonical(repeated))) {
      stop(namespace, ": partial ETF duplicate removal")
    }
  }
  expected_inputs <- book_correlation_input_canonical(clean)
  actual_inputs <- book_correlation_input_canonical(current)
  if (!identical(expected_inputs, actual_inputs)) {
    stop(namespace, ": inputs changed beyond the exact duplicate ETF append correction")
  }
  historical <- book_correlation_original(raw, namespace, retain_undefined = FALSE)
  if (!book_correlation_equal(baseline$output, historical, tolerance)) {
    stop(namespace, ": baseline capture differs from independent original CCF")
  }
  reference <- book_correlation_original(clean, namespace)
  # Independently check current actual df_all as well as cleaned historical
  # df_all. Dropping an ancillary NA column must not alter pair selection.
  rownames(clean) <- rownames(current) <- NULL
  current_reference <- if (identical(clean, current)) reference else book_correlation_original(current, namespace)
  if (!book_correlation_equal(reference, current_reference, tolerance) ||
      !book_correlation_equal(optimized$output, reference, tolerance)) {
    stop(namespace, ": optimized complete pairs differ from independent original clean CCF")
  }
  core <- paste0("best_corr_value_", c(30L, 365L, 1825L))
  a <- book_correlation_canonical(optimized$output)
  b <- book_correlation_canonical(reference)
  errors <- abs(as.matrix(a[core]) - as.matrix(b[core]))
  maximum <- if (any(!is.na(errors))) max(errors, na.rm = TRUE) else 0
  data.frame(namespace = namespace, pairs = nrow(unique(a[c("x1", "x2")])),
             rows = nrow(a), removed_exact_etf_rows = sum(duplicated_row),
             max_coefficient_error = maximum, tolerance = tolerance)
}

book_load_correlation_captures <- function(directory) {
  files <- paste0(c("indicators-correlations", "etf-correlations"), ".rds")
    path <- file.path(directory, "correlations")
    present <- list.files(path, "\\.rds$")
    if (!identical(sort(present), sort(files))) stop("Missing/unexpected namespaced correlation captures: ", directory)
    records <- lapply(files, function(file) {
      record <- readRDS(file.path(path, file))
      if (!identical(record$namespace, sub("\\.rds$", "", file))) {
        stop("Correlation capture filename/namespace mismatch: ", file)
      }
      record
    })
    # The shared runtime's anonymous captures must all be covered by this audit.
    # A third unrelated df_ccfs object is not exempt merely by its variable name.
    anonymous <- list.files(directory, "^df_ccfs-[0-9]+\\.rds$", full.names = TRUE)
    covered <- logical(length(records))
    if (!length(anonymous)) stop("Missing full df_ccfs captures: ", directory)
    for (file in anonymous) {
      value <- readRDS(file)
      matches <- vapply(records, function(record) identical(value, record$output), logical(1))
      if (!any(matches)) stop("Unaudited df_ccfs capture: ", file)
      covered <- covered | matches
    }
    if (!all(covered)) stop("Namespaced outputs missing from full df_ccfs captures: ", directory)
    records
}

book_compare_correlation_captures <- function(reference, current) {
  left <- book_load_correlation_captures(reference)
  right <- book_load_correlation_captures(current)
  if (!identical(left, right)) stop("Full correlation input/output captures changed within version: ", current)
  invisible(TRUE)
}

book_audit_correlation_captures <- function(baseline, optimized, tolerance = 1e-8) {
  left <- book_load_correlation_captures(baseline)
  right <- book_load_correlation_captures(optimized)
  do.call(rbind, lapply(seq_along(left), function(i) {
    book_audit_correlation_record(left[[i]], right[[i]], tolerance)
  }))
}
