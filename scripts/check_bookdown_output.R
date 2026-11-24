# Offline validation of the complete publication, including widget dependencies.
book_expected_pages <- c(
  "index.html", "economic-release-calendar.html", "data-status.html",
  "leading-economic-indicators.html", "united-states-housing-market.html",
  "danish-housing-market.html", "interest-rates-and-yield-curves.html",
  "equity-markets-and-the-sp-500.html", "market-chart-gallery.html",
  "bond-etf-chart-gallery.html", "sector-etf-chart-gallery.html",
  "etf-tracking-and-analysis.html"
)

check_bookdown_output <- function(book_dir = "_book", expected_pages = book_expected_pages,
                                  check_content = TRUE,
                                  check_chart_alt = TRUE,
                                  site_prefix = "/money-printer-go-brrr/") {
  if (!requireNamespace("xml2", quietly = TRUE)) stop("Missing locked dependency: xml2")
  if (!dir.exists(book_dir)) stop("Missing book directory: ", book_dir)
  root <- normalizePath(book_dir, winslash = "/", mustWork = TRUE)
  issues <- character()
  report <- function(path, message) {
    issues <<- c(issues, paste0(substring(path, nchar(root) + 2L), ": ", message))
  }
  missing <- expected_pages[!file.exists(file.path(root, expected_pages))]
  if (length(missing)) issues <- c(issues, paste("Missing published page:", missing))
  excluded <- c("foreign-exchange-markets.html", "cryptocurrency-markets.html")
  if (any(file.exists(file.path(root, excluded)))) {
    issues <- c(issues, "Unpublished currency/crypto chapter present")
  }
  pages <- list.files(root, "\\.html?$", recursive = TRUE, full.names = TRUE,
                      ignore.case = TRUE)
  if (!length(pages)) stop("No HTML pages in ", root)
  documents <- lapply(pages, xml2::read_html)
  names(documents) <- normalizePath(pages, winslash = "/", mustWork = TRUE)
  targets <- lapply(documents, function(doc) {
    unique(c(xml2::xml_attr(xml2::xml_find_all(doc, "//*[@id]"), "id"),
             xml2::xml_attr(xml2::xml_find_all(doc, "//a[@name]"), "name")))
  })
  # Bookdown's generated 404 sidebar can retain first-page fragment-only URLs
  # with data-path="". Fix those actual links, rather than exempting the 404
  # from validation. A unique destination is required; ambiguous/broken links
  # still fail the checks below. This same repair runs for both benchmark books.
  not_found <- file.path(root, "404.html")
  if (!is.null(documents[[not_found]])) {
    doc <- documents[[not_found]]
    anchors <- xml2::xml_find_all(doc, paste0(
      "//*[contains(concat(' ', normalize-space(@class), ' '), ' book-summary ')]",
      "//li[@data-path='']/a[starts-with(@href, '#')]"
    ))
    repaired <- 0L
    for (anchor in anchors) {
      reference <- xml2::xml_attr(anchor, "href")
      fragment <- utils::URLdecode(sub("^#", "", reference))
      if (!nzchar(fragment) || fragment %in% targets[[not_found]]) next
      destinations <- names(targets)[vapply(targets, function(ids) fragment %in% ids, logical(1))]
      if (length(destinations) != 1L) next
      relative <- substring(destinations[[1L]], nchar(root) + 2L)
      xml2::xml_set_attr(anchor, "href", paste0(relative, reference))
      repaired <- repaired + 1L
    }
    if (repaired) {
      xml2::write_html(doc, not_found)
      documents[[not_found]] <- doc
      cat("Repaired", repaired, "generated 404 sidebar link(s)\n")
    }
  }
  check_reference <- function(reference, from) {
    if (is.na(reference) || !nzchar(trimws(reference))) return(invisible(NULL))
    reference <- trimws(reference)
    if (grepl("^(//|[[:alpha:]][[:alnum:]+.-]*:)", reference)) return(invisible(NULL))
    fragment <- if (grepl("#", reference, fixed = TRUE)) {
      utils::URLdecode(sub("^[^#]*#", "", reference))
    } else ""
    relative <- utils::URLdecode(sub("[?#].*$", "", reference))
    if (!nzchar(relative)) {
      target <- from
    } else if (startsWith(relative, "/")) {
      if (nzchar(site_prefix) && startsWith(relative, site_prefix)) {
        relative <- substring(relative, nchar(site_prefix) + 1L)
      }
      target <- file.path(root, sub("^/+", "", relative))
    } else target <- file.path(dirname(from), relative)
    if (dir.exists(target)) target <- file.path(target, "index.html")
    if (!file.exists(target)) {
      report(from, paste("Missing local target:", reference))
      return(invisible(NULL))
    }
    target <- normalizePath(target, winslash = "/", mustWork = TRUE)
    if (!startsWith(target, paste0(root, "/"))) {
      report(from, paste("Local target escapes publication:", reference))
      return(invisible(NULL))
    }
    if (nzchar(fragment) && !startsWith(fragment, ":~:text=")) {
      fragment <- sub(":~:text=.*$", "", fragment)
      ids <- targets[[target]]
      if (is.null(ids) && grepl("\\.svg$", target, ignore.case = TRUE)) {
        svg <- xml2::read_xml(target)
        ids <- xml2::xml_attr(xml2::xml_find_all(svg, "//*[@id]"), "id")
      }
      if ((!is.null(targets[[target]]) || grepl("\\.svg$", target, ignore.case = TRUE)) &&
          !fragment %in% ids) report(from, paste("Missing fragment:", reference))
    }
    invisible(NULL)
  }
  css_references <- function(css, from) {
    pattern <- "url\\(\\s*(?:\"[^\"]*\"|'[^']*'|[^)]*)\\s*\\)|@import\\s+(?:\"[^\"]*\"|'[^']*')"
    matches <- regmatches(css, gregexpr(pattern, css, perl = TRUE))[[1L]]
    for (match in matches) {
      value <- if (startsWith(match, "url")) {
        sub("\\s*\\)$", "", sub("^url\\(\\s*", "", match))
      } else sub("^@import\\s+", "", match)
      value <- sub("[\"']$", "", sub("^[\"']", "", trimws(value)))
      check_reference(value, from)
    }
  }
  attributes <- c("href", "src", "poster", "data-src", "xlink:href")
  error_pattern <- paste0(
    "(?im)^\\s*(?:##\\s*)?(?:Error(?: in [^\\n]*)?:|Execution halted\\b|",
    "Quitting from lines\\b|Traceback\\s*:)"
  )
  for (path in names(documents)) {
    doc <- documents[[path]]
    visible <- xml2::xml_find_all(doc, "//body//text()[not(ancestor::script or ancestor::style)]")
    if (any(grepl(error_pattern, xml2::xml_text(visible), perl = TRUE)) ||
        length(xml2::xml_find_all(doc, "//*[contains(concat(' ', normalize-space(@class), ' '), ' r-error ')]"))) {
      report(path, "Exposed render error")
    }
    ids <- xml2::xml_attr(xml2::xml_find_all(doc, "//*[@id]"), "id")
    if (anyDuplicated(ids[nzchar(ids)])) report(path, "Duplicate fragment IDs")
    sources <- xml2::xml_attr(xml2::xml_find_all(doc, "//*[@src]"), "src")
    if (any(!nzchar(trimws(sources)))) report(path, "Empty src attribute")
    images <- xml2::xml_find_all(doc, "//img")
    image_sources <- xml2::xml_attr(images, "src")
    chart <- !is.na(image_sources) & grepl("(^|/)figure-html/", utils::URLdecode(image_sources))
    alternatives <- xml2::xml_attr(images[chart], "alt")
    if (check_chart_alt && any(is.na(alternatives) | !nzchar(trimws(alternatives)))) {
      report(path, "Missing or empty alt description for rendered figure-html chart")
    }
    nodes <- xml2::xml_find_all(doc, "//*")
    for (attribute in attributes) {
      refs <- xml2::xml_attr(nodes, attribute)
      for (reference in refs[!is.na(refs)]) check_reference(reference, path)
    }
    for (reference in xml2::xml_attr(xml2::xml_find_all(doc, "//object[@data]"), "data")) {
      check_reference(reference, path)
    }
    for (srcset in xml2::xml_attr(xml2::xml_find_all(doc, "//*[@srcset]"), "srcset")) {
      srcset <- gsub("data:[^[:space:]]+(?:\\s+[0-9.]+[wx])?", "", srcset, perl = TRUE)
      entries <- trimws(strsplit(srcset, ",", fixed = TRUE)[[1L]])
      for (entry in entries[nzchar(entries)]) {
        check_reference(sub("\\s+[0-9.]+[wx]\\s*$", "", entry, perl = TRUE), path)
      }
    }
    for (style in xml2::xml_attr(xml2::xml_find_all(doc, "//*[@style]"), "style")) {
      css_references(style, path)
    }
    for (style in xml2::xml_text(xml2::xml_find_all(doc, "//style"))) css_references(style, path)
  }
  for (css in list.files(root, "\\.css$", recursive = TRUE, full.names = TRUE)) {
    text <- paste(readLines(css, warn = FALSE), collapse = "\n")
    text <- gsub("(?s)/\\*.*?\\*/", "", text, perl = TRUE)
    css_references(text, css)
  }
  if (check_content) {
    index <- documents[[file.path(root, "index.html")]]
    if (!is.null(index) && !identical(xml2::xml_text(xml2::xml_find_first(index, "//head/title")),
                                    "Money Printer Go BRRR")) {
      report(file.path(root, "index.html"), "Unexpected book title")
    }
    etf <- documents[[file.path(root, "etf-tracking-and-analysis.html")]]
    if (!is.null(etf) && (!"danish-fund-tax" %in% targets[[file.path(root, "etf-tracking-and-analysis.html")]] ||
                         !grepl("aktiesparekonto", xml2::xml_text(etf), ignore.case = TRUE))) {
      report(file.path(root, "etf-tracking-and-analysis.html"), "Missing Danish fund-tax coverage")
    }
  }
  if (length(issues)) stop(paste(c("Bookdown output validation failed:", unique(issues)), collapse = "\n"),
                          call. = FALSE)
  cat("Bookdown output checked:", length(pages), "pages and local dependencies\n")
  invisible(length(pages))
}

if (sys.nframe() == 0L) {
  args <- commandArgs(trailingOnly = TRUE)
  check_bookdown_output(if (length(args)) args[[1L]] else "_book")
}
