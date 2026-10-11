"""Reader integration checks; no network requests or R render.

Run: python3 -m unittest discover -s tests -p 'test_reader_output.py' -v
Set BOOK_OUTPUT_DIR to validate a completed book outside the default _book.
Source links use Pandoc's header IDs, not a second implementation of its slugs.
"""

from html.parser import HTMLParser
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import tempfile
import unittest
from urllib.parse import unquote, urlsplit


ROOT = Path(__file__).resolve().parents[1]


class ReaderHTML(HTMLParser):
    def __init__(self, html):
        super().__init__(convert_charrefs=True)
        self.ids = set()
        self.links = []
        self.assets = []
        self.charts = []
        self.feed(html)

    def handle_starttag(self, tag, attributes):
        attrs = dict(attributes)
        if attrs.get("id"):
            self.ids.add(attrs["id"])
        if tag == "a" and attrs.get("href"):
            self.links.append(attrs["href"])
        if tag == "link" and "stylesheet" in attrs.get("rel", "").split():
            self.assets.append(attrs.get("href", ""))
        if tag == "img":
            src = attrs.get("src", "")
            self.assets.append(src)
            if "figure-html/" in unquote(urlsplit(src).path):
                self.charts.append((src, attrs.get("alt", "").strip()))


def local_target(page, url):
    parts = urlsplit(url)
    # Remote assets, mail links, data URLs and site-root links are not files
    # relative to this artifact. Root links require the hosting base URL.
    if parts.scheme or parts.netloc or parts.path.startswith("/"):
        return None
    path = page.parent / unquote(parts.path) if parts.path else page
    return path.resolve(), unquote(parts.fragment)


def check_output(directory):
    """Return actionable local HTML/asset/alt errors for a completed artifact."""
    directory = Path(directory).resolve()
    pages = {
        page.resolve(): ReaderHTML(page.read_text(encoding="utf-8"))
        for page in directory.rglob("*.html")
    }
    errors = []
    for page, document in pages.items():
        for link in document.links:
            target = local_target(page, link)
            if target is None:
                continue
            path, fragment = target
            if path.suffix.lower() != ".html":
                continue
            if not path.is_file():
                errors.append(f"{page.name}: missing link target {link}")
            elif fragment and path in pages and fragment not in pages[path].ids:
                errors.append(f"{page.name}: missing anchor {link}")
        for asset in document.assets:
            if not asset:
                errors.append(f"{page.name}: empty image/stylesheet source")
                continue
            target = local_target(page, asset)
            if target is not None and not target[0].is_file():
                errors.append(f"{page.name}: missing asset {asset}")
        for src, alt in document.charts:
            if not alt:
                errors.append(f"{page.name}: chart lacks descriptive alt text: {src}")
    return errors


def prose(text):
    """Exclude front matter and fenced R code before parsing reader Markdown."""
    lines = text.splitlines()
    if lines and lines[0].strip() == "---":
        end = next(i for i, line in enumerate(lines[1:], 1) if line.strip() == "---")
        lines = lines[end + 1:]
    result = []
    fence = None
    for line in lines:
        match = re.match(r"^\s*(`{3,}|~{3,})", line)
        if match:
            marker = match.group(1)[0]
            if fence is None:
                fence = marker
            elif fence == marker:
                fence = None
        elif fence is None:
            result.append(line)
    return "\n".join(result)


def nodes(value):
    if isinstance(value, dict):
        yield value
        for child in value.values():
            yield from nodes(child)
    elif isinstance(value, list):
        for child in value:
            yield from nodes(child)


class SourceReaderTests(unittest.TestCase):
    @unittest.skipUnless(shutil.which("pandoc"), "Pandoc needed to derive source header IDs")
    def test_published_prose_links_resolve_to_pages_and_anchors(self):
        files = re.findall(r"^\s+-\s+(\S+\.Rmd)\s*$", (ROOT / "_bookdown.yml").read_text(), re.M)
        self.assertTrue(files, "No published chapters found")
        pages = {}
        links = []
        for filename in files:
            parsed = json.loads(subprocess.run(
                ["pandoc", "--from=markdown", "--to=json"],
                input=prose((ROOT / filename).read_text()),
                text=True, capture_output=True, check=True, timeout=10,
            ).stdout)
            elements = list(nodes(parsed))
            headers = [node["c"] for node in elements if node.get("t") == "Header"]
            first = next(header for header in headers if header[0] == 1)
            page = "index.html" if filename == "index.Rmd" else first[1][0] + ".html"
            self.assertNotIn(page, pages, f"Duplicate chapter URL: {page}")
            pages[page] = {header[1][0] for header in headers}
            links.extend((page, node["c"][-1][0]) for node in elements if node.get("t") == "Link")
        reviewed = 0
        for page, link in links:
            parts = urlsplit(link)
            if parts.scheme or parts.netloc or parts.path.startswith("/"):
                continue
            if parts.path and not parts.path.endswith(".html"):
                continue
            target = unquote(parts.path) or page
            with self.subTest(page=page, link=link):
                self.assertIn(target, pages, f"Unpublished page linked from {page}: {link}")
                if parts.fragment:
                    self.assertIn(unquote(parts.fragment), pages[target], f"Missing source anchor: {link}")
            reviewed += 1
        self.assertGreater(reviewed, 0, "No local reader links checked")
        self.assertIn("data-status.html", pages)


class OutputValidatorFixtures(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory()
        self.addCleanup(self.scratch.cleanup)
        self.root = Path(self.scratch.name)
        (self.root / "charts/figure-html").mkdir(parents=True)
        (self.root / "charts/figure-html/price plot.png").write_bytes(b"fixture asset")
        (self.root / "style.css").write_text("img { max-width: 100%; }")
        (self.root / "gallery.html").write_text('<h1 id="gallery-sp500">S&amp;P 500</h1>')

    def validate(self, html):
        (self.root / "index.html").write_text(html)
        return check_output(self.root)

    def test_valid_fragment_encoded_image_css_and_external_links(self):
        errors = self.validate('''
            <link rel="stylesheet" href="style.css?v=1">
            <a href="gallery.html#gallery-sp500">Gallery</a>
            <a href="https://example.org/page.html#remote">External</a>
            <img src="charts/figure-html/price%20plot.png" alt="Opening price in USD">
        ''')
        self.assertEqual(errors, [])

    def test_missing_page(self):
        self.assertIn("missing link target missing.html", "\n".join(self.validate('<a href="missing.html">Missing</a>')))

    def test_missing_anchor(self):
        self.assertIn("missing anchor gallery.html#wrong", "\n".join(self.validate('<a href="gallery.html#wrong">Wrong</a>')))

    def test_same_page_fragment(self):
        self.assertEqual(self.validate('<h1 id="start">Start</h1><a href="#start">Start</a>'), [])
        self.assertIn("missing anchor #wrong", "\n".join(self.validate('<a href="#wrong">Wrong</a>')))

    def test_missing_css_and_chart_image(self):
        errors = self.validate('<link rel="stylesheet" href="absent.css"><img src="charts/figure-html/absent.png" alt="Price">')
        self.assertEqual(sum("missing asset" in error for error in errors), 2)

    def test_missing_or_blank_chart_alt(self):
        for attribute in ("", ' alt="  "'):
            with self.subTest(attribute=attribute):
                errors = self.validate(f'<img src="charts/figure-html/price%20plot.png"{attribute}>')
                self.assertTrue(any("lacks descriptive alt" in error for error in errors))

    def test_relative_link_from_nested_page(self):
        (self.root / "nested").mkdir()
        (self.root / "nested/page.html").write_text('<a href="../gallery.html#gallery-sp500">Gallery</a>')
        self.assertEqual(self.validate('<a href="nested/page.html">Nested</a>'), [])


class PublishedReaderOutputTests(unittest.TestCase):
    def test_completed_book_links_assets_and_chart_alts(self):
        configured = os.environ.get("BOOK_OUTPUT_DIR")
        directory = Path(configured) if configured else ROOT / "_book"
        if not (directory / "index.html").is_file():
            if configured:
                self.fail(f"BOOK_OUTPUT_DIR has no index.html: {directory}")
            self.skipTest("No completed _book output; source and validator fixtures still run")
        for page in ("index.html", "market-chart-gallery.html", "bond-etf-chart-gallery.html",
                     "sector-etf-chart-gallery.html", "data-status.html"):
            self.assertTrue((directory / page).is_file(), f"Missing required reader page: {page}")
        self.assertEqual(check_output(directory), [])


class MarketReaderFixtures(unittest.TestCase):
    def test_fx_placeholder_preserves_other_panels_and_russell_is_optional(self):
        # READER_R_COMMAND can run this fixture in the existing publication
        # container. The default uses local R and skips missing locked packages.
        command = shlex.split(os.environ.get("READER_R_COMMAND", "Rscript --vanilla -"))
        if not command or not shutil.which(command[0]):
            self.skipTest("R fixture runner unavailable")
        script = r'''
packages <- c("ggplot2", "dplyr", "tidyr", "lubridate", "data.table",
              "glue", "gridExtra", "xts", "TTR", "scales")
missing <- packages[!vapply(packages, requireNamespace, logical(1), quietly = TRUE)]
if (length(missing)) {
  cat("Missing locked reader fixture packages:", paste(missing, collapse = ", "), "\n")
  quit(status = 42L)
}
suppressPackageStartupMessages(for (package in packages) library(package, character.only = TRUE))
source("money_theme.R")
book_date <- function() as.Date("2016-12-31")
lines <- readLines("Chapters/04_Markets/Markets.Rmd")
expressions <- list()
active <- FALSE
code <- character()
for (line in lines) {
  if (grepl("^```\\{r", line)) {
    active <- TRUE
    code <- character()
  } else if (active && grepl("^```\\s*$", line)) {
    expressions <- c(expressions, as.list(parse(text = code)))
    active <- FALSE
  } else if (active) code <- c(code, line)
}
definition <- function(name) Filter(function(x) {
  is.call(x) && (identical(x[[1]], as.name("=")) || identical(x[[1]], as.name("<-"))) &&
    identical(x[[2]], as.name(name))
}, expressions)
for (name in c("draw_plots", "get_yahoo_ticker")) eval(definition(name)[[1]])
eval(tail(definition("series_ids_yahoo"), 1)[[1]])
stopifnot("^RUT" %in% series_ids_yahoo)
requests <- 0L
book_yahoo <- function(ticker, env = NULL, attempts = 3L) {
  requests <<- requests + 1L
  stopifnot(identical(ticker, "^RUT"), is.null(env), identical(attempts, 1L))
  xts::xts(matrix(1:12, ncol = 6), order.by = as.Date(c("2016-12-30", "2016-12-31")))
}
prices <- get_yahoo_ticker("^RUT", attempts = 1)
stopifnot(requests == 1L, identical(prices$price, 1:2),
          all(prices$ticker == "^RUT"),
          identical(prices$date, as.Date(c("2016-12-30", "2016-12-31"))))
book_yahoo <- function(...) stop("optional Yahoo fixture unavailable")
stopifnot(is.null(suppressWarnings(get_yahoo_ticker("^RUT", attempts = 1))))

dates <- seq(as.Date("2014-01-01"), book_date(), by = "day")
data <- bind_rows(lapply(c("NOMINAL", "PRICE_INDEX", "CL=F", "SI=F", "GC=F", "USDDKK=X"), function(series) {
  data.frame(date = dates, index = 100 + seq_along(dates) / 100 + sin(seq_along(dates) / 30),
             ticker = "^RUT", currency = "USD", series_id = series)
}))
captured <- NULL
grid.arrange <- function(..., ncol) {
  captured <<- list(...)
  invisible(NULL)
}
capture <- function(input) {
  invisible(suppressWarnings(draw_plots(input)))
  stopifnot(length(captured) == 11L)
  captured
}
present <- capture(data)
missing <- capture(filter(data, series_id != "USDDKK=X"))
stopifnot(identical(ggplot_build(present[[6]])$data[[1]]$y,
                    data$index[data$series_id == "USDDKK=X"]))
stopifnot(identical(ggplot_build(missing[[6]])$data[[1]]$label,
                    "FX comparison data unavailable for this chart"))
for (panel in setdiff(seq_along(present), 6L)) {
  stopifnot(identical(ggplot_build(present[[panel]])$data,
                      ggplot_build(missing[[panel]])$data))
}
for (value in c(NA_real_, Inf)) {
  invalid <- data
  invalid$index[invalid$series_id == "USDDKK=X"] <- value
  plot <- capture(invalid)[[6]]
  stopifnot(identical(ggplot_build(plot)$data[[1]]$label,
                      "FX comparison data unavailable for this chart"))
}
unavailable <- draw_plots(data[FALSE, ])
stopifnot(identical(unavailable$labels$title, "Market data unavailable"))
cat("Russell success/failure, empty/non-finite FX labels, 11 panels and unchanged other panel values passed\n")
'''
        result = subprocess.run(command, input=script, text=True, capture_output=True, cwd=ROOT, timeout=60)
        if result.returncode == 42:
            self.skipTest(result.stdout.strip())
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
