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
  fixture <- xts::xts(matrix(seq_len(12), ncol = 6),
                      order.by = as.Date(c("2026-10-08", "2026-10-09")))
  colnames(fixture) <- paste0("SPY.", c("Open", "High", "Low", "Close", "Volume", "Adjusted"))
  provider <- function(Symbols, env, auto.assign, ...) {
    stopifnot(identical(Symbols, "SPY"), is.null(env), identical(auto.assign, FALSE))
    calls[[length(calls) + 1L]] <<- list(Symbols = Symbols, env = env,
                                       auto.assign = auto.assign, dots = list(...))
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
})
