# Offline package fixtures; use a file to avoid nested shell/R quoting in CI.
testthat::test_local("packages/dstcollect", stop_on_failure = TRUE)
