periods <- function(codes) {
  if (anyDuplicated(codes)) {
    parsed <- periods(unique(codes))
    return(parsed[match(codes,parsed$period_code),,drop=FALSE])
  }
  start <- end <- as.Date(rep(NA_character_,length(codes))); frequency <- rep("unknown",length(codes))
  for (i in seq_along(codes)) {
    x <- codes[[i]]; s <- e <- as.Date(NA); f <- "unknown"
    if (grepl("^[0-9]{4}$",x)) {
      s <- as.Date(paste0(x,"-01-01")); e <- as.Date(paste0(as.integer(x)+1L,"-01-01"))-1; f <- "annual"
    } else if (grepl("^[0-9]{4}[KQ][1-4]$",x)) {
      y <- substr(x,1,4); q <- as.integer(substr(x,6,6)); m <- (q-1L)*3L+1L
      s <- as.Date(sprintf("%s-%02d-01",y,m)); e <- seq(s,by="3 months",length.out=2)[2]-1; f <- "quarterly"
    } else if (grepl("^[0-9]{4}M(0[1-9]|1[0-2])$",x)) {
      s <- as.Date(paste0(substr(x,1,4),"-",substr(x,6,7),"-01")); e <- seq(s,by="month",length.out=2)[2]-1; f <- "monthly"
    } else if (grepl("^[0-9]{4}H[12]$",x)) {
      s <- as.Date(paste0(substr(x,1,4),if (substr(x,6,6)=="1") "-01-01" else "-07-01"))
      e <- seq(s,by="6 months",length.out=2)[2]-1; f <- "half_yearly"
    } else if (grepl("^[0-9]{4}M(0[1-9]|1[0-2])D[0-3][0-9]$",x)) {
      s <- suppressWarnings(as.Date(paste0(substr(x,1,4),"-",substr(x,6,7),"-",substr(x,9,10)),format="%Y-%m-%d"))
      e <- s; if (!is.na(s)) f <- "daily"
    } else if (grepl("^[0-9]{4}-[0-9]{2}-[0-9]{2}$",x)) {
      s <- suppressWarnings(as.Date(x,format="%Y-%m-%d")); e <- s; if (!is.na(s)) f <- "daily"
    }
    # Unfamiliar or week-calendar codes are intentionally retained unparsed:
    # an ISO week convention cannot safely be assumed for arbitrary tables.
    start[i] <- s; end[i] <- e; frequency[i] <- f
  }
  tibble::tibble(period_code=codes,period_start=start,period_end=end,frequency=frequency)
}

resolve_selection <- function(meta,selection) {
  dims <- meta$dimensions$dimension_id
  if (!is.list(selection) || is.null(names(selection)) || anyDuplicated(toupper(names(selection))))
    stop("selection must be a uniquely named list of dimension codes",call.=FALSE)
  ids <- dims[match(toupper(names(selection)),toupper(dims))]
  if (anyNA(ids) || !setequal(ids,dims)) stop("Explicitly select every metadata dimension; use dst_query() as a scaffold",call.=FALSE)
  names(selection) <- ids
  for (id in dims) {
    chosen <- as.character(selection[[id]])
    if (!length(chosen) || anyNA(chosen)) stop("Empty or missing selection: ",id)
    all <- meta$categories$category_code[meta$categories$dimension_id==id]
    result <- character()
    for (token in chosen) {
      if (token %in% all) found <- token
      else if (token=="(1)" || token=="(-1)") found <- if (token=="(1)") tail(all,1L) else head(all,1L)
      else if (grepl("[()]",token)) stop("Only latest/first period selectors (1) and (-1) are supported; API calculations are not supported")
      else if (startsWith(token,">=") || startsWith(token,"<=")) {
        parts <- regmatches(token,gregexpr("(?:>=|<=)[^<>]+",token,perl=TRUE))[[1L]]
        if (!length(parts) || paste(parts,collapse="")!=token) stop("Unsupported range: ",token)
        keep <- rep(TRUE,length(all))
        for (part in parts) {
          at <- match(substring(part,3L),all)
          if (is.na(at)) stop("Range boundary is absent from metadata: ",part)
          keep <- keep & if (startsWith(part,">=")) seq_along(all)>=at else seq_along(all)<=at
        }
        found <- all[keep]
      } else if (grepl("*",token,fixed=TRUE)) {
        found <- all[grepl(utils::glob2rx(token),all)]
      } else stop("Unknown category code ",token," for ",id,"; inspect dst_metadata()")
      if (!length(found)) stop("Selection matched no categories for ",id)
      result <- union(result,found)
    }
    selection[[id]] <- all[all %in% result]
  }
  selection[dims]
}

decode_values <- function(x,n,missing=NA_real_) {
  if (is.null(x)) return(rep(missing,n))
  if (!is.null(names(x))) {
    indices <- suppressWarnings(as.integer(names(x)))+1L
    if (anyNA(indices) || any(indices<1L | indices>n)) stop("Invalid sparse JSON-stat indices")
    out <- rep(missing,n)
    out[indices] <- vapply(x,function(v) if (is.null(v)) missing else v[[1L]],missing)
  } else if (length(x)==1L && n>1L && is.character(missing)) out <- rep(as.character(x[[1L]]),n)
  else {
    if (length(x)!=n) stop("JSON-stat value count does not match dimensions")
    out <- vapply(x,function(v) if (is.null(v)) missing else v[[1L]],missing)
  }
  out
}

decode_dataset <- function(meta,response,request_id,lang) {
  d <- response$dataset
  if (is.null(d) && identical(response$class,"dataset")) d <- response
  if (is.null(d$dimension) || is.null(d$value)) stop("Malformed JSON-stat dataset")
  dim <- d$dimension; ids <- as.character(unlist(dim$id %or% d$id)); sizes <- as.integer(unlist(dim$size %or% d$size))
  if (!length(ids) || length(ids)!=length(sizes) || any(sizes<1L)) stop("Invalid JSON-stat dimensions")
  codes <- lapply(ids,function(id) {
    idx <- dim[[id]]$category$index
    vals <- if (is.null(names(idx))) as.character(unlist(idx)) else names(idx)[order(as.integer(unlist(idx)))]
    if (!length(vals)) stop("Missing JSON-stat category index: ",id)
    vals
  }); names(codes) <- ids
  if (!identical(as.integer(lengths(codes)),sizes)) stop("JSON-stat category sizes disagree")
  time <- as.character(unlist(dim$role$time %or% d$role$time))
  if (!length(time)) time <- meta$dimensions$dimension_id[meta$dimensions$is_time]
  if (length(time)!=1L || !time %in% ids) stop("Expected one explicit time dimension")
  grid <- expand.grid(rev(codes),KEEP.OUT.ATTRS=FALSE,stringsAsFactors=FALSE)[ids]
  non_time <- sort(setdiff(ids,time)); table <- meta$tables$table_id[[1L]]
  # Hash each distinct tuple once, independent of response dimension ordering.
  tuples <- unique(grid[non_time]); tuple_json <- apply(tuples,1L,function(v) json(as.list(stats::setNames(v,non_time))))
  tuple_keys <- function(frame) do.call(paste0,lapply(frame,function(v) paste0(nchar(v,type="bytes"),":",v)))
  keys <- tuple_keys(grid[non_time])
  series <- paste0(table,":",vapply(tuple_json,function(v) hash(paste(table,v,sep="\n")),character(1)))
  series_id <- series[match(keys,tuple_keys(tuples))]
  out <- empty_bundle(); out$series <- tibble::tibble(table_id=table,series_id=series)
  for (id in non_time) out$series_dimensions <- rbind(out$series_dimensions,tibble::tibble(
    table_id=table,series_id=series,dimension_id=id,category_code=as.character(tuples[[id]])))
  for (id in ids) {
    category <- dim[[id]]$category
    if (!id %in% meta$dimensions$dimension_id) out$dimensions <- rbind(out$dimensions,tibble::tibble(
      table_id=table,dimension_id=id,label=scalar(dim[[id]]$label),language=lang,
      position=as.integer(match(id,ids)),is_time=id==time,eliminable=FALSE))
    missing_codes <- setdiff(codes[[id]],meta$categories$category_code[meta$categories$dimension_id==id])
    for (code in missing_codes) out$categories <- rbind(out$categories,tibble::tibble(
      table_id=table,dimension_id=id,category_code=code,label=scalar(category$label[[code]],code),language=lang,
      position=as.integer(match(code,codes[[id]]))))
  }
  p <- periods(as.character(grid[[time]])); values <- decode_values(d$value,nrow(grid))
  status <- decode_values(d$status,nrow(grid),NA_character_)
  status[is.na(status)] <- ifelse(is.na(values[is.na(status)]),"missing","observed")
  unit <- rep(meta$tables$unit[[1L]],nrow(grid))
  for (id in as.character(unlist(dim$role$metric %or% d$role$metric))) {
    u <- dim[[id]]$category$unit
    if (!is.null(u)) for (code in names(u)) unit[grid[[id]]==code] <- scalar(u[[code]]$base)
  }
  out$data <- tibble::tibble(table_id=table,series_id=series_id,period_code=p$period_code,
    period_start=p$period_start,period_end=p$period_end,frequency=p$frequency,
    value=as.numeric(values),source_status=as.character(status),unit=unit,
    index_base=rep(NA_character_,length(unit)),request_id=request_id)
  out
}

#' Collect observations through bounded JSON-stat requests
#' @param table StatBank table ID.
#' @param selection Named list of codes for every metadata dimension.
#' @param lang Label language.
#' @param max_cells Conservative per-request cell budget, default 500000.
#' @param transport Injectable transport returning parsed API JSON.
#' @param metadata Optional previously retrieved metadata bundle.
#' @return A dst_bundle; partial collections and mixed updates are rejected.
#' @export
dst_collect <- function(table,selection,lang="da",max_cells=500000,transport=api_transport,metadata=NULL) {
  if (length(max_cells)!=1L || !is.finite(max_cells) || max_cells<10) stop("max_cells must be finite and at least 10")
  meta <- metadata %or% dst_metadata(table,lang,transport)
  if (!inherits(meta,"dst_bundle") || !identical(meta$tables$table_id,toupper(table)) ||
      !identical(meta$tables$language,lang)) stop("Metadata table/language mismatch")
  selection <- resolve_selection(meta,selection)
  time <- meta$dimensions$dimension_id[meta$dimensions$is_time]
  if (length(time)!=1L) stop("Expected one time dimension")
  pending <- list(selection); chunks <- list()
  while (length(pending)) {
    query <- pending[[1L]]; pending <- pending[-1L]
    size <- prod(as.double(lengths(query)))*(length(query)+1L)
    if (size>max_cells) {
      candidates <- c(time,setdiff(names(query),time)); candidates <- candidates[lengths(query[candidates])>1L]
      if (!length(candidates)) stop("Cell budget too small for one observation")
      id <- candidates[[1L]]; at <- ceiling(length(query[[id]])/2)
      a <- b <- query; a[[id]] <- head(query[[id]],at); b[[id]] <- tail(query[[id]],-at)
      pending <- c(list(a,b),pending); next
    }
    chunks[[length(chunks)+1L]] <- query
  }
  outputs <- list(meta)
  for (query in chunks) {
    variables <- lapply(names(query),function(id) list(code=id,values=as.list(query[[id]])))
    part <- request_bundle("data",list(table=toupper(table),format="JSONSTAT",lang=lang,
      valuePresentation="Code",variables=variables),transport)
    decoded <- decode_dataset(meta,part$requests$response[[1L]],part$requests$request_id[[1L]],lang)
    outputs[[length(outputs)+1L]] <- dst_bind(part,decoded)
  }
  check <- dst_metadata(table,lang,transport)
  if (!identical(meta$tables$updated,check$tables$updated) ||
      !identical(meta$categories[,c("dimension_id","category_code")],check$categories[,c("dimension_id","category_code")]))
    stop("Table changed during collection; retry the complete request",call.=FALSE)
  out <- dst_bind(c(outputs,list(check)))
  out$concepts <- map_concepts(out)
  out <- apply_measure_units(out)
  out$data <- out$data[order(out$data$series_id,out$data$period_code),,drop=FALSE]
  out
}
