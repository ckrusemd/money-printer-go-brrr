# Shared preparation and the chapter's existing random-forest methods.
# Cache only derived results: callers must supply freshly acquired input data.
yield_model_cache <- function(namespace, inputs, compute, packages, code) {
  if (!exists("book_cache_derived", mode = "function")) return(compute())
  book_cache_derived(namespace, inputs, compute, packages = packages, code = code)
}

yield_complete_curve <- function(curve) {
  # Equivalent to na.omit() of the filled wide curve before gathering it.
  incomplete_dates <- unique(curve$date[is.na(curve$value)])
  dplyr::filter(curve, !date %in% incomplete_dates)
}

yield_spread_features <- function(checkboard) {
  # The predictors are identical for every target. Pivot the large pair table
  # once, before joining the much smaller one-year-ahead outcome series.
  checkboard |>
    dplyr::filter(series_id != joined_series) |>
    tidyr::unite(series_id, series_id, joined_series) |>
    dplyr::select(date, series_id, spread) |>
    tidyr::spread(series_id, spread) |>
    dplyr::mutate(one_year_ahead = date + lubridate::years(1))
}

yield_target_features <- function(features, target, levels, descending = FALSE) {
  result <- features |>
    dplyr::left_join(target, by = c("one_year_ahead" = "date")) |>
    dplyr::select(date, value, dplyr::all_of(setdiff(
      names(features), c("date", "one_year_ahead")
    ))) |>
    dplyr::left_join(levels, by = "date")
  if (descending) result <- dplyr::arrange(result, dplyr::desc(date))
  result
}

yield_fit_rf <- function(data, target_name, num_trees = 300,
                         tune_grid = data.frame(mtry = 3),
                         train_control = caret::trainControl(method = "none"),
                         date_column = "date", value_column = "value") {
  clean <- stats::na.omit(data)
  x <- as.data.frame(clean[, setdiff(names(clean), c(date_column, value_column)),
                           drop = FALSE])
  y <- clean[[value_column]]
  yield_model_cache(
    paste0("yield-fit-", target_name),
    inputs = list(x = x, y = y, num_trees = num_trees,
                  tune_grid = tune_grid, train_control = train_control),
    compute = function() caret::train(
      x = x, y = y, method = "rf", tuneGrid = tune_grid,
      ntree = num_trees, metric = "RMSE", trControl = train_control
    ),
    packages = c("caret", "randomForest"),
    code = list(body(yield_fit_rf), body(yield_model_cache))
  )
}

yield_walk_forward_rf <- function(target_name, target_spec, num_trees = 300,
                                  initial_years = 15, test_every_months = 3) {
  # Select month-end observations before complete-case filtering, matching the
  # original chapter (an incomplete month end must not move the origin earlier).
  model_data <- target_spec$data |>
    dplyr::mutate(target_date = date + lubridate::years(1),
                  month = lubridate::floor_date(date, "month")) |>
    dplyr::filter(!is.na(value)) |>
    dplyr::group_by(month) |>
    dplyr::filter(date == max(date)) |>
    dplyr::ungroup() |>
    dplyr::select(-month) |>
    dplyr::arrange(date)
  feature_names <- setdiff(names(model_data), c("date", "target_date", "value"))
  model_data <- model_data[stats::complete.cases(model_data[, feature_names]), ]
  first_origin <- min(model_data$date) + lubridate::years(initial_years)
  origins <- model_data$date[
    model_data$date >= first_origin & !is.na(model_data$value) &
      lubridate::month(model_data$date) %in% seq(1, 12, by = test_every_months)
  ]
  predictors <- as.data.frame(model_data[, feature_names, drop = FALSE])
  results <- lapply(seq_along(origins), function(i) {
    origin <- origins[i]
    train_rows <- which(model_data$target_date <= origin & !is.na(model_data$value))
    test_rows <- which(model_data$date == origin & !is.na(model_data$value))
    if (length(train_rows) < 120 || length(test_rows) != 1) return(NULL)
    x <- predictors[train_rows, , drop = FALSE]
    test_x <- predictors[test_rows, , drop = FALSE]
    rownames(x) <- NULL
    rownames(test_x) <- NULL
    y <- model_data$value[train_rows]
    test <- model_data[test_rows, ]

    # Set the original fold seed outside the cache. The runtime includes the
    # incoming RNG state in the key and replays the outgoing state on a hit.
    set.seed(1971 + i)
    yield_model_cache(
      paste0("yield-fold-", target_name),
      inputs = list(x = x, y = y, test_x = test_x, origin = origin,
                    target_date = test$target_date, actual = test$value,
                    persistence = test[[target_spec$current]],
                    curve_levels = c(test$level_DGS10, test$level_DGS2),
                    num_trees = num_trees, mtry = min(3, length(feature_names))),
      compute = function() {
        fit <- randomForest::randomForest(
          x = x, y = y, ntree = num_trees, mtry = min(3, length(feature_names))
        )
        data.frame(
          target = target_name, origin = origin, target_date = test$target_date,
          actual = test$value,
          random_forest = as.numeric(stats::predict(fit, test_x)),
          persistence = as.numeric(test[[target_spec$current]]),
          curve_regime = ifelse(test$level_DGS10 - test$level_DGS2 < 0,
                                "Inverted", "Normal")
        )
      },
      packages = c("randomForest", "dplyr", "lubridate"),
      code = list(body(yield_walk_forward_rf), body(yield_model_cache))
    )
  })
  dplyr::bind_rows(results)
}
