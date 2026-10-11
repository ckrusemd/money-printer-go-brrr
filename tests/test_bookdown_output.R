source("scripts/check_bookdown_output.R")
source("scripts/check_sources.R")
source("scripts/benchmark_book.R")

local({
  root <- tempfile("book-output-tests-")
  dir.create(root)
  on.exit(unlink(root, recursive = TRUE), add = TRUE)
  dir.create(file.path(root, "assets"))
  dir.create(file.path(root, "nested"))
  writeLines("asset", file.path(root, "assets", "chart space.png"))
  writeLines("console.log('Error: invisible code');", file.path(root, "assets", "widget.js"))
  writeLines("svg { fill: url(#gradient); }", file.path(root, "assets", "unused.txt"))
  writeLines('<svg xmlns="http://www.w3.org/2000/svg"><g id="gradient"/></svg>',
             file.path(root, "assets", "chart.svg"))
  writeLines("body { background: url('chart%20space.png'); }", file.path(root, "assets", "site.css"))
  html <- function(body, head = "") paste0("<!DOCTYPE html><html><head><title>Money Printer Go BRRR</title>",
                                          head, "</head><body>", body, "</body></html>")
  home <- paste0('<h1 id="home">Book</h1><a href="nested/page.html?x=1#plot">Plot</a>',
                 '<a href="/money-printer-go-brrr/nested/page.html#plot">Root</a>',
                 '<img src="assets/chart%20space.png" alt="Chart" ',
                 'srcset="data:image/png;base64,AAAA 1x, assets/chart%20space.png 2x">',
                 '<script src="assets/widget.js"></script>',
                 '<iframe src="nested/page.html"></iframe>',
                 '<a href="assets/chart.svg#gradient">SVG</a>',
                 '<a href="https://example.invalid/missing">External</a>',
                 '<a href="mailto:example@example.invalid">Email</a>')
  write_home <- function(body = home) writeLines(html(body, '<link href="assets/site.css" rel="stylesheet">'),
                                                file.path(root, "index.html"))
  write_home()
  writeLines(html('<h2 id="plot">Plot</h2><a name="legacy"></a><a href="../index.html#home">Home</a>'),
             file.path(root, "nested", "page.html"))
  validate <- function() check_bookdown_output(root, expected_pages = "index.html", check_content = FALSE)
  expect_failure <- function(pattern, run = validate) {
    error <- tryCatch({ run(); NULL }, error = identity)
    stopifnot(inherits(error, "error"), grepl(pattern, conditionMessage(error), fixed = TRUE))
  }
  stopifnot(validate() == 2L)
  for (bad in c('<a href="missing.html">Missing page</a>',
                '<script src="assets/missing.js"></script>',
                '<img src="/assets/missing.png">',
                '<source srcset="assets/missing.png 2x">',
                '<video poster="assets/missing.png"></video>',
                '<object data="assets/missing.pdf"></object>')) {
    write_home(paste0(home, bad))
    expect_failure("Missing local target")
  }
  write_home(paste0(home, '<a href="nested/page.html#missing">Bad fragment</a>'))
  expect_failure("Missing fragment")
  write_home(paste0(home, '<a href="#missing">Same-page fragment</a>'))
  expect_failure("Missing fragment")
  write_home(paste0(home, '<h2 id="home">Duplicate</h2>'))
  expect_failure("Duplicate fragment IDs")
  for (empty in c('<img src="">', '<script src=" "></script>', '<iframe src=""></iframe>')) {
    write_home(paste0(home, empty))
    expect_failure("Empty src attribute")
  }
  dir.create(file.path(root, "assets", "figure-html"))
  writeLines("chart", file.path(root, "assets", "figure-html", "chart.png"))
  for (alt in c("", 'alt=""', 'alt="  "')) {
    write_home(paste0(home, '<img src="assets/figure-html/chart.png" ', alt, '>'))
    expect_failure("alt description")
    stopifnot(check_bookdown_output(root, expected_pages="index.html", check_content=FALSE,
                                    check_chart_alt=FALSE) == 2L)
  }
  write_home(paste0(home, '<img src="assets/figure-html/chart.png" alt="US yield curve">'))
  stopifnot(validate() == 2L)
  for (error in c("## Error in model(x): missing data", "Execution halted", "Quitting from lines 4-8")) {
    write_home(paste0(home, "<pre><code>", error, "</code></pre>"))
    expect_failure("Exposed render error")
  }
  write_home()
  writeLines(html('<div class="book-summary"><ul><li class="chapter" data-path=""><a href="#home">Home</a></li></ul></div>'),
             file.path(root, "404.html"))
  stopifnot(validate() == 3L)
  repaired <- xml2::read_html(file.path(root, "404.html"))
  stopifnot(identical(xml2::xml_attr(xml2::xml_find_first(repaired, "//a"), "href"), "index.html#home"))
  writeLines(html('<div class="book-summary"><li data-path=""><a href="#missing">Missing</a></li></div>'),
             file.path(root, "404.html"))
  expect_failure("Missing fragment")
  unlink(file.path(root, "404.html"))
  writeLines(html('<pre>## Error: nested failure</pre>'), file.path(root, "nested", "page.html"))
  expect_failure("Exposed render error")
  writeLines(html('<h2 id="plot">Plot</h2>'), file.path(root, "nested", "page.html"))
  writeLines("@import 'missing.css';", file.path(root, "assets", "site.css"))
  expect_failure("Missing local target")
  writeLines("body { background: url('../assets/missing.png'); }", file.path(root, "assets", "site.css"))
  expect_failure("Missing local target")
  writeLines("/* url(missing.png) */ body { background: url('chart%20space.png'); }",
             file.path(root, "assets", "site.css"))
  outside <- tempfile("outside-")
  writeLines("outside", outside)
  on.exit(unlink(outside), add = TRUE)
  if (file.symlink(outside, file.path(root, "assets", "escape.txt"))) {
    write_home(paste0(home, '<a href="assets/escape.txt">Escape</a>'))
    expect_failure("escapes publication")
  }
  write_home()
  expect_failure("Missing published page", function() {
    check_bookdown_output(root, expected_pages = c("index.html", "missing.html"), check_content = FALSE)
  })
  writeLines(html("<p>Unpublished</p>"), file.path(root, "cryptocurrency-markets.html"))
  expect_failure("Unpublished currency/crypto")
  unlink(file.path(root, "cryptocurrency-markets.html"))
  stopifnot(validate() == 2L)

  rmd <- file.path(root, "syntax.Rmd")
  writeLines(c("Inline `r 1 + 1`", "```{python}", "not R syntax", "```",
               "```{r eval=FALSE}", "x <- 1 + 2", "```", "~~~{r}", "y <- x", "~~~"), rmd)
  stopifnot(check_rmd_syntax(rmd) == 2L)
  writeLines(c("```{r eval=FALSE}", "x <- )", "```"), rmd)
  expect_failure("chunk starting line", function() check_rmd_syntax(rmd))
  writeLines("Inline `r 1 + )`", rmd)
  expect_failure("inline line", function() check_rmd_syntax(rmd))
  writeLines(c("```{r}", "x <- 1"), rmd)
  expect_failure("Unclosed code fence", function() check_rmd_syntax(rmd))

  baseline <- file.path(root, "baseline")
  optimized <- file.path(root, "optimized")
  dir.create(baseline)
  dir.create(optimized)
  model <- data.frame(target = "DFF", prediction = seq_len(10000) / 10000)
  saveRDS(model, file.path(baseline, "rf_backtest-001.rds"))
  slightly <- model
  slightly$prediction[1L] <- slightly$prediction[1L] + 1e-9
  saveRDS(slightly, file.path(optimized, "rf_backtest-001.rds"))
  stopifnot(!length(book_compare_numeric(baseline, optimized)))
  wrong <- model
  wrong$prediction[1L] <- wrong$prediction[1L] + 1e-6
  saveRDS(wrong, file.path(optimized, "rf_backtest-001.rds"))
  stopifnot(length(book_compare_numeric(baseline, optimized)) == 1L)
  renamed <- model
  renamed$target <- "DGS10"
  stopifnot(!book_numeric_equal(model, renamed))
  stopifnot(!book_numeric_equal(c(NA_real_, 1), c(1, NA_real_)))
  stopifnot(!book_numeric_equal(c(Inf, 1), c(-Inf, 1)))
  saveRDS(model, file.path(optimized, "rf_backtest-001.rds"))
  saveRDS(data.frame(best_corr_value_30 = 0.5), file.path(baseline, "df_ccfs-001.rds"))
  saveRDS(data.frame(best_corr_value_30 = 0.4), file.path(optimized, "df_ccfs-001.rds"))
  stopifnot(!length(book_compare_numeric(baseline, optimized)),
            length(book_compare_numeric(baseline, optimized, correlations = TRUE)) == 1L)
  saveRDS(model, file.path(optimized, "rf_backtest-002.rds"))
  stopifnot(length(book_compare_numeric(baseline, optimized)) == 1L)

  for (checkout in c(baseline, optimized)) {
    dir.create(file.path(checkout, "scripts"))
    writeLines("# replay-capable fixture marker", file.path(checkout, "scripts/book_runtime.R"))
  }
  inputs <- file.path(root, "inputs")
  dir.create(inputs)
  saveRDS(list(value = 1), file.path(inputs, "fixture.rds"))
  writeLines("2026-10-11", file.path(inputs, "as-of.txt"))
  unsafe <- file.path(baseline, ".cache", "unused", "..", "..", "tracked-output")
  expect_failure("must be under .cache/", function() benchmark_book(baseline, optimized, inputs, unsafe))
  stopifnot(!dir.exists(file.path(baseline, "tracked-output")))
  expect_failure("must not be written into provider snapshots", function() {
    benchmark_book(baseline, optimized, inputs, file.path(inputs, "output"))
  })
  expect_failure("differs from the snapshot recording date", function() {
    benchmark_book(baseline, optimized, inputs, file.path(root, "date-mismatch"), as_of = "2026-10-10")
  })

  if (requireNamespace("bookdown", quietly = TRUE) && file.exists("scripts/book_runtime.R")) {
    # A real tiny offline Bookdown render proves that the subprocess installs
    # the runtime hooks and saves complete numeric outputs before comparison.
    tiny <- file.path(root, "tiny-book")
    dir.create(tiny)
    dir.create(file.path(tiny, "scripts"))
    stopifnot(file.copy("scripts/book_runtime.R", file.path(tiny, "scripts/book_runtime.R")))
    writeLines(c("rmd_files:", "  - index.Rmd", "delete_merged_file: true"), file.path(tiny, "_bookdown.yml"))
    writeLines(c("---", 'title: "Money Printer Go BRRR"', "output: bookdown::gitbook", "---",
                 "# Money Printer Go BRRR", "```{r include=FALSE}",
                 'df_ccfs <- data.frame(x1="a", x2="b", best_corr_value_30=0.5)',
                 'rf_backtest <- data.frame(target="DFF", prediction=c(1, 2, 3))',
                 'rf_metrics <- rf_regime_metrics <- rf_live_forecast <- rf_backtest',
                 'dff_rf_has_skill <- FALSE', "```", 'Frozen date: `r book_date()`.',
                 "# Another fixture", "No provider requests."),
               file.path(tiny, "index.Rmd"))
    manifest_inputs <- file.path(root, "manifest-inputs")
    dir.create(manifest_inputs)
    saveRDS(list(schema_version=1L, as_of=as.Date("2026-10-11"), requests=list(), failures=list()),
            file.path(manifest_inputs, "manifest.rds"))
    validator <- file.path(root, "tiny-validator.R")
    checker <- normalizePath("scripts/check_bookdown_output.R", mustWork=TRUE)
    writeLines(c(paste0("source(", encodeString(checker, quote='"'), ")"),
                 'book_expected_pages <- "index.html"'), validator)
    config <- list(root=tiny, snapshots=manifest_inputs, as_of="2026-10-11",
                   derived=file.path(root, "tiny-derived"), metrics=file.path(root, "tiny-metrics.csv"),
                   numeric=file.path(root, "tiny-numeric"), validator=validator)
    config_path <- file.path(root, "tiny-config.rds")
    saveRDS(config, config_path)
    runner <- file.path(root, "tiny-child.R")
    harness <- normalizePath("scripts/benchmark_book.R", mustWork=TRUE)
    writeLines(c(paste0("source(", encodeString(harness, quote='"'), ")"),
                 paste0("book_benchmark_render(", encodeString(config_path, quote='"'), ")")), runner)
    log <- file.path(root, "tiny-render.log")
    status <- system2(file.path(R.home("bin"), "Rscript"), c("--vanilla", shQuote(runner)), stdout=log, stderr=log)
    if (status != 0L) {
      cat(paste(readLines(log, warn=FALSE), collapse="\n"), "\n")
      not_found <- file.path(tiny, "_book", "404.html")
      if (file.exists(not_found)) {
        page <- xml2::read_html(not_found)
        anchors <- xml2::xml_find_all(page, "//a[starts-with(@href, '#')]")
        for (anchor in anchors) cat(as.character(xml2::xml_parent(anchor)), "\n")
      }
      stop("Tiny offline benchmark render failed")
    }
    stopifnot(length(list.files(config$numeric, "\\.rds$")) == 6L,
              identical(readRDS(file.path(config$numeric, "rf_backtest-001.rds")),
                        data.frame(target="DFF", prediction=c(1, 2, 3))),
              identical(readRDS(file.path(config$numeric, "dff_rf_has_skill-001.rds")), FALSE))
  }
})
cat("Book output and syntax fixtures passed\n")
