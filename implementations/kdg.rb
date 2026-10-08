#!/usr/bin/env ruby
# frozen_string_literal: true
#
# KDG (Key-Delimiter Grammar) Parser - Ruby implementation
#
# Usage:
#   ruby kdg.rb parse <file>           Parse KDG to JSON
#   ruby kdg.rb validate <file>        Validate KDG syntax
#   ruby kdg.rb convert <file> [fmt]   Convert to format (json, csv)
#
# This implementation has no dependencies beyond the Ruby standard library.

require 'date'

USAGE = 'Usage: kdg <parse|validate|convert> <file> [json|csv]'

VALID_TYPES = %w[str int float bool date].freeze

# Characters that cannot be delimiters (SPEC 3.4).
RESERVED_CHARS = (
  ('a'..'z').to_a + ('A'..'Z').to_a + ('0'..'9').to_a +
  [':', '"', ' ', "\t", "\n", "\r"]
).freeze

# Same shape as the Go/Python/JavaScript reference implementations.
DEFINITION_PATTERN = /\A([a-z]+):"((?:[^"\\]|\\.)*)"(.)\z/
INT_PATTERN = /\A[+-]?[0-9]+\z/
FLOAT_PATTERN = /\A[+-]?(?:[0-9]+\.?[0-9]*|\.[0-9]+)(?:[eE][+-]?[0-9]+)?\z/

# Base error for KDG parsing failures. line is nil when the error carries no
# line number (only MissingSeparator does).
class KDGError < StandardError
  attr_reader :line

  def initialize(message, line = nil)
    @line = line
    @message = message
    super(line ? "Line #{line}: #{message}" : message)
  end
end

# Parse a single definition line. Returns [type_name, label, delimiter].
def parse_definition(line, line_num)
  match = DEFINITION_PATTERN.match(line)
  raise KDGError.new("Invalid definition syntax: '#{line}'", line_num) unless match

  type_name = match[1]
  raw_label = match[2]
  delimiter = match[3]

  unless VALID_TYPES.include?(type_name)
    raise KDGError.new("Unknown type: '#{type_name}'", line_num)
  end

  if RESERVED_CHARS.include?(delimiter)
    raise KDGError.new("Invalid delimiter: '#{delimiter}' (reserved character)", line_num)
  end

  # Unescape the label. Order matters: \" first, then \\.
  label = raw_label.gsub(/\\"/) { '"' }.gsub(/\\\\/) { '\\' }

  [type_name, label, delimiter]
end

# Convert a string value to its typed representation.
def convert_value(value, type_name, line_num)
  case type_name
  when 'str'
    value

  when 'int'
    raise KDGError.new("Invalid integer: '#{value}'", line_num) unless INT_PATTERN.match?(value)

    value.to_i

  when 'float'
    raise KDGError.new("Invalid float: '#{value}'", line_num) unless FLOAT_PATTERN.match?(value)

    value.to_f

  when 'bool'
    lower = value.downcase
    return true if lower == 'true' || lower == '1'
    return false if lower == 'false' || lower == '0'

    raise KDGError.new("Invalid boolean: '#{value}'", line_num)

  when 'date'
    parts = value.split('-', -1)
    if parts.length == 3
      year = strict_int(parts[0])
      month = strict_int(parts[1])
      day = strict_int(parts[2])
      if year && month && day && year >= 1 && year <= 9999 && Date.valid_date?(year, month, day)
        return value # Returned as its string form for JSON compatibility.
      end
    end
    raise KDGError.new("Invalid date (expected YYYY-MM-DD): '#{value}'", line_num)

  else
    raise KDGError.new("Unknown type: '#{type_name}'", line_num)
  end
end

# Strict signed-integer parser: Integer() would accept surrounding whitespace.
def strict_int(str)
  return nil unless INT_PATTERN.match?(str)

  str.to_i
end

# Scan a double-quoted value starting at line[start] == '"'. Returns
# [value, position_after_closing_quote]. Backslash escapes for \" and \\ are
# honoured per SPEC 6.2.
def scan_wrapped_value(line, start, line_num)
  chars = []
  i = start + 1
  while i < line.length
    c = line[i]
    if c == '\\' && i + 1 < line.length && (line[i + 1] == '"' || line[i + 1] == '\\')
      chars << line[i + 1]
      i += 2
      next
    end
    return [chars.join, i + 1] if c == '"'

    chars << c
    i += 1
  end
  raise KDGError.new('Unterminated quoted value', line_num)
end

# Parse a single record line into a Hash. Ruby hashes keep insertion order,
# which is what CSV header generation needs.
def parse_record(line, delimiter_map, line_num)
  return {} if line.empty?

  record = {}
  position = 0
  length = line.length

  while position < length
    # A field is value-then-delimiter. The value may be wrapped in double
    # quotes, which lets it contain delimiter characters (SPEC 6.2).
    if line[position] == '"'
      value, position = scan_wrapped_value(line, position, line_num)
      if position >= length
        raise KDGError.new("Missing delimiter after value '#{value}'", line_num)
      end
    else
      start = position
      position += 1 while position < length && !delimiter_map.key?(line[position])
      if position == length
        raise KDGError.new("No delimiter found for value starting at column #{start}", line_num)
      end
      value = line[start...position]
    end

    delimiter = line[position]
    field = delimiter_map[delimiter]
    raise KDGError.new("Undefined delimiter: '#{delimiter}'", line_num) unless field

    if record.key?(field[:label])
      raise KDGError.new("Duplicate field in record: '#{field[:label]}'", line_num)
    end

    record[field[:label]] = convert_value(value, field[:type], line_num)
    position += 1
  end

  record
end

# Parse a KDG document into an array of record hashes.
def parse(content)
  lines = content.gsub("\r\n", "\n").split("\n", -1)

  # A trailing newline produces a spurious final empty element. Drop one so a
  # document with no blank-line separator is reported as MissingSeparator
  # instead of having its first record misread as a definition.
  lines.pop if !lines.empty? && lines[-1] == ''

  # Find the separator (blank line).
  separator_idx = lines.index('')
  if separator_idx.nil?
    raise KDGError.new('No blank line separator found between definitions and data')
  end

  delimiter_map = {}
  (0...separator_idx).each do |i|
    line = lines[i]
    next if line.empty? # Skip empty lines in the definition block.

    type_name, label, delimiter = parse_definition(line, i + 1)

    if delimiter_map.key?(delimiter)
      existing = delimiter_map[delimiter]
      raise KDGError.new("Delimiter '#{delimiter}' already used for field '#{existing[:label]}'", i + 1)
    end

    delimiter_map[delimiter] = { type: type_name, label: label, delimiter: delimiter }
  end

  records = []
  ((separator_idx + 1)...lines.length).each do |i|
    line = lines[i]
    next if line.empty? # Skip empty lines in the data block.

    records << parse_record(line, delimiter_map, i + 1)
  end

  records
end

# Escape a string for a JSON string literal. Non-ASCII characters pass through
# raw (never escaped).
def json_escape(str)
  out = String.new
  str.each_char do |ch|
    case ch
    when '"'  then out << '\\"'
    when '\\' then out << '\\\\'
    when "\n" then out << '\\n'
    when "\r" then out << '\\r'
    when "\t" then out << '\\t'
    when "\b" then out << '\\b'
    when "\f" then out << '\\f'
    else
      if ch.ord < 0x20
        out << format('\\u%04x', ch.ord)
      else
        out << ch
      end
    end
  end
  out
end

def value_json(value)
  case value
  when String then "\"#{json_escape(value)}\""
  when true then 'true'
  when false then 'false'
  when Integer then value.to_s
  when Float then value.to_s
  when nil then 'null'
  else value.to_s
  end
end

def record_json(record)
  return '  {}' if record.empty?

  fields = record.map { |k, v| "    \"#{json_escape(k)}\": #{value_json(v)}" }
  "  {\n#{fields.join(",\n")}\n  }"
end

# Serialize records as JSON with 2-space indentation (no trailing newline).
def to_json(records)
  return '[]' if records.empty?

  "[\n#{records.map { |r| record_json(r) }.join(",\n")}\n]"
end

# Render a value the way Python's str() does (the Go reference replicates it).
def csv_value(value)
  case value
  when nil then ''
  when true then 'True'
  when false then 'False'
  else value.to_s
  end
end

def escape_csv(str)
  return str unless str.include?(',') || str.include?('"') || str.include?("\n")

  "\"#{str.gsub('"', '""')}\""
end

def to_csv(records)
  return '' if records.empty?

  all_keys = []
  seen = {}
  records.each do |record|
    record.each_key do |key|
      next if seen[key]

      seen[key] = true
      all_keys << key
    end
  end

  lines = [all_keys.map { |k| escape_csv(k) }.join(',')]
  records.each do |record|
    lines << all_keys.map { |k| escape_csv(csv_value(record[k])) }.join(',')
  end
  lines.join("\n")
end

def main(argv)
  if argv.length < 2
    warn USAGE
    return 1
  end

  command = argv[0]
  filepath = argv[1]

  begin
    content = File.read(filepath, encoding: 'UTF-8')
  rescue Errno::ENOENT
    warn "Error: File not found: #{filepath}"
    return 1
  rescue SystemCallError => e
    warn "Error reading file: #{e.message}"
    return 1
  end

  case command
  when 'parse'
    begin
      records = parse(content)
      puts(to_json(records))
    rescue KDGError => e
      warn "Parse error: #{e.message}"
      return 1
    end
    0

  when 'validate'
    begin
      parse(content)
      puts 'Valid KDG document'
      0
    rescue KDGError => e
      warn "Invalid: #{e.message}"
      1
    end

  when 'convert'
    format = argv.length > 2 ? argv[2] : 'json'
    begin
      records = parse(content)
    rescue KDGError => e
      warn "Parse error: #{e.message}"
      return 1
    end

    case format
    when 'json'
      puts(to_json(records))
    when 'csv'
      puts(to_csv(records))
    else
      warn "Unknown format: #{format}"
      return 1
    end
    0

  else
    warn "Unknown command: #{command}"
    warn USAGE
    1
  end
end

exit(main(ARGV))
