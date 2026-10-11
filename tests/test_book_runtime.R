source("scripts/book_runtime.R")
scratch <- tempfile("book-tests-")
dir.create(scratch)
.book_runtime$snapshots <- file.path(scratch, "inputs")
.book_runtime$derived <- file.path(scratch, "derived")
.book_runtime$metrics <- file.path(scratch, "metrics.csv")
.book_runtime$mode <- "record"
count <- 0L
fetch <- function() { count <<- count + 1L; data.frame(date = as.Date("2026-10-11"), value = 10) }
original <- book_fetch("fixture", list(id = "one"), fetch)
stopifnot(identical(original, book_fetch("fixture", list(id = "one"), fetch)), count == 1L)
source("scripts/book_runtime.R")
stopifnot(identical(original, book_fetch("fixture", list(id = "one"), fetch)), count == 1L)
.book_runtime$observations <- new.env(parent = emptyenv())
.book_runtime$mode <- "replay"
stopifnot(identical(original, book_fetch("fixture", list(id = "one"), function() stop("network forbidden"))))
stopifnot(inherits(try(book_fetch("fixture", list(id = "missing"), fetch), silent = TRUE), "try-error"))
.book_runtime$mode <- "live"
.book_runtime$observations <- new.env(parent = emptyenv())
stopifnot(inherits(try(book_fetch("fixture", list(id = "one"), function() stop("offline"), attempts = 1L), silent = TRUE), "try-error"))
count <- 0L
compute <- function() { count <<- count + 1L; runif(5) }
set.seed(1971)
first <- book_cache_derived("rng", list(x = 1), compute)
next_first <- runif(1)
set.seed(1971)
cached <- book_cache_derived("rng", list(x = 1), compute)
next_cached <- runif(1)
stopifnot(identical(first, cached), identical(next_first, next_cached), count == 1L)
set.seed(1971)
book_cache_derived("rng", list(x = 2), compute)
stopifnot(count == 2L)
set.seed(1971)
book_cache_derived("rng", list(x = 1), compute, code = "changed")
stopifnot(count == 3L)
book_prune_cache(limit = 1)
stopifnot(length(list.files(.book_runtime$derived)) == 0L)
unlink(scratch, recursive = TRUE)
cat("Book runtime fixtures passed\n")
