#!/usr/bin/env node
/**
 * KDG (Key-Delimiter Grammar) Parser - Reference Implementation
 *
 * Usage:
 *   node kdg.ts parse <file>           Parse KDG to JSON
 *   node kdg.ts validate <file>        Validate KDG syntax
 *   node kdg.ts convert <file> [fmt]   Convert to format (json, csv)
 *
 * Port of implementations/kdg.go. No dependencies beyond the Node standard
 * library; the annotations stay erasable so Node can run the file directly.
 */

import * as fs from "node:fs";

/** A field definition from the KDG header. */
type FieldDef = {
  type: string;
  label: string;
  delimiter: string;
};

/** A coerced field value: str, int, float, bool or date. */
type KdgValue = string | number | boolean;

/** One parsed record: label -> value, keys in first-seen order. */
type KdgRecord = Record<string, KdgValue>;

/** A parsed document: its records plus the declared type of each label. */
type KdgDocument = {
  records: KdgRecord[];
  fieldTypes: Map<string, string>;
};

/** A KDG parsing error. `line` is null only for MissingSeparator. */
class KDGError extends Error {
  line: number | null;

  constructor(message: string, line: number | null = null) {
    super(line === null ? message : `Line ${line}: ${message}`);
    this.name = "KDGError";
    this.line = line;
  }
}

const VALID_TYPES = new Set(["str", "int", "float", "bool", "date"]);

/** Characters that cannot be delimiters (SPEC 3.4). */
const RESERVED_CHARS = new Set(
  'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789:" \t\n\r'
);

/**
 * Definition line pattern (SPEC 5.2). The `u` flag makes `.` match a whole code
 * point, so a delimiter outside the BMP works exactly as in the Go reference.
 */
const DEFINITION_PATTERN = /^([a-z]+):"((?:[^"\\]|\\.)*)"(.)$/u;

/** Parse a single field definition line. */
function parseDefinition(line: string, lineNum: number): FieldDef {
  const match = DEFINITION_PATTERN.exec(line);
  if (match === null) {
    throw new KDGError(`Invalid definition syntax: '${line}'`, lineNum);
  }

  const typeName = match[1];
  const rawLabel = match[2];
  const delimiter = match[3];

  if (!VALID_TYPES.has(typeName)) {
    throw new KDGError(`Unknown type: '${typeName}'`, lineNum);
  }

  if (RESERVED_CHARS.has(delimiter)) {
    throw new KDGError(
      `Invalid delimiter: '${delimiter}' (reserved character)`,
      lineNum
    );
  }

  // Unescape the label. Order matters: \" first, then \\.
  const label = rawLabel.replace(/\\"/g, '"').replace(/\\\\/g, "\\");

  return { type: typeName, label, delimiter };
}

const INTEGER_PATTERN = /^[+-]?[0-9]+$/;
const FLOAT_BODY_PATTERN = /^(?:[0-9]+\.?[0-9]*|\.[0-9]+)(?:[eE][+-]?[0-9]+)?$/;

/**
 * Mirrors strconv.Atoi: an optional sign followed by one or more digits.
 * SPEC 4.3 makes overflow of the implementation's integer range a
 * TypeMismatch, and JavaScript numbers are exact only up to 2^53.
 */
function parseInteger(value: string): number | null {
  if (!INTEGER_PATTERN.test(value)) return null;

  const parsed = Number(value);
  return Number.isSafeInteger(parsed) ? parsed : null;
}

/**
 * Mirrors strconv.ParseFloat for the forms SPEC 4.4 covers (sign, digits,
 * optional fraction, optional exponent) plus the special values it accepts
 * (Inf/Infinity/NaN). Whitespace and junk are rejected, and overflow to
 * infinity is an error, like strconv.ErrRange.
 */
function parseFloat(value: string): number | null {
  if (value === "") return null;

  let body = value;
  let negative = false;
  if (body[0] === "+" || body[0] === "-") {
    negative = body[0] === "-";
    body = body.slice(1);
  }
  if (body === "") return null;

  const lower = body.toLowerCase();
  if (lower === "inf" || lower === "infinity") {
    return negative ? -Infinity : Infinity;
  }
  if (lower === "nan") return NaN;

  if (!FLOAT_BODY_PATTERN.test(body)) return null;

  const parsed = Number(value);
  return Number.isFinite(parsed) ? parsed : null;
}

function daysInMonth(year: number, month: number): number {
  switch (month) {
    case 1:
    case 3:
    case 5:
    case 7:
    case 8:
    case 10:
    case 12:
      return 31;
    case 4:
    case 6:
    case 9:
    case 11:
      return 30;
    case 2:
      return year % 4 === 0 && (year % 100 !== 0 || year % 400 === 0) ? 29 : 28;
    default:
      return 0;
  }
}

/** YYYY-MM-DD, year 1..9999, real calendar day (SPEC 4.6). */
function isValidDate(value: string): boolean {
  const parts = value.split("-");
  if (parts.length !== 3) return false;

  const year = parseInteger(parts[0]);
  const month = parseInteger(parts[1]);
  const day = parseInteger(parts[2]);
  if (year === null || month === null || day === null) return false;
  if (year < 1 || year > 9999 || month < 1 || month > 12) return false;

  return day >= 1 && day <= daysInMonth(year, month);
}

/** Convert a raw string value to its typed representation. */
function convertValue(value: string, typeName: string, lineNum: number): KdgValue {
  switch (typeName) {
    case "str":
      return value;

    case "int": {
      const parsed = parseInteger(value);
      if (parsed === null) {
        throw new KDGError(`Invalid integer: '${value}'`, lineNum);
      }
      return parsed;
    }

    case "float": {
      const parsed = parseFloat(value);
      if (parsed === null) {
        throw new KDGError(`Invalid float: '${value}'`, lineNum);
      }
      return parsed;
    }

    case "bool": {
      const lower = value.toLowerCase();
      if (lower === "true" || lower === "1") return true;
      if (lower === "false" || lower === "0") return false;
      throw new KDGError(`Invalid boolean: '${value}'`, lineNum);
    }

    case "date":
      if (isValidDate(value)) return value; // keep the string form, as Go does
      throw new KDGError(`Invalid date (expected YYYY-MM-DD): '${value}'`, lineNum);

    default:
      throw new KDGError(`Unknown type: '${typeName}'`, lineNum);
  }
}

/**
 * Scan a double-quoted value at chars[start] === '"'. Returns the unescaped
 * value and the index just after the closing quote (SPEC 6.2).
 */
function scanWrappedValue(
  chars: string[],
  start: number,
  lineNum: number
): { value: string; end: number } {
  const out: string[] = [];
  let i = start + 1;

  while (i < chars.length) {
    const c = chars[i];

    if (
      c === "\\" &&
      i + 1 < chars.length &&
      (chars[i + 1] === '"' || chars[i + 1] === "\\")
    ) {
      out.push(chars[i + 1]);
      i += 2;
      continue;
    }

    if (c === '"') {
      return { value: out.join(""), end: i + 1 };
    }

    out.push(c);
    i += 1;
  }

  throw new KDGError("Unterminated quoted value", lineNum);
}

/** Parse a single record line into an object. */
function parseRecord(
  line: string,
  delimiterMap: Map<string, FieldDef>,
  lineNum: number
): KdgRecord {
  // A null-prototype object keeps a label like "__proto__" an ordinary key.
  const record: KdgRecord = Object.create(null);

  // Scan by code point, matching the Go reference's rune indexing.
  const chars = Array.from(line);
  let position = 0;

  while (position < chars.length) {
    let value: string;

    // A field is value-then-delimiter; a quoted value may contain delimiters.
    if (chars[position] === '"') {
      const scanned = scanWrappedValue(chars, position, lineNum);
      value = scanned.value;
      position = scanned.end;

      if (position >= chars.length) {
        throw new KDGError(`Missing delimiter after value '${value}'`, lineNum);
      }
    } else {
      const start = position;
      while (position < chars.length && !delimiterMap.has(chars[position])) {
        position += 1;
      }

      if (position === chars.length) {
        throw new KDGError(
          `No delimiter found for value starting at column ${start}`,
          lineNum
        );
      }

      value = chars.slice(start, position).join("");
    }

    const delimiter = chars[position];

    const field = delimiterMap.get(delimiter);
    if (field === undefined) {
      throw new KDGError(`Undefined delimiter: '${delimiter}'`, lineNum);
    }

    if (Object.hasOwn(record, field.label)) {
      throw new KDGError(`Duplicate field in record: '${field.label}'`, lineNum);
    }

    record[field.label] = convertValue(value, field.type, lineNum);
    position += 1;
  }

  return record;
}

/** Parse a KDG document into its records and declared field types. */
function parse(content: string): KdgDocument {
  const lines = content.replace(/\r\n/g, "\n").split("\n");

  // A trailing newline leaves one spurious empty element. Drop it so a document
  // with no separator reports MissingSeparator instead of having its first
  // record read as a definition.
  if (lines.length > 0 && lines[lines.length - 1] === "") {
    lines.pop();
  }

  // The separator is the first empty line.
  let separatorIdx = -1;
  for (let i = 0; i < lines.length; i++) {
    if (lines[i] === "") {
      separatorIdx = i;
      break;
    }
  }

  if (separatorIdx < 0) {
    throw new KDGError(
      "No blank line separator found between definitions and data",
      null
    );
  }

  const delimiterMap = new Map<string, FieldDef>();
  for (let i = 0; i < separatorIdx; i++) {
    const line = lines[i];
    if (line === "") continue;

    const field = parseDefinition(line, i + 1);

    const existing = delimiterMap.get(field.delimiter);
    if (existing !== undefined) {
      throw new KDGError(
        `Delimiter '${field.delimiter}' already used for field '${existing.label}'`,
        i + 1
      );
    }

    delimiterMap.set(field.delimiter, field);
  }

  const records: KdgRecord[] = [];
  for (let i = separatorIdx + 1; i < lines.length; i++) {
    const line = lines[i];
    if (line === "") continue;

    records.push(parseRecord(line, delimiterMap, i + 1));
  }

  const fieldTypes = new Map<string, string>();
  for (const field of delimiterMap.values()) {
    fieldTypes.set(field.label, field.type);
  }

  return { records, fieldTypes };
}

/** Name a non-finite float the way encoding/json does. */
function unsupportedFloatName(value: number): string {
  if (Number.isNaN(value)) return "NaN";
  return value > 0 ? "+Inf" : "-Inf";
}

/**
 * Serialize records as JSON with 2-space indentation and a trailing newline.
 * A non-finite float has no JSON representation; JSON.stringify would silently
 * write null, so it is refused the way encoding/json refuses it.
 */
function toJSON(records: KdgRecord[]): string {
  for (const record of records) {
    for (const key of Object.keys(record)) {
      const value = record[key];
      if (typeof value === "number" && !Number.isFinite(value)) {
        throw new KDGError(`json: unsupported value: ${unsupportedFloatName(value)}`, null);
      }
    }
  }

  return JSON.stringify(records, null, 2) + "\n";
}

/** Render a float the way strconv.FormatFloat(v, 'g', -1, 64) does. */
function csvFloat(value: number): string {
  if (Number.isNaN(value)) return "NaN";
  if (value === Infinity) return "+Inf";
  if (value === -Infinity) return "-Inf";
  return String(value);
}

/**
 * Render a value the way the Go reference's csvValue does. JavaScript has one
 * number type, so the declared field type decides between the integer and the
 * float rendering.
 */
function csvValue(value: KdgValue | undefined, typeName: string | undefined): string {
  if (typeof value === "string") return value;
  if (typeof value === "boolean") return value ? "True" : "False";
  if (typeof value === "number") {
    if (typeName === "int") return String(value);
    const text = csvFloat(value);
    return /[.eEni]/.test(text) ? text : text + ".0";
  }
  return "";
}

/** Quote a field containing a comma, double quote, or newline. */
function escapeCSV(field: string): string {
  if (field.includes(",") || field.includes('"') || field.includes("\n")) {
    return '"' + field.replace(/"/g, '""') + '"';
  }
  return field;
}

/** Serialize a document as CSV: keys in first-seen order across all records. */
function toCSV(document: KdgDocument): string {
  if (document.records.length === 0) return "";

  const allKeys: string[] = [];
  const seen = new Set<string>();
  for (const record of document.records) {
    for (const key of Object.keys(record)) {
      if (!seen.has(key)) {
        seen.add(key);
        allKeys.push(key);
      }
    }
  }

  const rows: string[] = [allKeys.map(escapeCSV).join(",")];
  for (const record of document.records) {
    rows.push(
      allKeys
        .map((key) => escapeCSV(csvValue(record[key], document.fieldTypes.get(key))))
        .join(",")
    );
  }

  return rows.join("\n");
}

const USAGE = "Usage: kdg <parse|validate|convert> <file> [json|csv]";

/** Parse, reporting a KDG error to stderr; null means the caller exits 1. */
function tryParse(content: string): KdgDocument | null {
  return reportErrors(() => parse(content));
}

/** Run a step that can raise a KDG error, reporting it as a parse error. */
function reportErrors<T>(step: () => T): T | null {
  try {
    return step();
  } catch (err) {
    if (err instanceof KDGError) {
      process.stderr.write(`Parse error: ${err.message}\n`);
      return null;
    }
    throw err;
  }
}

/** Execute the CLI and return the process exit code. */
function run(args: string[]): number {
  if (args.length < 2) {
    process.stderr.write(USAGE + "\n");
    return 1;
  }

  const command = args[0];
  const filepath = args[1];

  let content: string;
  try {
    content = fs.readFileSync(filepath, "utf-8");
  } catch (err) {
    if ((err as { code?: string }).code === "ENOENT") {
      process.stderr.write(`Error: File not found: ${filepath}\n`);
    } else {
      process.stderr.write(`Error reading file: ${(err as Error).message}\n`);
    }
    return 1;
  }

  switch (command) {
    case "parse": {
      const document = tryParse(content);
      if (document === null) return 1;
      const json = reportErrors(() => toJSON(document.records));
      if (json === null) return 1;
      process.stdout.write(json);
      return 0;
    }

    case "validate": {
      try {
        parse(content);
      } catch (err) {
        if (err instanceof KDGError) {
          process.stderr.write(`Invalid: ${err.message}\n`);
          return 1;
        }
        throw err;
      }
      process.stdout.write("Valid KDG document\n");
      return 0;
    }

    case "convert": {
      const format = args.length > 2 ? args[2] : "json";
      const document = tryParse(content);
      if (document === null) return 1;

      if (format === "json") {
        const json = reportErrors(() => toJSON(document.records));
        if (json === null) return 1;
        process.stdout.write(json);
      } else if (format === "csv") {
        process.stdout.write(toCSV(document) + "\n");
      } else {
        process.stderr.write(`Unknown format: ${format}\n`);
        return 1;
      }
      return 0;
    }

    default:
      process.stderr.write(`Unknown command: ${command}\n`);
      process.stderr.write(USAGE + "\n");
      return 1;
  }
}

process.exit(run(process.argv.slice(2)));
