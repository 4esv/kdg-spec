// KDG (Key-Delimiter Grammar) Parser - Reference Implementation
//
// Usage:
//
// 	kotlinc kdg.kt -include-runtime -d kdg.jar
// 	java -jar kdg.jar parse <file>           Parse KDG to JSON
// 	java -jar kdg.jar validate <file>        Validate KDG syntax
// 	java -jar kdg.jar convert <file> [fmt]   Convert to format (json, csv)
//
// This implementation has no dependencies beyond the Kotlin standard library.
// This was considered important.
import java.io.File
import java.io.FileDescriptor
import java.io.FileOutputStream
import java.io.IOException
import java.io.PrintStream
import java.math.BigDecimal
import kotlin.math.abs
import kotlin.system.exitProcess

private const val USAGE = "Usage: kdg <parse|validate|convert> <file> [json|csv]"

private val VALID_TYPES = setOf("str", "int", "float", "bool", "date")

// Characters that cannot be delimiters.
private const val RESERVED_CHAR_LIST =
    "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789:\" \t\n\r"
private val RESERVED_CHARS: Set<Char> = RESERVED_CHAR_LIST.toSet()

// Regex for parsing definition lines, kept byte-identical to the Go and Python
// reference implementations. DOTALL keeps `.` equivalent to Go's, which matches
// every character except a newline.
private val DEFINITION_PATTERN =
    Regex("(?s)^([a-z]+):\"((?:[^\"\\\\]|\\\\.)*)\"(.)\$")

/** A field definition from the KDG header. */
private class FieldDef(
    val typeName: String,
    val label: String,
    val delimiter: Char,
)

/**
 * A record keeps its values plus the first-seen key order within the record.
 * The order is needed for deterministic CSV headers (SPEC and the Python
 * reference emit keys in first-seen order); JSON output does not depend on it.
 */
private class ParsedRecord {
    val values: LinkedHashMap<String, Any> = LinkedHashMap()
    val keys: ArrayList<String> = ArrayList()
}

/**
 * Base error for KDG parsing errors. [line] is 0 when the error carries no line
 * number (only MissingSeparator does).
 */
private class KdgError(
    detail: String,
    line: Int = 0,
) : Exception(
        if (line > 0) "Line $line: $detail" else detail,
    )

/** Parses a single field definition line. */
private fun parseDefinition(
    line: String,
    lineNum: Int,
): FieldDef {
    val match =
        DEFINITION_PATTERN.matchEntire(line)
            ?: throw KdgError("Invalid definition syntax: '$line'", lineNum)

    val typeName = match.groupValues[1]
    val rawLabel = match.groupValues[2]
    val delimiter = match.groupValues[3]

    if (typeName !in VALID_TYPES) {
        throw KdgError("Unknown type: '$typeName'", lineNum)
    }

    if (delimiter.isEmpty() || delimiter[0] in RESERVED_CHARS) {
        throw KdgError("Invalid delimiter: '$delimiter' (reserved character)", lineNum)
    }

    // Unescape the label. Order matters: \" first, then \\.
    val label = rawLabel.replace("\\\"", "\"").replace("\\\\", "\\")

    return FieldDef(typeName, label, delimiter[0])
}

private fun isLeapYear(year: Int): Boolean = (year % 4 == 0 && year % 100 != 0) || year % 400 == 0

private fun daysInMonth(
    year: Int,
    month: Int,
): Int =
    when (month) {
        1, 3, 5, 7, 8, 10, 12 -> 31
        4, 6, 9, 11 -> 30
        2 -> if (isLeapYear(year)) 29 else 28
        else -> 0
    }

/** True for a real calendar day in the form YYYY-MM-DD with year 1..9999. */
private fun isValidDate(value: String): Boolean {
    val parts = value.split("-")
    if (parts.size != 3) return false

    val year = parts[0].toIntOrNull() ?: return false
    val month = parts[1].toIntOrNull() ?: return false
    val day = parts[2].toIntOrNull() ?: return false

    if (year < 1 || year > 9999) return false
    if (day < 1 || day > daysInMonth(year, month)) return false
    return true
}

/** Converts a string value to its typed representation. */
private fun convertValue(
    value: String,
    typeName: String,
    lineNum: Int,
): Any =
    when (typeName) {
        "str" -> {
            value
        }

        "int" -> {
            value.toLongOrNull()
                ?: throw KdgError("Invalid integer: '$value'", lineNum)
        }

        "float" -> {
            value.toDoubleOrNull()
                ?: throw KdgError("Invalid float: '$value'", lineNum)
        }

        "bool" -> {
            when (value.lowercase()) {
                "true", "1" -> true
                "false", "0" -> false
                else -> throw KdgError("Invalid boolean: '$value'", lineNum)
            }
        }

        "date" -> {
            if (!isValidDate(value)) {
                throw KdgError("Invalid date (expected YYYY-MM-DD): '$value'", lineNum)
            }
            value // Return as string for JSON compatibility
        }

        else -> {
            throw KdgError("Unknown type: '$typeName'", lineNum)
        }
    }

/**
 * Scans a double-quoted value beginning at `line[start] == '"'`. Returns the
 * value and the position just after the closing quote. Backslash escapes for
 * \" and \\ are honoured per SPEC 6.2.
 */
private fun scanWrappedValue(
    line: String,
    start: Int,
    lineNum: Int,
): Pair<String, Int> {
    val chars = StringBuilder()
    var i = start + 1

    while (i < line.length) {
        val c = line[i]

        if (c == '\\' && i + 1 < line.length && (line[i + 1] == '"' || line[i + 1] == '\\')) {
            chars.append(line[i + 1])
            i += 2
            continue
        }

        if (c == '"') {
            return chars.toString() to (i + 1)
        }

        chars.append(c)
        i++
    }

    throw KdgError("Unterminated quoted value", lineNum)
}

/** Parses a single record line into a [ParsedRecord]. */
private fun parseRecord(
    line: String,
    delimiterMap: Map<Char, FieldDef>,
    lineNum: Int,
): ParsedRecord {
    val record = ParsedRecord()
    if (line.isEmpty()) return record

    var position = 0

    while (position < line.length) {
        val value: String

        // A field is value-then-delimiter. The value may be wrapped in double
        // quotes, which lets it contain delimiter characters (SPEC 6.2).
        if (line[position] == '"') {
            val (scanned, next) = scanWrappedValue(line, position, lineNum)
            value = scanned
            position = next

            if (position >= line.length) {
                throw KdgError("Missing delimiter after value '$value'", lineNum)
            }
        } else {
            val start = position
            while (position < line.length && line[position] !in delimiterMap) {
                position++
            }

            if (position == line.length) {
                throw KdgError(
                    "No delimiter found for value starting at column $start",
                    lineNum,
                )
            }

            value = line.substring(start, position)
        }

        val delimiter = line[position]

        val field =
            delimiterMap[delimiter]
                ?: throw KdgError("Undefined delimiter: '$delimiter'", lineNum)

        if (record.values.containsKey(field.label)) {
            throw KdgError("Duplicate field in record: '${field.label}'", lineNum)
        }

        record.values[field.label] = convertValue(value, field.typeName, lineNum)
        record.keys.add(field.label)
        position++
    }

    return record
}

/** Parses a KDG document into a list of records. */
private fun parse(content: String): List<ParsedRecord> {
    val lines = content.replace("\r\n", "\n").split("\n").toMutableList()

    // A trailing newline produces a spurious final empty element. Drop it so a
    // document with no blank-line separator is reported as MissingSeparator
    // instead of having its first record misread as a definition.
    if (lines.isNotEmpty() && lines[lines.size - 1].isEmpty()) {
        lines.removeAt(lines.size - 1)
    }

    // Find the separator (blank line).
    var separatorIdx = -1
    for (i in lines.indices) {
        if (lines[i].isEmpty()) {
            separatorIdx = i
            break
        }
    }

    if (separatorIdx < 0) {
        throw KdgError("No blank line separator found between definitions and data")
    }

    // Parse definitions.
    val delimiterMap = LinkedHashMap<Char, FieldDef>()
    for (i in 0 until separatorIdx) {
        val line = lines[i]
        if (line.isEmpty()) continue // Skip empty lines in the definition block

        val field = parseDefinition(line, i + 1)

        val existing = delimiterMap[field.delimiter]
        if (existing != null) {
            throw KdgError(
                "Delimiter '${field.delimiter}' already used for field '${existing.label}'",
                i + 1,
            )
        }

        delimiterMap[field.delimiter] = field
    }

    // Parse records.
    val records = ArrayList<ParsedRecord>()
    for (i in separatorIdx + 1 until lines.size) {
        val line = lines[i]
        if (line.isEmpty()) continue // Skip empty lines in the data block

        records.add(parseRecord(line, delimiterMap, i + 1))
    }

    return records
}

private fun jsonEscape(s: String): String {
    val sb = StringBuilder(s.length + 8)
    for (c in s) {
        when (c) {
            '"' -> sb.append("\\\"")
            '\\' -> sb.append("\\\\")
            '\n' -> sb.append("\\n")
            '\r' -> sb.append("\\r")
            '\t' -> sb.append("\\t")
            '\b' -> sb.append("\\b")
            '\u000C' -> sb.append("\\f")
            else -> if (c < ' ') sb.append("\\u%04x".format(c.code)) else sb.append(c)
        }
    }
    return sb.toString()
}

/**
 * Renders a double the way Go's encoding/json does: shortest round-trip
 * decimal, plain notation for 1e-6 <= |x| < 1e21 and exponent notation outside
 * that range. NaN and infinities have no JSON representation (Go errors out).
 */
private fun jsonDouble(d: Double): String {
    if (d.isNaN()) throw KdgError("json: unsupported value: NaN")
    if (d.isInfinite()) {
        val text = if (d > 0) "+Inf" else "-Inf"
        throw KdgError("json: unsupported value: $text")
    }
    if (d == 0.0) return if (1.0 / d < 0) "-0" else "0"

    val magnitude = abs(d)
    if (magnitude < 1e-6 || magnitude >= 1e21) return goExponent(d)

    var plain = BigDecimal(d.toString()).toPlainString()
    if (plain.endsWith(".0")) plain = plain.dropLast(2)
    return plain
}

/** Shortest exponent form as Go's strconv emits it, e.g. 1e-7, 1.5e+22. */
private fun goExponent(d: Double): String {
    val s = d.toString()
    val e = s.indexOfFirst { it == 'E' || it == 'e' }
    if (e < 0) return s

    var mantissa = s.substring(0, e)
    if (mantissa.endsWith(".0")) mantissa = mantissa.dropLast(2)

    val exponent = s.substring(e + 1).toInt()
    return mantissa + "e" + if (exponent >= 0) "+$exponent" else "$exponent"
}

private fun jsonValue(value: Any): String =
    when (value) {
        is String -> "\"" + jsonEscape(value) + "\""
        is Boolean -> if (value) "true" else "false"
        is Long -> value.toString()
        is Double -> jsonDouble(value)
        else -> "\"" + jsonEscape(value.toString()) + "\""
    }

/** Converts parsed records to a JSON string with 2-space indentation. */
private fun toJson(records: List<ParsedRecord>): String {
    if (records.isEmpty()) return "[]\n"

    val sb = StringBuilder()
    sb.append("[\n")
    records.forEachIndexed { index, record ->
        sb.append("  {\n")
        record.keys.forEachIndexed { keyIndex, key ->
            sb
                .append("    \"")
                .append(jsonEscape(key))
                .append("\": ")
                .append(jsonValue(record.values.getValue(key)))
            if (keyIndex < record.keys.size - 1) sb.append(',')
            sb.append('\n')
        }
        sb.append("  }")
        if (index < records.size - 1) sb.append(',')
        sb.append('\n')
    }
    sb.append("]\n")
    return sb.toString()
}

/** Renders a value the way the Python reference's str() does. */
private fun csvValue(value: Any?): String =
    when (value) {
        null -> ""
        is String -> value
        is Boolean -> if (value) "True" else "False"
        is Long -> value.toString()
        is Double -> csvDouble(value)
        else -> value.toString()
    }

/** Renders a double as Go's strconv.FormatFloat(v, 'g', -1, 64) would. */
private fun csvDouble(d: Double): String {
    if (d.isNaN()) return "NaN"
    if (d.isInfinite()) return if (d > 0) "+Inf" else "-Inf"
    if (d == 0.0) return if (1.0 / d < 0) "-0.0" else "0.0"

    val magnitude = abs(d)
    if (magnitude < 1e-4 || magnitude >= 1e21) {
        val s = d.toString()
        val e = s.indexOfFirst { it == 'E' || it == 'e' }
        if (e < 0) return s

        var mantissa = s.substring(0, e)
        if (mantissa.endsWith(".0")) mantissa = mantissa.dropLast(2)

        val exponent = s.substring(e + 1).toInt()
        val sign = if (exponent < 0) "-" else "+"
        return mantissa + "e" + sign + abs(exponent).toString().padStart(2, '0')
    }

    val plain = BigDecimal(d.toString()).toPlainString()
    return if (plain.contains('.')) plain else "$plain.0"
}

/**
 * Quotes a field containing a comma, double quote, or newline, doubling
 * internal quotes.
 */
private fun escapeCsv(s: String): String =
    if (s.any { it == ',' || it == '"' || it == '\n' }) {
        "\"" + s.replace("\"", "\"\"") + "\""
    } else {
        s
    }

/** Converts parsed records to a CSV string. */
private fun toCsv(records: List<ParsedRecord>): String {
    if (records.isEmpty()) return ""

    // Get all unique keys across all records, in first-seen order.
    val allKeys = ArrayList<String>()
    val seen = HashSet<String>()
    for (record in records) {
        for (key in record.keys) {
            if (seen.add(key)) allKeys.add(key)
        }
    }

    val sb = StringBuilder()
    sb.append(allKeys.joinToString(",") { escapeCsv(it) })
    for (record in records) {
        sb.append('\n')
        sb.append(allKeys.joinToString(",") { escapeCsv(csvValue(record.values[it])) })
    }
    return sb.toString()
}

private fun fail(message: String): Nothing {
    System.err.println(message)
    exitProcess(1)
}

fun main(args: Array<String>) {
    // Force UTF-8 on both streams: the JVM's console encoding can fall back to
    // ASCII when no locale is set, which would mangle non-ASCII output.
    System.setOut(PrintStream(FileOutputStream(FileDescriptor.out), true, "UTF-8"))
    System.setErr(PrintStream(FileOutputStream(FileDescriptor.err), true, "UTF-8"))

    if (args.size < 2) {
        System.err.println(USAGE)
        exitProcess(1)
    }

    val command = args[0]
    val filepath = args[1]

    val content =
        try {
            File(filepath).readText()
        } catch (e: java.io.FileNotFoundException) {
            fail("Error: File not found: $filepath")
        } catch (e: IOException) {
            fail("Error reading file: ${e.message}")
        }

    when (command) {
        "parse" -> {
            val records =
                try {
                    parse(content)
                } catch (e: KdgError) {
                    fail("Parse error: ${e.message}")
                }
            val out =
                try {
                    toJson(records)
                } catch (e: KdgError) {
                    fail("Parse error: ${e.message}")
                }
            print(out)
        }

        "validate" -> {
            val error =
                try {
                    parse(content)
                    null
                } catch (e: KdgError) {
                    e
                }
            if (error != null) fail("Invalid: ${error.message}")
            println("Valid KDG document")
        }

        "convert" -> {
            val format = if (args.size > 2) args[2] else "json"
            val records =
                try {
                    parse(content)
                } catch (e: KdgError) {
                    fail("Parse error: ${e.message}")
                }
            when (format) {
                "json" -> {
                    val out =
                        try {
                            toJson(records)
                        } catch (e: KdgError) {
                            fail("Parse error: ${e.message}")
                        }
                    print(out)
                }

                "csv" -> {
                    println(toCsv(records))
                }

                else -> {
                    fail("Unknown format: $format")
                }
            }
        }

        else -> {
            System.err.println("Unknown command: $command")
            System.err.println(USAGE)
            exitProcess(1)
        }
    }
}
