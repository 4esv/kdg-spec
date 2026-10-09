# KDG

**KDG** is the stupid delimiter format, and the second-best data format you'll ever need.

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

---

## The Name

KDG is a three-letter handle, pronounced "kay-dee-gee". The expansion is deliberately not fixed. Depending on your mood, KDG is:

- **Key-Delimited Grammar**: the reading used in the specification. It is a grammar.
- **Key-Delimited Garbage**: when it does not parse, or when you are being honest.
- **Keyed Data Grid**: the tabular reading. Records are rows; delimiters are the grid lines.
- **Keep Data Grounded**: the aspirational reading.
- **Key-Delimiter Grammar**: the pedantic reading, which distinguishes the delimiter character from the format.

As with the format itself, the interpretation is left to the reader.

---

## Overview

KDG is a text-based data serialization format. It is not JSON. It is not CSV. It's the other one.

```kdg
str:"name"@
int:"age"#

Alice@30#
Bob@25#
```

The delimiter *is* the key. When the parser sees `@`, it knows the preceding value was the name. 
When it sees `#`, that was the age.

This is either elegant or unnecessary, depending on who you ask.

---

## Quick Start

```bash
python implementations/kdg.py parse file.kdg
node implementations/kdg.js validate file.kdg
go run implementations/kdg.go parse file.kdg
```

And the same, in twenty-one other languages. See [SPEC.md](./SPEC.md#appendix-a-reference-implementations).

---

## How It Works

A KDG document has two parts: definitions, then data, separated by one blank line.

### Definitions

```
type:"label"delimiter
```

The delimiter can be any non-alphanumeric character except `"` and `:`. 
It becomes the suffix that identifies that field's values. 

Some people use `@` for names. Some use `$` for prices.

The specification has no opinion on this. Who are we to judge?

### Data

```kdg
str:"name"@
int:"age"#

Alice@30#
25#Bob@
```

Both records are valid. Order is irrelevant. The parser identifies fields by their trailing delimiter, not position.

An unwrapped delimiter cannot appear inside a value. To include a delimiter in a value, wrap the value in double quotes (like CSV). Wrapping is optional.

---

## Type System

| Type    | Description          | Example               |
|---------|---------------------|-----------------------|
| `str`   | Text                | `hello`               |
| `int`   | Integer             | `42`                  |
| `float` | Floating point      | `3.14`                |
| `bool`  | Boolean             | `true`, `false`       |
| `date`  | ISO 8601 date       | `2024-12-22`          |

There are five types.

---

## Comparison

| Format | Field Identity | Notes |
|--------|---------------|-------|
| CSV    | Column position | Efficient. Fragile. |
| JSON   | Explicit keys | Flexible. Verbose. |
| KDG    | Delimiter | Different. |

KDG occupies a specific point in the design space. 

Whether that point needed occupying is left as an exercise for the reader.

---

## CLI Reference

```bash
# Parse to JSON
python implementations/kdg.py parse file.kdg

# Validate syntax
python implementations/kdg.py validate file.kdg

# Convert formats
python implementations/kdg.py convert file.kdg csv
```

Every implementation accepts identical arguments. See [SPEC.md](./SPEC.md#appendix-a-reference-implementations) for the full invocation list.

---

## Specification

The full specification is in [SPEC.md](./SPEC.md). It contains:

- EBNF grammar
- Type definitions
- Parsing algorithm
- Error taxonomy
- Security considerations
- Compatibility considerations (accessibility, languages, time, aliens, nuclear semiotics, and more)

---

## Reference Implementations

Twenty-four, in twenty-four languages: Python, JavaScript, Go, C, C++, Rust, TypeScript, Java, Kotlin, C#, Bash, Haskell, PowerShell, R, BQN, Erlang, Elixir, Ruby, Perl, Lua, Swift, Dart, Julia, and Tcl. Each is zero-dependency and ships a CLI. See [SPEC.md](./SPEC.md#appendix-a-reference-implementations).

---

## Project Structure

```
kdg-spec/
├── README.md
├── SPEC.md
├── CONTRIBUTING.md
├── LICENSE
├── .github/
│   └── workflows/
│       └── ci.yml
├── implementations/
│   ├── kdg.py
│   ├── kdg.js
│   ├── kdg.go
│   ├── kdg.c
│   ├── kdg.cpp
│   ├── kdg.rs
│   ├── kdg.ts
│   ├── kdg.java
│   ├── kdg.kt
│   ├── kdg.cs
│   ├── kdg.sh
│   ├── kdg.hs
│   ├── kdg.ps1
│   ├── kdg.R
│   ├── kdg.bqn
│   ├── kdg.erl
│   ├── kdg.exs
│   ├── kdg.rb
│   ├── kdg.pl
│   ├── kdg.lua
│   ├── kdg.swift
│   ├── kdg.dart
│   ├── kdg.jl
│   └── kdg.tcl
├── tests/
│   ├── run_tests.py
│   └── vectors/
│       ├── valid/
│       ├── invalid/
│       └── expected/
└── examples/
```

---

## Examples

See the `examples/` directory. They are examples.

---

## Testing

```bash
python3 tests/run_tests.py
```

That is the whole suite. It runs all twenty-four parsers. Any whose toolchain is not installed are skipped.

It checks every valid vector against its expected JSON. Every invalid vector must fail with the expected error. Every example must validate.

CI runs it on every push and pull request. You do not have to remember.

---

## FAQ

**Why not just use JSON?**

You can use JSON.

**Why not just use CSV?**

You can use CSV.

**When should I use KDG?**

That is between you and your data.

**Is this production-ready?**

The parsers parse. The validators validate. Draw your own conclusions.

**Who maintains this?**

Maintenance is ongoing in the sense that the repository exists.

---

## Further Reading

- [SPEC.md](./SPEC.md): the normative specification.
- [PHILOSOPHY.md](./PHILOSOPHY.md): the design rationale.

## Contributing

See [CONTRIBUTING.md](./CONTRIBUTING.md).

---

## License

MIT. See [LICENSE](./LICENSE).

---

<p align="center">
<i>A format.</i>
</p>
