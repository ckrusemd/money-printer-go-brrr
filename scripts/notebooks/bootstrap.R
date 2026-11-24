# Explicit first cell in every publication notebook; no package installation.
notebook_root <- function() {
  path <- normalizePath(getwd())
  repeat {
    if (file.exists(file.path(path, "_quarto.yml"))) return(path)
    parent <- dirname(path)
    if (identical(parent, path)) stop("Open this notebook inside the project checkout")
    path <- parent
  }
}
setwd(notebook_root())
if (!isTRUE(getOption("book.environment.verified"))) {
  source("scripts/notebooks/environment.R", local = TRUE)
  options(book.environment.verified = TRUE)
}
source("scripts/book_runtime.R")
suppressPackageStartupMessages(library(ggplot2))
suppressPackageStartupMessages(library(lubridate))
suppressPackageStartupMessages(library(scales))
source("money_theme.R")
options(scipen = 999, repr.plot.width = 10, repr.plot.height = 7, repr.plot.res = 120)
if (.book_runtime$mode != "replay") {
  key <- Sys.getenv("FRED_API")
  if (nzchar(key)) fredr::fredr_set_key(key)
}

# Supply rich output with complete JS/CSS dependencies, including in IRkernel.
# Standalone srcdoc avoids relative widget dependencies in VS Code and Pages.
repr_html.htmlwidget <- function(obj, ...) {
  path <- tempfile(fileext = ".html")
  on.exit(unlink(c(path, sub("\\.html$", "_files", path)), recursive = TRUE))
  htmlwidgets::saveWidget(obj, path, selfcontained = TRUE)
  html <- paste(readLines(path, warn = FALSE), collapse = "\n")
  description <- getOption("book.figure.alt", "Interactive chart or table; use its controls to explore the displayed observations")
  paste0('<iframe title="', htmltools::htmlEscape(description, attribute = TRUE),
         '" style="width:100%;height:650px;border:0" srcdoc="',
         htmltools::htmlEscape(html, attribute = TRUE), '"></iframe>')
}
registerS3method("repr_html", "htmlwidget", repr_html.htmlwidget, envir = asNamespace("repr"))

book_display_table <- function(data) IRdisplay::display_html(as.character(
  knitr::kable(data, format = "html", row.names = FALSE)))

book_display_text <- function(text) IRdisplay::display_markdown(text)
