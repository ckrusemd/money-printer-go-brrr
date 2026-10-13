# Audit declared publication packages before a live render, without API calls.
publication_dependencies <- function() {
  packages <- c("bookdown", "rmarkdown", "knitr", "renv")
  visit <- function(expression, declarations = FALSE) {
    if (!is.call(expression) && !is.expression(expression) && !is.pairlist(expression)) return()
    if (is.call(expression)) {
      head <- expression[[1L]]
      if (is.symbol(head) && as.character(head) %in% c("::", ":::")) {
        packages <<- c(packages, as.character(expression[[2L]]))
      }
      if (declarations && is.symbol(head) &&
          as.character(head) %in% c("book_load_packages", "library")) {
        args <- as.list(expression)[-1L]
        if (as.character(head) == "library") args <- args[1L]
        for (argument in args) {
          if (is.symbol(argument) || is.character(argument)) packages <<- c(packages, as.character(argument))
        }
      }
    }
    children <- as.list(expression)
    for (i in seq_along(children)) {
      # Empty formal defaults and df[, column] contain R's missing-argument
      # sentinel. Passing it to visit() would turn into an absent argument.
      if (!identical(children[[i]], quote(expr = ))) visit(children[[i]], declarations)
    }
  }
  paths <- sub("^\\s*-\\s*", "", grep("\\.Rmd$", readLines("_bookdown.yml"), value = TRUE))
  for (path in paths) {
    code <- tempfile(fileext = ".R")
    knitr::purl(path, output = code, quiet = TRUE, documentation = 0L)
    visit(parse(code), TRUE)
    unlink(code)
  }
  for (path in c("money_theme.R", "scripts/book_runtime.R",
                 list.files("scripts/analysis", "\\.R$", full.names = TRUE))) visit(parse(path))
  sort(unique(packages))
}

check_publication_dependencies <- function() {
  packages <- publication_dependencies()
  lock <- renv::lockfile_read("renv/publication.lock")
  standard <- rownames(installed.packages(priority = c("base", "recommended")))
  unrecorded <- setdiff(packages, c(names(lock$Packages), standard))
  missing <- packages[!vapply(packages, requireNamespace, logical(1), quietly = TRUE)]
  if (length(unrecorded) || length(missing)) {
    stop("Publication dependency audit failed. Unrecorded: ", paste(unrecorded, collapse = ", "),
         "; missing: ", paste(missing, collapse = ", "))
  }
  cat("Audited", length(packages), "declared publication dependencies\n")
  invisible(packages)
}

if (sys.nframe() == 0L) check_publication_dependencies()
