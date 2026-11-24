# Run from the repository root: Rscript --vanilla tests/test_yield_models.R
# Synthetic observations only; no provider requests or publication artifacts.
required <- c("dplyr", "tidyr", "lubridate", "caret", "randomForest", "digest")
missing <- required[!vapply(required, requireNamespace, logical(1), quietly = TRUE)]
if (length(missing)) stop("Missing test dependencies: ", paste(missing, collapse = ", "))
suppressPackageStartupMessages(library(dplyr))
suppressPackageStartupMessages(library(tidyr))
suppressPackageStartupMessages(library(lubridate))
source("scripts/analysis/yield_models.R")

assert_equal <- function(actual, expected, label) {
  difference <- all.equal(actual, expected, tolerance = 0)
  if (!isTRUE(difference)) stop(label, ": ", paste(difference, collapse = "; "))
}

# Frozen pre-extraction implementations, independent of the new helpers.
legacy_target_features <- function(checkboard, target, levels, descending) {
  result <- checkboard %>%
    filter(series_id != joined_series) %>%
    mutate(one_year_ahead = date + years(1)) %>%
    left_join(target, by = c("one_year_ahead" = "date")) %>%
    unite(series_id, series_id, joined_series) %>%
    select(date, series_id, spread, value) %>%
    spread(series_id, spread)
  if (descending) result <- arrange(result, desc(date))
  left_join(result, levels, by = "date")
}

legacy_fit_rf <- function(data, date_column = "date", value_column = "value") {
  caret::train(
    x = data %>% na.omit() %>%
      select(-all_of(c(date_column, value_column))) %>% data.frame(),
    y = (data %>% na.omit())[[value_column]],
    method = "rf", tuneGrid = data.frame(mtry = 3), ntree = 300,
    metric = "RMSE", trControl = caret::trainControl(method = "none")
  )
}

num_trees <- 300
legacy_walk_forward_rf = function(target_name,target_spec,
                           initial_years=15,test_every_months=3) {
  model_data = target_spec$data %>%
    dplyr::mutate(target_date=date+years(1),
                  month=lubridate::floor_date(date,"month")) %>%
    dplyr::filter(!is.na(value)) %>%
    dplyr::group_by(month) %>%
    dplyr::filter(date==max(date)) %>%
    dplyr::ungroup() %>%
    dplyr::select(-month) %>%
    dplyr::arrange(date)

  feature_names = setdiff(names(model_data),c("date","target_date","value"))
  model_data = model_data %>%
    dplyr::filter(stats::complete.cases(dplyr::select(.,dplyr::all_of(feature_names))))

  first_origin = min(model_data$date)+years(initial_years)
  origins = model_data %>%
    dplyr::filter(date>=first_origin,!is.na(value)) %>%
    dplyr::filter(lubridate::month(date) %in% seq(1,12,by=test_every_months)) %>%
    dplyr::pull(date)

  results = lapply(seq_along(origins),function(i) {
    origin = origins[i]
    train = model_data %>%
      dplyr::filter(target_date<=origin,!is.na(value))
    test = model_data %>%
      dplyr::filter(date==origin,!is.na(value))

    if (nrow(train)<120 || nrow(test)!=1) return(NULL)

    set.seed(1971+i)
    fit = randomForest::randomForest(
      x=data.frame(train[,feature_names,drop=FALSE]),
      y=train$value,
      ntree=num_trees,
      mtry=min(3,length(feature_names))
    )

    data.frame(
      target=target_name,
      origin=origin,
      target_date=test$target_date,
      actual=test$value,
      random_forest=as.numeric(predict(fit,data.frame(test[,feature_names,drop=FALSE]))),
      persistence=as.numeric(test[[target_spec$current]]),
      curve_regime=ifelse(test$level_DGS10-test$level_DGS2<0,"Inverted","Normal")
    )
  })

  dplyr::bind_rows(results)
}


run_tests <- function() {
  # Exercise all 13 curve series and all 11 target tables, including missing
  # outcomes, shuffled inputs, descending targets and the leap-day NA target.
  series <- c("DFF", "DGS1MO", "DGS3MO", "DGS6MO", "DGS1", "DGS2",
              "DGS3", "DGS5", "DGS7", "DGS10", "DGS20", "DGS30", "MORTGAGE30US")
  dates <- seq(as.Date("2019-01-01"), as.Date("2022-04-30"), by = "day")
  curve <- expand.grid(date = dates, series_id = factor(series, levels = series)) %>%
    mutate(value = 2 + as.integer(series_id) / 10 + sin(as.numeric(date) / 27),
           time = as.integer(series_id) * 30)
  curve$value[curve$date == min(dates) & curve$series_id == "DGS30"] <- NA_real_
  filled_wide <- curve %>% select(-time) %>% spread(series_id, value) %>%
    arrange(desc(date)) %>% fill(2:ncol(.), .direction = "up")
  incomplete <- filled_wide %>% gather(series_id, value, -date) %>%
    mutate(series_id = factor(series_id, levels = series))
  expected_curve <- filled_wide %>% na.omit() %>% gather(series_id, value, -date) %>%
    mutate(series_id = factor(series_id, levels = series))
  complete_curve <- yield_complete_curve(incomplete)
  # na.action records the discarded wide rows, not analytical data.
  attr(expected_curve, "na.action") <- NULL
  assert_equal(complete_curve, expected_curve, "complete curve dates and order")
  stopifnot(!min(dates) %in% complete_curve$date)

  pairs <- as.data.frame(t(combn(series, 2)))
  names(pairs) <- c("series_id", "joined_series")
  checkboard <- pairs %>% inner_join(complete_curve, by = "series_id", relationship = "many-to-many") %>%
    inner_join(complete_curve, by = c("joined_series" = "series_id", "date" = "date")) %>%
    mutate(spread = value.x - value.y) %>%
    select(series_id, joined_series, date, spread)
  levels <- complete_curve %>% select(date, series_id, value) %>%
    mutate(series_id = paste0("level_", series_id)) %>% spread(series_id, value)
  features <- yield_spread_features(checkboard)
  target_names <- c("DFF", "DGS2", "DGS10", "MORTGAGE30US", "DK_Short", "DK_Long",
                    "CPIAUCSL", "CSUSHPINSA", "M2SL", "UMCSENT", "USREC")
  prepared <- lapply(seq_along(target_names), function(i) {
    target <- data.frame(date = rev(dates), value = 2 + i / 10 + cos(as.numeric(rev(dates)) / 40))
    target$value[seq(7, nrow(target), by = 31)] <- NA_real_
    reference <- legacy_target_features(checkboard, target, levels, i >= 6)
    result <- yield_target_features(features, target, levels, descending = i >= 6)
    assert_equal(result, reference, paste("target preparation", target_names[i]))
    stopifnot(is.na(result$value[result$date == as.Date("2020-02-29")]),
              identical(names(result)[1:2], c("date", "value")),
              ncol(result) == 2 + choose(length(series), 2) + length(series))
    result[seq(1, nrow(result), by = 7), ]
  })
  names(prepared) <- target_names

  # The ECB helper has different date/outcome column names and its own seed.
  ecb <- prepared$DFF
  names(ecb)[1:2] <- c("obstime", "obsvalue")
  set.seed(1971)
  reference_ecb <- legacy_fit_rf(ecb, "obstime", "obsvalue")
  reference_ecb_rng <- .Random.seed
  set.seed(1971)
  fallback_ecb <- yield_fit_rf(ecb, "ECB-DF", date_column = "obstime", value_column = "obsvalue")
  assert_equal(predict(fallback_ecb, ecb), predict(reference_ecb, ecb), "ECB fallback prediction")
  assert_equal(.Random.seed, reference_ecb_rng, "uncached fallback RNG")

  # Use the actual shared runtime, with cache and metrics isolated in tempdir.
  if (!file.exists("scripts/book_runtime.R")) stop("Shared book runtime is required for cache regression tests")
  cache_dir <- tempfile("yield-model-tests-")
  dir.create(cache_dir)
  on.exit(unlink(cache_dir, recursive = TRUE), add = TRUE)
  runtime <- new.env(parent = globalenv())
  runtime$.book_runtime <- new.env(parent = emptyenv())
  runtime$.book_runtime$derived <- file.path(cache_dir, "derived")
  runtime$.book_runtime$metrics <- file.path(cache_dir, "metrics.csv")
  # Source with a private runtime already visible to the initialization guard.
  # Save/restore any caller-owned global runtime rather than discarding it.
  had_runtime <- exists(".book_runtime", envir = globalenv(), inherits = FALSE)
  if (had_runtime) previous_runtime <- get(".book_runtime", envir = globalenv())
  assign(".book_runtime", runtime$.book_runtime, envir = globalenv())
  on.exit({
    if (had_runtime) assign(".book_runtime", previous_runtime, envir = globalenv())
    else rm(".book_runtime", envir = globalenv())
  }, add = TRUE)
  source("scripts/book_runtime.R", local = runtime)
  had_cache <- exists("book_cache_derived", envir = globalenv(), inherits = FALSE)
  if (had_cache) previous_cache <- get("book_cache_derived", envir = globalenv())
  assign("book_cache_derived", runtime$book_cache_derived, envir = globalenv())
  on.exit({
    if (had_cache) assign("book_cache_derived", previous_cache, envir = globalenv())
    else rm("book_cache_derived", envir = globalenv())
  }, add = TRUE)
  metric_count <- function(status) {
    if (!file.exists(runtime$.book_runtime$metrics)) return(0L)
    sum(read.csv(runtime$.book_runtime$metrics)$status == status)
  }

  # Compare every full-sample fit, preserving the single seed and sequential
  # RNG consumption across targets. Warm cache hits must replay that sequence.
  set.seed(1971)
  baseline_fit_time <- system.time(reference_fits <- lapply(prepared, legacy_fit_rf))[["elapsed"]]
  reference_rng <- .Random.seed
  reference_continuation <- runif(8)
  fit_all <- function() {
    set.seed(1971)
    lapply(names(prepared), function(name) yield_fit_rf(prepared[[name]], name))
  }
  cold_fit_time <- system.time(cold_fits <- fit_all())[["elapsed"]]
  assert_equal(.Random.seed, reference_rng, "cold fit sequence RNG")
  assert_equal(runif(8), reference_continuation, "cold fit RNG continuation")
  computed_before <- metric_count("computed")
  warm_fit_time <- system.time(warm_fits <- fit_all())[["elapsed"]]
  assert_equal(.Random.seed, reference_rng, "warm fit sequence RNG")
  assert_equal(runif(8), reference_continuation, "warm fit RNG continuation")
  stopifnot(metric_count("computed") == computed_before)
  for (i in seq_along(reference_fits)) {
    assert_equal(predict(cold_fits[[i]], prepared[[i]]),
                 predict(reference_fits[[i]], prepared[[i]]), paste("cold fit", target_names[i]))
    assert_equal(warm_fits[[i]], cold_fits[[i]], paste("serialized fit", target_names[i]))
    stopifnot(cold_fits[[i]]$finalModel$ntree == 300,
              cold_fits[[i]]$finalModel$mtry == 3)
  }

  # Execute the chapter's actual fit calls against the fixture tables, so a
  # missed target or a wiring change is caught alongside helper regressions.
  chapter <- readLines("Chapters/03_InterestRates/InterestRates.Rmd", warn = FALSE)
  chapter_chunk <- function(header) {
    start <- which(startsWith(chapter, paste0("```{r ", header)))[1]
    if (is.na(start)) stop("Missing chapter chunk: ", header)
    end <- which(seq_along(chapter) > start & chapter == "```")[1]
    chapter[seq.int(start + 1L, end - 1L)]
  }
  chapter_env <- new.env(parent = globalenv())
  chapter_env$num_trees <- 300
  chapter_env$tune_grid <- data.frame(mtry = 3)
  chapter_env$train_control <- caret::trainControl(method = "none")
  for (name in names(prepared)) assign(paste0("df_predict_", name), prepared[[name]], chapter_env)
  fit_code <- chapter_chunk("libraryrf")
  fit_code <- fit_code[!grepl("^pacman::|^book_load_packages|^detach", fit_code)]
  before <- metric_count("computed")
  invisible(eval(parse(text = fit_code), envir = chapter_env))
  stopifnot(metric_count("computed") == before)
  assert_equal(.Random.seed, reference_rng, "chapter fit call sequence RNG")
  for (i in seq_along(target_names)) {
    assert_equal(get(paste0("fit_", target_names[i]), chapter_env),
                 cold_fits[[i]], paste("chapter fit output", target_names[i]))
  }
  for (pass in 1:2) {
    set.seed(1971)
    cached_ecb <- yield_fit_rf(ecb, "ECB-DF", date_column = "obstime", value_column = "obsvalue")
    assert_equal(predict(cached_ecb, ecb), predict(reference_ecb, ecb), "ECB cached prediction")
    assert_equal(.Random.seed, reference_ecb_rng, "ECB cached RNG")
  }

  # A changed response, predictor, configuration, incoming seed, or helper
  # body must miss; subsequent targets must still see the correct RNG state.
  before <- metric_count("computed")
  changed <- prepared$DFF
  changed$value[which(!is.na(changed$value))[1]] <- changed$value[which(!is.na(changed$value))[1]] + 0.1
  set.seed(1971)
  changed_fit <- yield_fit_rf(changed, "DFF")
  stopifnot(metric_count("computed") == before + 1L)
  set.seed(1971)
  changed_reference <- legacy_fit_rf(changed)
  assert_equal(predict(changed_fit, changed), predict(changed_reference, changed), "response invalidation")
  changed <- prepared$DFF
  changed[[3]][1] <- changed[[3]][1] + 0.1
  set.seed(1971)
  yield_fit_rf(changed, "DFF")
  set.seed(1971)
  yield_fit_rf(prepared$DFF, "DFF", num_trees = 301)
  set.seed(1971)
  yield_fit_rf(prepared$DFF, "DFF", tune_grid = data.frame(mtry = 2))
  set.seed(1972)
  yield_fit_rf(prepared$DFF, "DFF")
  stopifnot(metric_count("computed") == before + 5L)
  original_fit <- yield_fit_rf
  on.exit(assign("yield_fit_rf", original_fit, envir = globalenv()), add = TRUE)
  modified_fit <- yield_fit_rf
  body(modified_fit) <- as.call(list(as.name("{"), quote(invisible(NULL)), body(modified_fit)))
  assign("yield_fit_rf", modified_fit, envir = globalenv())
  set.seed(1971)
  yield_fit_rf(prepared$DFF, "DFF")
  assign("yield_fit_rf", original_fit, envir = globalenv())
  stopifnot(metric_count("computed") == before + 6L)

  # Eighteen years with multiple rows per month: missing month ends are not
  # replaced by earlier complete observations. Outcomes are observed +1 year.
  months <- seq(as.Date("1990-01-01"), by = "month", length.out = 216)
  monthly_dates <- sort(c(months + 10, months + 20))
  walk_data <- data.frame(
    date = monthly_dates, value = 3 + sin(seq_along(monthly_dates) / 18),
    level_DFF = 2 + cos(seq_along(monthly_dates) / 13),
    level_DGS2 = 3 + sin(seq_along(monthly_dates) / 22),
    level_DGS10 = 3 + cos(seq_along(monthly_dates) / 17),
    level_MORTGAGE30US = 4 + cos(seq_along(monthly_dates) / 11),
    spread_a = sin(seq_along(monthly_dates) / 7)
  )
  walk_data$spread_a[396] <- NA_real_ # 2006-06 month-end feature unavailable
  walk_data$value[398] <- NA_real_ # 2006-07 month-end outcome unavailable
  walk_targets <- setNames(lapply(target_names[1:4], function(name) {
    list(data = walk_data, current = paste0("level_", name))
  }), target_names[1:4])
  baseline_walk_time <- system.time(reference_walk <- lapply(names(walk_targets), function(name) {
    legacy_walk_forward_rf(name, walk_targets[[name]])
  }))[["elapsed"]]
  reference_walk_rng <- .Random.seed
  walk_all <- function() lapply(names(walk_targets), function(name) {
    yield_walk_forward_rf(name, walk_targets[[name]])
  })
  cold_walk_time <- system.time(cold_walk <- walk_all())[["elapsed"]]
  assert_equal(cold_walk, reference_walk, "all walk-forward origins and outputs")
  assert_equal(.Random.seed, reference_walk_rng, "cold walk RNG")
  before <- metric_count("computed")
  warm_walk_time <- system.time(warm_walk <- walk_all())[["elapsed"]]
  assert_equal(warm_walk, reference_walk, "warm walk outputs")
  assert_equal(.Random.seed, reference_walk_rng, "warm walk RNG")
  stopifnot(metric_count("computed") == before,
            all(vapply(cold_walk, nrow, integer(1)) >= 8L))
  stopifnot(!as.Date("2006-07-21") %in% cold_walk[[1]]$origin,
            all(cold_walk[[1]]$target_date == cold_walk[[1]]$origin + years(1)),
            all(cold_walk[[1]]$persistence == walk_data$level_DFF[match(cold_walk[[1]]$origin, walk_data$date)]))

  for (name in names(walk_targets)) assign(paste0("df_predict_", name), walk_data, chapter_env)
  invisible(eval(parse(text = chapter_chunk("rf-walk-forward-validation")), envir = chapter_env))
  assert_equal(.Random.seed, reference_walk_rng, "chapter backtest RNG")
  stopifnot(metric_count("computed") == before,
            nrow(chapter_env$rf_backtest) == sum(vapply(reference_walk, nrow, integer(1))),
            identical(names(chapter_env$rf_backtest), c(
              "target", "origin", "target_date", "actual", "random_forest", "persistence",
              "curve_regime", "error", "persistence_error", "interval_half_width", "lower_80", "upper_80"
            )),
            identical(names(chapter_env$rf_metrics), c(
              "target", "observations", "rf_rmse", "persistence_rmse", "rmse_skill",
              "rf_mae", "persistence_mae", "interval_80_coverage"
            )))
  for (name in names(walk_targets)) {
    rows <- chapter_env$rf_backtest %>% filter(target == name)
    assert_equal(rows[, names(reference_walk[[1]])],
                 tibble::as_tibble(reference_walk[[match(name, names(walk_targets))]]),
                 paste("chapter backtest outputs", name))
    expected_width <- vapply(seq_len(nrow(rows)), function(i) {
      errors <- abs(rows$random_forest[seq_len(i - 1L)] - rows$actual[seq_len(i - 1L)])
      if (length(errors) < 8) return(NA_real_)
      as.numeric(quantile(errors, 0.80, type = 8))
    }, numeric(1))
    assert_equal(rows$interval_half_width, expected_width, "historical interval calibration")
    assert_equal(rows$lower_80, rows$random_forest - expected_width, "lower interval")
    assert_equal(rows$upper_80, rows$random_forest + expected_width, "upper interval")
    metrics <- chapter_env$rf_metrics %>% filter(target == name)
    expected_skill <- 1 - sqrt(mean((rows$random_forest - rows$actual)^2)) /
      sqrt(mean((rows$persistence - rows$actual)^2))
    assert_equal(metrics$rmse_skill, expected_skill, "persistence skill for scenario selection")
  }

  # Appending a new origin reuses old folds; correcting an existing training
  # observation recomputes every affected fold instead of returning stale fits.
  new_rows <- tail(walk_data, 2)
  new_rows$date <- new_rows$date + months(1)
  appended <- list(data = bind_rows(walk_data, new_rows), current = "level_DFF")
  appended_result <- yield_walk_forward_rf("DFF", appended)
  stopifnot(metric_count("computed") == before + 1L)
  assert_equal(head(appended_result, nrow(cold_walk[[1]])), cold_walk[[1]], "old fold reuse after append")
  corrected <- walk_targets$DFF
  corrected$data$value[2] <- corrected$data$value[2] + 0.25
  before <- metric_count("computed")
  corrected_result <- yield_walk_forward_rf("DFF", corrected)
  corrected_rng <- .Random.seed
  stopifnot(metric_count("computed") == before + nrow(corrected_result))
  assert_equal(corrected_result, legacy_walk_forward_rf("DFF", corrected), "fold response invalidation")
  assert_equal(.Random.seed, corrected_rng, "corrected fold RNG")

  baseline <- baseline_fit_time + baseline_walk_time
  cold <- cold_fit_time + cold_walk_time
  warm <- warm_fit_time + warm_walk_time
  reduction <- 1 - warm / baseline
  cat(sprintf("PASS: 11 full-sample fits, ECB fit, four walk-forward targets, chapter wiring, invalidation and RNG continuation.\nOriginal model workload: %.3fs; cold cache: %.3fs; warm cache: %.3fs; warm reduction: %.1f%%.\n", baseline, cold, warm, 100 * reduction))
  stopifnot(reduction >= 0.30)
}

run_tests()
