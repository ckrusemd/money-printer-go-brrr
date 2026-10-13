# Base-R-only regression tests for the production benchmark memory gates.
source("scripts/benchmark_book.R")

local({
  measurements <- function(baseline = c(100, 100, 100), optimized = c(90, 90, 150)) {
    data.frame(version = rep(c("baseline", "optimized"), each = 4L),
               warmup = rep(c(TRUE, FALSE, FALSE, FALSE), 2L),
               max_rss_kb = c(200, baseline, 1000, optimized))
  }
  # The former median-only gate passes, but the approved worst-peak gate fails.
  outlier <- book_benchmark_rss(measurements())
  stopifnot(outlier$rss_measurements_valid, outlier$rss_median_target_met,
            !outlier$rss_peak_target_met, !outlier$rss_target_met,
            outlier$baseline_median_max_rss_kb == 100,
            outlier$optimized_median_max_rss_kb == 90,
            outlier$baseline_warm_peak_rss_kb == 100,
            outlier$optimized_warm_peak_rss_kb == 150)

  equal <- book_benchmark_rss(measurements(optimized = c(100, 100, 100)))
  stopifnot(equal$rss_target_met)
  lower <- book_benchmark_rss(measurements(optimized = c(90, 90, 95)))
  stopifnot(lower$rss_target_met,
            lower$baseline_warmup_peak_rss_kb == 200,
            lower$optimized_warmup_peak_rss_kb == 1000)
  median_regression <- book_benchmark_rss(measurements(c(80, 80, 100), c(90, 90, 100)))
  stopifnot(median_regression$rss_peak_target_met,
            !median_regression$rss_median_target_met, !median_regression$rss_target_met)

  for (invalid in c(0, -1, NA_real_, NaN, Inf, -Inf)) {
    values <- measurements(optimized = c(90, 90, 95))
    values$max_rss_kb[6L] <- invalid
    rejected <- book_benchmark_rss(values)
    stopifnot(!rejected$rss_measurements_valid, !rejected$rss_target_met)
  }
  values <- measurements()
  missing <- book_benchmark_rss(values[values$version == "baseline", ])
  empty <- book_benchmark_rss(values[values$warmup, ])
  stopifnot(!missing$rss_target_met, !empty$rss_target_met)
  cat("PASS: warm RSS median/max gates, positive finite measurements, and separate warmup peaks\n")
})
