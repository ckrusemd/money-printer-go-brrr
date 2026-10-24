# Audit declared publication packages before a live render, without API calls.
publication_dependencies <- function() {
  packages <- c("bookdown", "rmarkdown", "knitr", "renv", "IRkernel", "IRdisplay", "repr", "plotly")
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
        if (as.character(head) == "library") {
          # library(package, character.only=TRUE) loads a runtime argument;
          # the symbol "package" is not a literal dependency declaration.
          dynamic <- !is.null(args$character.only) && identical(args$character.only, TRUE)
          args <- if (dynamic) list() else args[1L]
        }
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
  paths <- sub("^\\s*-\\s*", "", grep("\\.ipynb$", readLines("_quarto.yml"), value = TRUE))
  for (path in paths) {
    notebook <- jsonlite::read_json(path)
    for (cell in notebook$cells) {
      if (identical(cell$cell_type, "code")) {
        visit(parse(text = paste0(unlist(cell$source), collapse = "")), TRUE)
      }
    }
  }
  for (path in c("money_theme.R", "scripts/book_runtime.R",
                 "scripts/notebooks/bootstrap.R",
                 list.files("scripts/analysis", "\\.R$", full.names = TRUE))) visit(parse(path), TRUE)
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
