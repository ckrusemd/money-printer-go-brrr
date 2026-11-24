# Keep quantmod's real getSymbols/importDefaults dispatch; replace only the
# Yahoo provider so this regression never contacts the network.
source("scripts/book_runtime.R")

local({
  stopifnot(requireNamespace("quantmod", quietly = TRUE),
            requireNamespace("xts", quietly = TRUE))
  scratch <- tempfile("book-yahoo-dispatch-")
  dir.create(scratch)
  on.exit(unlink(scratch, recursive = TRUE), add = TRUE)
  .book_runtime$mode <- "live"
  .book_runtime$observations <- new.env(parent = emptyenv())
  .book_runtime$manifest <- list()
  .book_runtime$failures <- list()
  .book_runtime$memory_order <- character()
  .book_runtime$snapshots <- file.path(scratch, "inputs")
  .book_runtime$metrics <- file.path(scratch, "metrics.csv")

  ns <- asNamespace("quantmod")
  original_provider <- get("getSymbols.yahoo", ns)
  on.exit(utils::assignInNamespace("getSymbols.yahoo", original_provider,
                                  ns = "quantmod"), add = TRUE)
  calls <- list()
  failures_left <- 0
  fixture <- xts::xts(matrix(seq_len(12), ncol = 6),
                      order.by = as.Date(c("2026-10-08", "2026-10-09")))
  colnames(fixture) <- paste0("SPY.", c("Open", "High", "Low", "Close", "Volume", "Adjusted"))
  provider <- function(Symbols, env, auto.assign, ...) {
    stopifnot(identical(Symbols, "SPY"), is.null(env), identical(auto.assign, FALSE))
    calls[[length(calls) + 1L]] <<- list(Symbols = Symbols, env = env,
                                       auto.assign = auto.assign, dots = list(...))
    if (failures_left > 0) {
      failures_left <<- failures_left - 1
      stop("Controlled Yahoo provider failure")
    }
    fixture
  }
  utils::assignInNamespace("getSymbols.yahoo", provider, ns = "quantmod")
  from <- as.Date("2026-10-01")
  to <- as.Date("2026-10-10")

  original <- quantmod::getSymbols(Symbols = "SPY", env = NULL, src = "yahoo",
                                   from = from, to = to)
  wrapped <- book_yahoo("SPY", from = from, to = to)
  stopifnot(identical(original, fixture), identical(wrapped, original),
            identical(calls[[1L]], calls[[2L]]),
            identical(calls[[2L]]$dots$from, from),
            identical(calls[[2L]]$dots$to, to), length(calls) == 2L,
            inherits(wrapped, "xts"))
  stopifnot(identical(book_yahoo("SPY", from = from, to = to), original),
            length(calls) == 2L)
  # Retry controls cannot change lookup identity or reach the Yahoo provider.
  stopifnot(identical(book_yahoo("SPY", from = from, to = to, attempts = 1L), original),
            length(calls) == 2L)
  expected_key <- book_hash(list(provider = "Yahoo Finance",
    parameters = list(Symbols = "SPY", env = NULL, src = "yahoo", from = from, to = to)))
  stopifnot(identical(names(.book_runtime$manifest), expected_key),
            !"attempts" %in% names(.book_runtime$manifest[[expected_key]]$parameters),
            !"attempts" %in% names(calls[[2L]]$dots))

  # The removed fetcher failed during importDefaults, before reaching Yahoo.
  old_failure <- tryCatch(
    do.call(quantmod::getSymbols, list(Symbols = "SPY", env = NULL, src = "yahoo",
                                      from = from, to = to)),
    error = identity
  )
  stopifnot(inherits(old_failure, "error"),
            grepl("cannot coerce type.*closure.*character", conditionMessage(old_failure)),
            length(calls) == 2L)
  cat("Yahoo real-dispatch regression passed: direct/wrapper xts and arguments identical; ",
      "cache deduplicates; old closure call fails before provider dispatch\n", sep = "")

  # Mock waits in a dedicated scope, keeping both actual retry loops and the
  # real quantmod dispatch. Neither the production runtime nor base is patched.
  retry_scope <- new.env(parent = globalenv())
  waits <- numeric()
  retry_scope$Sys.sleep <- function(seconds) { waits <<- c(waits, seconds); invisible(NULL) }
  retry_scope$book_fetch <- book_fetch
  environment(retry_scope$book_fetch) <- retry_scope
  retry_scope$book_yahoo <- book_yahoo
  environment(retry_scope$book_yahoo) <- retry_scope
  reset <- function(failures) {
    calls <<- list()
    waits <<- numeric()
    failures_left <<- failures
    .book_runtime$observations <- new.env(parent = emptyenv())
    .book_runtime$manifest <- list()
    .book_runtime$failures <- list()
    .book_runtime$memory_order <- character()
  }
  reset(Inf)
  failed <- try(retry_scope$book_yahoo("SPY"), silent = TRUE)
  stopifnot(inherits(failed, "try-error"), length(calls) == 3L, identical(waits, c(1, 2)),
            all(vapply(calls, function(call) !"attempts" %in% names(call$dots), logical(1))))
  reset(2L)
  stopifnot(identical(retry_scope$book_yahoo("SPY"), fixture),
            length(calls) == 3L, identical(waits, c(1, 2)))

  for (chapter in c("Chapters/04_Markets/Markets.Rmd", "Chapters/05_ETFs/ETFs.Rmd")) {
    lines <- readLines(chapter, warn = FALSE)
    name <- if (grepl("Markets.Rmd", chapter, fixed = TRUE)) "get_yahoo_ticker" else "get_yahoo_value"
    start <- which(startsWith(lines, paste0(name, " = function")))
    stopifnot(length(start) == 1L)
    end <- which(seq_along(lines) > start & lines == "}")[1L]
    eval(parse(text = lines[start:end]), retry_scope)
    getter <- get(name, retry_scope)
    reset(Inf)
    warnings <- character()
    result <- withCallingHandlers(getter("SPY"), warning = function(warning) {
      warnings <<- c(warnings, conditionMessage(warning))
      invokeRestart("muffleWarning")
    })
    stopifnot(is.null(result), length(calls) == 3L, identical(waits, c(1, 2)),
              length(warnings) == 1L, grepl("after 3 failed attempts", warnings, fixed = TRUE))
    plain_key <- book_hash(list(provider = "Yahoo Finance",
                               parameters = list(Symbols = "SPY", env = NULL, src = "yahoo")))
    stopifnot(identical(names(.book_runtime$failures), plain_key),
              !"attempts" %in% names(.book_runtime$failures[[plain_key]]$parameters),
              all(vapply(calls, function(call) !"attempts" %in% names(call$dots), logical(1))))
  }
  cat("Yahoo retry regression passed: default wrapper 3 calls; Markets and ETFs outer loops 3 calls each, waits 1/2s, original keys unchanged\n")
})
