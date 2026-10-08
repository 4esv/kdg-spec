// KDG (Key-Delimiter Grammar) Parser - Reference Implementation
//
// Usage:
//   java kdg.java parse <file>           Parse KDG to JSON
//   java kdg.java validate <file>        Validate KDG syntax
//   java kdg.java convert <file> [fmt]   Convert to format (json, csv)
//
// Port of implementations/kdg.go. No dependencies beyond the Java standard
// library (Java 11 source launch; JSON is emitted by hand).

import java.io.FileDescriptor;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.PrintStream;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.NoSuchFileException;
import java.nio.file.Paths;
import java.util.ArrayList;
import java.util.HashSet;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Set;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

class Kdg {

    /** A field definition from the KDG header. delimiter is a code point. */
    static final class FieldDef {
        final String type;
        final String label;
        final int delimiter;

        FieldDef(String type, String label, int delimiter) {
            this.type = type;
            this.label = label;
            this.delimiter = delimiter;
        }
    }

    /**
     * A KDG parsing error. line is null only for MissingSeparator, the one
     * error that carries no line number.
     */
    static final class KdgError extends RuntimeException {
        private static final long serialVersionUID = 1L;

        final Integer line;

        KdgError(String message, Integer line) {
            super(line == null ? message : "Line " + line + ": " + message);
            this.line = line;
        }
    }

    private static final Set<String> VALID_TYPES =
        new HashSet<>(List.of("str", "int", "float", "bool", "date"));

    /** Characters that cannot be delimiters (SPEC 3.4). */
    private static final String RESERVED_CHAR_LIST =
        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789:\" \t\n\r";

    /**
     * Definition line pattern (SPEC 5.2). Java's regex engine matches a
     * supplementary character as one code point, like the Go reference's
     * rune-based pattern.
     */
    private static final Pattern DEFINITION_PATTERN =
        Pattern.compile("^([a-z]+):\"((?:[^\"\\\\]|\\\\.)*)\"(.)$");

    private static final Pattern INTEGER_PATTERN = Pattern.compile("[+-]?[0-9]+");

    private static final Pattern FLOAT_BODY_PATTERN =
        Pattern.compile("(?:[0-9]+\\.?[0-9]*|\\.[0-9]+)(?:[eE][+-]?[0-9]+)?");

    private static final String USAGE =
        "Usage: kdg <parse|validate|convert> <file> [json|csv]";

    /** Parse a single field definition line. */
    static FieldDef parseDefinition(String line, int lineNum) {
        Matcher match = DEFINITION_PATTERN.matcher(line);
        if (!match.matches()) {
            throw new KdgError("Invalid definition syntax: '" + line + "'", lineNum);
        }

        String typeName = match.group(1);
        String rawLabel = match.group(2);
        String delimiter = match.group(3);

        if (!VALID_TYPES.contains(typeName)) {
            throw new KdgError("Unknown type: '" + typeName + "'", lineNum);
        }

        // A reserved delimiter is a single BMP character; a supplementary
        // delimiter cannot be reserved.
        if (delimiter.length() == 1 && RESERVED_CHAR_LIST.indexOf(delimiter.charAt(0)) >= 0) {
            throw new KdgError(
                "Invalid delimiter: '" + delimiter + "' (reserved character)", lineNum);
        }

        // Unescape the label. Order matters: \" first, then \\.
        String label = rawLabel.replace("\\\"", "\"").replace("\\\\", "\\");

        return new FieldDef(typeName, label, delimiter.codePointAt(0));
    }

    /**
     * Mirrors strconv.Atoi: an optional sign followed by one or more digits.
     * Out-of-range values overflow a 64-bit int, which SPEC 4.3 makes a
     * TypeMismatch.
     */
    static Long parseInteger(String value) {
        if (!INTEGER_PATTERN.matcher(value).matches()) return null;

        try {
            return Long.parseLong(value);
        } catch (NumberFormatException e) {
            return null;
        }
    }

    /**
     * Mirrors strconv.ParseFloat for the forms SPEC 4.4 covers (sign, digits,
     * optional fraction, optional exponent) plus the special values it accepts
     * (Inf/Infinity/NaN). Whitespace and junk are rejected, and overflow to
     * infinity is an error, like strconv.ErrRange.
     */
    static Double parseFloat(String value) {
        if (value.isEmpty()) return null;

        String body = value;
        boolean negative = false;
        if (body.charAt(0) == '+' || body.charAt(0) == '-') {
            negative = body.charAt(0) == '-';
            body = body.substring(1);
        }
        if (body.isEmpty()) return null;

        String lower = body.toLowerCase(Locale.ROOT);
        if (lower.equals("inf") || lower.equals("infinity")) {
            return negative ? Double.NEGATIVE_INFINITY : Double.POSITIVE_INFINITY;
        }
        if (lower.equals("nan")) return Double.NaN;

        if (!FLOAT_BODY_PATTERN.matcher(body).matches()) return null;

        double parsed = Double.parseDouble(value);
        return Double.isInfinite(parsed) ? null : parsed;
    }

    static int daysInMonth(int year, int month) {
        switch (month) {
            case 1: case 3: case 5: case 7: case 8: case 10: case 12:
                return 31;
            case 4: case 6: case 9: case 11:
                return 30;
            case 2:
                return year % 4 == 0 && (year % 100 != 0 || year % 400 == 0) ? 29 : 28;
            default:
                return 0;
        }
    }

    /** YYYY-MM-DD, year 1..9999, real calendar day (SPEC 4.6). */
    static boolean isValidDate(String value) {
        String[] parts = value.split("-", -1);
        if (parts.length != 3) return false;

        Long year = parseInteger(parts[0]);
        Long month = parseInteger(parts[1]);
        Long day = parseInteger(parts[2]);
        if (year == null || month == null || day == null) return false;
        if (year < 1 || year > 9999 || month < 1 || month > 12) return false;

        return day >= 1 && day <= daysInMonth(year.intValue(), month.intValue());
    }

    /** Convert a raw string value to its typed representation. */
    static Object convertValue(String value, String typeName, int lineNum) {
        switch (typeName) {
            case "str":
                return value;

            case "int": {
                Long parsed = parseInteger(value);
                if (parsed == null) {
                    throw new KdgError("Invalid integer: '" + value + "'", lineNum);
                }
                return parsed;
            }

            case "float": {
                Double parsed = parseFloat(value);
                if (parsed == null) {
                    throw new KdgError("Invalid float: '" + value + "'", lineNum);
                }
                return parsed;
            }

            case "bool": {
                String lower = value.toLowerCase(Locale.ROOT);
                if (lower.equals("true") || lower.equals("1")) return Boolean.TRUE;
                if (lower.equals("false") || lower.equals("0")) return Boolean.FALSE;
                throw new KdgError("Invalid boolean: '" + value + "'", lineNum);
            }

            case "date":
                // Returned as its string form, as the Go reference does.
                if (isValidDate(value)) return value;
                throw new KdgError(
                    "Invalid date (expected YYYY-MM-DD): '" + value + "'", lineNum);

            default:
                throw new KdgError("Unknown type: '" + typeName + "'", lineNum);
        }
    }

    static String delimiterString(int codePoint) {
        return new String(Character.toChars(codePoint));
    }

    /** The value and the index just after the closing quote. */
    static final class ScanResult {
        final String value;
        final int end;

        ScanResult(String value, int end) {
            this.value = value;
            this.end = end;
        }
    }

    /**
     * Scan a double-quoted value at points[start] == '"'. Backslash escapes for
     * \" and \\ are honoured per SPEC 6.2.
     */
    static ScanResult scanWrappedValue(int[] points, int start, int lineNum) {
        StringBuilder out = new StringBuilder();
        int i = start + 1;

        while (i < points.length) {
            int c = points[i];

            if (c == '\\' && i + 1 < points.length
                    && (points[i + 1] == '"' || points[i + 1] == '\\')) {
                out.appendCodePoint(points[i + 1]);
                i += 2;
                continue;
            }

            if (c == '"') {
                return new ScanResult(out.toString(), i + 1);
            }

            out.appendCodePoint(c);
            i += 1;
        }

        throw new KdgError("Unterminated quoted value", lineNum);
    }

    /** Parse a single record line into a label -> value map, keyed in order. */
    static Map<String, Object> parseRecord(
            String line, Map<Integer, FieldDef> delimiterMap, int lineNum) {
        Map<String, Object> record = new LinkedHashMap<>();
        if (line.isEmpty()) return record;

        // Scan by code point, matching the Go reference's rune indexing.
        int[] points = line.codePoints().toArray();
        int position = 0;

        while (position < points.length) {
            String value;

            // A field is value-then-delimiter; a quoted value may contain
            // delimiters.
            if (points[position] == '"') {
                ScanResult scanned = scanWrappedValue(points, position, lineNum);
                value = scanned.value;
                position = scanned.end;

                if (position >= points.length) {
                    throw new KdgError(
                        "Missing delimiter after value '" + value + "'", lineNum);
                }
            } else {
                int start = position;
                while (position < points.length && !delimiterMap.containsKey(points[position])) {
                    position += 1;
                }

                if (position == points.length) {
                    throw new KdgError(
                        "No delimiter found for value starting at column " + start, lineNum);
                }

                value = new String(points, start, position - start);
            }

            int delimiter = points[position];

            FieldDef field = delimiterMap.get(delimiter);
            if (field == null) {
                throw new KdgError(
                    "Undefined delimiter: '" + delimiterString(delimiter) + "'", lineNum);
            }

            if (record.containsKey(field.label)) {
                throw new KdgError("Duplicate field in record: '" + field.label + "'", lineNum);
            }

            record.put(field.label, convertValue(value, field.type, lineNum));
            position += 1;
        }

        return record;
    }

    /** Parse a KDG document into a list of records. */
    static List<Map<String, Object>> parse(String content) {
        // limit -1 keeps trailing empty elements, matching strings.Split.
        String[] lines = content.replace("\r\n", "\n").split("\n", -1);
        int lineCount = lines.length;

        // A trailing newline leaves one spurious empty element. Drop it so a
        // document with no separator reports MissingSeparator instead of having
        // its first record read as a definition.
        if (lineCount > 0 && lines[lineCount - 1].isEmpty()) {
            lineCount -= 1;
        }

        // The separator is the first empty line.
        int separatorIdx = -1;
        for (int i = 0; i < lineCount; i++) {
            if (lines[i].isEmpty()) {
                separatorIdx = i;
                break;
            }
        }

        if (separatorIdx < 0) {
            throw new KdgError(
                "No blank line separator found between definitions and data", null);
        }

        Map<Integer, FieldDef> delimiterMap = new LinkedHashMap<>();
        for (int i = 0; i < separatorIdx; i++) {
            String line = lines[i];
            if (line.isEmpty()) continue;

            FieldDef field = parseDefinition(line, i + 1);

            FieldDef existing = delimiterMap.get(field.delimiter);
            if (existing != null) {
                throw new KdgError(
                    "Delimiter '" + delimiterString(field.delimiter)
                        + "' already used for field '" + existing.label + "'",
                    i + 1);
            }

            delimiterMap.put(field.delimiter, field);
        }

        List<Map<String, Object>> records = new ArrayList<>();
        for (int i = separatorIdx + 1; i < lineCount; i++) {
            String line = lines[i];
            if (line.isEmpty()) continue;

            records.add(parseRecord(line, delimiterMap, i + 1));
        }

        return records;
    }

    /** Append a JSON string literal, leaving non-ASCII characters raw. */
    static void appendJsonString(StringBuilder sb, String value) {
        sb.append('"');
        for (int i = 0; i < value.length(); i++) {
            char c = value.charAt(i);
            switch (c) {
                case '"':
                    sb.append("\\\"");
                    break;
                case '\\':
                    sb.append("\\\\");
                    break;
                case '\n':
                    sb.append("\\n");
                    break;
                case '\r':
                    sb.append("\\r");
                    break;
                case '\t':
                    sb.append("\\t");
                    break;
                default:
                    if (c < 0x20 || c == '\u2028' || c == '\u2029') {
                        sb.append(String.format("\\u%04x", (int) c));
                    } else {
                        sb.append(c);
                    }
            }
        }
        sb.append('"');
    }

    /**
     * Render a double without a trailing ".0" when it is integral, the way
     * encoding/json and JSON.stringify do for ordinary values.
     */
    static String formatFloat(double value) {
        if (value == Math.rint(value) && Math.abs(value) < 1e15) {
            return Long.toString((long) value);
        }
        return Double.toString(value);
    }

    static void appendJsonFloat(StringBuilder sb, double value) {
        if (Double.isNaN(value) || Double.isInfinite(value)) {
            // encoding/json refuses these, and so does the Go reference.
            throw new KdgError(
                "json: unsupported value: "
                    + (Double.isNaN(value) ? "NaN" : (value > 0 ? "+Inf" : "-Inf")),
                null);
        }
        sb.append(formatFloat(value));
    }

    static void appendJsonValue(StringBuilder sb, Object value) {
        if (value instanceof String) {
            appendJsonString(sb, (String) value);
        } else if (value instanceof Boolean) {
            sb.append(((Boolean) value) ? "true" : "false");
        } else if (value instanceof Long) {
            sb.append(((Long) value).longValue());
        } else if (value instanceof Double) {
            appendJsonFloat(sb, ((Double) value).doubleValue());
        } else {
            sb.append("null");
        }
    }

    /** Serialize records as JSON with 2-space indentation and a trailing newline. */
    static String toJSON(List<Map<String, Object>> records) {
        StringBuilder sb = new StringBuilder();
        sb.append('[');

        for (int r = 0; r < records.size(); r++) {
            if (r > 0) sb.append(',');
            sb.append("\n  {");

            int index = 0;
            for (Map.Entry<String, Object> entry : records.get(r).entrySet()) {
                if (index > 0) sb.append(',');
                sb.append("\n    ");
                appendJsonString(sb, entry.getKey());
                sb.append(": ");
                appendJsonValue(sb, entry.getValue());
                index += 1;
            }

            if (index > 0) sb.append("\n  ");
            sb.append('}');
        }

        if (!records.isEmpty()) sb.append('\n');
        sb.append("]\n");
        return sb.toString();
    }

    /** Render a float the way strconv.FormatFloat(v, 'g', -1, 64) does. */
    static String formatCsvFloat(double value) {
        if (Double.isNaN(value)) return "NaN";
        if (value == Double.POSITIVE_INFINITY) return "+Inf";
        if (value == Double.NEGATIVE_INFINITY) return "-Inf";
        return Double.toString(value);
    }

    /** Render a value the way the Go reference's csvValue does. */
    static String csvValue(Object value) {
        if (value instanceof String) return (String) value;
        if (value instanceof Boolean) return ((Boolean) value) ? "True" : "False";
        if (value instanceof Long) return Long.toString(((Long) value).longValue());
        if (value instanceof Double) {
            String text = formatCsvFloat(((Double) value).doubleValue());
            return containsAny(text, ".eEni") ? text : text + ".0";
        }
        return "";
    }

    /** True when text contains any character in chars (strings.ContainsAny). */
    static boolean containsAny(String text, String chars) {
        for (int i = 0; i < text.length(); i++) {
            if (chars.indexOf(text.charAt(i)) >= 0) return true;
        }
        return false;
    }

    /** Quote a field containing a comma, double quote, or newline. */
    static String escapeCSV(String field) {
        if (field.indexOf(',') >= 0 || field.indexOf('"') >= 0 || field.indexOf('\n') >= 0) {
            return '"' + field.replace("\"", "\"\"") + '"';
        }
        return field;
    }

    /** Serialize records as CSV: keys in first-seen order across all records. */
    static String toCSV(List<Map<String, Object>> records) {
        if (records.isEmpty()) return "";

        List<String> allKeys = new ArrayList<>();
        Set<String> seen = new HashSet<>();
        for (Map<String, Object> record : records) {
            for (String key : record.keySet()) {
                if (seen.add(key)) allKeys.add(key);
            }
        }

        StringBuilder sb = new StringBuilder();
        for (int i = 0; i < allKeys.size(); i++) {
            if (i > 0) sb.append(',');
            sb.append(escapeCSV(allKeys.get(i)));
        }

        for (Map<String, Object> record : records) {
            sb.append('\n');
            for (int i = 0; i < allKeys.size(); i++) {
                if (i > 0) sb.append(',');
                sb.append(escapeCSV(csvValue(record.get(allKeys.get(i)))));
            }
        }

        return sb.toString();
    }

    /** Parse, reporting a KDG error to stderr; null means the caller exits 1. */
    static List<Map<String, Object>> tryParse(String content, PrintStream err) {
        try {
            return parse(content);
        } catch (KdgError e) {
            err.println("Parse error: " + e.getMessage());
            return null;
        }
    }

    /** Print records as JSON; returns the exit code (encoding can fail). */
    static int printJSON(List<Map<String, Object>> records, PrintStream out, PrintStream err) {
        String json;
        try {
            json = toJSON(records);
        } catch (KdgError e) {
            err.println("Parse error: " + e.getMessage());
            return 1;
        }
        out.print(json);
        return 0;
    }

    /** Execute the CLI and return the process exit code. */
    static int run(String[] args, PrintStream out, PrintStream err) {
        if (args.length < 2) {
            err.println(USAGE);
            return 1;
        }

        String command = args[0];
        String filepath = args[1];

        String content;
        try {
            content = new String(Files.readAllBytes(Paths.get(filepath)), StandardCharsets.UTF_8);
        } catch (NoSuchFileException e) {
            err.println("Error: File not found: " + filepath);
            return 1;
        } catch (IOException e) {
            err.println("Error reading file: " + e);
            return 1;
        }

        switch (command) {
            case "parse": {
                List<Map<String, Object>> records = tryParse(content, err);
                if (records == null) return 1;
                return printJSON(records, out, err);
            }

            case "validate":
                try {
                    parse(content);
                } catch (KdgError e) {
                    err.println("Invalid: " + e.getMessage());
                    return 1;
                }
                out.println("Valid KDG document");
                return 0;

            case "convert": {
                String format = args.length > 2 ? args[2] : "json";
                List<Map<String, Object>> records = tryParse(content, err);
                if (records == null) return 1;

                if (format.equals("json")) {
                    return printJSON(records, out, err);
                }
                if (format.equals("csv")) {
                    out.println(toCSV(records));
                    return 0;
                }
                err.println("Unknown format: " + format);
                return 1;
            }

            default:
                err.println("Unknown command: " + command);
                err.println(USAGE);
                return 1;
        }
    }

    public static void main(String[] args) {
        PrintStream out = new PrintStream(
            new FileOutputStream(FileDescriptor.out), true, StandardCharsets.UTF_8);
        PrintStream err = new PrintStream(
            new FileOutputStream(FileDescriptor.err), true, StandardCharsets.UTF_8);

        System.exit(run(args, out, err));
    }
}
