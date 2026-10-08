// KDG (Key-Delimiter Grammar) Parser - Reference Implementation
//
// Usage:
//
//	dotnet run kdg.cs -- parse <file>           Parse KDG to JSON
//	dotnet run kdg.cs -- validate <file>        Validate KDG syntax
//	dotnet run kdg.cs -- convert <file> [fmt]   Convert to format (json, csv)
//
// This implementation has no dependencies beyond the .NET standard library.
// This was considered important.
using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Text;
using System.Text.RegularExpressions;

/// <summary>Base error for KDG parsing errors.</summary>
/// <remarks>
/// <c>line</c> is 0 when the error carries no line number (only MissingSeparator
/// does).
/// </remarks>
internal sealed class KdgError : Exception
{
    public KdgError(string detail, int line = 0)
        : base(line > 0 ? $"Line {line}: {detail}" : detail)
    {
    }
}

/// <summary>A field definition from the KDG header.</summary>
internal sealed class FieldDef
{
    public string TypeName { get; init; } = "";

    public string Label { get; init; } = "";

    public char Delimiter { get; init; }
}

/// <summary>
/// A record keeps its values plus the first-seen key order within the record.
/// The order is needed for deterministic CSV headers (SPEC and the Python
/// reference emit keys in first-seen order); JSON output does not depend on it.
/// </summary>
internal sealed class ParsedRecord
{
    public Dictionary<string, object> Values { get; } = new();

    public List<string> Keys { get; } = new();
}

internal static class Program
{
    private const string Usage = "Usage: kdg <parse|validate|convert> <file> [json|csv]";

    // Characters that cannot be delimiters.
    private const string ReservedCharList =
        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789:\" \t\n\r";

    private static readonly HashSet<char> ReservedChars = new(ReservedCharList);

    private static readonly HashSet<string> ValidTypes =
        new() { "str", "int", "float", "bool", "date" };

    // Regex for parsing definition lines, kept equivalent to the Go and Python
    // reference implementations. Singleline keeps `.` equivalent to Go's, which
    // matches every character except a newline.
    private static readonly Regex DefinitionPattern =
        new(@"\A([a-z]+):""((?:[^""\\]|\\.)*)""(.)\z", RegexOptions.Singleline);

    // Explicit UTF-8 writers: the default console encoding is not UTF-8 on every
    // platform, which would mangle non-ASCII output.
    private static readonly TextWriter Out =
        new StreamWriter(Console.OpenStandardOutput(), new UTF8Encoding(false)) { AutoFlush = true };

    private static readonly TextWriter Err =
        new StreamWriter(Console.OpenStandardError(), new UTF8Encoding(false)) { AutoFlush = true };

    private static int Main(string[] args)
    {
        if (args.Length < 2)
        {
            Err.WriteLine(Usage);
            return 1;
        }

        string command = args[0];
        string filepath = args[1];

        if (!File.Exists(filepath))
        {
            return Fail($"Error: File not found: {filepath}");
        }

        string content;
        try
        {
            content = File.ReadAllText(filepath, Encoding.UTF8);
        }
        catch (Exception e)
        {
            return Fail($"Error reading file: {e.Message}");
        }

        switch (command)
        {
            case "parse":
            {
                string json;
                try
                {
                    json = ToJson(Parse(content));
                }
                catch (KdgError e)
                {
                    return Fail($"Parse error: {e.Message}");
                }

                Out.Write(json);
                return 0;
            }

            case "validate":
            {
                try
                {
                    Parse(content);
                }
                catch (KdgError e)
                {
                    return Fail($"Invalid: {e.Message}");
                }

                Out.WriteLine("Valid KDG document");
                return 0;
            }

            case "convert":
            {
                string format = args.Length > 2 ? args[2] : "json";
                try
                {
                    List<ParsedRecord> records = Parse(content);
                    switch (format)
                    {
                        case "json":
                            Out.Write(ToJson(records));
                            return 0;

                        case "csv":
                            Out.WriteLine(ToCsv(records));
                            return 0;

                        default:
                            return Fail($"Unknown format: {format}");
                    }
                }
                catch (KdgError e)
                {
                    return Fail($"Parse error: {e.Message}");
                }
            }

            default:
                Err.WriteLine($"Unknown command: {command}");
                Err.WriteLine(Usage);
                return 1;
        }
    }

    private static int Fail(string message)
    {
        Err.WriteLine(message);
        return 1;
    }

    /// <summary>Parses a single field definition line.</summary>
    private static FieldDef ParseDefinition(string line, int lineNum)
    {
        Match match = DefinitionPattern.Match(line);
        if (!match.Success)
        {
            throw new KdgError($"Invalid definition syntax: '{line}'", lineNum);
        }

        string typeName = match.Groups[1].Value;
        string rawLabel = match.Groups[2].Value;
        string delimiter = match.Groups[3].Value;

        if (!ValidTypes.Contains(typeName))
        {
            throw new KdgError($"Unknown type: '{typeName}'", lineNum);
        }

        if (delimiter.Length == 0 || ReservedChars.Contains(delimiter[0]))
        {
            throw new KdgError($"Invalid delimiter: '{delimiter}' (reserved character)", lineNum);
        }

        // Unescape the label. Order matters: \" first, then \\.
        string label = rawLabel.Replace("\\\"", "\"").Replace("\\\\", "\\");

        return new FieldDef { TypeName = typeName, Label = label, Delimiter = delimiter[0] };
    }

    private static bool IsLeapYear(int year) => (year % 4 == 0 && year % 100 != 0) || year % 400 == 0;

    private static int DaysInMonth(int year, int month = -1) => month switch
    {
        1 or 3 or 5 or 7 or 8 or 10 or 12 => 31,
        4 or 6 or 9 or 11 => 30,
        2 => IsLeapYear(year) ? 29 : 28,
        _ => 0,
    };

    /// <summary>True for a real calendar day in the form YYYY-MM-DD with year 1..9999.</summary>
    private static bool IsValidDate(string value)
    {
        string[] parts = value.Split('-');
        if (parts.Length != 3)
        {
            return false;
        }

        if (!TryParseInt(parts[0], out int year) ||
            !TryParseInt(parts[1], out int month) ||
            !TryParseInt(parts[2], out int day))
        {
            return false;
        }

        if (year < 1 || year > 9999)
        {
            return false;
        }

        return day >= 1 && day <= DaysInMonth(year, month);
    }

    private static bool TryParseInt(string text, out int value) =>
        int.TryParse(text, NumberStyles.AllowLeadingSign, CultureInfo.InvariantCulture, out value);

    /// <summary>Converts a string value to its typed representation.</summary>
    private static object ConvertValue(string value, string typeName, int lineNum)
    {
        switch (typeName)
        {
            case "str":
                return value;

            case "int":
                if (!long.TryParse(
                        value,
                        NumberStyles.AllowLeadingSign,
                        CultureInfo.InvariantCulture,
                        out long parsedInt))
                {
                    throw new KdgError($"Invalid integer: '{value}'", lineNum);
                }

                return parsedInt;

            case "float":
                if (!double.TryParse(
                        value,
                        NumberStyles.Float,
                        CultureInfo.InvariantCulture,
                        out double parsedFloat))
                {
                    throw new KdgError($"Invalid float: '{value}'", lineNum);
                }

                return parsedFloat;

            case "bool":
                switch (value.ToLowerInvariant())
                {
                    case "true" or "1":
                        return true;
                    case "false" or "0":
                        return false;
                    default:
                        throw new KdgError($"Invalid boolean: '{value}'", lineNum);
                }

            case "date":
                if (!IsValidDate(value))
                {
                    throw new KdgError($"Invalid date (expected YYYY-MM-DD): '{value}'", lineNum);
                }

                return value; // Return as string for JSON compatibility

            default:
                throw new KdgError($"Unknown type: '{typeName}'", lineNum);
        }
    }

    /// <summary>
    /// Scans a double-quoted value beginning at <c>line[start] == '"'</c>.
    /// Returns the value and the position just after the closing quote. Backslash
    /// escapes for \" and \\ are honoured per SPEC 6.2.
    /// </summary>
    private static (string Value, int Position) ScanWrappedValue(string line, int start, int lineNum)
    {
        StringBuilder chars = new();
        int i = start + 1;

        while (i < line.Length)
        {
            char c = line[i];

            if (c == '\\' && i + 1 < line.Length && (line[i + 1] == '"' || line[i + 1] == '\\'))
            {
                chars.Append(line[i + 1]);
                i += 2;
                continue;
            }

            if (c == '"')
            {
                return (chars.ToString(), i + 1);
            }

            chars.Append(c);
            i++;
        }

        throw new KdgError("Unterminated quoted value", lineNum);
    }

    /// <summary>Parses a single record line into a <see cref="ParsedRecord"/>.</summary>
    private static ParsedRecord ParseRecord(string line, Dictionary<char, FieldDef> delimiterMap, int lineNum)
    {
        ParsedRecord record = new();
        if (line.Length == 0)
        {
            return record;
        }

        int position = 0;

        while (position < line.Length)
        {
            string value;

            // A field is value-then-delimiter. The value may be wrapped in double
            // quotes, which lets it contain delimiter characters (SPEC 6.2).
            if (line[position] == '"')
            {
                (value, position) = ScanWrappedValue(line, position, lineNum);

                if (position >= line.Length)
                {
                    throw new KdgError($"Missing delimiter after value '{value}'", lineNum);
                }
            }
            else
            {
                int start = position;
                while (position < line.Length && !delimiterMap.ContainsKey(line[position]))
                {
                    position++;
                }

                if (position == line.Length)
                {
                    throw new KdgError(
                        $"No delimiter found for value starting at column {start}",
                        lineNum);
                }

                value = line.Substring(start, position - start);
            }

            char delimiter = line[position];

            if (!delimiterMap.TryGetValue(delimiter, out FieldDef? field))
            {
                throw new KdgError($"Undefined delimiter: '{delimiter}'", lineNum);
            }

            if (record.Values.ContainsKey(field.Label))
            {
                throw new KdgError($"Duplicate field in record: '{field.Label}'", lineNum);
            }

            record.Values[field.Label] = ConvertValue(value, field.TypeName, lineNum);
            record.Keys.Add(field.Label);
            position++;
        }

        return record;
    }

    /// <summary>Parses a KDG document into a list of records.</summary>
    private static List<ParsedRecord> Parse(string content)
    {
        List<string> lines = new(content.Replace("\r\n", "\n").Split('\n'));

        // A trailing newline produces a spurious final empty element. Drop it so a
        // document with no blank-line separator is reported as MissingSeparator
        // instead of having its first record misread as a definition.
        if (lines.Count > 0 && lines[^1].Length == 0)
        {
            lines.RemoveAt(lines.Count - 1);
        }

        // Find the separator (blank line).
        int separatorIdx = -1;
        for (int i = 0; i < lines.Count; i++)
        {
            if (lines[i].Length == 0)
            {
                separatorIdx = i;
                break;
            }
        }

        if (separatorIdx < 0)
        {
            throw new KdgError("No blank line separator found between definitions and data");
        }

        // Parse definitions.
        Dictionary<char, FieldDef> delimiterMap = new();
        for (int i = 0; i < separatorIdx; i++)
        {
            string line = lines[i];
            if (line.Length == 0)
            {
                continue; // Skip empty lines in the definition block
            }

            FieldDef field = ParseDefinition(line, i + 1);

            if (delimiterMap.TryGetValue(field.Delimiter, out FieldDef? existing))
            {
                throw new KdgError(
                    $"Delimiter '{field.Delimiter}' already used for field '{existing.Label}'",
                    i + 1);
            }

            delimiterMap[field.Delimiter] = field;
        }

        // Parse records.
        List<ParsedRecord> records = new();
        for (int i = separatorIdx + 1; i < lines.Count; i++)
        {
            string line = lines[i];
            if (line.Length == 0)
            {
                continue; // Skip empty lines in the data block
            }

            records.Add(ParseRecord(line, delimiterMap, i + 1));
        }

        return records;
    }

    private static string JsonEscape(string s)
    {
        StringBuilder sb = new(s.Length + 8);
        foreach (char c in s)
        {
            switch (c)
            {
                case '"':
                    sb.Append("\\\"");
                    break;
                case '\\':
                    sb.Append("\\\\");
                    break;
                case '\n':
                    sb.Append("\\n");
                    break;
                case '\r':
                    sb.Append("\\r");
                    break;
                case '\t':
                    sb.Append("\\t");
                    break;
                case '\b':
                    sb.Append("\\b");
                    break;
                case '\f':
                    sb.Append("\\f");
                    break;
                default:
                    if (c < ' ')
                    {
                        sb.Append("\\u").Append(((int)c).ToString("x4", CultureInfo.InvariantCulture));
                    }
                    else
                    {
                        sb.Append(c);
                    }

                    break;
            }
        }

        return sb.ToString();
    }

    /// <summary>
    /// Renders a double the way Go's encoding/json does: shortest round-trip
    /// decimal, plain notation for 1e-6 &lt;= |x| &lt; 1e21 and exponent notation
    /// outside that range. NaN and infinities have no JSON representation (Go
    /// errors out).
    /// </summary>
    private static string JsonDouble(double d)
    {
        if (double.IsNaN(d))
        {
            throw new KdgError("json: unsupported value: NaN");
        }

        if (double.IsInfinity(d))
        {
            throw new KdgError(d > 0 ? "json: unsupported value: +Inf" : "json: unsupported value: -Inf");
        }

        if (d == 0.0)
        {
            return 1.0 / d < 0 ? "-0" : "0";
        }

        double magnitude = Math.Abs(d);
        if (magnitude < 1e-6 || magnitude >= 1e21)
        {
            return GoExponent(d);
        }

        return DecimalPlainString(d);
    }

    /// <summary>Shortest exponent form as Go's strconv emits it, e.g. 1e-7, 1.5e+22.</summary>
    private static string GoExponent(double d)
    {
        string s = d.ToString("R", CultureInfo.InvariantCulture);
        int e = s.IndexOfAny(new[] { 'E', 'e' });
        if (e < 0)
        {
            return s;
        }

        string mantissa = s.Substring(0, e);
        if (mantissa.EndsWith(".0", StringComparison.Ordinal))
        {
            mantissa = mantissa.Substring(0, mantissa.Length - 2);
        }

        int exponent = int.Parse(s.Substring(e + 1), CultureInfo.InvariantCulture);
        return mantissa + "e" + (exponent >= 0 ? "+" : "") + exponent.ToString(CultureInfo.InvariantCulture);
    }

    /// <summary>
    /// Renders the plain decimal expansion of a shortest round-trip double. Valid
    /// only in the 1e-6..1e21 range, where every double fits a <see cref="decimal"/>
    /// exactly.
    /// </summary>
    private static string DecimalPlainString(double d)
    {
        string roundTrip = d.ToString("R", CultureInfo.InvariantCulture);
        decimal exact = decimal.Parse(roundTrip, NumberStyles.Float, CultureInfo.InvariantCulture);
        return exact.ToString(CultureInfo.InvariantCulture);
    }

    private static string JsonValue(object value) => value switch
    {
        string s => "\"" + JsonEscape(s) + "\"",
        bool b => b ? "true" : "false",
        long l => l.ToString(CultureInfo.InvariantCulture),
        double d => JsonDouble(d),
        _ => "\"" + JsonEscape(value.ToString() ?? "") + "\"",
    };

    /// <summary>Converts parsed records to a JSON string with 2-space indentation.</summary>
    private static string ToJson(List<ParsedRecord> records)
    {
        if (records.Count == 0)
        {
            return "[]\n";
        }

        StringBuilder sb = new();
        sb.Append("[\n");
        for (int index = 0; index < records.Count; index++)
        {
            ParsedRecord record = records[index];
            sb.Append("  {\n");
            for (int keyIndex = 0; keyIndex < record.Keys.Count; keyIndex++)
            {
                string key = record.Keys[keyIndex];
                sb.Append("    \"")
                    .Append(JsonEscape(key))
                    .Append("\": ")
                    .Append(JsonValue(record.Values[key]));
                if (keyIndex < record.Keys.Count - 1)
                {
                    sb.Append(',');
                }

                sb.Append('\n');
            }

            sb.Append("  }");
            if (index < records.Count - 1)
            {
                sb.Append(',');
            }

            sb.Append('\n');
        }

        sb.Append("]\n");
        return sb.ToString();
    }

    /// <summary>Renders a value the way the Python reference's str() does.</summary>
    private static string CsvValue(object? value) => value switch
    {
        null => "",
        string s => s,
        bool b => b ? "True" : "False",
        long l => l.ToString(CultureInfo.InvariantCulture),
        double d => CsvDouble(d),
        _ => value.ToString() ?? "",
    };

    /// <summary>Renders a double as Go's strconv.FormatFloat(v, 'g', -1, 64) would.</summary>
    private static string CsvDouble(double d)
    {
        if (double.IsNaN(d))
        {
            return "NaN";
        }

        if (double.IsInfinity(d))
        {
            return d > 0 ? "+Inf" : "-Inf";
        }

        if (d == 0.0)
        {
            return 1.0 / d < 0 ? "-0.0" : "0.0";
        }

        double magnitude = Math.Abs(d);
        if (magnitude < 1e-4 || magnitude >= 1e21)
        {
            string s = d.ToString("R", CultureInfo.InvariantCulture);
            int e = s.IndexOfAny(new[] { 'E', 'e' });
            if (e < 0)
            {
                return s;
            }

            string mantissa = s.Substring(0, e);
            if (mantissa.EndsWith(".0", StringComparison.Ordinal))
            {
                mantissa = mantissa.Substring(0, mantissa.Length - 2);
            }

            int exponent = int.Parse(s.Substring(e + 1), CultureInfo.InvariantCulture);
            string sign = exponent < 0 ? "-" : "+";
            return mantissa + "e" + sign + Math.Abs(exponent).ToString("00", CultureInfo.InvariantCulture);
        }

        string plain = DecimalPlainString(d);
        return plain.Contains('.') ? plain : plain + ".0";
    }

    /// <summary>
    /// Quotes a field containing a comma, double quote, or newline, doubling
    /// internal quotes.
    /// </summary>
    private static string EscapeCsv(string s) =>
        s.IndexOfAny(new[] { ',', '"', '\n' }) >= 0
            ? "\"" + s.Replace("\"", "\"\"") + "\""
            : s;

    /// <summary>Converts parsed records to a CSV string.</summary>
    private static string ToCsv(List<ParsedRecord> records)
    {
        if (records.Count == 0)
        {
            return "";
        }

        // Get all unique keys across all records, in first-seen order.
        List<string> allKeys = new();
        HashSet<string> seen = new();
        foreach (ParsedRecord record in records)
        {
            foreach (string key in record.Keys)
            {
                if (seen.Add(key))
                {
                    allKeys.Add(key);
                }
            }
        }

        StringBuilder sb = new();
        sb.Append(string.Join(",", allKeys.ConvertAll(EscapeCsv)));
        foreach (ParsedRecord record in records)
        {
            sb.Append('\n');
            List<string> row = new(allKeys.Count);
            foreach (string key in allKeys)
            {
                row.Add(EscapeCsv(
                    record.Values.TryGetValue(key, out object? value) ? CsvValue(value) : ""));
            }

            sb.Append(string.Join(",", row));
        }

        return sb.ToString();
    }
}
