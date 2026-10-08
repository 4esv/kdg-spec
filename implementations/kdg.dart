// KDG (Key-Delimiter Grammar) Parser - Dart reference implementation.
//
// Usage:
//
//   dart kdg.dart parse <file>           Parse KDG to JSON
//   dart kdg.dart validate <file>        Validate KDG syntax
//   dart kdg.dart convert <file> [fmt]   Convert to format (json, csv)
//
// Single file, standard library only (dart:core, dart:io). The parsing
// behaviour (definition grammar, label unescaping, trailing-newline handling,
// record scanning, wrapped values, type coercion and error messages)
// intentionally reproduces the Go reference implementation.

import 'dart:io';

const String usage = 'Usage: kdg <parse|validate|convert> <file> [json|csv]';

const Set<String> _validTypes = {'str', 'int', 'float', 'bool', 'date'};

// The numeric grammars of SPEC 4.3 and 4.4: an int is `-?[0-9]+`, and a float
// is decimal notation with an optional exponent. Dart's parsers are looser
// than the grammar (int.tryParse accepts surrounding whitespace), so the value
// is matched against the grammar before it is parsed.
final RegExp _intPattern = RegExp(r'^[+-]?[0-9]+$');
final RegExp _floatPattern =
    RegExp(r'^[+-]?(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)(?:[eE][+-]?[0-9]+)?$');

/// A parsing error. [line] is 0 when the error carries no line number prefix
/// (only MissingSeparator does).
class KdgError implements Exception {
  final String message;
  final int line;

  KdgError(this.message, [this.line = 0]);

  @override
  String toString() => line > 0 ? 'Line $line: $message' : message;
}

/// A field definition from the KDG header. [delimiter] is the delimiter's
/// Unicode code point.
class FieldDef {
  final String typeName;
  final String label;
  final int delimiter;

  FieldDef(this.typeName, this.label, this.delimiter);
}

/// Characters that cannot be delimiters (SPEC 3.3).
bool _isReserved(int cp) {
  if (cp >= 0x61 && cp <= 0x7a) return true; // a-z
  if (cp >= 0x41 && cp <= 0x5a) return true; // A-Z
  if (cp >= 0x30 && cp <= 0x39) return true; // 0-9
  return cp == 0x3a || // :
      cp == 0x22 || // "
      cp == 0x20 || // space
      cp == 0x09 || // tab
      cp == 0x0a || // LF
      cp == 0x0d; // CR
}

String _scalarString(int cp) => String.fromCharCode(cp);

/// Replace every occurrence of [from] with [to], scanning left to right
/// (Dart's String.replaceAll, the analogue of Go's strings.ReplaceAll).
String _replaceAll(String input, String from, String to) =>
    input.replaceAll(from, to);

/// Parse a single field definition line.
///
/// Equivalent to matching the reference regex
/// `^([a-z]+):"((?:[^"\\]|\\.)*)"(.)$` and extracting its three groups. The
/// match is deterministic: the label ends at the first unescaped double quote,
/// and exactly one character must follow it.
FieldDef parseDefinition(String line, int lineNum) {
  final s = line.runes.toList();
  final n = s.length;

  KdgError invalid() =>
      KdgError("Invalid definition syntax: '$line'", lineNum);

  var i = 0;
  while (i < n && s[i] >= 0x61 && s[i] <= 0x7a) {
    i++;
  }
  final typeEnd = i;
  if (typeEnd == 0 || typeEnd >= n || s[i] != 0x3a) throw invalid(); // ':'
  i++;
  if (i >= n || s[i] != 0x22) throw invalid(); // '"'
  i++;

  final labelStart = i;
  var closeIdx = -1;
  while (i < n) {
    final c = s[i];
    if (c == 0x5c) {
      // A backslash must be followed by another character to form `\\.`;
      // a trailing backslash cannot be part of the label.
      if (i + 1 >= n) break;
      i += 2;
      continue;
    }
    if (c == 0x22) {
      closeIdx = i;
      break;
    }
    i++;
  }

  if (closeIdx < 0 || closeIdx + 2 != n) throw invalid();

  final typeName = String.fromCharCodes(s.sublist(0, typeEnd));
  final rawLabel = String.fromCharCodes(s.sublist(labelStart, closeIdx));
  final delimiter = s[closeIdx + 1];

  if (!_validTypes.contains(typeName)) {
    throw KdgError("Unknown type: '$typeName'", lineNum);
  }

  if (_isReserved(delimiter)) {
    throw KdgError(
        "Invalid delimiter: '${_scalarString(delimiter)}' (reserved character)",
        lineNum);
  }

  // Unescape the label. Order matters: \" first, then \\.
  final label = _replaceAll(_replaceAll(rawLabel, r'\"', '"'), r'\\', '\\');

  return FieldDef(typeName, label, delimiter);
}

int _daysInMonth(int year, int month) {
  const days = [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];
  if (month == 2 && year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)) {
    return 29;
  }
  return days[month - 1];
}

/// Convert a string value to its typed representation.
Object? convertValue(String value, String typeName, int lineNum) {
  switch (typeName) {
    case 'str':
      return value;

    case 'int':
      final parsed = _intPattern.hasMatch(value) ? int.tryParse(value) : null;
      if (parsed == null) {
        throw KdgError("Invalid integer: '$value'", lineNum);
      }
      return parsed;

    case 'float':
      final parsed =
          _floatPattern.hasMatch(value) ? double.tryParse(value) : null;
      if (parsed == null || !parsed.isFinite) {
        throw KdgError("Invalid float: '$value'", lineNum);
      }
      return parsed;

    case 'bool':
      final lower = value.toLowerCase();
      if (lower == 'true' || lower == '1') return true;
      if (lower == 'false' || lower == '0') return false;
      throw KdgError("Invalid boolean: '$value'", lineNum);

    case 'date':
      final parts = value.split('-');
      if (parts.length == 3) {
        final year = int.tryParse(parts[0]);
        final month = int.tryParse(parts[1]);
        final day = int.tryParse(parts[2]);
        if (year != null &&
            month != null &&
            day != null &&
            year >= 1 &&
            year <= 9999 &&
            month >= 1 &&
            month <= 12 &&
            day >= 1 &&
            day <= _daysInMonth(year, month)) {
          return value; // Return as string for JSON compatibility
        }
      }
      throw KdgError("Invalid date (expected YYYY-MM-DD): '$value'", lineNum);
  }

  throw KdgError("Unknown type: '$typeName'", lineNum);
}

/// Scan a double-quoted value beginning at [runes]\[[start]] == '"'. Returns
/// the value and the position just after the closing quote. Backslash escapes
/// for `\"` and `\\` are honoured per SPEC 6.2.
(String, int) _scanWrappedValue(List<int> runes, int start, int lineNum) {
  final chars = <int>[];
  var i = start + 1;
  while (i < runes.length) {
    final c = runes[i];
    if (c == 0x5c &&
        i + 1 < runes.length &&
        (runes[i + 1] == 0x22 || runes[i + 1] == 0x5c)) {
      chars.add(runes[i + 1]);
      i += 2;
      continue;
    }
    if (c == 0x22) {
      return (String.fromCharCodes(chars), i + 1);
    }
    chars.add(c);
    i++;
  }
  throw KdgError('Unterminated quoted value', lineNum);
}

/// Parse a single record line into a label -> value map (insertion ordered).
Map<String, Object?> parseRecord(
    String line, Map<int, FieldDef> delimiterMap, int lineNum) {
  final record = <String, Object?>{};
  if (line.isEmpty) return record;

  final runes = line.runes.toList();
  var position = 0;

  while (position < runes.length) {
    String value;

    // A field is value-then-delimiter. The value may be wrapped in double
    // quotes, which lets it contain delimiter characters (SPEC 6.2).
    if (runes[position] == 0x22) {
      final scanned = _scanWrappedValue(runes, position, lineNum);
      value = scanned.$1;
      position = scanned.$2;
      if (position >= runes.length) {
        throw KdgError("Missing delimiter after value '$value'", lineNum);
      }
    } else {
      final start = position;
      while (position < runes.length &&
          !delimiterMap.containsKey(runes[position])) {
        position++;
      }
      if (position == runes.length) {
        throw KdgError(
            'No delimiter found for value starting at column $start', lineNum);
      }
      value = String.fromCharCodes(runes.sublist(start, position));
    }

    final delimiter = runes[position];
    final field = delimiterMap[delimiter];
    if (field == null) {
      throw KdgError(
          "Undefined delimiter: '${_scalarString(delimiter)}'", lineNum);
    }

    if (record.containsKey(field.label)) {
      throw KdgError("Duplicate field in record: '${field.label}'", lineNum);
    }

    record[field.label] = convertValue(value, field.typeName, lineNum);
    position++;
  }

  return record;
}

/// Parse a KDG document into a list of records.
List<Map<String, Object?>> parse(String content) {
  final lines = content.replaceAll('\r\n', '\n').split('\n');

  // A trailing newline produces a spurious final empty element. Drop it so a
  // document with no blank-line separator is reported as MissingSeparator
  // instead of having its first record misread as a definition.
  if (lines.isNotEmpty && lines.last.isEmpty) {
    lines.removeLast();
  }

  // Find the separator (blank line).
  var separatorIdx = -1;
  for (var i = 0; i < lines.length; i++) {
    if (lines[i].isEmpty) {
      separatorIdx = i;
      break;
    }
  }
  if (separatorIdx < 0) {
    throw KdgError(
        'No blank line separator found between definitions and data');
  }

  // Parse definitions.
  final delimiterMap = <int, FieldDef>{};
  for (var i = 0; i < separatorIdx; i++) {
    final line = lines[i];
    if (line.isEmpty) continue; // Skip empty lines in the definition block

    final field = parseDefinition(line, i + 1);
    final existing = delimiterMap[field.delimiter];
    if (existing != null) {
      throw KdgError(
          "Delimiter '${_scalarString(field.delimiter)}' already used for field '${existing.label}'",
          i + 1);
    }
    delimiterMap[field.delimiter] = field;
  }

  // Parse records.
  final records = <Map<String, Object?>>[];
  for (var i = separatorIdx + 1; i < lines.length; i++) {
    final line = lines[i];
    if (line.isEmpty) continue; // Skip empty lines in the data block
    records.add(parseRecord(line, delimiterMap, i + 1));
  }

  return records;
}

String _escapeJson(String s) {
  final out = StringBuffer();
  for (final rune in s.runes) {
    switch (rune) {
      case 0x22:
        out.write(r'\"');
        break;
      case 0x5c:
        out.write(r'\\');
        break;
      case 0x08:
        out.write(r'\b');
        break;
      case 0x0c:
        out.write(r'\f');
        break;
      case 0x0a:
        out.write(r'\n');
        break;
      case 0x0d:
        out.write(r'\r');
        break;
      case 0x09:
        out.write(r'\t');
        break;
      default:
        if (rune < 0x20) {
          out.write('\\u${rune.toRadixString(16).padLeft(4, '0')}');
        } else {
          out.writeCharCode(rune);
        }
    }
  }
  return out.toString();
}

String _valueToJson(Object? value) {
  if (value is String) return '"${_escapeJson(value)}"';
  if (value is bool) return value ? 'true' : 'false';
  if (value is int) return value.toString();
  if (value is double) return value.toString();
  return 'null';
}

/// Convert parsed records to a JSON string with 2-space indentation. Keys are
/// emitted in first-seen order within each record.
String toJson(List<Map<String, Object?>> records) {
  if (records.isEmpty) return '[]';

  final buf = StringBuffer();
  buf.write('[\n');
  for (var i = 0; i < records.length; i++) {
    final entries = records[i].entries.toList();
    if (entries.isEmpty) {
      buf.write('  {}');
    } else {
      buf.write('  {\n');
      for (var k = 0; k < entries.length; k++) {
        buf.write('    "');
        buf.write(_escapeJson(entries[k].key));
        buf.write('": ');
        buf.write(_valueToJson(entries[k].value));
        if (k + 1 < entries.length) buf.write(',');
        buf.write('\n');
      }
      buf.write('  }');
    }
    if (i + 1 < records.length) buf.write(',');
    buf.write('\n');
  }
  buf.write(']');
  return buf.toString();
}

/// Render a value the way the Python reference's str() does.
String _valueToCsv(Object? value) {
  if (value == null) return '';
  if (value is String) return value;
  if (value is bool) return value ? 'True' : 'False';
  return value.toString();
}

/// Quote a field containing a comma, double quote, or newline, doubling
/// internal quotes.
String _escapeCsv(String s) {
  if (s.contains(',') || s.contains('"') || s.contains('\n')) {
    return '"${s.replaceAll('"', '""')}"';
  }
  return s;
}

/// Convert parsed records to a CSV string.
String toCsv(List<Map<String, Object?>> records) {
  if (records.isEmpty) return '';

  // All unique labels across all records, in first-seen order.
  final allKeys = <String>[];
  final seen = <String>{};
  for (final record in records) {
    for (final key in record.keys) {
      if (seen.add(key)) allKeys.add(key);
    }
  }

  final lines = <String>[allKeys.map(_escapeCsv).join(',')];
  for (final record in records) {
    lines.add(
        allKeys.map((key) => _escapeCsv(_valueToCsv(record[key]))).join(','));
  }
  return lines.join('\n');
}

int run(List<String> args) {
  if (args.length < 2) {
    stderr.writeln(usage);
    return 1;
  }

  final command = args[0];
  final filepath = args[1];

  final file = File(filepath);
  if (!file.existsSync()) {
    stderr.writeln('Error: File not found: $filepath');
    return 1;
  }

  String content;
  try {
    content = file.readAsStringSync();
  } catch (e) {
    stderr.writeln('Error reading file: $e');
    return 1;
  }

  switch (command) {
    case 'parse':
      List<Map<String, Object?>> records;
      try {
        records = parse(content);
      } on KdgError catch (e) {
        stderr.writeln('Parse error: $e');
        return 1;
      }
      stdout.write(toJson(records));
      stdout.write('\n');
      return 0;

    case 'validate':
      try {
        parse(content);
      } on KdgError catch (e) {
        stderr.writeln('Invalid: $e');
        return 1;
      }
      stdout.writeln('Valid KDG document');
      return 0;

    case 'convert':
      final format = args.length > 2 ? args[2] : 'json';
      List<Map<String, Object?>> records;
      try {
        records = parse(content);
      } on KdgError catch (e) {
        stderr.writeln('Parse error: $e');
        return 1;
      }
      if (format == 'json') {
        stdout.write(toJson(records));
        stdout.write('\n');
        return 0;
      }
      if (format == 'csv') {
        stdout.write(toCsv(records));
        stdout.write('\n');
        return 0;
      }
      stderr.writeln('Unknown format: $format');
      return 1;

    default:
      stderr.writeln('Unknown command: $command');
      stderr.writeln(usage);
      return 1;
  }
}

void main(List<String> args) {
  exitCode = run(args);
}
