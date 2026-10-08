# KDG

**Key-Delimited Garbage**. The second-best format you'll ever need.

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
go run implementations/kdg.go parse file.kdg
cc -o /tmp/kdg-c implementations/kdg.c && /tmp/kdg-c parse file.kdg
bash implementations/kdg.sh parse file.kdg
runghc implementations/kdg.hs parse file.kdg
pwsh -File implementations/kdg.ps1 parse file.kdg
Rscript implementations/kdg.R parse file.kdg
bqn implementations/kdg.bqn parse file.kdg
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

---

## Reference Implementations

Nine, in nine languages: Python, JavaScript, Go, C, Bash, Haskell, PowerShell, R, and BQN. Each is zero-dependency and ships a CLI. See [SPEC.md](./SPEC.md#appendix-a-reference-implementations).

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
│   ├── kdg.sh
│   ├── kdg.hs
│   ├── kdg.ps1
│   ├── kdg.R
│   └── kdg.bqn
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

That is the whole suite. It runs all nine parsers. Any whose toolchain is not installed are skipped.

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
