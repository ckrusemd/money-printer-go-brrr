suppressPackageStartupMessages(library(ggplot2))
definitions <- parse("money_theme.R")
for (name in c("book_dark_geom_defaults", "theme_money_void")) {
  definition <- Filter(function(x) is.call(x) && identical(x[[1L]], as.name("<-")) &&
                         identical(x[[2L]], as.name(name)), definitions)
  stopifnot(length(definition) == 1L)
  eval(definition[[1L]])
}
x <- data.frame(x = 1:4, y = c(2, 5, 3, 7), series = c("A", "A", "B", "B"))
build <- function(plot) ggplot_build(plot)$data[[1L]]
plain <- ggplot(x, aes(x, y)) + geom_line()
explicit <- ggplot(x, aes(x, y)) + geom_line(colour = "#f4b860")
mapped <- ggplot(x, aes(x, y, colour = series)) + geom_line()
coordinates <- build(plain)[, c("x", "y")]
mapped_before <- build(mapped)
book_dark_geom_defaults()
stopifnot(identical(coordinates, build(plain)[, c("x", "y")]),
          identical(mapped_before, build(mapped)),
          all(build(explicit)$colour == "#f4b860"))
luminance <- function(colour) {
  rgb <- as.numeric(col2rgb(colour)) / 255
  sum(c(.2126, .7152, .0722) * ifelse(rgb <= .04045, rgb / 12.92, ((rgb + .055) / 1.055)^2.4))
}
contrast <- function(a, b) {
  values <- sort(c(luminance(a), luminance(b)))
  (values[2] + .05) / (values[1] + .05)
}
stopifnot(contrast(build(plain)$colour[1], "#17223a") >= 4.5)
reference <- build(ggplot(x, aes(x, y)) + geom_hline(yintercept = 0))
stopifnot(all(reference$yintercept == 0), contrast(reference$colour[1], "#17223a") >= 4.5)
placeholder <- theme_money_void()
stopifnot(luminance(placeholder$plot.background$fill) < .05,
          contrast(placeholder$text$colour, placeholder$plot.background$fill) >= 4.5)
cat("Dark chart contrast, preserved coordinates and explicit/mapped colours passed\n")
