# Explicit compatibility views for existing consumers. New callers use codes.
#' Compatibility data view for the existing book and collector
#' @param x A single-table dst_bundle.
#' @param dimension_order Requested source dimensions in output order.
#' @param code_labels Include code prefixes, matching dkstat's overlap behavior.
#' @return A data.frame with uppercase source fields, TID and value.
#' @export
dst_legacy_data <- function(x,dimension_order=NULL,code_labels=FALSE) {
  if (length(unique(x$data$table_id))!=1L) stop("Legacy view requires one table")
  if (is.null(dimension_order)) dimension_order <- x$dimensions$dimension_id[!x$dimensions$is_time]
  dimension_order <- toupper(dimension_order)
  out <- data.frame(row.names=seq_len(nrow(x$data)))
  for (id in setdiff(dimension_order,"TID")) {
    d <- x$series_dimensions[toupper(x$series_dimensions$dimension_id)==id,,drop=FALSE]
    codes <- d$category_code[match(x$data$series_id,d$series_id)]
    dict <- x$categories[toupper(x$categories$dimension_id)==id,,drop=FALSE]
    labels <- dict$label[match(codes,dict$category_code)]
    out[[id]] <- if (code_labels) paste(codes,labels) else labels
  }
  # Preserve the installed legacy client's Copenhagen-midnight timestamps.
  # Canonical data uses Date boundaries and does not inherit this convention.
  out$TID <- as.POSIXct(as.character(x$data$period_start),tz="Europe/Copenhagen"); out$value <- x$data$value
  if (anyNA(out$TID)) stop("Legacy date interface cannot represent this table's periods")
  # Legacy CSV ordering is category order followed by ascending time.
  order_fields <- lapply(setdiff(dimension_order,"TID"),function(id) {
    dict <- x$categories[toupper(x$categories$dimension_id)==id,,drop=FALSE]
    labels <- if (code_labels) paste(dict$category_code,dict$label) else dict$label
    match(out[[id]],labels)
  })
  indices <- do.call(order,c(order_fields,list(out$TID)))
  out <- out[indices,c(setdiff(dimension_order,"TID"),"TID","value"),drop=FALSE]
  attr(out,"series_id") <- x$data$series_id[indices]
  rownames(out) <- NULL; out
}

#' Metadata view for existing dkstat consumers
#' @param x A metadata bundle.
#' @return A list with basics, variables and values components.
#' @export
dst_legacy_metadata <- function(x) {
  m <- x$tables$metadata[[1L]]
  variables <- data.frame(id=x$dimensions$dimension_id,text=x$dimensions$label,
    elimination=x$dimensions$eliminable,time=x$dimensions$is_time)
  values <- stats::setNames(lapply(variables$id,function(id) {
    c <- x$categories[x$categories$dimension_id==id,,drop=FALSE]
    data.frame(id=c$category_code,text=c$label,stringsAsFactors=FALSE)
  }),variables$id)
  basics <- m; basics$variables <- NULL; basics$text <- m$text %or% m$description
  list(basics=basics,variables=variables,values=values)
}

#' Preserve the collection notebook's external series aliases
#' @param x A bundle.
#' @param series_cols Dimensions forming the historical series alias; NULL uses the table ID.
#' @param code_labels Include historical code prefixes.
#' @return A data.frame with series, date and value; alias collisions are rejected.
#' @export
dst_legacy_series <- function(x,series_cols=NULL,code_labels=FALSE) {
  view <- dst_legacy_data(x,code_labels=code_labels)
  alias <- rep(x$data$table_id,nrow(x$data))
  for (id in series_cols) alias <- paste(alias,view[[toupper(id)]],sep="_")
  pairs <- unique(data.frame(alias=alias,series_id=attr(view,"series_id")))
  if (anyDuplicated(pairs$alias)) stop("Legacy alias collision; include all varying dimensions in series_cols")
  result <- data.frame(series=alias,date=as.Date(view$TID,tz="Europe/Copenhagen"),value=view$value)
  attr(result,"canonical_series_id") <- attr(view,"series_id")
  result
}
