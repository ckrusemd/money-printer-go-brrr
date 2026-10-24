# Pure DST adapter: sourcing this file never opens a database or collects data.
fetch_dst_table <- function(cfg, lang="da", transport=NULL) {
  options <- if (is.null(transport)) list() else list(transport=transport)
  meta <- do.call(dstcollect::dst_metadata,c(list(table=cfg$table,lang=lang),options))
  query <- cfg$query
  if (!is.null(cfg$filters)) for (id in names(cfg$filters)) query[[id]] <- cfg$filters[[id]]
  bundle <- do.call(dstcollect::dst_collect,c(list(table=cfg$table,selection=query,
    lang=lang,metadata=meta),options))
  result <- dstcollect::dst_legacy_series(bundle,series_cols=cfg$series_cols,code_labels=TRUE)
  ids <- attr(result,"canonical_series_id")
  # Keep the notebook's existing external database aliases exactly.
  result$series <- trimws(gsub("_+","_",gsub("[^A-Za-z0-9_.-]","_",result$series)))
  aliases <- unique(data.frame(alias=result$series,canonical=ids))
  if (anyDuplicated(aliases$alias)) stop("Cleaned database series alias collision")
  keep <- !is.na(result$value)
  result <- result[keep,,drop=FALSE]
  attr(result,"canonical_series_id") <- ids[keep]
  result
}
