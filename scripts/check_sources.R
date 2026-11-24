# Parse without executing sources or installing dependencies. Safe on offline PRs.
check_rmd_syntax <- function(path) {
  lines <- readLines(path, warn = FALSE)
  fence <- NULL
  is_r <- FALSE
  begin <- 0L
  chunks <- 0L
  parse_lines <- function(code, label) {
    tryCatch(parse(text = code, keep.source = FALSE), error = function(e) {
      stop(path, " (", label, "): ", conditionMessage(e), call. = FALSE)
    })
  }
  for (i in seq_along(lines)) {
    line <- lines[[i]]
    if (is.null(fence)) {
      match <- regexec("^\\s*(`{3,}|~{3,})(.*)$", line, perl = TRUE)
      parts <- regmatches(line, match)[[1L]]
      if (length(parts)) {
        fence <- parts[[2L]]
        is_r <- grepl("^\\s*(\\{[rR](?:[ ,}]|$)|[rR]\\s*$)", parts[[3L]], perl = TRUE)
        begin <- i
      } else {
        inline <- regmatches(line, gregexpr("`r[[:space:]]+[^`]+`", line, perl = TRUE))[[1L]]
        for (expression in inline) {
          parse_lines(sub("`$", "", sub("^`r[[:space:]]+", "", expression)), paste("inline line", i))
        }
      }
    } else if (grepl(paste0("^\\s*", substr(fence, 1L, 1L), "{", nchar(fence), ",}\\s*$"),
                     line, perl = TRUE)) {
      if (is_r) {
        code <- if (i > begin + 1L) lines[seq.int(begin + 1L, i - 1L)] else character()
        parse_lines(code, paste("chunk starting line", begin))
        chunks <- chunks + 1L
      }
      fence <- NULL
    }
  }
  if (!is.null(fence)) stop(path, ": Unclosed code fence at line ", begin, call. = FALSE)
  invisible(chunks)
}

check_sources <- function(root = ".") {
  files <- list.files(root, "\\.(R|Rmd|ipynb)$", recursive = TRUE, full.names = TRUE,
                      ignore.case = TRUE)
  files <- files[!grepl("/(\\.git|\\.cache|_book|renv/library|renv/cache|renv/staging)/", files)]
  if (!length(files)) stop("No R sources found in ", root)
  for (file in files) {
    if (grepl("\\.ipynb$", file, ignore.case = TRUE)) {
      notebook <- jsonlite::read_json(file)
      if (!identical(tolower(notebook$metadata$kernelspec$language), "r")) next
      for (i in seq_along(notebook$cells)) {
        cell <- notebook$cells[[i]]
        if (!identical(cell$cell_type, "code")) next
        tryCatch(parse(text = paste0(unlist(cell$source), collapse = "")), error = function(e) {
          stop(file, " cell ", i, ": ", conditionMessage(e), call. = FALSE)
        })
      }
    } else if (grepl("\\.Rmd$", file, ignore.case = TRUE)) check_rmd_syntax(file)
    else tryCatch(parse(file = file, keep.source = FALSE), error = function(e) {
      stop(file, ": ", conditionMessage(e), call. = FALSE)
    })
  }
  cat("Parsed", length(files), "R/R Markdown sources without execution\n")
  invisible(length(files))
}

if (sys.nframe() == 0L) {
  args <- commandArgs(trailingOnly = TRUE)
  check_sources(if (length(args)) args[[1L]] else ".")
}
