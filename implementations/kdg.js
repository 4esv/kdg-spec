#!/usr/bin/env node
/**
 * KDG (Key-Delimiter Grammar) Parser - Reference Implementation
 *
 * Usage:
 *   node kdg.js parse <file>           Parse KDG to JSON
 *   node kdg.js validate <file>        Validate KDG syntax
 *   node kdg.js convert <file> [fmt]   Convert to format (json, csv)
 *
 * This implementation has no dependencies. This was considered important.
 */

const fs = require("fs");
const path = require("path");

// Error classes
class KDGError extends Error {
  constructor(message, line = null) {
    super(line ? `Line ${line}: ${message}` : message);
    this.name = "KDGError";
    this.line = line;
  }
}

class DuplicateDelimiterError extends KDGError {
  constructor(message, line) {
    super(message, line);
    this.name = "DuplicateDelimiterError";
  }
}

class InvalidTypeError extends KDGError {
  constructor(message, line) {
    super(message, line);
    this.name = "InvalidTypeError";
  }
}

class MalformedDefinitionError extends KDGError {
  constructor(message, line) {
    super(message, line);
    this.name = "MalformedDefinitionError";
  }
}

class UndefinedDelimiterError extends KDGError {
  constructor(message, line) {
    super(message, line);
    this.name = "UndefinedDelimiterError";
  }
}

class DuplicateFieldError extends KDGError {
  constructor(message, line) {
    super(message, line);
    this.name = "DuplicateFieldError";
  }
}

class TypeMismatchError extends KDGError {
  constructor(message, line) {
    super(message, line);
    this.name = "TypeMismatchError";
  }
}

class MissingSeparatorError extends KDGError {
  constructor(message) {
    super(message);
    this.name = "MissingSeparatorError";
  }
}

class UnterminatedValueError extends KDGError {
  constructor(message, line) {
    super(message, line);
    this.name = "UnterminatedValueError";
  }
}

const VALID_TYPES = new Set(["str", "int", "float", "bool", "date"]);

// Characters that cannot be delimiters
const RESERVED_CHARS = new Set(
  'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789:" \t\n\r'.split(
    ""
  )
);

// Regex for parsing definition lines
const DEFINITION_PATTERN = /^([a-z]+):"((?:[^"\\]|\\.)*)\"(.)$/;

/**
 * Parse a single field definition line.
 * @param {string} line - The definition line
 * @param {number} lineNum - Line number for error reporting
 * @returns {{type: string, label: string, delimiter: string}}
 */
function parseDefinition(line, lineNum) {
  const match = line.match(DEFINITION_PATTERN);
  if (!match) {
    throw new MalformedDefinitionError(
      `Invalid definition syntax: "${line}"`,
      lineNum
    );
  }

  const [, typeName, rawLabel, delimiter] = match;

  if (!VALID_TYPES.has(typeName)) {
    throw new InvalidTypeError(`Unknown type: "${typeName}"`, lineNum);
  }

  if (RESERVED_CHARS.has(delimiter)) {
    throw new MalformedDefinitionError(
      `Invalid delimiter: "${delimiter}" (reserved character)`,
      lineNum
    );
  }

  // Unescape the label
  const label = rawLabel.replace(/\\"/g, '"').replace(/\\\\/g, "\\");

  return { type: typeName, label, delimiter };
}

/**
 * Convert a string value to its typed representation.
 * @param {string} value - The raw string value
 * @param {string} typeName - The declared type
 * @param {number} lineNum - Line number for error reporting
 * @returns {*} The converted value
 */
function convertValue(value, typeName, lineNum) {
  if (typeName === "str") {
    return value;
  }

  if (typeName === "int") {
    const parsed = parseInt(value, 10);
    if (isNaN(parsed) || !Number.isInteger(parsed)) {
      throw new TypeMismatchError(`Invalid integer: "${value}"`, lineNum);
    }
    return parsed;
  }

  if (typeName === "float") {
    const parsed = parseFloat(value);
    if (isNaN(parsed)) {
      throw new TypeMismatchError(`Invalid float: "${value}"`, lineNum);
    }
    return parsed;
  }

  if (typeName === "bool") {
    const lower = value.toLowerCase();
    if (lower === "true" || lower === "1") {
      return true;
    }
    if (lower === "false" || lower === "0") {
      return false;
    }
    throw new TypeMismatchError(`Invalid boolean: "${value}"`, lineNum);
  }

  if (typeName === "date") {
    const parts = value.split("-");
    if (parts.length !== 3) {
      throw new TypeMismatchError(
        `Invalid date (expected YYYY-MM-DD): "${value}"`,
        lineNum
      );
    }

    const year = Number(parts[0]);
    const month = Number(parts[1]);
    const day = Number(parts[2]);

    if (
      !Number.isInteger(year) ||
      !Number.isInteger(month) ||
      !Number.isInteger(day) ||
      year < 1 ||
      year > 9999 ||
      month < 1 ||
      month > 12 ||
      day < 1 ||
      day > 31
    ) {
      throw new TypeMismatchError(
        `Invalid date (expected YYYY-MM-DD): "${value}"`,
        lineNum
      );
    }

    // setUTCFullYear treats the year literally (no 1900 mapping for 0-99) and
    // avoids local-timezone quirks; the round-trip check rejects 2023-02-29.
    const dateObj = new Date(0);
    dateObj.setUTCFullYear(year, month - 1, day);

    if (
      dateObj.getUTCFullYear() !== year ||
      dateObj.getUTCMonth() !== month - 1 ||
      dateObj.getUTCDate() !== day
    ) {
      throw new TypeMismatchError(
        `Invalid date (expected YYYY-MM-DD): "${value}"`,
        lineNum
      );
    }

    return value; // Return as string for JSON compatibility
  }

  throw new InvalidTypeError(`Unknown type: "${typeName}"`, lineNum);
}

/**
 * Scan a double-quoted value beginning at line[start] === '"'.
 * @param {string} line
 * @param {number} start
 * @param {number} lineNum
 * @returns {{value: string, end: number}}
 */
function scanWrappedValue(line, start, lineNum) {
  const chars = [];
  let i = start + 1;

  while (i < line.length) {
    const c = line[i];

    if (c === "\\" && i + 1 < line.length && (line[i + 1] === '"' || line[i + 1] === "\\")) {
      chars.push(line[i + 1]);
      i += 2;
      continue;
    }

    if (c === '"') {
      return { value: chars.join(""), end: i + 1 };
    }

    chars.push(c);
    i += 1;
  }

  throw new UnterminatedValueError("Unterminated quoted value", lineNum);
}

/**
 * Parse a single record line into an object.
 * @param {string} line - The record line
 * @param {Map<string, {type: string, label: string}>} delimiterMap
 * @param {number} lineNum - Line number for error reporting
 * @returns {Object}
 */
function parseRecord(line, delimiterMap, lineNum) {
  if (!line) {
    return {};
  }

  const record = {};
  let position = 0;

  while (position < line.length) {
    let value;

    // A field is value-then-delimiter. The value may be wrapped in double
    // quotes, which lets it contain delimiter characters (SPEC 6.2).
    if (line[position] === '"') {
      const scanned = scanWrappedValue(line, position, lineNum);
      value = scanned.value;
      position = scanned.end;

      if (position >= line.length) {
        throw new KDGError(`Missing delimiter after value "${value}"`, lineNum);
      }
    } else {
      const start = position;
      while (position < line.length && !delimiterMap.has(line[position])) {
        position += 1;
      }

      if (position === line.length) {
        throw new KDGError(
          `No delimiter found for value starting at column ${start}`,
          lineNum
        );
      }

      value = line.slice(start, position);
    }

    const delimiter = line[position];

    if (!delimiterMap.has(delimiter)) {
      throw new UndefinedDelimiterError(
        `Undefined delimiter: "${delimiter}"`,
        lineNum
      );
    }

    const fieldDef = delimiterMap.get(delimiter);

    if (Object.hasOwn(record, fieldDef.label)) {
      throw new DuplicateFieldError(
        `Duplicate field in record: "${fieldDef.label}"`,
        lineNum
      );
    }

    record[fieldDef.label] = convertValue(value, fieldDef.type, lineNum);
    position += 1;
  }

  return record;
}

/**
 * Parse a KDG document into a list of records.
 * @param {string} content - The full KDG document
 * @returns {Object[]} Array of record objects
 */
function parse(content) {
  const lines = content.replace(/\r\n/g, "\n").split("\n");

  // A trailing newline produces a spurious final empty element. Drop it so a
  // document with no blank-line separator is reported as MissingSeparator
  // instead of having its first record misread as a definition.
  if (lines.length && lines[lines.length - 1] === "") {
    lines.pop();
  }

  // Find the separator (blank line)
  let separatorIdx = null;
  for (let i = 0; i < lines.length; i++) {
    if (lines[i] === "") {
      separatorIdx = i;
      break;
    }
  }

  if (separatorIdx === null) {
    throw new MissingSeparatorError(
      "No blank line separator found between definitions and data"
    );
  }

  // Parse definitions
  const delimiterMap = new Map();
  for (let i = 0; i < separatorIdx; i++) {
    const line = lines[i];
    if (!line) continue; // Skip empty lines

    const fieldDef = parseDefinition(line, i + 1);

    if (delimiterMap.has(fieldDef.delimiter)) {
      const existing = delimiterMap.get(fieldDef.delimiter);
      throw new DuplicateDelimiterError(
        `Delimiter "${fieldDef.delimiter}" already used for field "${existing.label}"`,
        i + 1
      );
    }

    delimiterMap.set(fieldDef.delimiter, fieldDef);
  }

  // Parse records
  const records = [];
  for (let i = separatorIdx + 1; i < lines.length; i++) {
    const line = lines[i];
    if (!line) continue; // Skip empty lines

    const record = parseRecord(line, delimiterMap, i + 1);
    records.push(record);
  }

  return records;
}

/**
 * Validate a KDG document.
 * @param {string} content - The full KDG document
 * @returns {{valid: boolean, error: string|null}}
 */
function validate(content) {
  try {
    parse(content);
    return { valid: true, error: null };
  } catch (e) {
    if (e instanceof KDGError) {
      return { valid: false, error: e.message };
    }
    throw e;
  }
}

/**
 * Convert parsed records to JSON string.
 * @param {Object[]} records
 * @param {number} indent
 * @returns {string}
 */
function toJSON(records, indent = 2) {
  return JSON.stringify(records, null, indent);
}

/**
 * Convert parsed records to CSV string.
 * @param {Object[]} records
 * @returns {string}
 */
function toCSV(records) {
  if (!records.length) {
    return "";
  }

  // Get all unique keys across all records
  const allKeys = [];
  const seen = new Set();
  for (const record of records) {
    for (const key of Object.keys(record)) {
      if (!seen.has(key)) {
        allKeys.push(key);
        seen.add(key);
      }
    }
  }

  // Build CSV
  const escapeCSV = (value) => {
    const s = value != null ? String(value) : "";
    if (s.includes(",") || s.includes('"') || s.includes("\n")) {
      return '"' + s.replace(/"/g, '""') + '"';
    }
    return s;
  };

  const lines = [allKeys.map(escapeCSV).join(",")];
  for (const record of records) {
    const row = allKeys.map((k) => escapeCSV(record[k]));
    lines.push(row.join(","));
  }

  return lines.join("\n");
}

/**
 * CLI entry point.
 */
function main() {
  const args = process.argv.slice(2);

  if (args.length < 2) {
    console.log(`KDG Parser - Reference Implementation

Usage:
  node kdg.js parse <file>           Parse KDG to JSON
  node kdg.js validate <file>        Validate KDG syntax
  node kdg.js convert <file> [fmt]   Convert to format (json, csv)`);
    process.exit(1);
  }

  const [command, filepath] = args;
  let content;

  try {
    content = fs.readFileSync(filepath, "utf-8");
  } catch (e) {
    if (e.code === "ENOENT") {
      console.error(`Error: File not found: ${filepath}`);
    } else {
      console.error(`Error reading file: ${e.message}`);
    }
    process.exit(1);
  }

  switch (command) {
    case "parse":
      try {
        const records = parse(content);
        console.log(toJSON(records));
      } catch (e) {
        if (e instanceof KDGError) {
          console.error(`Parse error: ${e.message}`);
          process.exit(1);
        }
        throw e;
      }
      break;

    case "validate":
      const { valid, error } = validate(content);
      if (valid) {
        console.log("Valid KDG document");
      } else {
        console.error(`Invalid: ${error}`);
        process.exit(1);
      }
      break;

    case "convert":
      const fmt = args[2] || "json";
      try {
        const records = parse(content);
        if (fmt === "json") {
          console.log(toJSON(records));
        } else if (fmt === "csv") {
          console.log(toCSV(records));
        } else {
          console.error(`Unknown format: ${fmt}`);
          process.exit(1);
        }
      } catch (e) {
        if (e instanceof KDGError) {
          console.error(`Parse error: ${e.message}`);
          process.exit(1);
        }
        throw e;
      }
      break;

    default:
      console.error(`Unknown command: ${command}`);
      console.log(`
Usage:
  node kdg.js parse <file>           Parse KDG to JSON
  node kdg.js validate <file>        Validate KDG syntax
  node kdg.js convert <file> [fmt]   Convert to format (json, csv)`);
      process.exit(1);
  }
}

// Export for use as module
module.exports = {
  parse,
  validate,
  toJSON,
  toCSV,
  KDGError,
  DuplicateDelimiterError,
  InvalidTypeError,
  MalformedDefinitionError,
  UndefinedDelimiterError,
  DuplicateFieldError,
  TypeMismatchError,
  MissingSeparatorError,
};

// Run CLI if executed directly
if (require.main === module) {
  main();
}
