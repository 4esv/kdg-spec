#!/usr/bin/env elixir
# KDG (Key-Delimited Grammar) parser - Elixir implementation.
#
# Usage:
#   elixir implementations/kdg.exs parse <file>          Parse KDG to JSON
#   elixir implementations/kdg.exs validate <file>       Validate KDG syntax
#   elixir implementations/kdg.exs convert <file> [fmt]  Convert to json or csv
#
# Standard library only. Messages, exit codes and the JSON/CSV shape follow
# implementations/kdg.go.

defmodule KDG do
  @usage "Usage: kdg <parse|validate|convert> <file> [json|csv]"
  @valid_types ["str", "int", "float", "bool", "date"]

  # A definition line: type:"label"delimiter, where the label may contain \" and \\.
  @definition_pattern ~r/^([a-z]+):"((?:[^"\\]|\\.)*)"(.)$/u

  # Float forms: optional sign, digits with an optional fraction (or a bare
  # fraction), optional exponent. This is what the Go and Python references accept.
  @float_pattern ~r/^[+-]?([0-9]+(\.[0-9]*)?|\.[0-9]+)([eE][+-]?[0-9]+)?$/

  # ------------------------------------------------------------------ CLI --

  def main(argv) do
    case argv do
      [command, file | rest] -> read(command, file, rest)
      _ ->
        IO.puts(:stderr, @usage)
        System.halt(1)
    end
  end

  defp read(command, file, rest) do
    case File.read(file) do
      {:ok, content} ->
        if String.valid?(content) do
          System.halt(run(command, content, rest))
        else
          IO.puts(:stderr, "Error reading file: #{file}: invalid UTF-8")
          System.halt(1)
        end

      {:error, :enoent} ->
        IO.puts(:stderr, "Error: File not found: #{file}")
        System.halt(1)

      {:error, reason} ->
        IO.puts(:stderr, "Error reading file: #{:file.format_error(reason)}")
        System.halt(1)
    end
  end

  defp run("parse", content, _rest) do
    case parse_safe(content) do
      {:ok, records} ->
        IO.write([to_json(records), "\n"])
        0

      {:error, message} ->
        IO.puts(:stderr, "Parse error: #{message}")
        1
    end
  end

  defp run("validate", content, _rest) do
    case parse_safe(content) do
      {:ok, _records} ->
        IO.write("Valid KDG document\n")
        0

      {:error, message} ->
        IO.puts(:stderr, "Invalid: #{message}")
        1
    end
  end

  defp run("convert", content, rest) do
    format =
      case rest do
        [requested | _] -> requested
        [] -> "json"
      end

    case parse_safe(content) do
      {:ok, records} when format == "json" ->
        IO.write([to_json(records), "\n"])
        0

      {:ok, records} when format == "csv" ->
        IO.write([to_csv(records), "\n"])
        0

      {:ok, _records} ->
        IO.puts(:stderr, "Unknown format: #{format}")
        1

      {:error, message} ->
        IO.puts(:stderr, "Parse error: #{message}")
        1
    end
  end

  defp run(command, _content, _rest) do
    IO.puts(:stderr, "Unknown command: #{command}")
    IO.puts(:stderr, @usage)
    1
  end

  # ------------------------------------------------------------- messaging --

  # MissingSeparator is the only error without a line number.
  defp fail(line_number, message), do: throw({:kdg_error, error_text(line_number, message)})

  defp error_text(0, message), do: message
  defp error_text(line_number, message), do: "Line #{line_number}: #{message}"

  defp parse_safe(content) do
    {:ok, parse(content)}
  catch
    {:kdg_error, message} -> {:error, message}
  end

  # --------------------------------------------------------------- parsing --

  defp parse(content) do
    lines = content |> String.replace("\r\n", "\n") |> String.split("\n") |> drop_trailing_empty()

    case Enum.find_index(lines, &(&1 == "")) do
      nil ->
        fail(0, "No blank line separator found between definitions and data")

      separator ->
        {definition_lines, [_separator | record_lines]} = Enum.split(lines, separator)
        delimiter_map = parse_definitions(definition_lines, %{})
        parse_records(record_lines, separator + 2, delimiter_map, [])
    end
  end

  defp drop_trailing_empty(lines) do
    case Enum.reverse(lines) do
      ["" | rest] -> Enum.reverse(rest)
      _ -> lines
    end
  end

  defp parse_definitions(lines, delimiter_map) do
    lines
    |> Enum.with_index(1)
    |> Enum.reduce(delimiter_map, fn {line, line_number}, acc ->
      if line == "" do
        acc
      else
        {type_name, label, delimiter} = parse_definition(line, line_number)
        <<delimiter_codepoint::utf8>> = delimiter

        case Map.fetch(acc, delimiter_codepoint) do
          {:ok, {_type, existing_label, _delimiter}} ->
            fail(line_number, "Delimiter '#{delimiter}' already used for field '#{existing_label}'")

          :error ->
            Map.put(acc, delimiter_codepoint, {type_name, label, delimiter})
        end
      end
    end)
  end

  defp parse_definition(line, line_number) do
    case Regex.run(@definition_pattern, line) do
      [_, type_name, raw_label, delimiter] ->
        if type_name not in @valid_types do
          fail(line_number, "Unknown type: '#{type_name}'")
        end

        if reserved?(delimiter) do
          fail(line_number, "Invalid delimiter: '#{delimiter}' (reserved character)")
        end

        {type_name, unescape_label(raw_label), delimiter}

      nil ->
        fail(line_number, "Invalid definition syntax: '#{line}'")
    end
  end

  # \" first, then \\.
  defp unescape_label(raw_label) do
    raw_label
    |> String.replace("\\\"", "\"")
    |> String.replace("\\\\", "\\")
  end

  # Alphanumerics, ':', '"' and whitespace. The delimiter is one code point.
  defp reserved?(<<codepoint::utf8>>) do
    (codepoint >= ?a and codepoint <= ?z) or
      (codepoint >= ?A and codepoint <= ?Z) or
      (codepoint >= ?0 and codepoint <= ?9) or
      codepoint == ?: or codepoint == ?" or
      codepoint == ?\s or codepoint == ?\t or codepoint == ?\n or codepoint == ?\r
  end

  defp parse_records([], _line_number, _delimiter_map, acc), do: Enum.reverse(acc)

  defp parse_records([line | rest], line_number, delimiter_map, acc) do
    acc = if line == "", do: acc, else: [parse_record(line, line_number, delimiter_map) | acc]
    parse_records(rest, line_number + 1, delimiter_map, acc)
  end

  # A field is a value followed by its delimiter; the value may be wrapped in
  # double quotes, which lets it contain delimiter characters.
  defp parse_record(line, line_number, delimiter_map) do
    parse_record(line, line_number, delimiter_map, 0, [])
  end

  defp parse_record("", _line_number, _delimiter_map, _position, acc), do: Enum.reverse(acc)

  defp parse_record(rest, line_number, delimiter_map, position, acc) do
    {value, after_value} = scan_field(rest, delimiter_map, line_number, position)
    <<codepoint::utf8, tail::binary>> = after_value

    {type_name, label, _delimiter} =
      case Map.fetch(delimiter_map, codepoint) do
        {:ok, definition} -> definition
        :error -> fail(line_number, "Undefined delimiter: '#{<<codepoint::utf8>>}'")
      end

    if Enum.any?(acc, fn {existing, _value} -> existing == label end) do
      fail(line_number, "Duplicate field in record: '#{label}'")
    end

    typed_value = convert_value(value, type_name, line_number)
    consumed = binary_part(rest, 0, byte_size(rest) - byte_size(tail))
    parse_record(tail, line_number, delimiter_map, position + cp_length(consumed), [
      {label, typed_value} | acc
    ])
  end

  defp scan_field(<<"\"", _::binary>> = rest, _delimiter_map, line_number, _position) do
    {value, after_quote} = scan_wrapped(rest, line_number)
    if after_quote == "", do: fail(line_number, "Missing delimiter after value '#{value}'")
    {value, after_quote}
  end

  defp scan_field(rest, delimiter_map, line_number, position) do
    {value, after_delimiter} = scan_raw(rest, delimiter_map, [])

    if after_delimiter == "" do
      fail(line_number, "No delimiter found for value starting at column #{position}")
    end

    {value, after_delimiter}
  end

  # Starting at the opening quote; returns the value and the rest after the
  # closing quote. \" and \\ are honoured per SPEC 6.2.
  defp scan_wrapped(<<"\"", inner::binary>>, line_number) do
    scan_wrapped_chars(inner, [], line_number)
  end

  defp scan_wrapped_chars(<<>>, _acc, line_number) do
    fail(line_number, "Unterminated quoted value")
  end

  defp scan_wrapped_chars(<<?\\, codepoint::utf8, tail::binary>>, acc, line_number)
       when codepoint in [?", ?\\] do
    scan_wrapped_chars(tail, [codepoint | acc], line_number)
  end

  defp scan_wrapped_chars(<<"\"", tail::binary>>, acc, _line_number) do
    {chars_to_binary(acc), tail}
  end

  defp scan_wrapped_chars(<<codepoint::utf8, tail::binary>>, acc, line_number) do
    scan_wrapped_chars(tail, [codepoint | acc], line_number)
  end

  # Consumes up to the next defined delimiter.
  defp scan_raw(<<>>, _delimiter_map, acc), do: {chars_to_binary(acc), ""}

  defp scan_raw(<<codepoint::utf8, tail::binary>> = rest, delimiter_map, acc) do
    if Map.has_key?(delimiter_map, codepoint) do
      {chars_to_binary(acc), rest}
    else
      scan_raw(tail, delimiter_map, [codepoint | acc])
    end
  end

  defp chars_to_binary(acc), do: acc |> Enum.reverse() |> :unicode.characters_to_binary()

  defp cp_length(binary), do: cp_length(binary, 0)

  defp cp_length(<<_codepoint::utf8, rest::binary>>, count), do: cp_length(rest, count + 1)
  defp cp_length(<<>>, count), do: count

  # ---------------------------------------------------------------- values --

  defp convert_value(value, "str", _line_number), do: {:str, value}
  defp convert_value(value, "int", line_number) do
    case parse_int(value) do
      {:ok, integer} -> {:int, integer}
      :error -> fail(line_number, "Invalid integer: '#{value}'")
    end
  end

  defp convert_value(value, "float", line_number) do
    case parse_float(value) do
      {:ok, float} -> {:float, float}
      :error -> fail(line_number, "Invalid float: '#{value}'")
    end
  end

  defp convert_value(value, "bool", line_number) do
    case String.downcase(value) do
      "true" -> {:bool, true}
      "1" -> {:bool, true}
      "false" -> {:bool, false}
      "0" -> {:bool, false}
      _ -> fail(line_number, "Invalid boolean: '#{value}'")
    end
  end

  defp convert_value(value, "date", line_number) do
    if valid_date?(value) do
      {:date, value}
    else
      fail(line_number, "Invalid date (expected YYYY-MM-DD): '#{value}'")
    end
  end

  defp convert_value(_value, type_name, line_number) do
    fail(line_number, "Unknown type: '#{type_name}'")
  end

  # The specification's int form: -?[0-9]+.
  defp parse_int(value) do
    digits =
      case value do
        <<"-", rest::binary>> -> rest
        _ -> value
      end

    if digits != "" and Regex.match?(~r/^[0-9]+$/, digits) do
      {:ok, String.to_integer(value)}
    else
      :error
    end
  end

  defp parse_float(value) do
    if Regex.match?(@float_pattern, value) do
      case Float.parse(normalize_float(value)) do
        {float, ""} -> {:ok, float}
        _ -> :error
      end
    else
      :error
    end
  end

  # Float.parse/1 needs a digit on both sides of the decimal point, so pad the
  # integer part, the fraction, and the missing point of "1e3"/"3." first.
  defp normalize_float(value) do
    {sign, unsigned} =
      case value do
        <<"-", rest::binary>> -> {"-", rest}
        <<"+", rest::binary>> -> {"+", rest}
        _ -> {"", value}
      end

    {body, exponent} = split_exponent(unsigned)

    case String.split(body, ".", parts: 2) do
      [integer_part] -> sign <> pad(integer_part) <> ".0" <> exponent
      [integer_part, fraction] -> sign <> pad(integer_part) <> "." <> pad(fraction) <> exponent
    end
  end

  defp split_exponent(unsigned) do
    case :binary.match(unsigned, ["e", "E"]) do
      :nomatch ->
        {unsigned, ""}

      {index, _length} ->
        {binary_part(unsigned, 0, index),
         binary_part(unsigned, index, byte_size(unsigned) - index)}
    end
  end

  defp pad(""), do: "0"
  defp pad(digits), do: digits

  defp valid_date?(value) do
    case String.split(value, "-") do
      [year, month, day] ->
        with {:ok, y} <- parse_int(year),
             {:ok, m} <- parse_int(month),
             {:ok, d} <- parse_int(day) do
          valid_date(y, m, d)
        else
          _ -> false
        end

      _ ->
        false
    end
  end

  defp valid_date(year, month, day)
       when year >= 1 and year <= 9999 and month >= 1 and month <= 12 and day >= 1 do
    day <= days_in_month(year, month)
  end

  defp valid_date(_year, _month, _day), do: false

  defp days_in_month(year, 2), do: if(leap_year?(year), do: 29, else: 28)

  defp days_in_month(_year, month) do
    Enum.at([31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31], month - 1)
  end

  defp leap_year?(year), do: rem(year, 4) == 0 and (rem(year, 100) != 0 or rem(year, 400) == 0)

  # ---------------------------------------------------------------- output --

  # Records are lists of {label, typed_value} in first-seen order, so the JSON
  # keys and the CSV header keep that order. The parsed JSON is
  # order-insensitive; kdg.go's map-based encoder sorts keys instead.
  defp to_json([]), do: "[]"

  defp to_json(records) do
    ["[\n", Enum.map_join(records, ",\n", &json_record(&1, 2)), "\n]"]
  end

  defp json_record([], indent), do: [spaces(indent), "{}"]

  defp json_record(fields, indent) do
    rendered =
      Enum.map(fields, fn {label, value} ->
        [spaces(indent + 2), json_string(label), ": ", json_value(value)]
      end)

    [spaces(indent), "{\n", Enum.join(rendered, ",\n"), "\n", spaces(indent), "}"]
  end

  defp spaces(count), do: String.duplicate(" ", count)

  defp json_value({:str, value}), do: json_string(value)
  defp json_value({:date, value}), do: json_string(value)
  defp json_value({:int, value}), do: Integer.to_string(value)
  defp json_value({:float, value}), do: Float.to_string(value)
  defp json_value({:bool, true}), do: "true"
  defp json_value({:bool, false}), do: "false"

  defp json_string(value), do: [?", Enum.map(String.to_charlist(value), &json_escape/1), ?"]

  defp json_escape(?"), do: "\\\""
  defp json_escape(?\\), do: "\\\\"
  defp json_escape(?\b), do: "\\b"
  defp json_escape(?\f), do: "\\f"
  defp json_escape(?\n), do: "\\n"
  defp json_escape(?\r), do: "\\r"
  defp json_escape(?\t), do: "\\t"

  defp json_escape(codepoint) when codepoint < 32 do
    "\\u" <> String.pad_leading(Integer.to_string(codepoint, 16), 4, "0")
  end

  defp json_escape(codepoint), do: codepoint

  defp to_csv([]), do: ""

  defp to_csv(records) do
    keys = all_keys(records, [])
    header = Enum.map_join(keys, ",", &escape_csv/1)

    rows =
      Enum.map(records, fn record ->
        Enum.map_join(keys, ",", fn key -> escape_csv(csv_value(lookup(key, record))) end)
      end)

    Enum.join([header | rows], "\n")
  end

  defp lookup(key, fields) do
    case List.keyfind(fields, key, 0) do
      {_key, value} -> value
      nil -> :missing
    end
  end

  defp all_keys([], acc), do: Enum.reverse(acc)

  defp all_keys([fields | rest], acc) do
    acc =
      Enum.reduce(fields, acc, fn {label, _value}, seen ->
        if label in seen, do: seen, else: [label | seen]
      end)

    all_keys(rest, acc)
  end

  # Mirrors the Python reference's str(): bools are True/False, floats keep a
  # decimal point, missing fields are empty.
  defp csv_value(:missing), do: ""
  defp csv_value({:str, value}), do: value
  defp csv_value({:date, value}), do: value
  defp csv_value({:int, value}), do: Integer.to_string(value)
  defp csv_value({:float, value}), do: Float.to_string(value)
  defp csv_value({:bool, true}), do: "True"
  defp csv_value({:bool, false}), do: "False"

  defp escape_csv(value) do
    if String.contains?(value, [",", "\"", "\n"]) do
      "\"" <> String.replace(value, "\"", "\"\"") <> "\""
    else
      value
    end
  end
end

KDG.main(System.argv())
