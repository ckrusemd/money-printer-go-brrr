# Offline transport fixture: use the real ECB URL builder and SDMX parser,
# substituting only httr::GET. Run in the publication image with --network none.
local({
  scratch <- tempfile("ecb-runtime-tests-")
  dir.create(scratch)
  on.exit(unlink(scratch, recursive = TRUE), add = TRUE)
  Sys.setenv(BOOK_SNAPSHOT_MODE = "record", BOOK_AS_OF = "2026-10-11",
             BOOK_SNAPSHOT_DIR = file.path(scratch, "inputs"),
             BOOK_DERIVED_DIR = file.path(scratch, "derived"),
             BOOK_METRICS_FILE = file.path(scratch, "metrics.csv"), BOOK_RESULTS_DIR = "")
  source("scripts/book_runtime.R", local = .GlobalEnv)

  xml <- paste(c(
    '<?xml version="1.0" encoding="UTF-8"?>',
    '<message:GenericData xmlns:message="http://www.sdmx.org/resources/sdmxml/schemas/v2_1/message"',
    ' xmlns:common="http://www.sdmx.org/resources/sdmxml/schemas/v2_1/common"',
    ' xmlns:generic="http://www.sdmx.org/resources/sdmxml/schemas/v2_1/data/generic">',
    '<message:Header><message:ID>ECB-FIXTURE</message:ID><message:Test>true</message:Test>',
    '<message:Prepared>2026-10-11T00:00:00Z</message:Prepared><message:Sender id="ECB"/>',
    '<message:Structure structureID="ECB-FIXTURE" dimensionAtObservation="TIME_PERIOD">',
    '<common:Structure><Ref agencyID="ECB" id="ECB-FIXTURE"/></common:Structure>',
    '</message:Structure></message:Header>',
    '<message:DataSet structureRef="ECB-FIXTURE">',
    '<generic:Series><generic:SeriesKey>',
    '<generic:Value id="FREQ" value="D"/><generic:Value id="REF_AREA" value="U2"/>',
    '<generic:Value id="CURRENCY" value="EUR"/><generic:Value id="FM_ID" value="DFR"/>',
    '</generic:SeriesKey>',
    '<generic:Obs><generic:ObsDimension value="2026-10-09"/><generic:ObsValue value="2.25"/>',
    '<generic:Attributes><generic:Value id="OBS_STATUS" value="A"/></generic:Attributes></generic:Obs>',
    '<generic:Obs><generic:ObsDimension value="2026-10-10"/><generic:ObsValue value="2.50"/>',
    '<generic:Attributes><generic:Value id="OBS_STATUS" value="A"/></generic:Attributes></generic:Obs>',
    '</generic:Series></message:DataSet></message:GenericData>'
  ), collapse = "\n")
  calls <- list()
  original_get <- get("GET", asNamespace("httr"))
  on.exit(assignInNamespace("GET", original_get, ns = "httr"), add = TRUE)
  fixture_get <- function(url, ...) {
    calls[[length(calls) + 1L]] <<- list(url = url, arguments = list(...),
                                       config = getOption("httr_config"))
    structure(list(url = url, status_code = 200L,
                   headers = list(`Content-Type` = "application/xml"),
                   content = charToRaw(xml)), class = "response")
  }
  assignInNamespace("GET", fixture_get, ns = "httr")
  key <- "FM.D.U2.EUR.4F.KR.DFR.LEV"

  # Independent original-provider call proves that the wrapper preserves the
  # entire parsed object, including column names, types and tibble classes.
  original <- ecb::get_data(key = key)
  stopifnot(identical(calls[[1]]$url,
    "https://data-api.ecb.europa.eu/service/data/FM/D.U2.EUR.4F.KR.DFR.LEV?detail=dataonly"))
  original_request <- calls[[1]]
  calls <- list()
  recorded <- book_ecb_data(glue::glue(key))
  stopifnot(identical(recorded, original), nrow(recorded) == 2L,
            identical(class(recorded), c("tbl_df", "tbl", "data.frame")),
            identical(names(recorded), tolower(names(recorded))),
            identical(as.character(recorded$obstime), c("2026-10-09", "2026-10-10")),
            identical(recorded$obsvalue, c(2.25, 2.50)),
            calls[[1]]$config$options$timeout_ms == 30000)
  data_headers <- calls[[1]]$arguments[[1]]$headers
  stopifnot(identical(data_headers, original_request$arguments[[1]]$headers),
            "application/vnd.sdmx.structurespecificdata+xml;version=2.1" %in% unname(data_headers))
  stopifnot(identical(book_ecb_data(key, attempts = 1L), recorded), length(calls) == 1L)
  request_key <- book_hash(list(provider = "ECB observations", parameters = list(key = key, filter = NULL)))
  record <- readRDS(file.path(.book_runtime$snapshots, paste0(request_key, ".rds")))
  stopifnot(identical(record$value, original),
            identical(record$parameters, list(key = key, filter = NULL)),
            identical(record$latest_observation, "2026-10-10"),
            identical(.book_runtime$manifest[[request_key]]$latest_observation, "2026-10-10"),
            !"attempts" %in% names(record$parameters))

  filter <- list(startPeriod = "2026-10-09", endPeriod = "2026-10-10")
  filtered <- book_ecb_data(key, filter = filter)
  stopifnot(identical(filtered, original), length(calls) == 2L,
            identical(calls[[2]]$url, paste0(
              "https://data-api.ecb.europa.eu/service/data/FM/D.U2.EUR.4F.KR.DFR.LEV",
              "?startPeriod=2026-10-09&endPeriod=2026-10-10&detail=dataonly")))
  for (series in c("YC.B.U2.EUR.4F.G_N_A.SV_C_YM.SR_3M",
                   "IRS.M.DK.L.L40.CI.0000.DKK.N.Z",
                   "FM.M.DK.DKK.DS.MM.CIBOR3M.ASKA")) {
    book_ecb_data(series)
    pieces <- strsplit(series, ".", fixed = TRUE)[[1]]
    expected_url <- paste0("https://data-api.ecb.europa.eu/service/data/", pieces[1], "/",
                           paste(pieces[-1], collapse = "."), "?detail=dataonly")
    stopifnot(identical(tail(calls, 1)[[1]]$url, expected_url))
  }

  # Both named and positional transport arguments participate in snapshot
  # identity even though this transport fixture returns the same XML.
  extra_a <- httr::add_headers(`X-Fixture` = "a")
  extra_b <- httr::add_headers(`X-Fixture` = "b")
  # Positional filter is an API argument; use explicitly named filter=NULL
  # for positional dots, just as the original ecb::get_data API requires.
  before <- length(calls)
  with_extra_a <- book_ecb_data(key, filter = NULL, extra_a)
  with_extra_b <- book_ecb_data(key, filter = NULL, extra_b)
  named_extra <- book_ecb_data(key, filter = NULL, config = extra_a)
  stopifnot(length(calls) == before + 3L,
            identical(book_ecb_data(key, filter = NULL, extra_a, attempts = 1L), with_extra_a),
            length(calls) == before + 3L)
  manifest <- readRDS(file.path(.book_runtime$snapshots, "manifest.rds"))
  extra_parameters <- c(list(key = key, filter = NULL), list(extra_a))
  extra_key <- book_hash(list(provider = "ECB observations", parameters = extra_parameters))
  named_key <- book_hash(list(provider = "ECB observations",
                             parameters = c(list(key = key, filter = NULL), list(config = extra_a))))
  stopifnot(extra_key %in% names(manifest$requests), named_key %in% names(manifest$requests),
            identical(manifest$requests[[extra_key]]$parameters, book_redact_parameters(extra_parameters)),
            !identical(extra_key, named_key))

  # Restart the real runtime in replay mode, with all network calls forbidden.
  forbidden_calls <- 0L
  assignInNamespace("GET", function(...) {
    forbidden_calls <<- forbidden_calls + 1L
    stop("NETWORK FORBIDDEN")
  }, ns = "httr")
  rm(".book_runtime", envir = .GlobalEnv)
  Sys.setenv(BOOK_SNAPSHOT_MODE = "replay")
  source("scripts/book_runtime.R", local = .GlobalEnv)
  stopifnot(identical(book_ecb_data(key), original),
            identical(book_ecb_data(key, filter = filter), filtered),
            identical(book_ecb_data(key, filter = NULL, extra_a), with_extra_a),
            identical(book_ecb_data(key, filter = NULL, extra_b), with_extra_b),
            identical(book_ecb_data(key, filter = NULL, config = extra_a), named_extra))
  missing <- try(book_ecb_data("FM.D.UNRECORDED", attempts = 1L), silent = TRUE)
  missing_extra <- try(book_ecb_data(key, filter = NULL,
                                    httr::add_headers(`X-Fixture` = "unrecorded")), silent = TRUE)
  missing_filter <- try(book_ecb_data(key, filter = list(startPeriod = "1900")), silent = TRUE)
  stopifnot(inherits(missing, "try-error"), inherits(missing_extra, "try-error"),
            inherits(missing_filter, "try-error"), forbidden_calls == 0L)

  # Evaluate the chapter's actual local wrapper, excluding only credential
  # setup, then use it to replay the already recorded ECB observation table.
  chapter <- readLines("Chapters/03_InterestRates/InterestRates.Rmd", warn = FALSE)
  start <- which(grepl("^get_ecb_data <- function", chapter))
  end <- which(seq_along(chapter) > start & chapter == "}")[1]
  chapter_env <- new.env(parent = globalenv())
  eval(parse(text = chapter[start:end]), envir = chapter_env)
  stopifnot(identical(chapter_env$get_ecb_data(key), original), forbidden_calls == 0L)

  # Live mode must fail on a provider error rather than publishing an old
  # recorded table. A single attempt avoids waits in this offline fixture.
  rm(".book_runtime", envir = .GlobalEnv)
  Sys.setenv(BOOK_SNAPSHOT_MODE = "live")
  source("scripts/book_runtime.R", local = .GlobalEnv)
  failed <- try(book_ecb_data(key, attempts = 1L), silent = TRUE)
  stopifnot(inherits(failed, "try-error"), forbidden_calls == 1L,
            grepl("Current data unavailable from ECB observations", as.character(failed), fixed = TRUE))
  cat("ECB fixtures passed: original URL/parser, request identity, record/replay, chapter wiring, and live failure.\n")
})
