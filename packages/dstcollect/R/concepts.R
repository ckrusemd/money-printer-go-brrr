map_concepts <- function(x) {
  mappings <- utils::read.csv(system.file("concepts.csv",package="dstcollect"),
    colClasses="character",check.names=FALSE,na.strings=NULL)
  m <- merge(x$series_dimensions,mappings,by=c("table_id","dimension_id","category_code"),sort=FALSE)
  out <- empty_bundle()$concepts
  if (nrow(m)) out <- tibble::as_tibble(m[names(out)])
  out
}

apply_measure_units <- function(x) {
  unit_codes <- c("m2"="m2","antal"="count","number"="count","indeks"="index",
    "index"="index","pct."="percent","per cent"="percent","percent"="percent","%"="percent")
  codes <- unname(unit_codes[tolower(x$data$unit_label)])
  known <- !is.na(codes)
  x$data$unit[known] <- codes[known]
  m <- x$concepts[x$concepts$concept=="measure",,drop=FALSE]
  measure <- m$concept_code[match(x$data$series_id,m$series_id)]
  # Table-level units may say "Indeks" even when selected cells are changes.
  percent <- !is.na(measure) & measure %in% c("period_change_percent","year_change_percent")
  x$data$unit[percent] <- "percent"
  explicit_base <- regexpr("[12][0-9]{3}\\s*=\\s*100",x$data$unit_label,perl=TRUE)
  has_base <- !is.na(explicit_base) & explicit_base>0L
  x$data$index_base[has_base] <- sub("\\s*=.*$","",regmatches(x$data$unit_label,explicit_base))
  x$data$index_base[percent] <- NA_character_
  x
}
