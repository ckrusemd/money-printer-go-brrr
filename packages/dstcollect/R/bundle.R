# Every endpoint returns the same typed components. Labels never form keys.
empty_bundle <- function() {
  chr <- character(); date <- as.Date(character())
  structure(list(
    data = tibble::tibble(table_id=chr, series_id=chr, period_code=chr,
      period_start=date, period_end=date, frequency=chr, value=double(),
      source_status=chr, unit=chr, index_base=chr, request_id=chr),
    series = tibble::tibble(table_id=chr, series_id=chr),
    series_dimensions = tibble::tibble(table_id=chr, series_id=chr,
      dimension_id=chr, category_code=chr),
    dimensions = tibble::tibble(table_id=chr, dimension_id=chr, label=chr,
      language=chr, position=integer(), is_time=logical(), eliminable=logical()),
    categories = tibble::tibble(table_id=chr, dimension_id=chr,
      category_code=chr, label=chr, language=chr, position=integer()),
    concepts = tibble::tibble(table_id=chr, series_id=chr, dimension_id=chr,
      category_code=chr, concept=chr, concept_code=chr, relationship=chr,
      mapping_version=chr, evidence=chr),
    subjects = tibble::tibble(subject_id=chr, parent_id=chr, label=chr, language=chr),
    tables = tibble::tibble(table_id=chr, label=chr, unit=chr, updated=chr,
      active=logical(), language=chr, metadata=list()),
    requests = tibble::tibble(request_id=chr, endpoint=chr, language=chr,
      retrieved_at=chr, parameters=list(), response=list())
  ), class=c("dst_bundle", "list"))
}

`%or%` <- function(x, y) if (is.null(x)) y else x
scalar <- function(x, default=NA_character_) if (is.null(x) || !length(x)) default else as.character(x[[1L]])
hash <- function(x) digest::digest(x, algo="sha256", serialize=FALSE)
json <- function(x) jsonlite::toJSON(x, auto_unbox=TRUE, null="null", digits=NA)
row_bind <- function(xs) {
  if (!length(xs)) return(NULL)
  do.call(rbind, xs)
}

#' Combine metadata-preserving StatBank bundles
#' @param ... Bundles returned by a dstcollect endpoint.
#' @return A dst_bundle. Conflicting duplicate observation keys are rejected.
#' @export
dst_bind <- function(...) {
  xs <- list(...)
  if (length(xs)==1L && is.list(xs[[1L]]) && !inherits(xs[[1L]], "dst_bundle")) xs <- xs[[1L]]
  stopifnot(all(vapply(xs, inherits, logical(1), "dst_bundle")))
  out <- empty_bundle()
  for (name in names(out)) {
    parts <- lapply(xs, `[[`, name)
    out[[name]] <- row_bind(c(list(out[[name]]), parts))
    # List columns contain raw metadata; use serialized row identities.
    if (nrow(out[[name]])) {
      if (any(vapply(out[[name]],is.list,logical(1)))) {
        keys <- vapply(seq_len(nrow(out[[name]])), function(i)
          digest::digest(out[[name]][i,,drop=FALSE], algo="sha256"), character(1))
        keep <- !duplicated(keys)
      } else keep <- !duplicated(out[[name]])
      out[[name]] <- out[[name]][keep,,drop=FALSE]
    }
  }
  d <- out$data
  if (nrow(d)) {
    key <- paste(d$series_id, d$period_code, sep="\r")
    dup <- which(duplicated(key)); first <- match(key[dup],key)
    equal <- function(a,b) (is.na(a) & is.na(b)) | (!is.na(a) & !is.na(b) & a==b)
    if (any(!equal(d$value[dup],d$value[first]) | !equal(d$source_status[dup],d$source_status[first]) |
            !equal(d$unit[dup],d$unit[first])))
      stop("Conflicting observations for one series and period", call.=FALSE)
    out$data <- d[!duplicated(key),,drop=FALSE]
  }
  out
}

#' View observations with their source dimensions
#' @param x A dst_bundle.
#' @param dimensions Either "none", "codes" or "labels". Expanded fields use source dimension IDs.
#' @param concepts Include unambiguous curated concept columns prefixed with concept_.
#' @return A tibble with the common observation columns and optional dimensions.
#' @export
dst_as_tibble <- function(x, dimensions=c("none", "codes", "labels"), concepts=FALSE) {
  stopifnot(inherits(x, "dst_bundle"))
  dimensions <- match.arg(dimensions); out <- x$data
  if (dimensions!="none") {
    for (id in unique(x$series_dimensions$dimension_id)) {
      m <- x$series_dimensions[x$series_dimensions$dimension_id==id,,drop=FALSE]
      vals <- m$category_code
      if (dimensions=="labels") {
        dict <- x$categories[x$categories$dimension_id==id,,drop=FALSE]
        dict_key <- paste(dict$table_id, dict$category_code, sep="\r")
        vals <- dict$label[match(paste(m$table_id, m$category_code, sep="\r"), dict_key)]
      }
      out[[id]] <- vals[match(out$series_id, m$series_id)]
    }
  }
  if (concepts) for (id in unique(x$concepts$concept)) {
    m <- x$concepts[x$concepts$concept==id,,drop=FALSE]
    if (anyDuplicated(m$series_id)) stop("Ambiguous concept: ", id)
    out[[paste0("concept_",id)]] <- m$concept_code[match(out$series_id,m$series_id)]
  }
  out
}

#' @export
print.dst_bundle <- function(x, ...) {
  cat("<dst_bundle> ",nrow(x$data)," observations; ",nrow(x$series)," series; ",
      nrow(x$tables)," table metadata rows\n",sep="")
  mapped <- unique(paste(x$concepts$series_id,x$concepts$dimension_id))
  cat(length(mapped),"of",nrow(x$series_dimensions),"series dimensions have curated concept mappings\n")
  print(utils::head(x$data)); invisible(x)
}
