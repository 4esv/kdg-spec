# KDG Format Specification

**Version:** 1.0.0
**Status:** Stable
**Date:** 2024-12-22

## Abstract

KDG (Key-Delimited Garbage) is a text-based data serialization format that encodes field identity into delimiter choice. Unlike CSV (positional) or JSON (explicit keys), KDG uses unique delimiter suffixes to identify fields, enabling order-independent records with minimal syntax overhead.

This specification defines the grammar, type system, and parsing algorithm for KDG documents.

## Table of Contents

1. [Introduction](#1-introduction)
2. [Document Structure](#2-document-structure)
3. [Grammar](#3-grammar)
4. [Type System](#4-type-system)
5. [Parsing Algorithm](#5-parsing-algorithm)
6. [Escape Sequences](#6-escape-sequences)
7. [Error Handling](#7-error-handling)
8. [Test Vectors](#8-test-vectors)
9. [Security Considerations](#9-security-considerations)

---

## 1. Introduction

### 1.1 Motivation

Existing text formats force a choice:

| Format | Field Identity | Trade-off |
|--------|---------------|-----------|
| CSV | Position | Fragile to column reordering |
| JSON | Explicit keys | Verbose, repeated keys per record |
| KDG | Delimiter | Order-independent, compact |

KDG introduces a third approach: **delimiter-as-suffix encoding**. Each field is assigned a unique delimiter character that follows its value. The presence of that delimiter in a record identifies the preceding value, regardless of position.

### 1.2 Design Goals

1. **Order Independence**: Records may contain fields in any order
2. **Compactness**: No repeated field names in data section
3. **Human Readability**: Plain text, easily inspected
4. **Type Safety**: Explicit type declarations in schema
5. **Simplicity**: Minimal syntax, easy to implement

### 1.3 Terminology

The key words "MUST", "MUST NOT", "REQUIRED", "SHALL", "SHALL NOT", "SHOULD", "SHOULD NOT", "RECOMMENDED", "MAY", and "OPTIONAL" in this document are to be interpreted as described in [RFC 2119](https://tools.ietf.org/html/rfc2119).

---

## 2. Document Structure

A KDG document consists of two sections:

```
┌─────────────────────────────────┐
│         DEFINITION BLOCK        │
│   (field type/label/delimiter)  │
├─────────────────────────────────┤
│          BLANK LINE             │
│       (section separator)       │
├─────────────────────────────────┤
│          DATA BLOCK             │
│    (records using delimiters)   │
└─────────────────────────────────┘
```

### 2.1 Definition Block

The definition block declares fields. Each line defines one field:

```
type:"label"delimiter
```

Where:
- `type` is a supported type identifier
- `label` is a human-readable field name (quoted)
- `delimiter` is a single character used to identify this field in records

### 2.2 Section Separator

A single blank line (empty line containing only a newline) separates definitions from data.

### 2.3 Data Block

The data block contains records. Each line is one record. Fields within a record are identified by their trailing delimiter, not position.

```
value1delimiter1value2delimiter2value3delimiter3
```

---

## 3. Grammar

### 3.1 EBNF Grammar

```ebnf
document       = definitions , separator , records ;
definitions    = definition , { newline , definition } ;
definition     = type , ":" , quoted_label , delimiter ;
type           = "str" | "int" | "float" | "bool" | "date" ;
quoted_label   = '"' , label_chars , '"' ;
label_chars    = { any_char - '"' | '\"' } ;
delimiter      = visible_char - (alphanumeric | '"' | ':') ;
separator      = newline , newline ;
records        = [ record , { newline , record } ] ;
record         = field , { field } ;
field          = value , delimiter ;
value          = raw_value | wrapped_value ;
raw_value      = { any_char - defined_delimiter } ;
wrapped_value  = '"' , { any_char - '"' | '\"' } , '"' ;
newline        = LF | CRLF ;
visible_char   = ? any printable ASCII or Unicode character ? ;
alphanumeric   = "a"-"z" | "A"-"Z" | "0"-"9" ;
```

### 3.2 Lexical Rules

1. **Delimiters** MUST be visible (non-whitespace) characters
2. **Delimiters** MUST NOT be alphanumeric, colon (`:`), or double-quote (`"`)
3. **Delimiters** MUST be unique within a document
4. **Labels** MUST be enclosed in double quotes
5. **Labels** MAY contain escaped quotes (`\"`)
6. **Values** MAY be wrapped in double quotes
7. **Wrapped values** MAY contain delimiter characters
8. **Records** MUST NOT contain undefined delimiters at field-terminating positions
9. **Empty lines** in the data block are ignored

### 3.3 Reserved Characters

The following characters cannot be used as delimiters:

| Character | Reason |
|-----------|--------|
| `a-z`, `A-Z`, `0-9` | Reserved for values |
| `:` | Type/label separator |
| `"` | Label quoting |
| Space, Tab, Newline | Whitespace |

### 3.4 Recommended Delimiters

While any valid delimiter works, these are recommended for readability:

| Delimiter | Suggested Use |
|-----------|---------------|
| `@` | Identifiers, emails |
| `#` | Numeric IDs, counts |
| `$` | Currency, amounts |
| `%` | Percentages, ratios |
| `&` | Associations, links |
| `!` | Flags, alerts |
| `~` | Descriptions, notes |
| `^` | Priorities, levels |
| `/` | Paths, categories |
| `\|` | Separators, choices |

---

## 4. Type System

### 4.1 Supported Types

| Type | Description | Valid Values |
|------|-------------|--------------|
| `str` | Unicode string | Any text |
| `int` | Signed integer | `-?[0-9]+` |
| `float` | Floating point | `-?[0-9]+\.?[0-9]*` |
| `bool` | Boolean | `true`, `false`, `1`, `0` |
| `date` | ISO 8601 date | `YYYY-MM-DD` |

### 4.2 Type Coercion

Parsers SHOULD perform type validation. Invalid values SHOULD result in a parse error or warning, depending on parser configuration.

### 4.3 String Type

The `str` type accepts any valid UTF-8 text. Leading and trailing whitespace is preserved. Empty strings are valid.

### 4.4 Integer Type

The `int` type accepts:
- Positive integers: `42`, `1000`
- Negative integers: `-42`, `-1000`
- Zero: `0`

Leading zeros are permitted but not recommended: `007` parses as `7`.

### 4.5 Float Type

The `float` type accepts:
- Standard notation: `3.14`, `-2.5`
- Integer notation: `42` (coerced to `42.0`)
- Leading decimal: `.5` (coerced to `0.5`)

Scientific notation is NOT supported in this version.

### 4.6 Boolean Type

The `bool` type accepts (case-insensitive):
- True values: `true`, `1`
- False values: `false`, `0`

### 4.7 Date Type

The `date` type accepts ISO 8601 date format:
- Format: `YYYY-MM-DD`
- Example: `2024-12-22`

Time components are NOT supported in this version.

---

## 5. Parsing Algorithm

### 5.1 Overview

```
1. Split document into lines
2. Parse definition block until blank line
3. Build delimiter → (type, label) map
4. Parse each record line using delimiter map
5. Return array of record objects
```

### 5.2 Definition Parsing

For each line in the definition block:

```python
match = regex(r'^(str|int|float|bool|date):"([^"\\]*(?:\\.[^"\\]*)*)\"(.)')
type = match.group(1)
label = match.group(2).replace('\\"', '"')
delimiter = match.group(3)
```

### 5.3 Record Parsing

For each non-empty line in the data block:

```python
fields = {}
position = 0
while position < len(line):
    # Find next defined delimiter
    end = find_next_delimiter(line, position, delimiter_map)
    if end == -1:
        raise ParseError(f"No delimiter found for value starting at {position}")

    value = line[position:end]
    delimiter = line[end]

    if delimiter not in delimiter_map:
        raise ParseError(f"Undefined delimiter: {delimiter}")

    type, label = delimiter_map[delimiter]
    fields[label] = convert(value, type)
    position = end + 1

records.append(fields)
```

### 5.4 Delimiter Collision

If a delimiter appears multiple times in the same record, parsers MUST raise an error. Each field may appear at most once per record.

### 5.5 Missing Fields

Records MAY omit fields. Parsers SHOULD represent missing fields as `null`/`None` or omit them from the output object, depending on configuration.

---

## 6. Escape Sequences

### 6.1 In Labels

Within quoted labels, the following escape sequences are supported:

| Sequence | Meaning |
|----------|---------|
| `\"` | Literal double quote |
| `\\` | Literal backslash |

### 6.2 In Values

Values MAY be wrapped in double quotes. Wrapping is optional but required when a value contains a delimiter character.

```
str:"name"@
str:"note"#

Alice@"Contains @ symbol"#
Bob@No wrapping needed#
```

Within wrapped values, the following escape sequences are supported:

| Sequence | Meaning |
|----------|---------|
| `\"` | Literal double quote |
| `\\` | Literal backslash |

Unwrapped values do not support escape sequences.

---

## 7. Error Handling

### 7.1 Parse Errors

Parsers MUST report errors for:

| Error | Description |
|-------|-------------|
| `DuplicateDelimiter` | Same delimiter defined twice |
| `InvalidType` | Unknown type identifier |
| `MalformedDefinition` | Definition doesn't match grammar |
| `UndefinedDelimiter` | Record uses undeclared delimiter |
| `DuplicateField` | Same field appears twice in record |
| `TypeMismatch` | Value doesn't match declared type |
| `MissingSeparator` | No blank line between sections |

### 7.2 Error Format

Parsers SHOULD report errors with:
- Line number
- Column number (if applicable)
- Error type
- Descriptive message

---

## 8. Test Vectors

### 8.1 Minimal Valid Document

**Input:**
```
str:"name"@

Alice@
```

**Expected Output:**
```json
[{"name": "Alice"}]
```

### 8.2 All Types

**Input:**
```
str:"name"@
int:"age"#
float:"score"%
bool:"active"!
date:"joined"/

Bob@30#95.5%true!2024-01-15/
```

**Expected Output:**
```json
[{
  "name": "Bob",
  "age": 30,
  "score": 95.5,
  "active": true,
  "joined": "2024-01-15"
}]
```

### 8.3 Order Independence

**Input:**
```
str:"first"@
str:"last"#

Doe#Jane@
John@Smith#
```

**Expected Output:**
```json
[
  {"first": "Jane", "last": "Doe"},
  {"first": "John", "last": "Smith"}
]
```

### 8.4 Unicode Support

**Input:**
```
str:"greeting"@
str:"name"#

こんにちは@田中#
Привет@Мария#
مرحبا@أحمد#
```

**Expected Output:**
```json
[
  {"greeting": "こんにちは", "name": "田中"},
  {"greeting": "Привет", "name": "Мария"},
  {"greeting": "مرحبا", "name": "أحمد"}
]
```

### 8.5 Escaped Quotes in Labels

**Input:**
```
str:"user\"s name"@

Alice@
```

**Expected Output:**
```json
[{"user\"s name": "Alice"}]
```

### 8.6 Invalid: Duplicate Delimiter

**Input:**
```
str:"first"@
str:"second"@

test@
```

**Expected:** Parse error - duplicate delimiter `@`

---

## 9. Security Considerations

### 9.1 Input Validation

Parsers MUST validate input to prevent:
- Buffer overflows from extremely long lines
- Denial of service from deeply nested or circular structures (not applicable to KDG's flat structure)
- Resource exhaustion from extremely large documents

### 9.2 Output Encoding

When converting to other formats (JSON, etc.), parsers MUST properly escape output to prevent injection attacks.

### 9.3 File Size Limits

Implementations SHOULD support configurable maximum file size limits.

---

## Appendix A: Media Type

The recommended media type for KDG documents is:

```
text/x-kdg
```

File extension: `.kdg`

## Appendix B: Reference Implementations

Reference implementations are provided in:
- Python: `implementations/kdg.py`
- JavaScript: `implementations/kdg.js`

These implementations are normative for ambiguous cases not covered by this specification.

## Appendix C: Changelog

### Version 1.0.0 (2024-12-22)
- Initial stable release
- Defined core grammar and type system
- Established parsing algorithm
- Added test vectors

---

## Acknowledgments

KDG exists.
