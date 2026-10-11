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
