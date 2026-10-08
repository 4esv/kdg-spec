#!/usr/bin/env Rscript
# KDG (Key-Delimiter Grammar) Parser - Reference Implementation (R)
#
# Usage:
#   Rscript kdg.R parse <file>           Parse KDG to JSON
#   Rscript kdg.R validate <file>        Validate KDG syntax
#   Rscript kdg.R convert <file> [fmt]   Convert to format (json, csv)
#
# This implementation uses base R only. No external packages. This was
# considered important.

usage <- "Usage: kdg <parse|validate|convert> <file> [json|csv]"

valid_types <- c("str", "int", "float", "bool", "date")

# Characters that cannot be delimiters. Same set as kdg.go's reservedCharList.
reserved_char_list <- paste0(
  "abcdefghijklmnopqrstuvwxyz",
  "ABCDEFGHIJKLMNOPQRSTUVWXYZ",
  "0123456789:\" \t\n\r"
)
reserved_chars <- strsplit(reserved_char_list, "", fixed = TRUE)[[1]]

# Regex for parsing definition lines. Byte-for-byte equivalent to the Go/Python
# pattern `^([a-z]+):"((?:[^"\\]|\\.)*)"(.)$`.
definition_pattern <- "^([a-z]+):\"((?:[^\"\\\\]|\\\\.)*)\"(.)$"

# Strict integer syntax matching Go's strconv.Atoi (optional sign, ASCII digits).
integer_pattern <- "^[+-]?[0-9]+$"

# --- Errors -----------------------------------------------------------------

# kdg_error signals a KDG parse failure. line is 0 when the error carries no
# line number (only MissingSeparator does).
kdg_error <- function(message, line = 0L) {
  cond <- structure(
    list(message = message, line = as.integer(line)),
    class = c("kdgError", "error", "condition")
  )
  stop(cond)
}

# format_error renders a kdgError the way kdg.go's kdgError.Error() does.
format_error <- function(e) {
  if (e$line > 0L) {
    sprintf("Line %d: %s", e$line, e$message)
  } else {
    e$message
  }
}

# --- Definitions ------------------------------------------------------------

# parse_definition parses a single field definition line.
parse_definition <- function(line, line_num) {
  match <- regmatches(line, regexec(definition_pattern, line, perl = TRUE))[[1]]
  if (length(match) == 0L) {
    kdg_error(sprintf("Invalid definition syntax: '%s'", line), line_num)
  }

  type_name <- match[2]
  raw_label <- match[3]
  delimiter <- match[4]

  if (!(type_name %in% valid_types)) {
    kdg_error(sprintf("Unknown type: '%s'", type_name), line_num)
  }

  if (delimiter %in% reserved_chars) {
    kdg_error(sprintf("Invalid delimiter: '%s' (reserved character)", delimiter), line_num)
  }

  # Unescape the label. Order matters: \" first, then \\.
  label <- gsub('\\"', '"', raw_label, fixed = TRUE)
  label <- gsub('\\\\', '\\', label, fixed = TRUE)

  list(type = type_name, label = label, delimiter = delimiter)
}

# --- Type coercion ----------------------------------------------------------

# convert_value converts a string value to its typed representation. The
# returned list carries the declared type so output formatting stays faithful.
convert_value <- function(value, type_name, line_num) {
  if (type_name == "str") {
    return(list(type = "str", value = value))
  }

  if (type_name == "int") {
    if (grepl(integer_pattern, value, perl = TRUE)) {
      return(list(type = "int", value = as.numeric(value)))
    }
    kdg_error(sprintf("Invalid integer: '%s'", value), line_num)
  }

  if (type_name == "float") {
    parsed <- suppressWarnings(as.numeric(value))
    if (!is.na(parsed)) {
      return(list(type = "float", value = parsed))
    }
    kdg_error(sprintf("Invalid float: '%s'", value), line_num)
  }

  if (type_name == "bool") {
    lower <- tolower(value)
    if (lower == "true" || lower == "1") {
      return(list(type = "bool", value = TRUE))
    }
    if (lower == "false" || lower == "0") {
      return(list(type = "bool", value = FALSE))
    }
    kdg_error(sprintf("Invalid boolean: '%s'", value), line_num)
  }

  if (type_name == "date") {
    parts <- strsplit(value, "-", fixed = TRUE)[[1]]
    if (length(parts) == 3L && all(grepl(integer_pattern, parts, perl = TRUE))) {
      year <- as.numeric(parts[1])
      if (year >= 1 && year <= 9999) {
        # as.Date returns NA (rather than normalising) for impossible days such
        # as 2023-02-29, matching kdg.go's round-trip calendar check.
        parsed <- suppressWarnings(as.Date(value, format = "%Y-%m-%d"))
        if (!is.na(parsed)) {
          return(list(type = "date", value = value))
        }
      }
    }
    kdg_error(sprintf("Invalid date (expected YYYY-MM-DD): '%s'", value), line_num)
  }

  kdg_error(sprintf("Unknown type: '%s'", type_name), line_num)
}

# --- Records ----------------------------------------------------------------

# scan_wrapped_value scans a double-quoted value beginning at chars[start] == '"'.
# It returns the value and the position just after the closing quote. Backslash
# escapes for \" and \\ are honoured per SPEC 6.2.
scan_wrapped_value <- function(chars, start, line_num) {
  n <- length(chars)
  out <- character(0)
  i <- start + 1L

  while (i <= n) {
    ch <- chars[i]

    if (ch == "\\" && i + 1L <= n && (chars[i + 1L] == '"' || chars[i + 1L] == "\\")) {
      out <- c(out, chars[i + 1L])
      i <- i + 2L
      next
    }

    if (ch == '"') {
      return(list(value = paste(out, collapse = ""), position = i + 1L))
    }

    out <- c(out, ch)
    i <- i + 1L
  }

  kdg_error("Unterminated quoted value", line_num)
}

# parse_record parses a single record line. The result keeps the field values
# plus the first-seen key order needed for deterministic CSV headers.
parse_record <- function(line, delimiter_map, line_num) {
  record <- list(label = character(0), type = character(0), value = list())
  if (line == "") {
    return(record)
  }

  chars <- strsplit(line, "", fixed = TRUE)[[1]]
  n <- length(chars)
  delimiter_names <- names(delimiter_map)
  position <- 1L

  while (position <= n) {
    # A field is value-then-delimiter. The value may be wrapped in double
    # quotes, which lets it contain delimiter characters (SPEC 6.2).
    if (chars[position] == '"') {
      scanned <- scan_wrapped_value(chars, position, line_num)
      value <- scanned$value
      position <- scanned$position

      if (position > n) {
        kdg_error(sprintf("Missing delimiter after value '%s'", value), line_num)
      }
    } else {
      start <- position
      while (position <= n && !(chars[position] %in% delimiter_names)) {
        position <- position + 1L
      }

      if (position > n) {
        kdg_error(
          sprintf("No delimiter found for value starting at column %d", start - 1L),
          line_num
        )
      }

      if (position > start) {
        value <- paste(chars[start:(position - 1L)], collapse = "")
      } else {
        value <- ""
      }
    }

    delimiter <- chars[position]

    field <- delimiter_map[[delimiter]]
    if (is.null(field)) {
      kdg_error(sprintf("Undefined delimiter: '%s'", delimiter), line_num)
    }

    if (field$label %in% record$label) {
      kdg_error(sprintf("Duplicate field in record: '%s'", field$label), line_num)
    }

    converted <- convert_value(value, field$type, line_num)
    record$label <- c(record$label, field$label)
    record$type <- c(record$type, converted$type)
    record$value <- c(record$value, list(converted$value))
    position <- position + 1L
  }

  record
}

# --- Document ---------------------------------------------------------------

# parse parses a KDG document into a list of records.
parse_document <- function(content) {
  lines <- strsplit(content, "\n", fixed = TRUE)[[1]]

  # A trailing newline produces a spurious final empty element. Drop it so a
  # document with no blank-line separator is reported as MissingSeparator
  # instead of having its first record misread as a definition.
  if (length(lines) > 0L && lines[length(lines)] == "") {
    lines <- lines[-length(lines)]
  }

  # Find the separator (first blank line).
  separator_idx <- match("", lines)
  if (is.na(separator_idx)) {
    kdg_error("No blank line separator found between definitions and data", 0L)
  }

  # Parse definitions.
  delimiter_map <- list()
  if (separator_idx > 1L) {
    for (i in seq_len(separator_idx - 1L)) {
      line <- lines[i]
      if (line == "") { # Skip empty lines in the definition block
        next
      }

      field <- parse_definition(line, i)

      existing <- delimiter_map[[field$delimiter]]
      if (!is.null(existing)) {
        kdg_error(
          sprintf("Delimiter '%s' already used for field '%s'", field$delimiter, existing$label),
          i
        )
      }

      delimiter_map[[field$delimiter]] <- field
    }
  }

  # Parse records.
  records <- list()
  if (separator_idx < length(lines)) {
    for (i in seq.int(separator_idx + 1L, length(lines))) {
      line <- lines[i]
      if (line == "") { # Skip empty lines in the data block
        next
      }
      records[[length(records) + 1L]] <- parse_record(line, delimiter_map, i)
    }
  }

  records
}

# --- JSON -------------------------------------------------------------------

# json_escape escapes the characters JSON strings cannot contain literally.
json_escape <- function(s) {
  s <- gsub("\\", "\\\\", s, fixed = TRUE)
  s <- gsub("\"", "\\\"", s, fixed = TRUE)
  s <- gsub("\n", "\\n", s, fixed = TRUE)
  s <- gsub("\r", "\\r", s, fixed = TRUE)
  s <- gsub("\t", "\\t", s, fixed = TRUE)
  s
}

json_literal <- function(type, value) {
  if (type == "str" || type == "date") {
    return(paste0("\"", json_escape(value), "\""))
  }
  if (type == "bool") {
    return(if (isTRUE(value)) "true" else "false")
  }
  if (type == "int") {
    return(sprintf("%.0f", value))
  }
  # float
  format(value, trim = TRUE, scientific = FALSE, digits = 15)
}

record_to_json <- function(record) {
  n <- length(record$label)
  if (n == 0L) {
    return("{}")
  }

  fields <- character(n)
  for (i in seq_len(n)) {
    fields[i] <- paste0(
      "    \"", json_escape(record$label[i]), "\": ",
      json_literal(record$type[i], record$value[[i]])
    )
  }

  paste0("{\n", paste(fields, collapse = ",\n"), "\n  }")
}

# to_json converts parsed records to a JSON string with 2-space indentation.
to_json <- function(records) {
  if (length(records) == 0L) {
    return("[]\n")
  }
  objs <- vapply(records, record_to_json, character(1))
  paste0("[\n  ", paste(objs, collapse = ",\n  "), "\n]\n")
}

# --- CSV --------------------------------------------------------------------

# csv_value renders a value the way kdg.go's csvValue does.
csv_value <- function(type, value) {
  if (type == "bool") {
    return(if (isTRUE(value)) "True" else "False")
  }
  if (type == "int") {
    return(sprintf("%.0f", value))
  }
  if (type == "float") {
    s <- format(value, trim = TRUE, scientific = FALSE, digits = 15)
    if (!grepl("[.eEni]", s)) {
      s <- paste0(s, ".0")
    }
    return(s)
  }
  as.character(value)
}

# csv_escape quotes a field containing a comma, double quote, or newline,
# doubling internal quotes.
csv_escape <- function(s) {
  if (grepl("[,\"\n]", s)) {
    return(paste0("\"", gsub("\"", "\"\"", s, fixed = TRUE), "\""))
  }
  s
}

# to_csv converts parsed records to a CSV string.
to_csv <- function(records) {
  if (length(records) == 0L) {
    return("")
  }

  # Get all unique keys across all records, in first-seen order.
  all_keys <- character(0)
  for (record in records) {
    for (key in record$label) {
      if (!(key %in% all_keys)) {
        all_keys <- c(all_keys, key)
      }
    }
  }

  rows <- character(0)
  rows[1] <- paste(vapply(all_keys, csv_escape, character(1)), collapse = ",")

  for (record in records) {
    row <- character(length(all_keys))
    for (j in seq_along(all_keys)) {
      idx <- match(all_keys[j], record$label)
      if (is.na(idx)) {
        row[j] <- ""
      } else {
        row[j] <- csv_escape(csv_value(record$type[idx], record$value[[idx]]))
      }
    }
    rows <- c(rows, paste(row, collapse = ","))
  }

  paste(rows, collapse = "\n")
}

# --- CLI --------------------------------------------------------------------

read_content <- function(path) {
  lines <- readLines(path, warn = FALSE, encoding = "UTF-8")
  content <- paste(lines, collapse = "\n")
  content <- gsub("\r\n", "\n", content, fixed = TRUE)
  Encoding(content) <- "UTF-8"
  content
}

main <- function() {
  args <- commandArgs(trailingOnly = TRUE)

  if (length(args) < 2L) {
    cat(usage, "\n", sep = "", file = stderr())
    quit(status = 1)
  }

  command <- args[1]
  filepath <- args[2]

  if (!file.exists(filepath)) {
    cat(sprintf("Error: File not found: %s\n", filepath), file = stderr())
    quit(status = 1)
  }

  content <- tryCatch(
    read_content(filepath),
    error = function(e) {
      cat(sprintf("Error reading file: %s\n", conditionMessage(e)), file = stderr())
      quit(status = 1)
    }
  )

  if (command == "parse") {
    result <- tryCatch(parse_document(content), kdgError = function(e) e)
    if (inherits(result, "kdgError")) {
      cat(sprintf("Parse error: %s\n", format_error(result)), file = stderr())
      quit(status = 1)
    }
    cat(to_json(result))
    quit(status = 0)
  }

  if (command == "validate") {
    result <- tryCatch(parse_document(content), kdgError = function(e) e)
    if (inherits(result, "kdgError")) {
      cat(sprintf("Invalid: %s\n", format_error(result)), file = stderr())
      quit(status = 1)
    }
    cat("Valid KDG document\n")
    quit(status = 0)
  }

  if (command == "convert") {
    format_name <- if (length(args) > 2L) args[3] else "json"
    result <- tryCatch(parse_document(content), kdgError = function(e) e)
    if (inherits(result, "kdgError")) {
      cat(sprintf("Parse error: %s\n", format_error(result)), file = stderr())
      quit(status = 1)
    }
    if (format_name == "json") {
      cat(to_json(result))
    } else if (format_name == "csv") {
      cat(to_csv(result), "\n", sep = "")
    } else {
      cat(sprintf("Unknown format: %s\n", format_name), file = stderr())
      quit(status = 1)
    }
    quit(status = 0)
  }

  cat(sprintf("Unknown command: %s\n", command), file = stderr())
  cat(usage, "\n", sep = "", file = stderr())
  quit(status = 1)
}

main()
