#' Remove Consecutive Duplicate Values in a Column
#'
#' This function removes consecutive duplicate values in a specified column by
#' replacing them with empty strings when they match the cell above. This is
#' useful for creating cleaner tables where repeated values are suppressed
#' for better readability, commonly used in CONSORT tables or summary tables.
#'
#' @param df A data frame containing the column to be processed
#' @param column_name Character string specifying the name of the column to process
#' @param replacement Character string to replace duplicate values with. Default is ""
#' @param keep_first Logical. If TRUE, keeps the first occurrence of each group.
#'   If FALSE, all duplicates become empty. Default is TRUE
#' @param case_sensitive Logical. If TRUE, comparison is case-sensitive.
#'   If FALSE, comparison ignores case. Default is TRUE
#'
#' @return A data frame with consecutive duplicate values in the specified column
#'   replaced with the replacement string
#'
#' @examples
#' # Create sample data
#' sample_data <- data.frame(
#'   Database = c("AEMR 2025 (US)", "AEMR 2025 (US)", "PPLUS (US)", "PPLUS (US)"),
#'   Step = c("Step 1", "Step 2", "Step 1", "Step 2"),
#'   Count = c(1000, 950, 800, 750)
#' )
#'
#' # Remove duplicate database names
#' clean_data <- remove_duplicate_values(sample_data, "Database")
#' print(clean_data)
#'
#' # Use custom replacement string
#' clean_data2 <- remove_duplicate_values(sample_data, "Database", replacement = "---")
#' print(clean_data2)
#'
#' # Keep all duplicates (don't keep first)
#' clean_data3 <- remove_duplicate_values(sample_data, "Database", keep_first = FALSE)
#' print(clean_data3)
#'
#' @export
remove_duplicate_values <- function(df, 
                                   column_name, 
                                   replacement = "", 
                                   keep_first = TRUE,
                                   case_sensitive = TRUE) {
  
  # Input validation
  if (!is.data.frame(df)) {
    stop("Input 'df' must be a data frame")
  }
  
  if (!is.character(column_name) || length(column_name) != 1) {
    stop("'column_name' must be a single character string")
  }
  
  if (!column_name %in% names(df)) {
    stop(paste("Column '", column_name, "' not found in data frame", sep = ""))
  }
  
  if (!is.character(replacement) || length(replacement) != 1) {
    stop("'replacement' must be a single character string")
  }
  
  if (!is.logical(keep_first) || length(keep_first) != 1) {
    stop("'keep_first' must be a single logical value")
  }
  
  if (!is.logical(case_sensitive) || length(case_sensitive) != 1) {
    stop("'case_sensitive' must be a single logical value")
  }
  
  if (nrow(df) == 0) {
    warning("Input data frame is empty")
    return(df)
  }
  
  # Create a copy of the data frame
  df_copy <- df
  
  # Get the column as a vector
  col_values <- df_copy[[column_name]]
  
  # Handle case sensitivity
  if (!case_sensitive) {
    comparison_values <- tolower(as.character(col_values))
  } else {
    comparison_values <- as.character(col_values)
  }
  
  # Process duplicates starting from the second row
  if (length(col_values) > 1) {
    for (i in 2:length(col_values)) {
      # Check if current value matches previous value
      if (!is.na(comparison_values[i]) && 
          !is.na(comparison_values[i-1]) && 
          comparison_values[i] == comparison_values[i-1]) {
        
        if (keep_first) {
          # Replace current value with replacement string
          df_copy[[column_name]][i] <- replacement
        } else {
          # Replace both current and previous values
          df_copy[[column_name]][i] <- replacement
          df_copy[[column_name]][i-1] <- replacement
        }
      }
    }
  }
  
  return(df_copy)
}

#' Remove Consecutive Duplicates from Multiple Columns
#'
#' Wrapper function to apply remove_duplicate_values to multiple columns
#'
#' @param df A data frame containing the columns to be processed
#' @param columns Character vector of column names to process
#' @param ... Additional arguments passed to remove_duplicate_values
#'
#' @return A data frame with consecutive duplicates removed from specified columns
#'
#' @examples
#' # Create sample data
#' sample_data <- data.frame(
#'   Database = c("DB1", "DB1", "DB2", "DB2"),
#'   Treatment = c("A", "A", "B", "B"),
#'   Step = c("Step 1", "Step 2", "Step 1", "Step 2")
#' )
#'
#' # Clean multiple columns
#' clean_data <- remove_duplicate_values_multi(sample_data, c("Database", "Treatment"))
#' print(clean_data)
#'
#' @export
remove_duplicate_values_multi <- function(df, columns, ...) {
  
  # Input validation
  if (!is.data.frame(df)) {
    stop("Input 'df' must be a data frame")
  }
  
  if (!is.character(columns)) {
    stop("'columns' must be a character vector")
  }
  
  missing_cols <- setdiff(columns, names(df))
  if (length(missing_cols) > 0) {
    stop(paste("Columns not found in data frame:", paste(missing_cols, collapse = ", ")))
  }
  
  # Apply function to each column sequentially
  result_df <- df
  for (col in columns) {
    result_df <- remove_duplicate_values(result_df, col, ...)
  }
  
  return(result_df)
}

#' Save Data Frame to RDS with Automatic Numbering and Optional Duplicate Removal
#'
#' This function saves a data frame to an RDS file in a date-structured directory
#' under output/YYYY_MM_DD/tables with automatic table numbering (table001, table002, etc.).
#' It can optionally remove consecutive duplicate values from specified columns before saving.
#'
#' @param df A data frame to be saved
#' @param duplicate_columns Character vector of column names where consecutive duplicates
#'   should be removed. If NULL (default), no duplicate removal is performed
#' @param replacement Character string to replace duplicate values with. Default is ""
#' @param keep_first Logical. If TRUE, keeps the first occurrence of each group.
#'   If FALSE, all duplicates become empty. Default is TRUE
#' @param case_sensitive Logical. If TRUE, comparison is case-sensitive.
#'   If FALSE, comparison ignores case. Default is TRUE
#' @param base_dir Character string specifying the base directory. Default is current working directory
#'
#' @return Character string with the path of the saved file
#'
#' @examples
#' # Create sample data
#' sample_data <- data.frame(
#'   Database = c("AEMR 2025 (US)", "AEMR 2025 (US)", "PPLUS (US)", "PPLUS (US)"),
#'   Step = c("Step 1", "Step 2", "Step 1", "Step 2"),
#'   Count = c(1000, 950, 800, 750)
#' )
#'
#' # Save without duplicate removal
#' file_path <- save_table(sample_data)
#'
#' # Save with duplicate removal in Database column
#' file_path <- save_table(sample_data, duplicate_columns = "Database")
#'
#' # Save with duplicate removal in multiple columns
#' file_path <- save_table(sample_data, duplicate_columns = c("Database", "Step"))
#'
#' @export
save_table <- function(df,
                      duplicate_columns = NULL,
                      replacement = "",
                      keep_first = TRUE,
                      case_sensitive = TRUE,
                      base_dir = getwd()) {

  # Input validation
  if (!is.data.frame(df)) {
    stop("Input 'df' must be a data frame")
  }

  if (nrow(df) == 0) {
    warning("Input data frame is empty")
  }

  if (!is.null(duplicate_columns)) {
    if (!is.character(duplicate_columns)) {
      stop("'duplicate_columns' must be a character vector or NULL")
    }

    missing_cols <- setdiff(duplicate_columns, names(df))
    if (length(missing_cols) > 0) {
      stop(paste("Columns not found in data frame:", paste(missing_cols, collapse = ", ")))
    }
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
  output_dir <- file.path(base_dir, "output", date_dir, "tables")

  # Create directories if they don't exist
  if (!dir.exists(output_dir)) {
    dir.create(output_dir, recursive = TRUE, showWarnings = FALSE)
    cat("Created directory:", output_dir, "\n")
  }

  # Find the next table number
  existing_files <- list.files(output_dir, pattern = "^table[0-9]{3}\\.rds$", full.names = FALSE)

  if (length(existing_files) == 0) {
    table_number <- 1
  } else {
    # Extract numbers from existing files
    numbers <- as.numeric(gsub("table([0-9]{3})\\.rds", "\\1", existing_files))
    table_number <- max(numbers, na.rm = TRUE) + 1
  }

  # Format table number with leading zeros
  table_name <- sprintf("table%03d.rds", table_number)
  file_path <- file.path(output_dir, table_name)

  # Process data frame (remove duplicates if specified)
  processed_df <- df
  if (!is.null(duplicate_columns)) {
    processed_df <- remove_duplicate_values_multi(df, duplicate_columns,
                                                 replacement = replacement,
                                                 keep_first = keep_first,
                                                 case_sensitive = case_sensitive)
    cat("Removed consecutive duplicates from columns:", paste(duplicate_columns, collapse = ", "), "\n")
  }

  # Save the data frame
  saveRDS(processed_df, file = file_path)
  cat("Saved table as:", file_path, "\n")
  cat("Table dimensions:", nrow(processed_df), "rows x", ncol(processed_df), "columns\n")

  return(file_path)
}

# Example usage and demonstration
if (interactive()) {
  
  cat("=== remove_duplicate_values() Examples ===\n\n")
  
  # Example 1: Basic usage with CONSORT-style table
  cat("Example 1: Basic CONSORT table cleaning\n")
  consort_data <- data.frame(
    Database = c("AEMR 2025 (US)", "AEMR 2025 (US)", "AEMR 2025 (US)",
                 "PPLUS (US)", "PPLUS (US)", "PPLUS (US)",
                 "Truven CCAE (US)", "Truven CCAE (US)", "Truven CCAE (US)"),
    `Selection Step` = rep(c("1) Entire population", "2) Adults only", "3) With stroke"), 3),
    `Remaining (n)` = c(3262924, 3261758, 74871, 1666787, 1659566, 179995, 1341051, 1339115, 122084),
    check.names = FALSE
  )
  
  print("Original data:")
  print(consort_data)
  
  clean_consort <- remove_duplicate_values(consort_data, "Database")
  print("\nAfter removing duplicate database names:")
  print(clean_consort)
  
  # Example 2: Multiple columns
  cat("\n\nExample 2: Multiple columns with custom replacement\n")
  multi_col_data <- data.frame(
    Category = c("A", "A", "B", "B", "B"),
    Subcategory = c("X", "X", "Y", "Y", "Z"),
    Value = 1:5
  )
  
  print("Original data:")
  print(multi_col_data)
  
  clean_multi <- remove_duplicate_values_multi(multi_col_data, 
                                              c("Category", "Subcategory"), 
                                              replacement = "—")
  print("\nAfter cleaning both columns:")
  print(clean_multi)
  
  # Example 3: Case insensitive comparison
  cat("\n\nExample 3: Case insensitive comparison\n")
  case_data <- data.frame(
    Group = c("Group A", "group a", "GROUP A", "Group B"),
    Value = 1:4
  )
  
  print("Original data:")
  print(case_data)
  
  clean_case <- remove_duplicate_values(case_data, "Group", case_sensitive = FALSE)
  print("\nAfter case-insensitive cleaning:")
  print(clean_case)

  # Example 4: New save_table() function
  cat("\n\n=== save_table() Examples ===\n\n")

  cat("Example 4: Save table without duplicate removal\n")
  test_data <- data.frame(
    Database = c("AEMR 2025 (US)", "AEMR 2025 (US)", "PPLUS (US)", "PPLUS (US)"),
    Step = c("Step 1", "Step 2", "Step 1", "Step 2"),
    Count = c(1000, 950, 800, 750)
  )

  print("Test data:")
  print(test_data)

  # Save without duplicate removal
  file_path1 <- save_table(test_data)
  cat("\nSaved file:", file_path1, "\n")

  cat("\nExample 5: Save table with duplicate removal\n")
  # Save with duplicate removal in Database column
  file_path2 <- save_table(test_data, duplicate_columns = "Database")
  cat("\nSaved file with duplicate removal:", file_path2, "\n")

  # Verify the saved data
  saved_data <- readRDS(file_path2)
  print("\nData saved with duplicate removal:")
  print(saved_data)

  cat("\nExample 6: Save table with multiple column duplicate removal\n")
  multi_dup_data <- data.frame(
    Category = c("A", "A", "A", "B", "B", "C"),
    Subcategory = c("X", "X", "Y", "Y", "Y", "Z"),
    Treatment = c("Drug A", "Drug A", "Drug B", "Drug B", "Drug C", "Drug C"),
    Value = c(100, 95, 85, 80, 75, 70)
  )

  print("Multi-duplicate test data:")
  print(multi_dup_data)

  # Save with duplicate removal in multiple columns
  file_path3 <- save_table(multi_dup_data,
                          duplicate_columns = c("Category", "Subcategory", "Treatment"),
                          replacement = "—")

  saved_multi_data <- readRDS(file_path3)
  print("\nData saved with multi-column duplicate removal:")
  print(saved_multi_data)
}
