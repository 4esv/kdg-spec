// kdg.rs - KDG (Key-Delimited Grammar) parser in Rust, standard library only.
//
// CLI (mirrors implementations/kdg.go):
//   kdg parse <file>             Parse KDG to JSON on stdout, exit 0
//   kdg validate <file>          Print "Valid KDG document" or "Invalid: ..."
//   kdg convert <file> [json|csv]
//
// The parsing behaviour (definition grammar, label unescaping, trailing
// newline handling, record scanning, wrapped values, type coercion and error
// messages) intentionally reproduces the Go reference implementation. The
// definition line is hand-parsed because no regex crate is available.

use std::collections::HashMap;
use std::process::exit;

const USAGE: &str = "Usage: kdg <parse|validate|convert> <file> [json|csv]";

/* ------------------------------------------------------------------ */
/* Errors                                                              */
/* ------------------------------------------------------------------ */

/* line == 0 means "no line prefix"; only MissingSeparator uses that. */
struct KdgError {
    line: u32,
    message: String,
}

impl KdgError {
    fn render(&self) -> String {
        if self.line > 0 {
            format!("Line {}: {}", self.line, self.message)
        } else {
            self.message.clone()
        }
    }
}

type Res<T> = Result<T, KdgError>;

fn fail<T>(line: u32, message: String) -> Res<T> {
    Err(KdgError { line, message })
}

/* ------------------------------------------------------------------ */
/* UTF-8                                                               */
/* ------------------------------------------------------------------ */

/* Decode one rune at *i, advancing *i. Invalid sequences become U+FFFD and
 * consume a single byte, matching Go's []rune conversion. */
fn utf8_decode(s: &[u8], i: &mut usize) -> char {
    let b = s[*i];
    if b < 0x80 {
        *i += 1;
        return b as char;
    }
    let (need, mut cp): (usize, u32) = if b & 0xE0 == 0xC0 {
        (1, (b & 0x1F) as u32)
    } else if b & 0xF0 == 0xE0 {
        (2, (b & 0x0F) as u32)
    } else if b & 0xF8 == 0xF0 {
        (3, (b & 0x07) as u32)
    } else {
        *i += 1;
        return '\u{FFFD}';
    };
    if *i + need >= s.len() {
        *i += 1;
        return '\u{FFFD}';
    }
    for k in 1..=need {
        let c = s[*i + k];
        if c & 0xC0 != 0x80 {
            *i += 1;
            return '\u{FFFD}';
        }
        cp = (cp << 6) | (c & 0x3F) as u32;
    }
    if (need == 1 && cp < 0x80)
        || (need == 2 && cp < 0x800)
        || (need == 3 && (cp < 0x10000 || cp > 0x10FFFF))
        || (0xD800..=0xDFFF).contains(&cp)
    {
        *i += 1;
        return '\u{FFFD}';
    }
    *i += need + 1;
    char::from_u32(cp).unwrap_or('\u{FFFD}')
}

fn decode_runes(s: &[u8]) -> Vec<char> {
    let mut out: Vec<char> = Vec::with_capacity(s.len());
    let mut i = 0;
    while i < s.len() {
        out.push(utf8_decode(s, &mut i));
    }
    out
}

fn runes_to_string(rs: &[char]) -> String {
    rs.iter().collect()
}

/* ------------------------------------------------------------------ */
/* Types and definitions                                               */
/* ------------------------------------------------------------------ */

struct FieldDef {
    type_name: String,
    label: String,
    delimiter: String, /* UTF-8 bytes of the delimiter rune */
    delim_cp: char,
}

fn is_valid_type(t: &str) -> bool {
    t == "str" || t == "int" || t == "float" || t == "bool" || t == "date"
}

/* Characters that cannot be delimiters (SPEC 3.4). */
fn is_reserved(c: char) -> bool {
    if c.is_ascii_lowercase() || c.is_ascii_uppercase() || c.is_ascii_digit() {
        return true;
    }
    c == ':' || c == '"' || c == ' ' || c == '\t' || c == '\n' || c == '\r'
}

/* Parse a single field definition line. */
fn parse_definition(line: &[u8], line_num: u32) -> Res<FieldDef> {
    let rs = decode_runes(line);
    let n = rs.len();

    let text = runes_to_string(&rs);
    let invalid_syntax = || KdgError {
        line: line_num,
        message: format!("Invalid definition syntax: '{}'", text),
    };

    let mut i = 0;
    while i < n && rs[i].is_ascii_lowercase() {
        i += 1;
    }
    if i == 0 || i >= n || rs[i] != ':' {
        return Err(invalid_syntax());
    }

    let type_name: String = rs[..i].iter().collect();
    i += 1; /* past ':' */

    if i >= n || rs[i] != '"' {
        return Err(invalid_syntax());
    }
    let open_idx = i; /* the opening quote */

    if n < 2 {
        return Err(invalid_syntax());
    }
    /* The reference regexp closes with a literal quote and one delimiter rune,
     * so the closing quote is always the second-to-last rune of the line. */
    let close_idx = n - 2;
    if close_idx < open_idx + 1 || rs[close_idx] != '"' {
        return Err(invalid_syntax());
    }

    /* The label is a sequence of ordinary runes and two-rune backslash
     * escapes (group 2 of the reference regexp). */
    let mut k = open_idx + 1;
    while k < close_idx {
        let cp = rs[k];
        if cp == '\\' {
            if k + 1 >= close_idx {
                return Err(invalid_syntax());
            }
            k += 2;
        } else if cp == '"' {
            return Err(invalid_syntax());
        } else {
            k += 1;
        }
    }

    if !is_valid_type(&type_name) {
        return fail(line_num, format!("Unknown type: '{}'", type_name));
    }

    let delim_cp = rs[n - 1];
    let delimiter = delim_cp.to_string();
    if is_reserved(delim_cp) {
        return fail(
            line_num,
            format!("Invalid delimiter: '{}' (reserved character)", delimiter),
        );
    }

    let raw: String = rs[open_idx + 1..close_idx].iter().collect();
    /* Unescape order matters: \" first, then \\. */
    let label = raw.replace("\\\"", "\"").replace("\\\\", "\\");

    Ok(FieldDef {
        type_name,
        label,
        delimiter,
        delim_cp,
    })
}

/* ------------------------------------------------------------------ */
/* Values                                                              */
/* ------------------------------------------------------------------ */

enum Value {
    Str(String),
    Int(i64),
    Float(f64),
    Bool(bool),
}

fn days_in_month(y: i64, m: i64) -> i64 {
    const DM: [i64; 12] = [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];
    if m == 2 && (y % 4 == 0 && (y % 100 != 0 || y % 400 == 0)) {
        return 29;
    }
    DM[(m - 1) as usize]
}

/* Convert a string value to its typed representation. */
fn convert_value(value: &str, type_name: &str, line_num: u32) -> Res<Value> {
    match type_name {
        "str" => Ok(Value::Str(value.to_string())),

        "int" => match value.parse::<i64>() {
            Ok(v) => Ok(Value::Int(v)),
            Err(_) => fail(line_num, format!("Invalid integer: '{}'", value)),
        },

        "float" => match value.parse::<f64>() {
            Ok(v) => Ok(Value::Float(v)),
            Err(_) => fail(line_num, format!("Invalid float: '{}'", value)),
        },

        "bool" => match value.to_lowercase().as_str() {
            "true" | "1" => Ok(Value::Bool(true)),
            "false" | "0" => Ok(Value::Bool(false)),
            _ => fail(line_num, format!("Invalid boolean: '{}'", value)),
        },

        "date" => {
            let parts: Vec<&str> = value.split('-').collect();
            if parts.len() == 3 {
                if let (Ok(y), Ok(m), Ok(d)) = (
                    parts[0].parse::<i64>(),
                    parts[1].parse::<i64>(),
                    parts[2].parse::<i64>(),
                ) {
                    if y >= 1 && y <= 9999 && m >= 1 && m <= 12 && d >= 1 && d <= days_in_month(y, m) {
                        return Ok(Value::Str(value.to_string()));
                    }
                }
            }
            fail(
                line_num,
                format!("Invalid date (expected YYYY-MM-DD): '{}'", value),
            )
        }

        _ => fail(line_num, format!("Unknown type: '{}'", type_name)),
    }
}

/* ------------------------------------------------------------------ */
/* Records                                                             */
/* ------------------------------------------------------------------ */

struct RecordField {
    label: String,
    value: Value,
}

struct Record {
    fields: Vec<RecordField>,
}

fn record_has(rec: &Record, label: &str) -> bool {
    rec.fields.iter().any(|f| f.label == label)
}

fn record_find<'a>(rec: &'a Record, label: &str) -> Option<&'a Value> {
    rec.fields
        .iter()
        .find(|f| f.label == label)
        .map(|f| &f.value)
}

/* Parse a single record line. */
fn parse_record(line: &[u8], delimiter_map: &HashMap<char, FieldDef>, line_num: u32) -> Res<Record> {
    let mut rec = Record { fields: Vec::new() };
    if line.is_empty() {
        return Ok(rec);
    }

    let rs = decode_runes(line);
    let n = rs.len();
    let mut pos = 0;

    while pos < n {
        let value: String;

        /* A field is value-then-delimiter. The value may be wrapped in double
         * quotes, which lets it contain delimiter characters (SPEC 6.2). */
        if rs[pos] == '"' {
            let mut i = pos + 1;
            let mut buf = String::new();
            let mut closed = false;
            while i < n {
                let c = rs[i];
                if c == '\\' && i + 1 < n && (rs[i + 1] == '"' || rs[i + 1] == '\\') {
                    /* \" and \\ are unescaped; a backslash before any other rune
                     * is kept literally. */
                    buf.push(rs[i + 1]);
                    i += 2;
                    continue;
                }
                if c == '"' {
                    closed = true;
                    i += 1;
                    break;
                }
                buf.push(c);
                i += 1;
            }
            if !closed {
                return fail(line_num, "Unterminated quoted value".to_string());
            }
            value = buf;
            pos = i;
            if pos >= n {
                return fail(
                    line_num,
                    format!("Missing delimiter after value '{}'", value),
                );
            }
        } else {
            let start = pos;
            while pos < n && !delimiter_map.contains_key(&rs[pos]) {
                pos += 1;
            }
            if pos == n {
                return fail(
                    line_num,
                    format!("No delimiter found for value starting at column {}", start),
                );
            }
            value = runes_to_string(&rs[start..pos]);
        }

        let dc = rs[pos];
        let fd = match delimiter_map.get(&dc) {
            Some(fd) => fd,
            None => {
                return fail(
                    line_num,
                    format!("Undefined delimiter: '{}'", dc),
                )
            }
        };

        if record_has(&rec, &fd.label) {
            return fail(
                line_num,
                format!("Duplicate field in record: '{}'", fd.label),
            );
        }

        let v = convert_value(&value, &fd.type_name, line_num)?;
        rec.fields.push(RecordField {
            label: fd.label.clone(),
            value: v,
        });
        pos += 1;
    }

    Ok(rec)
}

/* ------------------------------------------------------------------ */
/* Document                                                            */
/* ------------------------------------------------------------------ */

fn parse_document(content: &[u8]) -> Res<Vec<Record>> {
    /* Normalise CRLF to LF. */
    let mut norm: Vec<u8> = Vec::with_capacity(content.len());
    let mut i = 0;
    while i < content.len() {
        if content[i] == b'\r' && i + 1 < content.len() && content[i + 1] == b'\n' {
            i += 1;
            continue;
        }
        norm.push(content[i]);
        i += 1;
    }

    /* Split on LF. */
    let mut lines: Vec<&[u8]> = Vec::new();
    let mut start = 0;
    let mut k = 0;
    while k <= norm.len() {
        if k == norm.len() || norm[k] == b'\n' {
            lines.push(&norm[start..k]);
            start = k + 1;
        }
        k += 1;
    }

    /* A trailing newline produces a spurious final empty element. Drop it so a
     * document with no blank-line separator is reported as MissingSeparator
     * instead of having its first record misread as a definition. */
    if lines.last().map_or(false, |l| l.is_empty()) {
        lines.pop();
    }

    /* First blank line is the section separator. */
    let mut sep: Option<usize> = None;
    for (idx, line) in lines.iter().enumerate() {
        if line.is_empty() {
            sep = Some(idx);
            break;
        }
    }
    let sep = match sep {
        Some(s) => s,
        None => {
            return fail(
                0,
                "No blank line separator found between definitions and data".to_string(),
            )
        }
    };

    /* Definitions. */
    let mut delimiter_map: HashMap<char, FieldDef> = HashMap::new();
    for idx in 0..sep {
        if lines[idx].is_empty() {
            continue; /* skip blank definition lines */
        }
        let fd = parse_definition(lines[idx], (idx + 1) as u32)?;

        if let Some(existing) = delimiter_map.get(&fd.delim_cp) {
            return fail(
                (idx + 1) as u32,
                format!(
                    "Delimiter '{}' already used for field '{}'",
                    fd.delimiter, existing.label
                ),
            );
        }
        delimiter_map.insert(fd.delim_cp, fd);
    }

    /* Records. */
    let mut records: Vec<Record> = Vec::new();
    for idx in (sep + 1)..lines.len() {
        if lines[idx].is_empty() {
            continue; /* skip blank record lines */
        }
        records.push(parse_record(lines[idx], &delimiter_map, (idx + 1) as u32)?);
    }

    Ok(records)
}

/* ------------------------------------------------------------------ */
/* JSON output                                                         */
/* ------------------------------------------------------------------ */

fn json_escape_into(out: &mut String, s: &str) {
    for c in s.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            '\u{0008}' => out.push_str("\\b"),
            '\u{000c}' => out.push_str("\\f"),
            _ => {
                if (c as u32) < 0x20 {
                    out.push_str(&format!("\\u{:04x}", c as u32));
                } else {
                    out.push(c);
                }
            }
        }
    }
}

/* Shortest decimal representation that round-trips exactly. */
fn fmt_double(d: f64) -> String {
    format!("{}", d)
}

fn json_value_into(out: &mut String, v: &Value) {
    match v {
        Value::Str(s) => {
            out.push('"');
            json_escape_into(out, s);
            out.push('"');
        }
        Value::Int(i) => out.push_str(&i.to_string()),
        Value::Float(f) => out.push_str(&fmt_double(*f)),
        Value::Bool(b) => out.push_str(if *b { "true" } else { "false" }),
    }
}

fn to_json(records: &[Record]) -> String {
    if records.is_empty() {
        return "[]\n".to_string();
    }

    let mut out = String::new();
    out.push_str("[\n");
    for (i, r) in records.iter().enumerate() {
        if r.fields.is_empty() {
            out.push_str("  {}");
        } else {
            out.push_str("  {\n");
            for (k, f) in r.fields.iter().enumerate() {
                out.push_str("    \"");
                json_escape_into(&mut out, &f.label);
                out.push_str("\": ");
                json_value_into(&mut out, &f.value);
                if k + 1 < r.fields.len() {
                    out.push(',');
                }
                out.push('\n');
            }
            out.push_str("  }");
        }
        if i + 1 < records.len() {
            out.push(',');
        }
        out.push('\n');
    }
    out.push_str("]\n");
    out
}

/* ------------------------------------------------------------------ */
/* CSV output                                                          */
/* ------------------------------------------------------------------ */

fn csv_escape_into(out: &mut String, s: &str) {
    if !s.chars().any(|c| c == ',' || c == '"' || c == '\n') {
        out.push_str(s);
        return;
    }
    out.push('"');
    for c in s.chars() {
        if c == '"' {
            out.push_str("\"\"");
        } else {
            out.push(c);
        }
    }
    out.push('"');
}

/* Render a value the way the Python reference's str() does. */
fn csv_value_into(out: &mut String, v: &Value) {
    match v {
        Value::Str(s) => csv_escape_into(out, s),
        Value::Int(i) => out.push_str(&i.to_string()),
        Value::Float(f) => {
            let mut s = fmt_double(*f);
            if !s.chars().any(|c| c == '.' || c == 'e' || c == 'E' || c == 'n' || c == 'i') {
                s.push_str(".0");
            }
            out.push_str(&s);
        }
        Value::Bool(b) => out.push_str(if *b { "True" } else { "False" }),
    }
}

fn to_csv(records: &[Record]) -> String {
    if records.is_empty() {
        return "\n".to_string();
    }

    /* Keys in first-seen order across all records. */
    let mut keys: Vec<&str> = Vec::new();
    for r in records {
        for f in &r.fields {
            if !keys.iter().any(|k| *k == f.label.as_str()) {
                keys.push(&f.label);
            }
        }
    }

    let mut out = String::new();
    for (q, key) in keys.iter().enumerate() {
        if q > 0 {
            out.push(',');
        }
        csv_escape_into(&mut out, key);
    }
    out.push('\n');
    for r in records {
        for (q, key) in keys.iter().enumerate() {
            if q > 0 {
                out.push(',');
            }
            if let Some(v) = record_find(r, key) {
                csv_value_into(&mut out, v);
            }
        }
        out.push('\n');
    }
    out
}

/* ------------------------------------------------------------------ */
/* CLI                                                                 */
/* ------------------------------------------------------------------ */

fn main() {
    let args: Vec<String> = std::env::args().collect();
    if args.len() < 3 {
        eprintln!("{}", USAGE);
        exit(1);
    }

    let cmd = args[1].as_str();
    let path = args[2].as_str();

    let content = match std::fs::read(path) {
        Ok(c) => c,
        Err(_) => {
            eprintln!("Error: File not found: {}", path);
            exit(1);
        }
    };

    match cmd {
        "parse" => match parse_document(&content) {
            Ok(records) => print!("{}", to_json(&records)),
            Err(e) => {
                eprintln!("Parse error: {}", e.render());
                exit(1);
            }
        },

        "validate" => match parse_document(&content) {
            Ok(_) => println!("Valid KDG document"),
            Err(e) => {
                eprintln!("Invalid: {}", e.render());
                exit(1);
            }
        },

        "convert" => {
            let fmt = if args.len() > 3 { args[3].as_str() } else { "json" };
            match parse_document(&content) {
                Ok(records) => {
                    if fmt == "json" {
                        print!("{}", to_json(&records));
                    } else if fmt == "csv" {
                        print!("{}", to_csv(&records));
                    } else {
                        eprintln!("Unknown format: {}", fmt);
                        exit(1);
                    }
                }
                Err(e) => {
                    eprintln!("Parse error: {}", e.render());
                    exit(1);
                }
            }
        }

        _ => {
            eprintln!("Unknown command: {}", cmd);
            eprintln!("{}", USAGE);
            exit(1);
        }
    }
}
