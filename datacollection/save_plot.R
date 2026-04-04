# save_png_plot.R
# Standard R function for saving ggplot objects as high-quality PNG files

#' Save ggplot object as PNG with customizable aspect ratio and DPI
#' 
#' This function saves a ggplot object as a PNG file with precise control over
#' dimensions, aspect ratio, and resolution.
#' 
#' @param plot_object A ggplot object to save
#' @param filename Character string for output filename. If NULL, uses plot object name
#' @param width_ratio Numeric, width component of aspect ratio (default: 16)
#' @param height_ratio Numeric, height component of aspect ratio (default: 9)
#' @param dpi Numeric, dots per inch for resolution (default: 300)
#' @param base_size Numeric, base size units for scaling (default: 50)
#' 
#' @return Invisible NULL. Saves PNG file and prints confirmation message.
#' 
#' @examples
#' # Basic usage
#' save_plot_png(my_plot)
#' 
#' # Custom filename and square aspect ratio
#' save_plot_png(my_plot, "analysis_results.png", 1, 1)
#' 
#' # High resolution for publication
#' save_plot_png(my_plot, "figure1.png", dpi = 600)
#' 
#' @export
save_plot_png <- function(plot_object, 
                         filename = NULL, 
                         width_ratio = 16, 
                         height_ratio = 9, 
                         dpi = 100,
                         base_size = 72) {
  
  # Load required library
  if (!requireNamespace("ggplot2", quietly = TRUE)) {
    stop("ggplot2 package is required but not installed.")
  }
  
  # If no filename provided, use the name of the plot object
  if (is.null(filename)) {
    filename <- paste0(deparse(substitute(plot_object)), ".png")
  }
  
  # Ensure filename ends with .png
  if (!grepl("\\.png$", filename, ignore.case = TRUE)) {
    filename <- paste0(filename, ".png")
  }
  
  # Calculate pixels based on aspect ratio and DPI
  # Using base_size as a scaling factor
  width_px <- width_ratio * base_size * (dpi / 100)
  height_px <- height_ratio * base_size * (dpi / 100)
  
  # Convert pixels to inches for ggsave
  width_in <- width_px / dpi
  height_in <- height_px / dpi
  
  # Save the plot
  ggplot2::ggsave(filename = filename,
                  plot = plot_object,
                  width = width_in,
                  height = height_in,
                  units = "in",
                  dpi = dpi)
  
  # Print confirmation message
  cat("✅ Plot saved as:", filename, "\n")
  cat("   Aspect ratio:", width_ratio, ":", height_ratio, "\n")
  cat("   Dimensions:", round(width_px), "x", round(height_px), "pixels (", 
      round(width_in, 2), "x", round(height_in, 2), "inches) at", dpi, "DPI\n")
  
  # Return invisibly
  invisible(NULL)
}

#' Save ggplot object as PNG with Automatic Numbering and Directory Management
#'
#' This function saves a ggplot object as a PNG file in a date-structured directory
#' under output/YYYY_MM_DD/plots with automatic plot numbering (plot001, plot002, etc.).
#' It maintains all the original functionality for customizing aspect ratio, DPI, and sizing.
#'
#' @param plot_object A ggplot object to save
#' @param width_ratio Numeric, width component of aspect ratio (default: 16)
#' @param height_ratio Numeric, height component of aspect ratio (default: 9)
#' @param dpi Numeric, dots per inch for resolution (default: 100)
#' @param base_size Numeric, base size units for scaling (default: 72)
#' @param base_dir Character string specifying the base directory. Default is current working directory
#'
#' @return Character string with the path of the saved file
#'
#' @examples
#' # Basic usage
#' file_path <- save_plot(my_plot)
#'
#' # Custom aspect ratio and high resolution
#' file_path <- save_plot(my_plot, width_ratio = 1, height_ratio = 1, dpi = 300)
#'
#' # Publication quality with custom sizing
#' file_path <- save_plot(my_plot, dpi = 600, base_size = 100)
#'
#' @export
save_plot <- function(plot_object,
                     width_ratio = 16,
                     height_ratio = 9,
                     dpi = 100,
                     base_size = 72,
                     base_dir = getwd()) {

  # Input validation
  if (!requireNamespace("ggplot2", quietly = TRUE)) {
    stop("ggplot2 package is required but not installed.")
  }

  if (!ggplot2::is.ggplot(plot_object)) {
    stop("Input 'plot_object' must be a ggplot object")
  }

  if (!is.numeric(width_ratio) || length(width_ratio) != 1 || width_ratio <= 0) {
    stop("'width_ratio' must be a single positive numeric value")
  }

  if (!is.numeric(height_ratio) || length(height_ratio) != 1 || height_ratio <= 0) {
    stop("'height_ratio' must be a single positive numeric value")
  }

  if (!is.numeric(dpi) || length(dpi) != 1 || dpi <= 0) {
    stop("'dpi' must be a single positive numeric value")
  }

  if (!is.numeric(base_size) || length(base_size) != 1 || base_size <= 0) {
    stop("'base_size' must be a single positive numeric value")
  }

  if (!is.character(base_dir) || length(base_dir) != 1) {
    stop("'base_dir' must be a single character string")
  }

  if (!dir.exists(base_dir)) {
    stop(paste("Base directory does not exist:", base_dir))
  }

  # Create date-based directory structure
  current_date <- Sys.Date()
  date_dir <- format(current_date, "%Y_%m_%d")
  output_dir <- file.path(base_dir, "output", date_dir, "plots")

  # Create directories if they don't exist
  if (!dir.exists(output_dir)) {
    dir.create(output_dir, recursive = TRUE, showWarnings = FALSE)
    cat("Created directory:", output_dir, "\n")
  }

  # Find the next plot number
  existing_files <- list.files(output_dir, pattern = "^plot[0-9]{3}\\.png$", full.names = FALSE)

  if (length(existing_files) == 0) {
    plot_number <- 1
  } else {
    # Extract numbers from existing files
    numbers <- as.numeric(gsub("plot([0-9]{3})\\.png", "\\1", existing_files))
    plot_number <- max(numbers, na.rm = TRUE) + 1
  }

  # Format plot number with leading zeros
  plot_name <- sprintf("plot%03d.png", plot_number)
  file_path <- file.path(output_dir, plot_name)

  # Calculate pixels based on aspect ratio and DPI (same logic as original)
  width_px <- width_ratio * base_size * (dpi / 100)
  height_px <- height_ratio * base_size * (dpi / 100)

  # Convert pixels to inches for ggsave
  width_in <- width_px / dpi
  height_in <- height_px / dpi

  # Save the plot
  ggplot2::ggsave(filename = file_path,
                  plot = plot_object,
                  width = width_in,
                  height = height_in,
                  units = "in",
                  dpi = dpi)

  # Print confirmation message
  cat("✅ Plot saved as:", file_path, "\n")
  cat("   Plot number:", sprintf("plot%03d", plot_number), "\n")
  cat("   Aspect ratio:", width_ratio, ":", height_ratio, "\n")
  cat("   Dimensions:", round(width_px), "x", round(height_px), "pixels (",
      round(width_in, 2), "x", round(height_in, 2), "inches) at", dpi, "DPI\n")

  return(file_path)
}

# Example usage and demonstration
if (interactive()) {

  cat("=== save_plot_png() Examples ===\n\n")

  # Load ggplot2 for examples
  if (requireNamespace("ggplot2", quietly = TRUE)) {
    library(ggplot2)

    # Create sample plots for demonstration
    cat("Creating sample plots for demonstration...\n\n")

    # Example 1: Basic scatter plot
    sample_plot1 <- ggplot(mtcars, aes(x = wt, y = mpg)) +
      geom_point() +
      labs(title = "Car Weight vs MPG",
           x = "Weight (1000 lbs)",
           y = "Miles Per Gallon") +
      theme_minimal()

    # Example 2: Bar plot
    sample_plot2 <- ggplot(mtcars, aes(x = factor(cyl))) +
      geom_bar() +
      labs(title = "Count of Cars by Cylinder",
           x = "Number of Cylinders",
           y = "Count") +
      theme_minimal()

    # Example 3: Box plot
    sample_plot3 <- ggplot(mtcars, aes(x = factor(cyl), y = mpg)) +
      geom_boxplot() +
      labs(title = "MPG Distribution by Cylinder Count",
           x = "Number of Cylinders",
           y = "Miles Per Gallon") +
      theme_minimal()

    cat("=== save_plot() Examples ===\n\n")

    cat("Example 1: Save plot with default settings\n")
    file_path1 <- save_plot(sample_plot1)
    cat("Saved:", file_path1, "\n\n")

    cat("Example 2: Save plot with square aspect ratio and high DPI\n")
    file_path2 <- save_plot(sample_plot2,
                           width_ratio = 1,
                           height_ratio = 1,
                           dpi = 300)
    cat("Saved:", file_path2, "\n\n")

    cat("Example 3: Save plot with custom dimensions for publication\n")
    file_path3 <- save_plot(sample_plot3,
                           width_ratio = 12,
                           height_ratio = 8,
                           dpi = 600,
                           base_size = 100)
    cat("Saved:", file_path3, "\n\n")

    cat("=== Backward Compatibility Example ===\n\n")
    cat("Example 4: Using the original save_plot_png function\n")
    save_plot_png(sample_plot1, "legacy_plot.png", width_ratio = 4, height_ratio = 3)

    cat("\nAll examples completed! Check your output directory for saved plots.\n")

  } else {
    cat("ggplot2 package not available. Please install ggplot2 to run examples.\n")
  }
}
