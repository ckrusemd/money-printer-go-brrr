# Multiple independent R processes must retain one build's source responses.
source("scripts/book_runtime.R")
scratch <- tempfile("notebook-runtime-")
dir.create(scratch)
Sys.setenv(BOOK_RUN_ID = "fixture-run", BOOK_AS_OF = "2026-10-24",
           BOOK_SNAPSHOT_MODE = "record", BOOK_SNAPSHOT_DIR = file.path(scratch, "inputs"),
           BOOK_METRICS_FILE = file.path(scratch, "metrics.csv"))
rm(.book_runtime, envir = .GlobalEnv)
source("scripts/book_runtime.R")
one <- book_fetch("fixture", list(id = "one"), function() data.frame(date=book_date(), value=1))
rm(.book_runtime, envir = .GlobalEnv)
source("scripts/book_runtime.R")
two <- book_fetch("fixture", list(id = "one"), function() stop("must reuse same-build response"))
stopifnot(identical(one, two))
book_fetch("fixture", list(id = "two"), function() data.frame(date=book_date(), value=2))
invisible(try(book_fetch("optional-fixture", list(id = "missing"), function() stop("unavailable"),
                         attempts = 1L), silent=TRUE))
rm(.book_runtime, envir = .GlobalEnv)
source("scripts/book_runtime.R")
status <- book_source_status()
stopifnot(nrow(status) == 3L, sum(status$Status == "Available") == 2L,
          sum(grepl("Unavailable", status$Status)) == 1L)
manifest <- readRDS(file.path(scratch, "inputs", "manifest.rds"))
stopifnot(length(manifest$requests) == 2L, length(manifest$failures) == 1L,
          identical(manifest$run_id, "fixture-run"))
Sys.setenv(BOOK_RUN_ID = "other-run")
rm(.book_runtime, envir = .GlobalEnv)
stopifnot(inherits(try(source("scripts/book_runtime.R"), silent=TRUE), "try-error"))
Sys.unsetenv(c("BOOK_RUN_ID", "BOOK_AS_OF", "BOOK_SNAPSHOT_MODE", "BOOK_SNAPSHOT_DIR", "BOOK_METRICS_FILE"))
unlink(scratch, recursive=TRUE)
cat("Independent kernel source isolation fixtures passed\n")
