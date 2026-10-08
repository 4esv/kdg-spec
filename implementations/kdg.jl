#!/usr/bin/env julia
# KDG (Key-Delimiter Grammar) Parser - Reference Implementation
#
# Usage:
#     julia kdg.jl parse <file>           Parse KDG to JSON
#     julia kdg.jl validate <file>        Validate KDG syntax
#     julia kdg.jl convert <file> [fmt]   Convert to format (json, csv)
#
# This implementation has no dependencies beyond the Julia standard library
# (only `Dates` is used, which ships with Julia). This was considered important.
#
# Behaviour mirrors implementations/kdg.go (the canonical reference): same
# accept/reject decisions, same error messages, same line-number prefixing.

using Dates

# A field definition from the definition block.
struct FieldDef
    type_name::String
    label::String
    delimiter::Char
end

# A parsed record: typed values plus the first-seen key order within the record.
# First-seen order is what the CSV header and the JSON output use.
struct Record
    values::Dict{String,Any}
    keys::Vector{String}
end

const VALID_TYPES = Set(["str", "int", "float", "bool", "date"])

# Characters that cannot be delimiters (SPEC 3.4).
const RESERVED_CHARS = Set(collect("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789:\" \t\n\r"))

# Definition-line grammar, byte-identical to the Python/Go reference pattern.
const DEFINITION_PATTERN = Regex("^([a-z]+):\"((?:[^\"\\\\]|\\\\.)*)\"(.)\$")

# Strict whole-string integer/float grammars. They intentionally reject
# surrounding whitespace (matching Go's strconv) while allowing the decimal and
# scientific forms the reference parsers accept.
const INT_PATTERN = Regex("\\A[+-]?[0-9]+\\z")
const FLOAT_PATTERN = Regex("\\A[+-]?(?:[0-9]+(?:\\.[0-9]*)?|\\.[0-9]+)(?:[eE][+-]?[0-9]+)?\\z")

const USAGE = "Usage: kdg <parse|validate|convert> <file> [json|csv]"

# Raise a KDG parse error. A line of 0 means the error is document-wide
# (only MissingSeparator), so no "Line <n>: " prefix is added.
function kdg_error(message::AbstractString, line::Int)
    error(line > 0 ? "Line $line: $message" : String(message))
end

errmsg(e) = e isa ErrorException ? e.msg : sprint(showerror, e)

# Parse a single field definition line into a FieldDef.
function parse_definition(line::AbstractString, line_num::Int)
    m = match(DEFINITION_PATTERN, line)
    if m === nothing
        kdg_error("Invalid definition syntax: '$line'", line_num)
    end

    type_name = m.captures[1]
    raw_label = m.captures[2]
    delimiter = only(m.captures[3])

    if !(type_name in VALID_TYPES)
        kdg_error("Unknown type: '$type_name'", line_num)
    end

    if delimiter in RESERVED_CHARS
        kdg_error("Invalid delimiter: '$delimiter' (reserved character)", line_num)
    end

    # Unescape the label: \" first, then \\ (order matters).
    label = replace(raw_label, "\\\"" => "\"")
    label = replace(label, "\\\\" => "\\")

    return FieldDef(String(type_name), label, delimiter)
end

# Convert a raw value string to its typed representation, raising TypeMismatch
# (with the canonical message) on failure. `date` stays a string for JSON.
function convert_value(value::AbstractString, type_name::AbstractString, line_num::Int)
    if type_name == "str"
        return String(value)
    elseif type_name == "int"
        if occursin(INT_PATTERN, value)
            parsed = tryparse(Int, value)
            parsed !== nothing && return parsed
        end
        kdg_error("Invalid integer: '$value'", line_num)
    elseif type_name == "float"
        if occursin(FLOAT_PATTERN, value)
            parsed = tryparse(Float64, value)
            # Reject non-finite results so JSON output stays valid.
            parsed !== nothing && isfinite(parsed) && return parsed
        end
        kdg_error("Invalid float: '$value'", line_num)
    elseif type_name == "bool"
        lower = lowercase(value)
        (lower == "true" || lower == "1") && return true
        (lower == "false" || lower == "0") && return false
        kdg_error("Invalid boolean: '$value'", line_num)
    elseif type_name == "date"
        parts = split(value, "-")
        if length(parts) == 3 &&
           occursin(INT_PATTERN, parts[1]) &&
           occursin(INT_PATTERN, parts[2]) &&
           occursin(INT_PATTERN, parts[3])
            # tryparse (not parse): an absurdly long year must fail as a date,
            # not as an uncaught integer-overflow error.
            y = tryparse(Int, parts[1])
            mo = tryparse(Int, parts[2])
            d = tryparse(Int, parts[3])
            if y !== nothing && mo !== nothing && d !== nothing && 1 <= y <= 9999
                # Date() rejects out-of-range months/days; the round-trip check
                # mirrors the Go reference's normalise-and-compare.
                try
                    dt = Date(y, mo, d)
                    if year(dt) == y && month(dt) == mo && day(dt) == d
                        return String(value)
                    end
                catch
                end
            end
        end
        kdg_error("Invalid date (expected YYYY-MM-DD): '$value'", line_num)
    end

    kdg_error("Unknown type: '$type_name'", line_num)
end

# Scan a double-quoted value beginning at runes[start] == '"'. Returns the
# unescaped value and the position just after the closing quote. Backslash
# escapes for \" and \\ are honoured (SPEC 6.2).
function scan_wrapped_value(runes::Vector{Char}, start::Int, line_num::Int)
    chars = Char[]
    i = start + 1
    n = length(runes)
    while i <= n
        c = runes[i]
        if c == '\\' && i + 1 <= n && (runes[i + 1] == '"' || runes[i + 1] == '\\')
            push!(chars, runes[i + 1])
            i += 2
            continue
        end
        if c == '"'
            return String(chars), i + 1
        end
        push!(chars, c)
        i += 1
    end
    kdg_error("Unterminated quoted value", line_num)
end

# Parse a single record line (value-then-delimiter fields).
function parse_record(line::AbstractString, delimiter_map::Dict{Char,FieldDef}, line_num::Int)
    record = Record(Dict{String,Any}(), String[])
    isempty(line) && return record

    runes = collect(line)
    n = length(runes)
    position = 1 # 1-based character index

    while position <= n
        local value::String

        if runes[position] == '"'
            value, position = scan_wrapped_value(runes, position, line_num)
            if position > n
                kdg_error("Missing delimiter after value '$value'", line_num)
            end
        else
            start = position
            while position <= n
                if haskey(delimiter_map, runes[position])
                    break
                end
                position += 1
            end
            if position > n
                # Column is a 0-based character index, like the Go/Python refs.
                kdg_error("No delimiter found for value starting at column $(start - 1)", line_num)
            end
            value = String(runes[start:position - 1])
        end

        delimiter = runes[position]
        field = get(delimiter_map, delimiter, nothing)
        if field === nothing
            kdg_error("Undefined delimiter: '$delimiter'", line_num)
        end

        if haskey(record.values, field.label)
            kdg_error("Duplicate field in record: '$(field.label)'", line_num)
        end

        record.values[field.label] = convert_value(value, field.type_name, line_num)
        push!(record.keys, field.label)
        position += 1
    end

    return record
end

# Parse a KDG document into a list of records.
function parse_document(content::AbstractString)
    lines = split(replace(content, "\r\n" => "\n"), "\n")

    # A trailing newline produces a spurious final empty element; drop one so a
    # document without a blank-line separator reports MissingSeparator instead
    # of misreading its first record as a definition.
    if !isempty(lines) && lines[end] == ""
        pop!(lines)
    end

    separator_idx = findfirst(==(""), lines)
    if separator_idx === nothing
        kdg_error("No blank line separator found between definitions and data", 0)
    end

    delimiter_map = Dict{Char,FieldDef}()
    for i in 1:(separator_idx - 1)
        line = lines[i]
        isempty(line) && continue

        field = parse_definition(line, i)
        if haskey(delimiter_map, field.delimiter)
            existing = delimiter_map[field.delimiter]
            kdg_error("Delimiter '$(field.delimiter)' already used for field '$(existing.label)'", i)
        end
        delimiter_map[field.delimiter] = field
    end

    records = Record[]
    for i in (separator_idx + 1):length(lines)
        line = lines[i]
        isempty(line) && continue
        push!(records, parse_record(line, delimiter_map, i))
    end

    return records
end

# --- Output -----------------------------------------------------------------

# Escape a string for a JSON string literal (raw UTF-8 otherwise).
function json_escape(s::AbstractString)
    io = IOBuffer()
    for c in s
        if c == '"'
            print(io, "\\\"")
        elseif c == '\\'
            print(io, "\\\\")
        elseif c == '\n'
            print(io, "\\n")
        elseif c == '\r'
            print(io, "\\r")
        elseif c == '\t'
            print(io, "\\t")
        elseif c < ' '
            print(io, "\\u", lpad(string(UInt32(c), base = 16), 4, '0'))
        else
            print(io, c)
        end
    end
    return String(take!(io))
end

json_value(v::AbstractString) = "\"" * json_escape(v) * "\""
json_value(v::Bool) = v ? "true" : "false"
json_value(v::Integer) = string(v)
json_value(v::AbstractFloat) = string(v)
json_value(::Nothing) = "null"

# Convert records to a JSON string with 2-space indentation and a trailing newline.
function to_json(records::Vector{Record})
    io = IOBuffer()
    if isempty(records)
        print(io, "[]\n")
        return String(take!(io))
    end

    print(io, "[\n")
    for (ri, record) in enumerate(records)
        print(io, "  {")
        if isempty(record.keys)
            print(io, "}")
        else
            print(io, "\n")
            for (ki, key) in enumerate(record.keys)
                print(io, "    \"", json_escape(key), "\": ", json_value(record.values[key]))
                ki < length(record.keys) && print(io, ",")
                print(io, "\n")
            end
            print(io, "  }")
        end
        ri < length(records) && print(io, ",")
        print(io, "\n")
    end
    print(io, "]\n")
    return String(take!(io))
end

csv_value(::Nothing) = ""
csv_value(v::Bool) = v ? "True" : "False"
csv_value(v) = string(v)

# Quote a CSV field containing a comma, double quote, or newline.
function escape_csv(s::AbstractString)
    if occursin(',', s) || occursin('"', s) || occursin('\n', s)
        return "\"" * replace(s, "\"" => "\"\"") * "\""
    end
    return String(s)
end

# Convert records to a CSV string (first-seen header order).
function to_csv(records::Vector{Record})
    isempty(records) && return ""

    all_keys = String[]
    seen = Set{String}()
    for record in records
        for key in record.keys
            if !(key in seen)
                push!(seen, key)
                push!(all_keys, key)
            end
        end
    end

    lines = String[join((escape_csv(k) for k in all_keys), ",")]
    for record in records
        row = String[]
        for key in all_keys
            push!(row, escape_csv(csv_value(get(record.values, key, nothing))))
        end
        push!(lines, join(row, ","))
    end

    return join(lines, "\n")
end

# --- CLI --------------------------------------------------------------------

function main(args::Vector{String})
    if length(args) < 2
        println(stderr, USAGE)
        return 1
    end

    command = args[1]
    filepath = args[2]

    if !isfile(filepath)
        println(stderr, "Error: File not found: $filepath")
        return 1
    end

    content = try
        read(filepath, String)
    catch e
        println(stderr, "Error reading file: $(sprint(showerror, e))")
        return 1
    end

    if command == "parse"
        records = try
            parse_document(content)
        catch e
            println(stderr, "Parse error: ", errmsg(e))
            return 1
        end
        print(to_json(records))
        return 0
    elseif command == "validate"
        try
            parse_document(content)
        catch e
            println(stderr, "Invalid: ", errmsg(e))
            return 1
        end
        println("Valid KDG document")
        return 0
    elseif command == "convert"
        format = length(args) >= 3 ? args[3] : "json"
        records = try
            parse_document(content)
        catch e
            println(stderr, "Parse error: ", errmsg(e))
            return 1
        end
        if format == "json"
            print(to_json(records))
        elseif format == "csv"
            println(to_csv(records))
        else
            println(stderr, "Unknown format: $format")
            return 1
        end
        return 0
    else
        println(stderr, "Unknown command: $command")
        println(stderr, USAGE)
        return 1
    end
end

exit(main(ARGS))
