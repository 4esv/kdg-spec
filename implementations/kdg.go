// KDG (Key-Delimiter Grammar) Parser - Reference Implementation
//
// Usage:
//
//	go run kdg.go parse <file>           Parse KDG to JSON
//	go run kdg.go validate <file>        Validate KDG syntax
//	go run kdg.go convert <file> [fmt]   Convert to format (json, csv)
//
// This implementation has no dependencies beyond the Go standard library.
// This was considered important.
package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"os"
	"regexp"
	"strconv"
	"strings"
	"time"
)

// fieldDef is a field definition from the KDG header.
type fieldDef struct {
	typeName  string
	label     string
	delimiter string
}

// parsedRecord keeps the field values plus the first-seen key order within the
// record. The order is needed for deterministic CSV headers (SPEC and the
// Python reference emit keys in first-seen order); JSON output does not depend
// on it.
type parsedRecord struct {
	values map[string]interface{}
	keys   []string
}

// kdgError is the base error type for KDG parsing errors. line is 0 when the
// error carries no line number (only MissingSeparator does).
type kdgError struct {
	message string
	line    int
}

func (e *kdgError) Error() string {
	if e.line > 0 {
		return fmt.Sprintf("Line %d: %s", e.line, e.message)
	}
	return e.message
}

var validTypes = map[string]bool{
	"str":   true,
	"int":   true,
	"float": true,
	"bool":  true,
	"date":  true,
}

// Characters that cannot be delimiters.
const reservedCharList = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789:\" \t\n\r"

var reservedChars = func() map[rune]bool {
	set := make(map[rune]bool)
	for _, r := range reservedCharList {
		set[r] = true
	}
	return set
}()

// Regex for parsing definition lines. Raw string literal so it is byte-identical
// to the Python and JavaScript reference implementations.
var definitionPattern = regexp.MustCompile(`^([a-z]+):"((?:[^"\\]|\\.)*)\"(.)$`)

// parseDefinition parses a single field definition line.
func parseDefinition(line string, lineNum int) (fieldDef, error) {
	match := definitionPattern.FindStringSubmatch(line)
	if match == nil {
		return fieldDef{}, &kdgError{
			message: fmt.Sprintf("Invalid definition syntax: '%s'", line),
			line:    lineNum,
		}
	}

	typeName, rawLabel, delimiter := match[1], match[2], match[3]

	if !validTypes[typeName] {
		return fieldDef{}, &kdgError{
			message: fmt.Sprintf("Unknown type: '%s'", typeName),
			line:    lineNum,
		}
	}

	if reservedChars[[]rune(delimiter)[0]] {
		return fieldDef{}, &kdgError{
			message: fmt.Sprintf("Invalid delimiter: '%s' (reserved character)", delimiter),
			line:    lineNum,
		}
	}

	// Unescape the label. Order matters: \" first, then \\.
	label := strings.ReplaceAll(rawLabel, `\"`, `"`)
	label = strings.ReplaceAll(label, `\\`, `\`)

	return fieldDef{typeName: typeName, label: label, delimiter: delimiter}, nil
}

// convertValue converts a string value to its typed representation.
func convertValue(value, typeName string, lineNum int) (interface{}, error) {
	switch typeName {
	case "str":
		return value, nil

	case "int":
		parsed, err := strconv.Atoi(value)
		if err != nil {
			return nil, &kdgError{
				message: fmt.Sprintf("Invalid integer: '%s'", value),
				line:    lineNum,
			}
		}
		return parsed, nil

	case "float":
		parsed, err := strconv.ParseFloat(value, 64)
		if err != nil {
			return nil, &kdgError{
				message: fmt.Sprintf("Invalid float: '%s'", value),
				line:    lineNum,
			}
		}
		return parsed, nil

	case "bool":
		lower := strings.ToLower(value)
		if lower == "true" || lower == "1" {
			return true, nil
		}
		if lower == "false" || lower == "0" {
			return false, nil
		}
		return nil, &kdgError{
			message: fmt.Sprintf("Invalid boolean: '%s'", value),
			line:    lineNum,
		}

	case "date":
		parts := strings.Split(value, "-")
		if len(parts) == 3 {
			year, errY := strconv.Atoi(parts[0])
			month, errM := strconv.Atoi(parts[1])
			day, errD := strconv.Atoi(parts[2])
			if errY == nil && errM == nil && errD == nil && year >= 1 && year <= 9999 {
				// time.Date normalises out-of-range components, so the
				// round-trip check rejects e.g. 2024-02-30.
				t := time.Date(year, time.Month(month), day, 0, 0, 0, 0, time.UTC)
				if t.Year() == year && int(t.Month()) == month && t.Day() == day {
					return value, nil // Return as string for JSON compatibility
				}
			}
		}
		return nil, &kdgError{
			message: fmt.Sprintf("Invalid date (expected YYYY-MM-DD): '%s'", value),
			line:    lineNum,
		}
	}

	return nil, &kdgError{
		message: fmt.Sprintf("Unknown type: '%s'", typeName),
		line:    lineNum,
	}
}

// scanWrappedValue scans a double-quoted value beginning at runes[start] == '"'.
// It returns the value and the position just after the closing quote. Backslash
// escapes for \" and \\ are honoured per SPEC 6.2.
func scanWrappedValue(runes []rune, start, lineNum int) (string, int, error) {
	chars := make([]rune, 0, len(runes)-start)
	i := start + 1

	for i < len(runes) {
		c := runes[i]

		if c == '\\' && i+1 < len(runes) && (runes[i+1] == '"' || runes[i+1] == '\\') {
			chars = append(chars, runes[i+1])
			i += 2
			continue
		}

		if c == '"' {
			return string(chars), i + 1, nil
		}

		chars = append(chars, c)
		i++
	}

	return "", 0, &kdgError{message: "Unterminated quoted value", line: lineNum}
}

// parseRecord parses a single record line into a parsedRecord.
func parseRecord(line string, delimiterMap map[string]fieldDef, lineNum int) (parsedRecord, error) {
	record := parsedRecord{values: map[string]interface{}{}}
	if line == "" {
		return record, nil
	}

	runes := []rune(line)
	position := 0

	for position < len(runes) {
		var value string

		// A field is value-then-delimiter. The value may be wrapped in double
		// quotes, which lets it contain delimiter characters (SPEC 6.2).
		if runes[position] == '"' {
			scanned, next, err := scanWrappedValue(runes, position, lineNum)
			if err != nil {
				return record, err
			}
			value = scanned
			position = next

			if position >= len(runes) {
				return record, &kdgError{
					message: fmt.Sprintf("Missing delimiter after value '%s'", value),
					line:    lineNum,
				}
			}
		} else {
			start := position
			for position < len(runes) {
				if _, ok := delimiterMap[string(runes[position])]; ok {
					break
				}
				position++
			}

			if position == len(runes) {
				return record, &kdgError{
					message: fmt.Sprintf("No delimiter found for value starting at column %d", start),
					line:    lineNum,
				}
			}

			value = string(runes[start:position])
		}

		delimiter := string(runes[position])

		field, ok := delimiterMap[delimiter]
		if !ok {
			return record, &kdgError{
				message: fmt.Sprintf("Undefined delimiter: '%s'", delimiter),
				line:    lineNum,
			}
		}

		if _, exists := record.values[field.label]; exists {
			return record, &kdgError{
				message: fmt.Sprintf("Duplicate field in record: '%s'", field.label),
				line:    lineNum,
			}
		}

		converted, err := convertValue(value, field.typeName, lineNum)
		if err != nil {
			return record, err
		}

		record.values[field.label] = converted
		record.keys = append(record.keys, field.label)
		position++
	}

	return record, nil
}

// parse parses a KDG document into a list of records.
func parse(content string) ([]parsedRecord, error) {
	lines := strings.Split(strings.ReplaceAll(content, "\r\n", "\n"), "\n")

	// A trailing newline produces a spurious final empty element. Drop it so a
	// document with no blank-line separator is reported as MissingSeparator
	// instead of having its first record misread as a definition.
	if len(lines) > 0 && lines[len(lines)-1] == "" {
		lines = lines[:len(lines)-1]
	}

	// Find the separator (blank line).
	separatorIdx := -1
	for i, line := range lines {
		if line == "" {
			separatorIdx = i
			break
		}
	}

	if separatorIdx < 0 {
		return nil, &kdgError{
			message: "No blank line separator found between definitions and data",
			line:    0,
		}
	}

	// Parse definitions.
	delimiterMap := map[string]fieldDef{}
	for i := 0; i < separatorIdx; i++ {
		line := lines[i]
		if line == "" { // Skip empty lines in the definition block
			continue
		}

		field, err := parseDefinition(line, i+1)
		if err != nil {
			return nil, err
		}

		if existing, ok := delimiterMap[field.delimiter]; ok {
			return nil, &kdgError{
				message: fmt.Sprintf("Delimiter '%s' already used for field '%s'", field.delimiter, existing.label),
				line:    i + 1,
			}
		}

		delimiterMap[field.delimiter] = field
	}

	// Parse records.
	records := make([]parsedRecord, 0)
	for i := separatorIdx + 1; i < len(lines); i++ {
		line := lines[i]
		if line == "" { // Skip empty lines in the data block
			continue
		}

		record, err := parseRecord(line, delimiterMap, i+1)
		if err != nil {
			return nil, err
		}
		records = append(records, record)
	}

	return records, nil
}

// toJSON converts parsed records to a JSON string with 2-space indentation.
func toJSON(records []parsedRecord) (string, error) {
	items := make([]map[string]interface{}, 0, len(records))
	for _, record := range records {
		items = append(items, record.values)
	}

	var buf bytes.Buffer
	encoder := json.NewEncoder(&buf)
	encoder.SetEscapeHTML(false)
	encoder.SetIndent("", "  ")
	if err := encoder.Encode(items); err != nil {
		return "", err
	}
	return buf.String(), nil
}

// csvValue renders a value the way the Python reference's str() does.
func csvValue(value interface{}) string {
	switch v := value.(type) {
	case nil:
		return ""
	case string:
		return v
	case bool:
		if v {
			return "True"
		}
		return "False"
	case int:
		return strconv.Itoa(v)
	case float64:
		s := strconv.FormatFloat(v, 'g', -1, 64)
		if !strings.ContainsAny(s, ".eEni") {
			s += ".0"
		}
		return s
	default:
		return fmt.Sprint(v)
	}
}

// escapeCSV quotes a field containing a comma, double quote, or newline,
// doubling internal quotes.
func escapeCSV(s string) string {
	if strings.ContainsAny(s, ",\"\n") {
		return "\"" + strings.ReplaceAll(s, "\"", "\"\"") + "\""
	}
	return s
}

// toCSV converts parsed records to a CSV string.
func toCSV(records []parsedRecord) string {
	if len(records) == 0 {
		return ""
	}

	// Get all unique keys across all records, in first-seen order.
	allKeys := make([]string, 0)
	seen := map[string]bool{}
	for _, record := range records {
		for _, key := range record.keys {
			if !seen[key] {
				seen[key] = true
				allKeys = append(allKeys, key)
			}
		}
	}

	lines := make([]string, 0, len(records)+1)
	header := make([]string, len(allKeys))
	for i, key := range allKeys {
		header[i] = escapeCSV(key)
	}
	lines = append(lines, strings.Join(header, ","))

	for _, record := range records {
		row := make([]string, len(allKeys))
		for i, key := range allKeys {
			row[i] = escapeCSV(csvValue(record.values[key]))
		}
		lines = append(lines, strings.Join(row, ","))
	}

	return strings.Join(lines, "\n")
}

const usage = "Usage: kdg <parse|validate|convert> <file> [json|csv]"

// run executes the CLI and returns the process exit code.
func run(args []string) int {
	if len(args) < 3 {
		fmt.Fprintln(os.Stderr, usage)
		return 1
	}

	command := args[1]
	filepath := args[2]

	content, err := os.ReadFile(filepath)
	if err != nil {
		if os.IsNotExist(err) {
			fmt.Fprintf(os.Stderr, "Error: File not found: %s\n", filepath)
		} else {
			fmt.Fprintf(os.Stderr, "Error reading file: %s\n", err)
		}
		return 1
	}

	switch command {
	case "parse":
		records, err := parse(string(content))
		if err != nil {
			fmt.Fprintf(os.Stderr, "Parse error: %s\n", err)
			return 1
		}
		out, err := toJSON(records)
		if err != nil {
			fmt.Fprintf(os.Stderr, "Parse error: %s\n", err)
			return 1
		}
		fmt.Print(out)
		return 0

	case "validate":
		if _, err := parse(string(content)); err != nil {
			fmt.Fprintf(os.Stderr, "Invalid: %s\n", err)
			return 1
		}
		fmt.Println("Valid KDG document")
		return 0

	case "convert":
		format := "json"
		if len(args) > 3 {
			format = args[3]
		}
		records, err := parse(string(content))
		if err != nil {
			fmt.Fprintf(os.Stderr, "Parse error: %s\n", err)
			return 1
		}
		switch format {
		case "json":
			out, err := toJSON(records)
			if err != nil {
				fmt.Fprintf(os.Stderr, "Parse error: %s\n", err)
				return 1
			}
			fmt.Print(out)
		case "csv":
			fmt.Println(toCSV(records))
		default:
			fmt.Fprintf(os.Stderr, "Unknown format: %s\n", format)
			return 1
		}
		return 0

	default:
		fmt.Fprintf(os.Stderr, "Unknown command: %s\n", command)
		fmt.Fprintln(os.Stderr, usage)
		return 1
	}
}

func main() {
	os.Exit(run(os.Args))
}
