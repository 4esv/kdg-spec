# KDG

**Key-Delimited Garbage** — The second-best format you'll ever need.

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

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
```

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

The specification has no opinion on this, who are we to judge?

### Data

```kdg
str:"name"@
int:"age"#

Alice@30#
25#Bob@
```

Both records are valid. Order is irrelevant. The parser identifies fields by their trailing delimiter, not position.

This means you cannot use a delimiter character inside a value. If your data contains `@` symbols, do not use `@` as a delimiter. This is by design. The design has trade-offs.

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

The JavaScript implementation accepts identical arguments.

---

## Specification

The full specification is in [SPEC.md](./SPEC.md). It contains:

- EBNF grammar
- Type definitions
- Parsing algorithm
- Error taxonomy
- Security considerations

---

## Project Structure

```
kdg-spec/
├── README.md
├── SPEC.md
├── CONTRIBUTING.md
├── LICENSE
├── implementations/
│   ├── kdg.py
│   └── kdg.js
├── tests/vectors/
│   ├── valid/
│   ├── invalid/
│   └── expected/
└── examples/
```

---

## Examples

See the `examples/` directory. They are examples.

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

## Contributing

See [CONTRIBUTING.md](./CONTRIBUTING.md).

---

## License

MIT. See [LICENSE](./LICENSE).

---

<p align="center">
<i>A format.</i>
</p>
