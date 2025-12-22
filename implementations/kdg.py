#!/usr/bin/env python3
"""
KDG (Key-Delimiter Grammar) Parser - Reference Implementation

Usage:
    python kdg.py parse <file>           Parse KDG to JSON
    python kdg.py validate <file>        Validate KDG syntax
    python kdg.py convert <file> [fmt]   Convert to format (json, csv)

This implementation has no dependencies. This was considered important.
"""

from __future__ import annotations

import json
import re
import sys
from dataclasses import dataclass
from datetime import date
from typing import Any


@dataclass
class FieldDef:
    """A field definition from the KDG header."""

    type: str
    label: str
    delimiter: str


class KDGError(Exception):
    """Base exception for KDG parsing errors."""

    def __init__(self, message: str, line: int | None = None):
        self.line = line
        self.message = message
        super().__init__(f"Line {line}: {message}" if line else message)


class DuplicateDelimiterError(KDGError):
    """Raised when a delimiter is defined more than once."""

    pass


class InvalidTypeError(KDGError):
    """Raised when an unknown type is specified."""

    pass


class MalformedDefinitionError(KDGError):
    """Raised when a definition line doesn't match the grammar."""

    pass


class UndefinedDelimiterError(KDGError):
    """Raised when a record uses an undeclared delimiter."""

    pass


class DuplicateFieldError(KDGError):
    """Raised when a field appears twice in the same record."""

    pass


class TypeMismatchError(KDGError):
    """Raised when a value doesn't match its declared type."""

    pass


class MissingSeparatorError(KDGError):
    """Raised when there's no blank line between sections."""

    pass


VALID_TYPES = frozenset({"str", "int", "float", "bool", "date"})

# Characters that cannot be delimiters
RESERVED_CHARS = frozenset('abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789:" \t\n\r')

# Regex for parsing definition lines
DEFINITION_PATTERN = re.compile(r'^(str|int|float|bool|date):"((?:[^"\\]|\\.)*)\"(.)$')


def parse_definition(line: str, line_num: int) -> FieldDef:
    """Parse a single field definition line."""
    match = DEFINITION_PATTERN.match(line)
    if not match:
        raise MalformedDefinitionError(f"Invalid definition syntax: {line!r}", line_num)

    type_name, label, delimiter = match.groups()

    if type_name not in VALID_TYPES:
        raise InvalidTypeError(f"Unknown type: {type_name!r}", line_num)

    if delimiter in RESERVED_CHARS:
        raise MalformedDefinitionError(
            f"Invalid delimiter: {delimiter!r} (reserved character)", line_num
        )

    # Unescape the label
    label = label.replace('\\"', '"').replace("\\\\", "\\")

    return FieldDef(type=type_name, label=label, delimiter=delimiter)


def convert_value(value: str, type_name: str, line_num: int) -> Any:
    """Convert a string value to its typed representation."""
    if type_name == "str":
        return value

    if type_name == "int":
        try:
            return int(value)
        except ValueError:
            raise TypeMismatchError(f"Invalid integer: {value!r}", line_num)

    if type_name == "float":
        try:
            return float(value)
        except ValueError:
            raise TypeMismatchError(f"Invalid float: {value!r}", line_num)

    if type_name == "bool":
        lower = value.lower()
        if lower in ("true", "1"):
            return True
        if lower in ("false", "0"):
            return False
        raise TypeMismatchError(f"Invalid boolean: {value!r}", line_num)

    if type_name == "date":
        try:
            parts = value.split("-")
            if len(parts) != 3:
                raise ValueError("Invalid date format")
            year, month, day = int(parts[0]), int(parts[1]), int(parts[2])
            date(year, month, day)  # Validate it's a real date
            return value  # Return as string for JSON compatibility
        except (ValueError, TypeError):
            raise TypeMismatchError(f"Invalid date (expected YYYY-MM-DD): {value!r}", line_num)

    raise InvalidTypeError(f"Unknown type: {type_name!r}", line_num)


def parse_record(
    line: str, delimiter_map: dict[str, FieldDef], line_num: int
) -> dict[str, Any]:
    """Parse a single record line into a dictionary."""
    if not line:
        return {}

    record: dict[str, Any] = {}
    position = 0

    while position < len(line):
        delimiter = line[position]

        if delimiter not in delimiter_map:
            raise UndefinedDelimiterError(
                f"Undefined delimiter: {delimiter!r}", line_num
            )

        field_def = delimiter_map[delimiter]

        if field_def.label in record:
            raise DuplicateFieldError(
                f"Duplicate field in record: {field_def.label!r}", line_num
            )

        # Find the end of this field's value
        end = len(line)
        for i in range(position + 1, len(line)):
            if line[i] in delimiter_map:
                end = i
                break

        value = line[position + 1 : end]
        record[field_def.label] = convert_value(value, field_def.type, line_num)
        position = end

    return record


def parse(content: str) -> list[dict[str, Any]]:
    """
    Parse a KDG document into a list of records.

    Args:
        content: The full KDG document as a string

    Returns:
        A list of dictionaries, one per record

    Raises:
        KDGError: If the document is malformed
    """
    lines = content.replace("\r\n", "\n").split("\n")

    # Find the separator (blank line)
    separator_idx = None
    for i, line in enumerate(lines):
        if line == "":
            separator_idx = i
            break

    if separator_idx is None:
        raise MissingSeparatorError("No blank line separator found between definitions and data")

    # Parse definitions
    delimiter_map: dict[str, FieldDef] = {}
    for i in range(separator_idx):
        line = lines[i]
        if not line:  # Skip empty lines in definition block
            continue

        field_def = parse_definition(line, i + 1)

        if field_def.delimiter in delimiter_map:
            existing = delimiter_map[field_def.delimiter]
            raise DuplicateDelimiterError(
                f"Delimiter {field_def.delimiter!r} already used for field {existing.label!r}",
                i + 1,
            )

        delimiter_map[field_def.delimiter] = field_def

    # Parse records
    records: list[dict[str, Any]] = []
    for i in range(separator_idx + 1, len(lines)):
        line = lines[i]
        if not line:  # Skip empty lines in data block
            continue

        record = parse_record(line, delimiter_map, i + 1)
        records.append(record)

    return records


def validate(content: str) -> tuple[bool, str | None]:
    """
    Validate a KDG document.

    Args:
        content: The full KDG document as a string

    Returns:
        A tuple of (is_valid, error_message)
    """
    try:
        parse(content)
        return True, None
    except KDGError as e:
        return False, str(e)


def to_json(records: list[dict[str, Any]], indent: int = 2) -> str:
    """Convert parsed records to JSON string."""
    return json.dumps(records, indent=indent, ensure_ascii=False)


def to_csv(records: list[dict[str, Any]]) -> str:
    """Convert parsed records to CSV string."""
    if not records:
        return ""

    # Get all unique keys across all records
    all_keys: list[str] = []
    seen: set[str] = set()
    for record in records:
        for key in record:
            if key not in seen:
                all_keys.append(key)
                seen.add(key)

    # Build CSV
    def escape_csv(value: Any) -> str:
        s = str(value) if value is not None else ""
        if "," in s or '"' in s or "\n" in s:
            return '"' + s.replace('"', '""') + '"'
        return s

    lines = [",".join(escape_csv(k) for k in all_keys)]
    for record in records:
        row = [escape_csv(record.get(k)) for k in all_keys]
        lines.append(",".join(row))

    return "\n".join(lines)


def main() -> int:
    """CLI entry point."""
    if len(sys.argv) < 3:
        print(__doc__)
        return 1

    command = sys.argv[1]
    filepath = sys.argv[2]

    try:
        with open(filepath, "r", encoding="utf-8") as f:
            content = f.read()
    except FileNotFoundError:
        print(f"Error: File not found: {filepath}", file=sys.stderr)
        return 1
    except IOError as e:
        print(f"Error reading file: {e}", file=sys.stderr)
        return 1

    if command == "parse":
        try:
            records = parse(content)
            print(to_json(records))
            return 0
        except KDGError as e:
            print(f"Parse error: {e}", file=sys.stderr)
            return 1

    elif command == "validate":
        is_valid, error = validate(content)
        if is_valid:
            print("Valid KDG document")
            return 0
        else:
            print(f"Invalid: {error}", file=sys.stderr)
            return 1

    elif command == "convert":
        fmt = sys.argv[3] if len(sys.argv) > 3 else "json"
        try:
            records = parse(content)
            if fmt == "json":
                print(to_json(records))
            elif fmt == "csv":
                print(to_csv(records))
            else:
                print(f"Unknown format: {fmt}", file=sys.stderr)
                return 1
            return 0
        except KDGError as e:
            print(f"Parse error: {e}", file=sys.stderr)
            return 1

    else:
        print(f"Unknown command: {command}", file=sys.stderr)
        print(__doc__)
        return 1


if __name__ == "__main__":
    sys.exit(main())
