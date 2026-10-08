#!/usr/bin/env lua
--
-- KDG (Key-Delimiter Grammar) Parser - Lua implementation
--
-- Usage:
--   lua kdg.lua parse <file>           Parse KDG to JSON
--   lua kdg.lua validate <file>        Validate KDG syntax
--   lua kdg.lua convert <file> [fmt]   Convert to format (json, csv)
--
-- This implementation has no dependencies beyond the Lua standard library.
-- There is no regex engine, so the definition grammar and record scanner are
-- written by hand over a list of UTF-8 characters (Go indexes by rune, and so
-- does this implementation).

local USAGE = 'Usage: kdg <parse|validate|convert> <file> [json|csv]'

local VALID_TYPES = { str = true, int = true, float = true, bool = true, date = true }

-- Characters that cannot be delimiters (SPEC 3.4).
local RESERVED_CHARS = {}
do
  for c in ('abcdefghijklmnopqrstuvwxyz'):gmatch('.') do RESERVED_CHARS[c] = true end
  for c in ('ABCDEFGHIJKLMNOPQRSTUVWXYZ'):gmatch('.') do RESERVED_CHARS[c] = true end
  for c in ('0123456789'):gmatch('.') do RESERVED_CHARS[c] = true end
  RESERVED_CHARS[':'] = true
  RESERVED_CHARS['"'] = true
  RESERVED_CHARS[' '] = true
  RESERVED_CHARS['\t'] = true
  RESERVED_CHARS['\n'] = true
  RESERVED_CHARS['\r'] = true
end

-- Errors carry an optional line number. Raising a table keeps the message and
-- the line separate so the caller can format them canonically.
local function fail(message, line)
  error({ message = message, line = line }, 0)
end

local function error_text(err)
  if type(err) == 'table' and err.message then
    if err.line then
      return 'Line ' .. err.line .. ': ' .. err.message
    end
    return err.message
  end
  return tostring(err)
end

-- Decode a string into a list of UTF-8 characters.
local function utf8_sequence_length(byte)
  if byte < 0x80 then return 1 end
  if byte < 0xC0 then return 1 end
  if byte < 0xE0 then return 2 end
  if byte < 0xF0 then return 3 end
  return 4
end

local function split_chars(str)
  local chars = {}
  local i, n = 1, #str
  while i <= n do
    local len = utf8_sequence_length(str:byte(i))
    if i + len - 1 > n then len = 1 end
    chars[#chars + 1] = str:sub(i, i + len - 1)
    i = i + len
  end
  return chars
end

local function split_lines(content)
  local lines = {}
  local pos = 1
  while true do
    local idx = content:find('\n', pos, true)
    if not idx then
      lines[#lines + 1] = content:sub(pos)
      break
    end
    lines[#lines + 1] = content:sub(pos, idx - 1)
    pos = idx + 1
  end
  return lines
end

local function is_int_string(value)
  return value:match('^[+-]?[0-9]+$') ~= nil
end

local function is_float_string(value)
  return value:match('^[+-]?[0-9]+$') ~= nil
      or value:match('^[+-]?[0-9]+%.[0-9]*$') ~= nil
      or value:match('^[+-]?%.[0-9]+$') ~= nil
      or value:match('^[+-]?[0-9]+[eE][+-]?[0-9]+$') ~= nil
      or value:match('^[+-]?[0-9]+%.[0-9]*[eE][+-]?[0-9]+$') ~= nil
      or value:match('^[+-]?%.[0-9]+[eE][+-]?[0-9]+$') ~= nil
end

local function is_leap_year(year)
  return (year % 4 == 0 and year % 100 ~= 0) or year % 400 == 0
end

local function is_real_date(year, month, day)
  if month < 1 or month > 12 or day < 1 then return false end
  local month_days = { 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }
  local max_day = month_days[month]
  if month == 2 and is_leap_year(year) then max_day = 29 end
  return day <= max_day
end

local function split_on_dash(value)
  local parts = {}
  local start = 1
  while true do
    local idx = value:find('-', start, true)
    if not idx then
      parts[#parts + 1] = value:sub(start)
      break
    end
    parts[#parts + 1] = value:sub(start, idx - 1)
    start = idx + 1
  end
  return parts
end

-- Parse a single definition line. Returns type_name, label, delimiter.
local function parse_definition(line, line_num)
  local chars = split_chars(line)
  local n = #chars

  -- type = [a-z]+
  local type_start = 1
  local i = 1
  while i <= n and chars[i]:match('^[a-z]$') do i = i + 1 end
  if i == type_start then
    fail("Invalid definition syntax: '" .. line .. "'", line_num)
  end
  local type_name = table.concat(chars, '', type_start, i - 1)

  -- ':'
  if i > n or chars[i] ~= ':' then
    fail("Invalid definition syntax: '" .. line .. "'", line_num)
  end
  i = i + 1

  -- opening quote
  if i > n or chars[i] ~= '"' then
    fail("Invalid definition syntax: '" .. line .. "'", line_num)
  end
  i = i + 1

  -- label body = (?:[^"\\]|\\.)*
  local label_parts = {}
  while i <= n do
    local c = chars[i]
    if c == '\\' then
      if i + 1 > n then break end
      label_parts[#label_parts + 1] = c
      label_parts[#label_parts + 1] = chars[i + 1]
      i = i + 2
    elseif c == '"' then
      break
    else
      label_parts[#label_parts + 1] = c
      i = i + 1
    end
  end
  local raw_label = table.concat(label_parts)

  -- closing quote
  if i > n or chars[i] ~= '"' then
    fail("Invalid definition syntax: '" .. line .. "'", line_num)
  end
  i = i + 1

  -- delimiter: exactly one more character, then end of line
  if i ~= n then
    fail("Invalid definition syntax: '" .. line .. "'", line_num)
  end
  local delimiter = chars[i]

  if not VALID_TYPES[type_name] then
    fail("Unknown type: '" .. type_name .. "'", line_num)
  end

  if RESERVED_CHARS[delimiter] then
    fail("Invalid delimiter: '" .. delimiter .. "' (reserved character)", line_num)
  end

  -- Unescape the label. Order matters: \" first, then \\.
  local label = raw_label:gsub('\\"', '"'):gsub('\\\\', '\\')

  return type_name, label, delimiter
end

-- Convert a string value to a tagged cell { kind = ..., value = ... }. The tag
-- is what lets the JSON writer distinguish a string "42" from an integer 42.
local function convert_value(value, type_name, line_num)
  if type_name == 'str' then
    return { kind = 'str', value = value }
  end
  if type_name == 'int' then
    if not is_int_string(value) then
      fail("Invalid integer: '" .. value .. "'", line_num)
    end
    return { kind = 'int', value = tonumber(value) }
  end
  if type_name == 'float' then
    if not is_float_string(value) then
      fail("Invalid float: '" .. value .. "'", line_num)
    end
    return { kind = 'float', value = tonumber(value) }
  end
  if type_name == 'bool' then
    local lower = value:lower()
    if lower == 'true' or lower == '1' then
      return { kind = 'bool', value = true }
    end
    if lower == 'false' or lower == '0' then
      return { kind = 'bool', value = false }
    end
    fail("Invalid boolean: '" .. value .. "'", line_num)
  end
  if type_name == 'date' then
    local parts = split_on_dash(value)
    if #parts == 3 and is_int_string(parts[1]) and is_int_string(parts[2]) and is_int_string(parts[3]) then
      local year, month, day = tonumber(parts[1]), tonumber(parts[2]), tonumber(parts[3])
      if year >= 1 and year <= 9999 and is_real_date(year, month, day) then
        return { kind = 'date', value = value } -- string form for JSON compatibility
      end
    end
    fail("Invalid date (expected YYYY-MM-DD): '" .. value .. "'", line_num)
  end
  fail("Unknown type: '" .. type_name .. "'", line_num)
end

-- Scan a double-quoted value starting at chars[start] == '"'. Returns the value
-- and the position just after the closing quote. Backslash escapes for \" and
-- \\ are honoured per SPEC 6.2.
local function scan_wrapped_value(chars, start, line_num)
  local parts = {}
  local i = start + 1
  local n = #chars
  while i <= n do
    local c = chars[i]
    if c == '\\' and i + 1 <= n and (chars[i + 1] == '"' or chars[i + 1] == '\\') then
      parts[#parts + 1] = chars[i + 1]
      i = i + 2
    elseif c == '"' then
      return table.concat(parts), i + 1
    else
      parts[#parts + 1] = c
      i = i + 1
    end
  end
  fail('Unterminated quoted value', line_num)
end

-- Parse a single record line. Keeps first-seen label order in a parallel list.
local function parse_record(line, delimiter_map, line_num)
  local record = { values = {}, keys = {} }
  if line == '' then
    return record
  end

  local chars = split_chars(line)
  local n = #chars
  local position = 1
  while position <= n do
    local value

    -- A field is value-then-delimiter. The value may be wrapped in double
    -- quotes, which lets it contain delimiter characters (SPEC 6.2).
    if chars[position] == '"' then
      value, position = scan_wrapped_value(chars, position, line_num)
      if position > n then
        fail("Missing delimiter after value '" .. value .. "'", line_num)
      end
    else
      local start = position
      while position <= n and not delimiter_map[chars[position]] do
        position = position + 1
      end
      if position > n then
        fail('No delimiter found for value starting at column ' .. (start - 1), line_num)
      end
      value = table.concat(chars, '', start, position - 1)
    end

    local delimiter = chars[position]
    local field = delimiter_map[delimiter]
    if not field then
      fail("Undefined delimiter: '" .. delimiter .. "'", line_num)
    end
    if record.values[field.label] ~= nil then
      fail("Duplicate field in record: '" .. field.label .. "'", line_num)
    end

    record.values[field.label] = convert_value(value, field.type, line_num)
    record.keys[#record.keys + 1] = field.label
    position = position + 1
  end

  return record
end

-- Parse a KDG document into a list of records.
local function parse_document(content)
  content = content:gsub('\r\n', '\n')
  local lines = split_lines(content)

  -- A trailing newline produces a spurious final empty element. Drop one so a
  -- document with no blank-line separator is reported as MissingSeparator
  -- instead of having its first record misread as a definition.
  if #lines > 0 and lines[#lines] == '' then
    table.remove(lines)
  end

  -- Find the separator (blank line).
  local separator_idx = nil
  for i = 1, #lines do
    if lines[i] == '' then
      separator_idx = i
      break
    end
  end
  if not separator_idx then
    fail('No blank line separator found between definitions and data', nil)
  end

  local delimiter_map = {}
  for i = 1, separator_idx - 1 do
    local line = lines[i]
    if line ~= '' then -- Skip empty lines in the definition block.
      local type_name, label, delimiter = parse_definition(line, i)
      if delimiter_map[delimiter] then
        local existing = delimiter_map[delimiter]
        fail("Delimiter '" .. delimiter .. "' already used for field '" .. existing.label .. "'", i)
      end
      delimiter_map[delimiter] = { type = type_name, label = label, delimiter = delimiter }
    end
  end

  local records = {}
  for i = separator_idx + 1, #lines do
    local line = lines[i]
    if line ~= '' then -- Skip empty lines in the data block.
      records[#records + 1] = parse_record(line, delimiter_map, i)
    end
  end

  return records
end

-- Escape a string for a JSON string literal. Non-ASCII characters pass through
-- raw (never escaped).
local function json_escape(str)
  local out = {}
  for i = 1, #str do
    local byte = str:byte(i)
    local c = str:sub(i, i)
    if c == '"' then
      out[#out + 1] = '\\"'
    elseif c == '\\' then
      out[#out + 1] = '\\\\'
    elseif c == '\n' then
      out[#out + 1] = '\\n'
    elseif c == '\r' then
      out[#out + 1] = '\\r'
    elseif c == '\t' then
      out[#out + 1] = '\\t'
    elseif byte == 8 then
      out[#out + 1] = '\\b'
    elseif byte == 12 then
      out[#out + 1] = '\\f'
    elseif byte < 32 then
      out[#out + 1] = string.format('\\u%04x', byte)
    else
      out[#out + 1] = c
    end
  end
  return table.concat(out)
end

-- Render a float the way Python's str() does: keep a decimal point so an
-- integral float like 42.0 does not collapse to 42.
local function float_text(number)
  local text = tostring(number)
  if not text:find('[%.eE]') then
    text = text .. '.0'
  end
  return text
end

local function int_text(number)
  if math.type and math.type(number) == 'integer' then
    return tostring(number)
  end
  return string.format('%d', number)
end

local function cell_json(cell)
  if cell.kind == 'str' or cell.kind == 'date' then
    return '"' .. json_escape(cell.value) .. '"'
  elseif cell.kind == 'bool' then
    return cell.value and 'true' or 'false'
  elseif cell.kind == 'int' then
    return int_text(cell.value)
  elseif cell.kind == 'float' then
    return float_text(cell.value)
  end
  return 'null'
end

local function record_json(record)
  if #record.keys == 0 then
    return '  {}'
  end
  local fields = {}
  for i = 1, #record.keys do
    local key = record.keys[i]
    fields[#fields + 1] = '    "' .. json_escape(key) .. '": ' .. cell_json(record.values[key])
  end
  return '  {\n' .. table.concat(fields, ',\n') .. '\n  }'
end

-- Serialize records as JSON with 2-space indentation (no trailing newline).
local function to_json(records)
  if #records == 0 then
    return '[]'
  end
  local parts = {}
  for i = 1, #records do
    parts[#parts + 1] = record_json(records[i])
  end
  return '[\n' .. table.concat(parts, ',\n') .. '\n]'
end

-- Render a value the way Python's str() does.
local function csv_value(cell)
  if not cell then
    return ''
  end
  if cell.kind == 'bool' then
    return cell.value and 'True' or 'False'
  end
  if cell.kind == 'float' then
    return float_text(cell.value)
  end
  if cell.kind == 'int' then
    return int_text(cell.value)
  end
  return tostring(cell.value)
end

local function escape_csv(str)
  if str:find(',', 1, true) or str:find('"', 1, true) or str:find('\n', 1, true) then
    return '"' .. (str:gsub('"', '""')) .. '"'
  end
  return str
end

local function to_csv(records)
  if #records == 0 then
    return ''
  end

  local all_keys = {}
  local seen = {}
  for i = 1, #records do
    local record = records[i]
    for j = 1, #record.keys do
      local key = record.keys[j]
      if not seen[key] then
        seen[key] = true
        all_keys[#all_keys + 1] = key
      end
    end
  end

  local lines = {}
  local header = {}
  for i = 1, #all_keys do
    header[i] = escape_csv(all_keys[i])
  end
  lines[#lines + 1] = table.concat(header, ',')

  for i = 1, #records do
    local record = records[i]
    local row = {}
    for j = 1, #all_keys do
      row[j] = escape_csv(csv_value(record.values[all_keys[j]]))
    end
    lines[#lines + 1] = table.concat(row, ',')
  end

  return table.concat(lines, '\n')
end

local function read_file(path)
  local handle = io.open(path, 'rb')
  if not handle then
    return nil
  end
  local content = handle:read('*a')
  handle:close()
  return content
end

local function main()
  if #arg < 2 then
    io.stderr:write(USAGE .. '\n')
    return 1
  end

  local command = arg[1]
  local filepath = arg[2]
  local content = read_file(filepath)
  if content == nil then
    io.stderr:write('Error: File not found: ' .. filepath .. '\n')
    return 1
  end

  if command == 'parse' then
    local ok, records = pcall(parse_document, content)
    if not ok then
      io.stderr:write('Parse error: ' .. error_text(records) .. '\n')
      return 1
    end
    io.write(to_json(records) .. '\n')
    return 0
  end

  if command == 'validate' then
    local ok, records = pcall(parse_document, content)
    if ok then
      io.write('Valid KDG document\n')
      return 0
    end
    io.stderr:write('Invalid: ' .. error_text(records) .. '\n')
    return 1
  end

  if command == 'convert' then
    local format = arg[3] or 'json'
    local ok, records = pcall(parse_document, content)
    if not ok then
      io.stderr:write('Parse error: ' .. error_text(records) .. '\n')
      return 1
    end
    if format == 'json' then
      io.write(to_json(records) .. '\n')
      return 0
    end
    if format == 'csv' then
      io.write(to_csv(records) .. '\n')
      return 0
    end
    io.stderr:write('Unknown format: ' .. format .. '\n')
    return 1
  end

  io.stderr:write('Unknown command: ' .. command .. '\n')
  io.stderr:write(USAGE .. '\n')
  return 1
end

os.exit(main())
