// KDG (Key-Delimiter Grammar) Parser - Swift reference implementation.
//
// Usage:
//
//   swift kdg.swift parse <file>           Parse KDG to JSON
//   swift kdg.swift validate <file>        Validate KDG syntax
//   swift kdg.swift convert <file> [fmt]   Convert to format (json, csv)
//
// Single file, standard library only (plus libc for file and stream I/O). The
// parsing behaviour (definition grammar, label unescaping, trailing-newline
// handling, record scanning, wrapped values, type coercion and error messages)
// intentionally reproduces the Go reference implementation.

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

let usage = "Usage: kdg <parse|validate|convert> <file> [json|csv]"

let validTypes: Set<String> = ["str", "int", "float", "bool", "date"]

/// A parsing error. `line` is 0 when the error carries no line number prefix
/// (only MissingSeparator does).
struct KdgError: Error {
    let message: String
    let line: Int

    init(_ message: String, line: Int = 0) {
        self.message = message
        self.line = line
    }

    var description: String {
        return line > 0 ? "Line \(line): \(message)" : message
    }
}

/// A field definition from the KDG header.
struct FieldDef {
    let typeName: String
    let label: String
    let delimiter: Unicode.Scalar
}

/// A typed field value.
enum Value {
    case str(String)
    case int(Int)
    case float(Double)
    case bool(Bool)
}

/// One parsed record: values plus the first-seen key order within the record.
struct Record {
    var values: [String: Value] = [:]
    var keys: [String] = []
}

// MARK: - Scalar helpers

func scalarString(_ scalar: Unicode.Scalar) -> String {
    var s = ""
    s.unicodeScalars.append(scalar)
    return s
}

func scalarsToString<S: Sequence>(_ scalars: S) -> String
where S.Element == Unicode.Scalar {
    var s = ""
    for u in scalars {
        s.unicodeScalars.append(u)
    }
    return s
}

/// Replace every occurrence of `from` with `to`, scanning left to right without
/// overlap (the analogue of Go's strings.ReplaceAll).
func replaceAll(_ input: String, _ from: String, _ to: String) -> String {
    let source = Array(input.unicodeScalars)
    let pattern = Array(from.unicodeScalars)
    let replacement = Array(to.unicodeScalars)
    if pattern.isEmpty {
        return input
    }

    var result = ""
    var i = 0
    while i + pattern.count <= source.count {
        var matched = true
        var k = 0
        while k < pattern.count {
            if source[i + k] != pattern[k] {
                matched = false
                break
            }
            k += 1
        }
        if matched {
            for u in replacement {
                result.unicodeScalars.append(u)
            }
            i += pattern.count
        } else {
            result.unicodeScalars.append(source[i])
            i += 1
        }
    }
    while i < source.count {
        result.unicodeScalars.append(source[i])
        i += 1
    }
    return result
}

/// Normalise CRLF line endings to LF.
func normalizeNewlines(_ input: String) -> String {
    let scalars = Array(input.unicodeScalars)
    var out = ""
    var i = 0
    while i < scalars.count {
        if scalars[i].value == 0x0d && i + 1 < scalars.count && scalars[i + 1].value == 0x0a {
            i += 1
            continue
        }
        out.unicodeScalars.append(scalars[i])
        i += 1
    }
    return out
}

// MARK: - Definitions

/// Characters that cannot be delimiters (SPEC 3.3).
func isReserved(_ cp: UInt32) -> Bool {
    if cp >= 0x61 && cp <= 0x7a { return true } // a-z
    if cp >= 0x41 && cp <= 0x5a { return true } // A-Z
    if cp >= 0x30 && cp <= 0x39 { return true } // 0-9
    return cp == 0x3a // :
        || cp == 0x22 // "
        || cp == 0x20 // space
        || cp == 0x09 // tab
        || cp == 0x0a // LF
        || cp == 0x0d // CR
}

/// Parse a single field definition line.
///
/// Equivalent to matching the reference regex
/// `^([a-z]+):"((?:[^"\\]|\\.)*)"(.)$` and extracting its three groups. The
/// match is deterministic: the label ends at the first unescaped double quote,
/// and exactly one character must follow it.
func parseDefinition(_ line: String, _ lineNum: Int) throws -> FieldDef {
    let scalars = Array(line.unicodeScalars)
    let n = scalars.count

    func invalid() -> KdgError {
        return KdgError("Invalid definition syntax: '\(line)'", line: lineNum)
    }

    var i = 0
    while i < n && scalars[i].value >= 0x61 && scalars[i].value <= 0x7a {
        i += 1
    }
    let typeEnd = i
    guard typeEnd > 0, typeEnd < n, scalars[i].value == 0x3a else { throw invalid() } // ':'
    i += 1
    guard i < n, scalars[i].value == 0x22 else { throw invalid() } // '"'
    i += 1

    let labelStart = i
    var closeIdx = -1
    while i < n {
        let c = scalars[i].value
        if c == 0x5c { // '\' begins an escape that consumes one more character
            if i + 1 >= n { break }
            i += 2
            continue
        }
        if c == 0x22 { // '"'
            closeIdx = i
            break
        }
        i += 1
    }
    guard closeIdx >= 0, closeIdx + 2 == n else { throw invalid() }

    let typeName = scalarsToString(scalars[0..<typeEnd])
    let rawLabel = scalarsToString(scalars[labelStart..<closeIdx])
    let delimiter = scalars[closeIdx + 1]

    guard validTypes.contains(typeName) else {
        throw KdgError("Unknown type: '\(typeName)'", line: lineNum)
    }

    guard !isReserved(delimiter.value) else {
        throw KdgError(
            "Invalid delimiter: '\(scalarString(delimiter))' (reserved character)",
            line: lineNum)
    }

    // Unescape the label. Order matters: \" first, then \\.
    let label = replaceAll(replaceAll(rawLabel, "\\\"", "\""), "\\\\", "\\")

    return FieldDef(typeName: typeName, label: label, delimiter: delimiter)
}

// MARK: - Value coercion

/// True for an ASCII decimal digit.
func isAsciiDigit(_ cp: UInt32) -> Bool {
    return cp >= 0x30 && cp <= 0x39
}

/// The integer grammar of SPEC 4.3: `[+-]?[0-9]+` (ASCII digits only). A
/// platform integer parser would otherwise accept spellings outside the
/// grammar (surrounding whitespace, underscores, hex prefixes).
func isDecimalInteger(_ s: String) -> Bool {
    let scalars = Array(s.unicodeScalars)
    if scalars.isEmpty {
        return false
    }
    var i = 0
    if scalars[0].value == 0x2b || scalars[0].value == 0x2d { // '+' or '-'
        i = 1
    }
    if i >= scalars.count {
        return false
    }
    while i < scalars.count {
        if !isAsciiDigit(scalars[i].value) {
            return false
        }
        i += 1
    }
    return true
}

/// The float grammar of SPEC 4.4: decimal notation with an optional exponent,
/// i.e. `[+-]?([0-9]+(\.[0-9]*)?|\.[0-9]+)([eE][+-]?[0-9]+)?`.
func isDecimalFloat(_ s: String) -> Bool {
    let scalars = Array(s.unicodeScalars)
    var i = 0
    let n = scalars.count

    if i < n && (scalars[i].value == 0x2b || scalars[i].value == 0x2d) { // '+' or '-'
        i += 1
    }

    var integerDigits = 0
    while i < n && isAsciiDigit(scalars[i].value) {
        i += 1
        integerDigits += 1
    }

    var fractionDigits = 0
    if i < n && scalars[i].value == 0x2e { // '.'
        i += 1
        while i < n && isAsciiDigit(scalars[i].value) {
            i += 1
            fractionDigits += 1
        }
    }

    if integerDigits == 0 && fractionDigits == 0 {
        return false
    }

    if i < n && (scalars[i].value == 0x65 || scalars[i].value == 0x45) { // 'e' or 'E'
        i += 1
        if i < n && (scalars[i].value == 0x2b || scalars[i].value == 0x2d) {
            i += 1
        }
        var exponentDigits = 0
        while i < n && isAsciiDigit(scalars[i].value) {
            i += 1
            exponentDigits += 1
        }
        if exponentDigits == 0 {
            return false
        }
    }

    return i == n
}

func daysInMonth(_ year: Int, _ month: Int) -> Int {
    let days = [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
    if month == 2 && year % 4 == 0 && (year % 100 != 0 || year % 400 == 0) {
        return 29
    }
    return days[month - 1]
}

func isValidDate(_ value: String) -> Bool {
    let parts = value.split(separator: "-", omittingEmptySubsequences: false)
    guard parts.count == 3,
        let year = Int(parts[0]),
        let month = Int(parts[1]),
        let day = Int(parts[2]),
        year >= 1, year <= 9999,
        month >= 1, month <= 12
    else { return false }
    return day >= 1 && day <= daysInMonth(year, month)
}

/// Convert a string value to its typed representation.
func convertValue(_ value: String, _ typeName: String, _ lineNum: Int) throws -> Value {
    switch typeName {
    case "str":
        return .str(value)

    case "int":
        guard isDecimalInteger(value), let parsed = Int(value) else {
            throw KdgError("Invalid integer: '\(value)'", line: lineNum)
        }
        return .int(parsed)

    case "float":
        guard isDecimalFloat(value), let parsed = Double(value), parsed.isFinite else {
            throw KdgError("Invalid float: '\(value)'", line: lineNum)
        }
        return .float(parsed)

    case "bool":
        let lower = value.lowercased()
        if lower == "true" || lower == "1" { return .bool(true) }
        if lower == "false" || lower == "0" { return .bool(false) }
        throw KdgError("Invalid boolean: '\(value)'", line: lineNum)

    case "date":
        if isValidDate(value) {
            return .str(value) // Return as string for JSON compatibility
        }
        throw KdgError("Invalid date (expected YYYY-MM-DD): '\(value)'", line: lineNum)

    default:
        throw KdgError("Unknown type: '\(typeName)'", line: lineNum)
    }
}

// MARK: - Records

/// Scan a double-quoted value beginning at `scalars[start]` == '"'. Returns the
/// value and the position just after the closing quote. Backslash escapes for
/// `\"` and `\\` are honoured per SPEC 6.2.
func scanWrappedValue(
    _ scalars: [Unicode.Scalar], _ start: Int, _ lineNum: Int
) throws -> (value: String, position: Int) {
    var chars: [Unicode.Scalar] = []
    var i = start + 1

    while i < scalars.count {
        let c = scalars[i]
        if c.value == 0x5c && i + 1 < scalars.count
            && (scalars[i + 1].value == 0x22 || scalars[i + 1].value == 0x5c)
        {
            chars.append(scalars[i + 1])
            i += 2
            continue
        }
        if c.value == 0x22 {
            return (scalarsToString(chars), i + 1)
        }
        chars.append(c)
        i += 1
    }

    throw KdgError("Unterminated quoted value", line: lineNum)
}

/// Parse a single record line.
func parseRecord(
    _ line: String, _ delimiterMap: [Unicode.Scalar: FieldDef], _ lineNum: Int
) throws -> Record {
    var record = Record()
    if line.isEmpty {
        return record
    }

    let scalars = Array(line.unicodeScalars)
    var position = 0

    while position < scalars.count {
        let value: String

        // A field is value-then-delimiter. The value may be wrapped in double
        // quotes, which lets it contain delimiter characters (SPEC 6.2).
        if scalars[position].value == 0x22 {
            let scanned = try scanWrappedValue(scalars, position, lineNum)
            value = scanned.value
            position = scanned.position
            if position >= scalars.count {
                throw KdgError("Missing delimiter after value '\(value)'", line: lineNum)
            }
        } else {
            let start = position
            while position < scalars.count && delimiterMap[scalars[position]] == nil {
                position += 1
            }
            if position == scalars.count {
                throw KdgError(
                    "No delimiter found for value starting at column \(start)",
                    line: lineNum)
            }
            value = scalarsToString(scalars[start..<position])
        }

        let delimiter = scalars[position]
        guard let field = delimiterMap[delimiter] else {
            throw KdgError(
                "Undefined delimiter: '\(scalarString(delimiter))'", line: lineNum)
        }

        guard record.values[field.label] == nil else {
            throw KdgError("Duplicate field in record: '\(field.label)'", line: lineNum)
        }

        record.values[field.label] = try convertValue(value, field.typeName, lineNum)
        record.keys.append(field.label)
        position += 1
    }

    return record
}

// MARK: - Document

/// Parse a KDG document into a list of records.
func parse(_ content: String) throws -> [Record] {
    var lines = normalizeNewlines(content)
        .split(separator: "\n", omittingEmptySubsequences: false)

    // A trailing newline produces a spurious final empty element. Drop it so a
    // document with no blank-line separator is reported as MissingSeparator
    // instead of having its first record misread as a definition.
    if let last = lines.last, last.isEmpty {
        lines.removeLast()
    }

    // Find the separator (blank line).
    var separatorIdx = -1
    for (i, line) in lines.enumerated() where line.isEmpty {
        separatorIdx = i
        break
    }
    guard separatorIdx >= 0 else {
        throw KdgError("No blank line separator found between definitions and data")
    }

    // Parse definitions.
    var delimiterMap: [Unicode.Scalar: FieldDef] = [:]
    for i in 0..<separatorIdx {
        let line = String(lines[i])
        if line.isEmpty { continue } // Skip empty lines in the definition block

        let field = try parseDefinition(line, i + 1)
        if let existing = delimiterMap[field.delimiter] {
            throw KdgError(
                "Delimiter '\(scalarString(field.delimiter))' already used for field '\(existing.label)'",
                line: i + 1)
        }
        delimiterMap[field.delimiter] = field
    }

    // Parse records.
    var records: [Record] = []
    for i in (separatorIdx + 1)..<lines.count {
        let line = String(lines[i])
        if line.isEmpty { continue } // Skip empty lines in the data block
        records.append(try parseRecord(line, delimiterMap, i + 1))
    }

    return records
}

// MARK: - Output

func jsonEscape(_ s: String) -> String {
    var out = ""
    for scalar in s.unicodeScalars {
        switch scalar.value {
        case 0x22: out += "\\\""
        case 0x5c: out += "\\\\"
        case 0x08: out += "\\b"
        case 0x0c: out += "\\f"
        case 0x0a: out += "\\n"
        case 0x0d: out += "\\r"
        case 0x09: out += "\\t"
        default:
            if scalar.value < 0x20 {
                out += unicodeEscape(scalar.value)
            } else {
                out.unicodeScalars.append(scalar)
            }
        }
    }
    return out
}

func unicodeEscape(_ value: UInt32) -> String {
    let digits: [Character] = [
        "0", "1", "2", "3", "4", "5", "6", "7",
        "8", "9", "a", "b", "c", "d", "e", "f",
    ]
    var s = "\\u"
    s.append(digits[Int((value >> 12) & 0xf)])
    s.append(digits[Int((value >> 8) & 0xf)])
    s.append(digits[Int((value >> 4) & 0xf)])
    s.append(digits[Int(value & 0xf)])
    return s
}

func jsonValue(_ value: Value) -> String {
    switch value {
    case .str(let s): return "\"\(jsonEscape(s))\""
    case .int(let i): return String(i)
    case .float(let d): return String(d)
    case .bool(let b): return b ? "true" : "false"
    }
}

/// Convert parsed records to a JSON string with 2-space indentation. Keys are
/// emitted in first-seen order within each record.
func toJSON(_ records: [Record]) -> String {
    if records.isEmpty {
        return "[]"
    }

    var out = "[\n"
    for (index, record) in records.enumerated() {
        if record.keys.isEmpty {
            out += "  {}"
        } else {
            out += "  {\n"
            for (k, key) in record.keys.enumerated() {
                out += "    \""
                out += jsonEscape(key)
                out += "\": "
                out += jsonValue(record.values[key]!)
                if k + 1 < record.keys.count {
                    out += ","
                }
                out += "\n"
            }
            out += "  }"
        }
        if index + 1 < records.count {
            out += ","
        }
        out += "\n"
    }
    out += "]"
    return out
}

/// Render a value the way the Python reference's str() does.
func csvValue(_ value: Value?) -> String {
    guard let value = value else { return "" }
    switch value {
    case .str(let s): return s
    case .int(let i): return String(i)
    case .float(let d): return String(d)
    case .bool(let b): return b ? "True" : "False"
    }
}

/// Quote a field containing a comma, double quote, or newline, doubling
/// internal quotes.
func escapeCSV(_ s: String) -> String {
    if s.contains(",") || s.contains("\"") || s.contains("\n") {
        return "\"" + replaceAll(s, "\"", "\"\"") + "\""
    }
    return s
}

/// Convert parsed records to a CSV string.
func toCSV(_ records: [Record]) -> String {
    if records.isEmpty {
        return ""
    }

    // All unique labels across all records, in first-seen order.
    var allKeys: [String] = []
    var seen: Set<String> = []
    for record in records {
        for key in record.keys where !seen.contains(key) {
            seen.insert(key)
            allKeys.append(key)
        }
    }

    var lines: [String] = [allKeys.map(escapeCSV).joined(separator: ",")]
    for record in records {
        let row = allKeys.map { escapeCSV(csvValue(record.values[$0])) }
        lines.append(row.joined(separator: ","))
    }
    return lines.joined(separator: "\n")
}

// MARK: - I/O

func writeToStream(_ s: String, _ stream: UnsafeMutablePointer<FILE>) {
    let bytes = Array(s.utf8)
    if bytes.isEmpty {
        return
    }
    bytes.withUnsafeBufferPointer { buffer in
        _ = fwrite(buffer.baseAddress, 1, buffer.count, stream)
    }
}

func readFile(_ path: String) -> [UInt8]? {
    guard let handle = fopen(path, "rb") else {
        return nil
    }
    defer { fclose(handle) }

    var data: [UInt8] = []
    let capacity = 65536
    var chunk = [UInt8](repeating: 0, count: capacity)
    while true {
        let count = chunk.withUnsafeMutableBufferPointer { buffer -> Int in
            return fread(buffer.baseAddress, 1, capacity, handle)
        }
        if count <= 0 {
            break
        }
        data.append(contentsOf: chunk[0..<count])
    }
    return data
}

// MARK: - CLI

func run(_ args: [String]) -> Int32 {
    if args.count < 3 {
        writeToStream(usage + "\n", stderr)
        return 1
    }

    let command = args[1]
    let path = args[2]

    guard let bytes = readFile(path) else {
        writeToStream("Error: File not found: \(path)\n", stderr)
        return 1
    }
    let content = String(decoding: bytes, as: UTF8.self)

    if command == "parse" {
        do {
            let records = try parse(content)
            writeToStream(toJSON(records) + "\n", stdout)
            return 0
        } catch let error as KdgError {
            writeToStream("Parse error: \(error.description)\n", stderr)
            return 1
        } catch {
            writeToStream("Parse error: \(error)\n", stderr)
            return 1
        }
    }

    if command == "validate" {
        do {
            _ = try parse(content)
        } catch let error as KdgError {
            writeToStream("Invalid: \(error.description)\n", stderr)
            return 1
        } catch {
            writeToStream("Invalid: \(error)\n", stderr)
            return 1
        }
        writeToStream("Valid KDG document\n", stdout)
        return 0
    }

    if command == "convert" {
        let format = args.count > 3 ? args[3] : "json"
        let records: [Record]
        do {
            records = try parse(content)
        } catch let error as KdgError {
            writeToStream("Parse error: \(error.description)\n", stderr)
            return 1
        } catch {
            writeToStream("Parse error: \(error)\n", stderr)
            return 1
        }
        if format == "json" {
            writeToStream(toJSON(records) + "\n", stdout)
            return 0
        }
        if format == "csv" {
            writeToStream(toCSV(records) + "\n", stdout)
            return 0
        }
        writeToStream("Unknown format: \(format)\n", stderr)
        return 1
    }

    writeToStream("Unknown command: \(command)\n", stderr)
    writeToStream(usage + "\n", stderr)
    return 1
}

exit(run(CommandLine.arguments))
