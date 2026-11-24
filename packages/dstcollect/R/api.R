#' @importFrom utils head tail
NULL

# Transport accepts/returns plain R lists, so recording and offline replay need
# no HTTP mocking or private credentials. Only the four public v1 APIs are used.
api_transport <- function(endpoint, parameters) {
  req <- httr2::request(paste0("https://api.statbank.dk/v1/", endpoint))
  req <- httr2::req_body_json(req, parameters, auto_unbox=TRUE)
  req <- httr2::req_timeout(req, 30)
  req <- httr2::req_retry(req, max_tries=3, max_seconds=90,
    retry_on_failure=TRUE, is_transient=function(resp) httr2::resp_status(resp) %in% c(408,429,500,502,503,504))
  resp <- httr2::req_perform(req)
  # StatBank currently sends text/json rather than application/json.
  result <- httr2::resp_body_json(resp, simplifyVector=FALSE, check_type=FALSE)
  if (!is.null(result$errorType) || (!is.null(result$error) && is.null(result$dataset)))
    stop("StatBank API error: ", scalar(result$message %or% result$error), call.=FALSE)
  result
}

request_bundle <- function(endpoint, parameters, transport) {
  if (!parameters$lang %in% c("da","en")) stop("lang must be da or en",call.=FALSE)
  response <- transport(endpoint, parameters)
  out <- empty_bundle()
  retrieved <- format(Sys.time(),tz="UTC",format="%Y-%m-%dT%H:%M:%OS6Z")
  out$requests <- tibble::tibble(request_id=hash(paste(endpoint,json(parameters),retrieved,sep="\n")),
    endpoint=endpoint, language=parameters$lang,
    retrieved_at=retrieved,
    parameters=list(parameters), response=list(response))
  out
}

table_rows <- function(items, lang) row_bind(lapply(items,function(m) tibble::tibble(
  table_id=toupper(scalar(m$id)), label=scalar(m$text %or% m$description),
  unit=scalar(m$unit),updated=scalar(m$updated),active=as.logical(m$active %or% NA),
  language=lang,metadata=list(m))))

#' Discover StatBank subjects
#' @param subjects Subject codes; NULL selects the root.
#' @param recursive Include descendant subjects.
#' @param include_tables Include tables in the response.
#' @param lang Label language, da or en.
#' @param transport Injectable function(endpoint, parameters) returning parsed JSON.
#' @return A dst_bundle.
#' @export
dst_subjects <- function(subjects=NULL, recursive=FALSE, include_tables=TRUE,
                         lang="da", transport=api_transport) {
  p <- list(format="JSON",lang=lang,recursive=recursive,includeTables=include_tables)
  if (!is.null(subjects)) p$subjects <- as.list(as.character(subjects))
  out <- request_bundle("subjects",p,transport)
  walk <- function(nodes,parent=NA_character_) for (m in nodes) {
    if (isTRUE(m$type=="table") || (!is.null(m$unit) && is.null(m$subjects))) {
      out$tables <<- rbind(out$tables,table_rows(list(m),lang))
    } else {
      out$subjects <<- rbind(out$subjects,tibble::tibble(subject_id=scalar(m$id),parent_id=parent,label=scalar(m$description %or% m$text),language=lang))
      if (length(m$tables)) out$tables <<- rbind(out$tables,table_rows(m$tables,lang))
      walk(m$subjects %or% m$children,scalar(m$id))
    }
  }
  walk(out$requests$response[[1L]]); out
}

#' Discover or search StatBank tables
#' @param subjects Optional subject codes.
#' @param past_days Only tables updated within this number of days.
#' @param include_inactive Include discontinued tables.
#' @param lang Label language.
#' @param transport Injectable transport.
#' @return A dst_bundle.
#' @export
dst_tables <- function(subjects=NULL,past_days=NULL,include_inactive=FALSE,lang="da",transport=api_transport) {
  p <- list(format="JSON",lang=lang,includeInactive=include_inactive)
  if (!is.null(subjects)) p$subjects <- as.list(as.character(subjects))
  if (!is.null(past_days)) p$pastdays <- past_days
  out <- request_bundle("tables",p,transport)
  rows <- table_rows(out$requests$response[[1L]],lang)
  if (!is.null(rows)) out$tables <- rows
  out
}

#' Search table titles and IDs without regular-expression interpretation
#' @param text Search string.
#' @param ... Arguments to dst_tables.
#' @return A filtered dst_bundle, retaining request provenance.
#' @export
dst_search <- function(text,...) {
  out <- dst_tables(...)
  keep <- grepl(tolower(text),tolower(paste(out$tables$table_id,out$tables$label)),fixed=TRUE)
  out$tables <- out$tables[keep,,drop=FALSE]; out
}

#' Retrieve table metadata and category dictionaries
#' @param table StatBank table ID.
#' @param lang Label language.
#' @param transport Injectable transport.
#' @return A dst_bundle with typed dimension/category tables.
#' @export
dst_metadata <- function(table,lang="da",transport=api_transport) {
  out <- request_bundle("tableinfo",list(table=toupper(table),format="JSON",lang=lang),transport)
  m <- out$requests$response[[1L]]
  if (is.null(m$id) || is.null(m$variables)) stop("Malformed table metadata",call.=FALSE)
  out$tables <- table_rows(list(m),lang)
  for (i in seq_along(m$variables)) {
    v <- m$variables[[i]]
    out$dimensions <- rbind(out$dimensions,tibble::tibble(table_id=toupper(m$id),
      dimension_id=v$id,label=scalar(v$text),language=lang,position=as.integer(i),
      is_time=isTRUE(v$time),eliminable=isTRUE(v$elimination)))
    for (j in seq_along(v$values)) {
      a <- v$values[[j]]
      out$categories <- rbind(out$categories,tibble::tibble(table_id=toupper(m$id),
        dimension_id=v$id,category_code=as.character(a$id),label=scalar(a$text),language=lang,position=as.integer(j)))
    }
  }
  out
}

#' Create an explicit selection scaffold
#' @param x A metadata bundle.
#' @return Named list selecting every category; narrow it before collection.
#' @export
dst_query <- function(x) stats::setNames(rep(list("*"),nrow(x$dimensions)),x$dimensions$dimension_id)
