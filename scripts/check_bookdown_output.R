book_dir <- "_book"
expected_pages <- c(
  "index.html",
  "equity-markets-and-the-sp-500.html",
  "market-chart-gallery.html",
  "bond-etf-chart-gallery.html",
  "sector-etf-chart-gallery.html"
)
stopifnot(all(file.exists(file.path(book_dir, expected_pages))))
stopifnot(!any(file.exists(file.path(book_dir, c(
  "foreign-exchange-markets.html",
  "cryptocurrency-markets.html"
)))))

index <- xml2::read_html(file.path(book_dir, "index.html"))
title <- xml2::xml_text(xml2::xml_find_first(index, "//head/title"))
stopifnot(identical(title, "Money Printer Go BRRR"))

page_paths <- list.files(book_dir, pattern = "\\.html$", full.names = TRUE)
for (page_path in page_paths) {
  page <- xml2::read_html(page_path)
  images <- xml2::xml_attr(xml2::xml_find_all(page, "//img[@src]"), "src")
  images <- images[!grepl("^(https?:|data:|/)", images)]
  images <- utils::URLdecode(sub("[?#].*$", "", images))
  missing <- images[!file.exists(file.path(dirname(page_path), images))]
  if (length(missing)) {
    stop("Missing images in ", page_path, ": ", paste(unique(missing), collapse = ", "))
  }
}

cat("Bookdown output checked:", length(page_paths), "pages\n")
