# Portable notebook paths. Source this file by absolute path, or bootstrap from
# a checkout ancestor. RESEARCH_REPO_ROOT selects another checkout (absolute).
# Relative overrides resolve from the checkout, never from the current cwd.
# RESEARCH_DB_PATH: datacollection/data/financial_data.duckdb
# RESEARCH_OUTPUT_DIR: datacollection (save helpers append output/date/type)
# RESEARCH_ENV_FILE: optional explicit dotenv file; no credential file by default.
# RESEARCH_REPORT_HELPER / RESEARCH_CORPORATE_DB_HELPER / RESEARCH_LOGGER_HELPER:
# optional R scripts, sourced lazily only by research_call_integration().

.research_default_root <- local({
  files <- vapply(sys.frames(), function(frame) {
    if (is.null(frame$ofile)) "" else as.character(frame$ofile)
  }, character(1))
  files <- files[nzchar(files)]
  if (!length(files)) stop("Source scripts/research_paths.R by its checkout path.")
  dirname(dirname(normalizePath(utils::tail(files, 1L), mustWork = TRUE)))
})

research_is_absolute <- function(path) grepl("^(/|[A-Za-z]:[/\\\\]|\\\\\\\\)", path)

research_repo_root <- function() {
  configured <- Sys.getenv("RESEARCH_REPO_ROOT", "")
  if (!nzchar(configured)) return(.research_default_root)
  configured <- path.expand(configured)
  if (!research_is_absolute(configured)) {
    stop("Set RESEARCH_REPO_ROOT to an absolute checkout path.", call. = FALSE)
  }
  normalizePath(configured, mustWork = TRUE)
}

research_path <- function(default, env_var = NULL) {
  path <- if (is.null(env_var)) default else Sys.getenv(env_var, default)
  if (!nzchar(path)) path <- default
  path <- path.expand(path)
  if (!research_is_absolute(path)) path <- file.path(research_repo_root(), path)
  normalizePath(path, mustWork = FALSE)
}

research_load_env <- function() {
  if (!nzchar(Sys.getenv("RESEARCH_ENV_FILE", ""))) return(invisible(FALSE))
  path <- research_path("", "RESEARCH_ENV_FILE")
  if (!file.exists(path)) stop("RESEARCH_ENV_FILE does not exist: ", path, call. = FALSE)
  if (!requireNamespace("dotenv", quietly = TRUE)) {
    stop("Install dotenv to load RESEARCH_ENV_FILE, or set variables in the process environment.", call. = FALSE)
  }
  dotenv::load_dot_env(path)
  invisible(TRUE)
}

research_load_theme <- function(envir = parent.frame()) {
  # Load the repository theme's prerequisite explicitly, independent of cwd.
  sys.source(research_path("scripts/book_runtime.R"), envir = envir)
  sys.source(research_path("money_theme.R"), envir = envir)
  theme <- get("theme_money_printer_go_brrr", envir = envir)
  # Research plots call the theme without a size; keep ggplot's usual default.
  formals(theme)$base_size <- 11
  assign("theme_money_printer_go_brrr", theme, envir = envir)
  invisible(NULL)
}

research_call_integration <- function(kind, function_name, ...) {
  variables <- c(report = "RESEARCH_REPORT_HELPER",
                 corporate_db = "RESEARCH_CORPORATE_DB_HELPER",
                 logger = "RESEARCH_LOGGER_HELPER")
  if (!kind %in% names(variables)) stop("Unknown research integration: ", kind, call. = FALSE)
  variable <- variables[[kind]]
  if (!nzchar(Sys.getenv(variable, ""))) {
    stop("Optional ", kind, " integration is not configured. Set ", variable,
         " to an R helper defining ", function_name, ", or skip this integration.", call. = FALSE)
  }
  path <- research_path("", variable)
  if (!file.exists(path)) stop(variable, " helper does not exist: ", path, call. = FALSE)
  integration <- new.env(parent = .GlobalEnv)
  tryCatch(sys.source(path, envir = integration), error = function(error) {
    stop("Cannot load ", variable, " helper at ", path, ": ", conditionMessage(error), call. = FALSE)
  })
  if (!exists(function_name, envir = integration, mode = "function", inherits = FALSE)) {
    stop(variable, " helper must define function ", function_name, ": ", path, call. = FALSE)
  }
  arguments <- list(...)
  if (kind == "report" && !is.null(arguments$template_path) &&
      !file.exists(arguments$template_path)) {
    stop("Report template does not exist: ", arguments$template_path,
         ". Set RESEARCH_REPORT_TEMPLATE to an existing template.", call. = FALSE)
  }
  tryCatch(do.call(get(function_name, envir = integration, inherits = FALSE), arguments),
           error = function(error) {
    stop("Optional ", kind, " integration failed in ", function_name, ": ",
         conditionMessage(error), ". Check ", variable, " and the integration configuration.",
         call. = FALSE)
  })
}

research_connect_database <- function(path = research_path(
    "datacollection/data/financial_data.duckdb", "RESEARCH_DB_PATH"),
    read_only = FALSE, connector = NULL) {
  if (read_only && !file.exists(path)) {
    stop("Research database not found: ", path,
         ". Run 01_etl.ipynb first or set RESEARCH_DB_PATH to an existing database.", call. = FALSE)
  }
  if (!read_only && !dir.exists(dirname(path))) {
    if (!dir.create(dirname(path), recursive = TRUE, showWarnings = FALSE)) {
      stop("Cannot create database directory: ", dirname(path), ". Check RESEARCH_DB_PATH and permissions.", call. = FALSE)
    }
  }
  if (is.null(connector)) {
    if (!requireNamespace("DBI", quietly = TRUE) || !requireNamespace("duckdb", quietly = TRUE)) {
      stop("Install the locked DBI and duckdb packages before opening RESEARCH_DB_PATH.", call. = FALSE)
    }
    connector <- function(path, read_only) {
      DBI::dbConnect(duckdb::duckdb(), dbdir = path, read_only = read_only)
    }
  }
  tryCatch(connector(path, read_only), error = function(error) {
    stop("Cannot open research database at ", path, ": ", conditionMessage(error),
         ". Close other database users or restart their kernels, then reopen normally",
         " so DuckDB can recover its WAL. Check RESEARCH_DB_PATH and permissions.",
         " WAL, lock, database and backup files are preserved; no automatic recovery is attempted.",
         call. = FALSE)
  })
}
