// kdg.cpp - KDG (Key-Delimited Grammar) parser in C++17, standard library only.
//
// CLI (mirrors implementations/kdg.go):
//   kdg parse <file>             Parse KDG to JSON on stdout, exit 0
//   kdg validate <file>          Print "Valid KDG document" or "Invalid: ..."
//   kdg convert <file> [json|csv]
//
// The parsing behaviour (definition grammar, label unescaping, trailing
// newline handling, record scanning, wrapped values, type coercion and error
// messages) intentionally reproduces the Go reference implementation.
#include <cctype>
#include <cerrno>
#include <climits>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <iterator>
#include <map>
#include <string>
#include <utility>
#include <vector>

namespace {

const char *USAGE = "Usage: kdg <parse|validate|convert> <file> [json|csv]";

/* ------------------------------------------------------------------ */
/* Errors                                                              */
/* ------------------------------------------------------------------ */

/* line == 0 means "no line prefix"; only MissingSeparator uses that. */
struct KdgError {
    int line;
    std::string message;

    KdgError(int line_, std::string message_)
        : line(line_), message(std::move(message_)) {}

    std::string str() const {
        if (line > 0)
            return "Line " + std::to_string(line) + ": " + message;
        return message;
    }
};

[[noreturn]] void fail(int line, std::string message) {
    throw KdgError(line, std::move(message));
}

/* ------------------------------------------------------------------ */
/* UTF-8                                                               */
/* ------------------------------------------------------------------ */

/* Decode one rune at *i, advancing *i. Invalid sequences become U+FFFD and
 * consume a single byte, matching Go's []rune conversion. */
uint32_t utf8_decode(const std::string &s, size_t n, size_t &i) {
    unsigned char b = (unsigned char)s[i];
    if (b < 0x80) {
        i++;
        return b;
    }
    int need;
    uint32_t cp;
    if ((b & 0xE0) == 0xC0) {
        need = 1;
        cp = b & 0x1F;
    } else if ((b & 0xF0) == 0xE0) {
        need = 2;
        cp = b & 0x0F;
    } else if ((b & 0xF8) == 0xF0) {
        need = 3;
        cp = b & 0x07;
    } else {
        i++;
        return 0xFFFD;
    }
    if (i + (size_t)need >= n) {
        i++;
        return 0xFFFD;
    }
    for (int k = 1; k <= need; k++) {
        unsigned char c = (unsigned char)s[i + (size_t)k];
        if ((c & 0xC0) != 0x80) {
            i++;
            return 0xFFFD;
        }
        cp = (cp << 6) | (c & 0x3F);
    }
    if ((need == 1 && cp < 0x80) || (need == 2 && cp < 0x800) ||
        (need == 3 && (cp < 0x10000 || cp > 0x10FFFF)) ||
        (cp >= 0xD800 && cp <= 0xDFFF)) {
        i++;
        return 0xFFFD;
    }
    i += (size_t)need + 1;
    return cp;
}

/* Encode cp as UTF-8, returning the number of bytes written (1..4). */
int utf8_encode(uint32_t cp, char out[4]) {
    if (cp < 0x80) {
        out[0] = (char)cp;
        return 1;
    }
    if (cp < 0x800) {
        out[0] = (char)(0xC0 | (cp >> 6));
        out[1] = (char)(0x80 | (cp & 0x3F));
        return 2;
    }
    if (cp < 0x10000) {
        out[0] = (char)(0xE0 | (cp >> 12));
        out[1] = (char)(0x80 | ((cp >> 6) & 0x3F));
        out[2] = (char)(0x80 | (cp & 0x3F));
        return 3;
    }
    out[0] = (char)(0xF0 | (cp >> 18));
    out[1] = (char)(0x80 | ((cp >> 12) & 0x3F));
    out[2] = (char)(0x80 | ((cp >> 6) & 0x3F));
    out[3] = (char)(0x80 | (cp & 0x3F));
    return 4;
}

struct Rune {
    uint32_t cp;
    size_t off;
    size_t len;
};

std::vector<Rune> build_runes(const std::string &s) {
    std::vector<Rune> rs;
    rs.reserve(s.size());
    size_t n = s.size();
    size_t i = 0;
    while (i < n) {
        size_t start = i;
        uint32_t cp = utf8_decode(s, n, i);
        Rune r;
        r.cp = cp;
        r.off = start;
        r.len = i - start;
        rs.push_back(r);
    }
    return rs;
}

/* ------------------------------------------------------------------ */
/* Types and definitions                                               */
/* ------------------------------------------------------------------ */

struct FieldDef {
    std::string typeName;
    std::string label;
    std::string delimiter; /* UTF-8 bytes of the delimiter rune */
    uint32_t delimCp;
};

bool is_valid_type(const std::string &t) {
    return t == "str" || t == "int" || t == "float" || t == "bool" ||
           t == "date";
}

/* Characters that cannot be delimiters (SPEC 3.4). */
bool is_reserved(uint32_t c) {
    if (c >= 'a' && c <= 'z') return true;
    if (c >= 'A' && c <= 'Z') return true;
    if (c >= '0' && c <= '9') return true;
    return c == ':' || c == '"' || c == ' ' || c == '\t' || c == '\n' ||
           c == '\r';
}

/* Replace every occurrence of *from* with *to*, left to right and without
 * overlap (Go's strings.ReplaceAll). */
std::string replace_all(const std::string &s, const std::string &from,
                        const std::string &to) {
    std::string out;
    size_t n = s.size();
    size_t fl = from.size();
    size_t i = 0;
    while (i + fl <= n) {
        if (s.compare(i, fl, from) == 0) {
            out += to;
            i += fl;
        } else {
            out += s[i];
            i++;
        }
    }
    while (i < n) {
        out += s[i];
        i++;
    }
    return out;
}

/* Parse a single field definition line. */
FieldDef parse_definition(const std::string &line, int lineNum) {
    size_t n = line.size();
    size_t i = 0;
    while (i < n && line[i] >= 'a' && line[i] <= 'z') i++;
    if (i == 0 || i >= n || line[i] != ':')
        fail(lineNum, "Invalid definition syntax: '" + line + "'");

    std::string typeName = line.substr(0, i);
    i++; /* past ':' */

    if (i >= n || line[i] != '"')
        fail(lineNum, "Invalid definition syntax: '" + line + "'");
    i++; /* past the opening quote */

    std::vector<Rune> rs = build_runes(line);
    int nr = (int)rs.size();
    int open_idx = -1;
    for (int k = 0; k < nr; k++) {
        if (rs[(size_t)k].off == i - 1) { /* the opening quote */
            open_idx = k;
            break;
        }
    }
    if (open_idx < 0 || nr < 2)
        fail(lineNum, "Invalid definition syntax: '" + line + "'");

    /* The regex's group 2 always ends two runes before the line end: the
     * pattern closes with a literal quote and a single delimiter rune. */
    int close_idx = nr - 2;
    if (close_idx < open_idx + 1 || rs[(size_t)close_idx].cp != '"')
        fail(lineNum, "Invalid definition syntax: '" + line + "'");

    /* The label is a sequence of ordinary runes and two-rune backslash
     * escapes (group 2 of the reference regexp). */
    for (int k = open_idx + 1; k < close_idx;) {
        uint32_t cp = rs[(size_t)k].cp;
        if (cp == '\\') {
            if (k + 1 >= close_idx)
                fail(lineNum, "Invalid definition syntax: '" + line + "'");
            k += 2;
        } else if (cp == '"') {
            fail(lineNum, "Invalid definition syntax: '" + line + "'");
        } else {
            k++;
        }
    }

    if (!is_valid_type(typeName))
        fail(lineNum, "Unknown type: '" + typeName + "'");

    uint32_t dc = rs[(size_t)(nr - 1)].cp;
    char db[4];
    int dl = utf8_encode(dc, db);
    std::string delim(db, (size_t)dl);
    if (is_reserved(dc))
        fail(lineNum, "Invalid delimiter: '" + delim + "' (reserved character)");

    std::string raw = line.substr(rs[(size_t)(open_idx + 1)].off,
                                  rs[(size_t)close_idx].off -
                                      rs[(size_t)(open_idx + 1)].off);

    FieldDef fd;
    /* Unescape order matters: \" first, then \\. */
    fd.typeName = typeName;
    fd.label = replace_all(replace_all(raw, "\\\"", "\""), "\\\\", "\\");
    fd.delimiter = delim;
    fd.delimCp = dc;
    return fd;
}

/* ------------------------------------------------------------------ */
/* Values                                                              */
/* ------------------------------------------------------------------ */

struct Value {
    enum Kind { STR, INT, FLOAT, BOOL };

    Kind kind;
    std::string s;
    long long i = 0;
    double d = 0;
    bool b = false;
};

bool parse_int_str(const std::string &s, long long &out) {
    const char *p = s.c_str();
    bool neg = false;
    if (*p == '+' || *p == '-') {
        neg = (*p == '-');
        p++;
    }
    if (!std::isdigit((unsigned char)*p)) return false;
    unsigned long long v = 0;
    for (; *p; p++) {
        if (!std::isdigit((unsigned char)*p)) return false;
        unsigned int d = (unsigned int)(*p - '0');
        if (v > (ULLONG_MAX - d) / 10) return false;
        v = v * 10 + d;
    }
    if (neg) {
        if (v > (unsigned long long)LLONG_MAX + 1ULL) return false;
        if (v == (unsigned long long)LLONG_MAX + 1ULL)
            out = LLONG_MIN;
        else
            out = -(long long)v;
    } else {
        if (v > (unsigned long long)LLONG_MAX) return false;
        out = (long long)v;
    }
    return true;
}

bool ci_eq(const std::string &a, const std::string &b) {
    if (a.size() != b.size()) return false;
    for (size_t i = 0; i < a.size(); i++) {
        if (std::tolower((unsigned char)a[i]) != std::tolower((unsigned char)b[i]))
            return false;
    }
    return true;
}

int days_in_month(int y, int m) {
    static const int dm[12] = {31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31};
    if (m == 2 && (y % 4 == 0 && (y % 100 != 0 || y % 400 == 0))) return 29;
    return dm[m - 1];
}

/* Convert a string value to its typed representation. */
Value convert_value(const std::string &value, const std::string &typeName,
                    int lineNum) {
    Value out;
    if (typeName == "str") {
        out.kind = Value::STR;
        out.s = value;
        return out;
    }

    if (typeName == "int") {
        long long v = 0;
        if (!parse_int_str(value, v))
            fail(lineNum, "Invalid integer: '" + value + "'");
        out.kind = Value::INT;
        out.i = v;
        return out;
    }

    if (typeName == "float") {
        if (value.empty() || std::isspace((unsigned char)value[0]))
            fail(lineNum, "Invalid float: '" + value + "'");
        errno = 0;
        char *end = NULL;
        double d = std::strtod(value.c_str(), &end);
        if (end == value.c_str() || *end != '\0' || errno == ERANGE)
            fail(lineNum, "Invalid float: '" + value + "'");
        out.kind = Value::FLOAT;
        out.d = d;
        return out;
    }

    if (typeName == "bool") {
        if (ci_eq(value, "true") || value == "1") {
            out.kind = Value::BOOL;
            out.b = true;
            return out;
        }
        if (ci_eq(value, "false") || value == "0") {
            out.kind = Value::BOOL;
            out.b = false;
            return out;
        }
        fail(lineNum, "Invalid boolean: '" + value + "'");
    }

    if (typeName == "date") {
        size_t p1 = value.find('-');
        size_t p2 = (p1 == std::string::npos) ? std::string::npos
                                              : value.find('-', p1 + 1);
        if (p1 != std::string::npos && p2 != std::string::npos &&
            value.find('-', p2 + 1) == std::string::npos) {
            long long y = 0, m = 0, d = 0;
            bool ok = parse_int_str(value.substr(0, p1), y) &&
                      parse_int_str(value.substr(p1 + 1, p2 - p1 - 1), m) &&
                      parse_int_str(value.substr(p2 + 1), d);
            if (ok && y >= 1 && y <= 9999 && m >= 1 && m <= 12 && d >= 1 &&
                d <= days_in_month((int)y, (int)m)) {
                out.kind = Value::STR; /* kept as a string for JSON */
                out.s = value;
                return out;
            }
        }
        fail(lineNum, "Invalid date (expected YYYY-MM-DD): '" + value + "'");
    }

    fail(lineNum, "Unknown type: '" + typeName + "'");
}

/* ------------------------------------------------------------------ */
/* Records                                                             */
/* ------------------------------------------------------------------ */

struct RecordField {
    std::string label;
    Value value;
};

struct Record {
    std::vector<RecordField> fields;
};

bool record_has(const Record &rec, const std::string &label) {
    for (size_t i = 0; i < rec.fields.size(); i++)
        if (rec.fields[i].label == label) return true;
    return false;
}

const Value *record_find(const Record &rec, const std::string &label) {
    for (size_t i = 0; i < rec.fields.size(); i++)
        if (rec.fields[i].label == label) return &rec.fields[i].value;
    return NULL;
}

/* Parse a single record line. */
Record parse_record(const std::string &line,
                    const std::map<uint32_t, FieldDef> &delimiterMap,
                    int lineNum) {
    Record rec;
    if (line.empty()) return rec;

    std::vector<Rune> rs = build_runes(line);
    int nr = (int)rs.size();
    int pos = 0;

    while (pos < nr) {
        std::string value;

        /* A field is value-then-delimiter. The value may be wrapped in double
         * quotes, which lets it contain delimiter characters (SPEC 6.2). */
        if (rs[(size_t)pos].cp == '"') {
            int i = pos + 1;
            bool closed = false;
            while (i < nr) {
                uint32_t c = rs[(size_t)i].cp;
                if (c == '\\' && i + 1 < nr &&
                    (rs[(size_t)(i + 1)].cp == '"' ||
                     rs[(size_t)(i + 1)].cp == '\\')) {
                    /* \" and \\ are unescaped; a backslash before any other
                     * rune is kept literally. */
                    value.append(line, rs[(size_t)(i + 1)].off,
                                 rs[(size_t)(i + 1)].len);
                    i += 2;
                    continue;
                }
                if (c == '"') {
                    closed = true;
                    i++;
                    break;
                }
                value.append(line, rs[(size_t)i].off, rs[(size_t)i].len);
                i++;
            }
            if (!closed) fail(lineNum, "Unterminated quoted value");
            pos = i;
            if (pos >= nr)
                fail(lineNum, "Missing delimiter after value '" + value + "'");
        } else {
            int start = pos;
            while (pos < nr &&
                   delimiterMap.find(rs[(size_t)pos].cp) == delimiterMap.end())
                pos++;
            if (pos == nr)
                fail(lineNum, "No delimiter found for value starting at column " +
                                  std::to_string(start));
            value = line.substr(rs[(size_t)start].off,
                                rs[(size_t)pos].off - rs[(size_t)start].off);
        }

        uint32_t dc = rs[(size_t)pos].cp;
        std::map<uint32_t, FieldDef>::const_iterator it = delimiterMap.find(dc);
        if (it == delimiterMap.end()) {
            char db[4];
            int dl = utf8_encode(dc, db);
            fail(lineNum, "Undefined delimiter: '" + std::string(db, (size_t)dl) +
                              "'");
        }
        const FieldDef &fd = it->second;

        if (record_has(rec, fd.label))
            fail(lineNum, "Duplicate field in record: '" + fd.label + "'");

        RecordField rf;
        rf.label = fd.label;
        rf.value = convert_value(value, fd.typeName, lineNum);
        rec.fields.push_back(std::move(rf));
        pos++;
    }

    return rec;
}

/* ------------------------------------------------------------------ */
/* Document                                                            */
/* ------------------------------------------------------------------ */

std::vector<Record> parse_document(const std::string &content) {
    /* Normalise CRLF to LF. */
    std::string norm;
    norm.reserve(content.size());
    for (size_t i = 0; i < content.size(); i++) {
        if (content[i] == '\r' && i + 1 < content.size() &&
            content[i + 1] == '\n')
            continue;
        norm += content[i];
    }

    std::vector<std::string> lines;
    {
        size_t start = 0;
        for (size_t i = 0; i <= norm.size(); i++) {
            if (i == norm.size() || norm[i] == '\n') {
                lines.push_back(norm.substr(start, i - start));
                start = i + 1;
            }
        }
    }

    /* A trailing newline produces a spurious final empty element. Drop it so a
     * document with no blank-line separator is reported as MissingSeparator
     * instead of having its first record misread as a definition. */
    if (!lines.empty() && lines.back().empty()) lines.pop_back();

    /* First blank line is the section separator. */
    int sep = -1;
    for (size_t i = 0; i < lines.size(); i++) {
        if (lines[i].empty()) {
            sep = (int)i;
            break;
        }
    }
    if (sep < 0)
        fail(0, "No blank line separator found between definitions and data");

    /* Definitions. */
    std::map<uint32_t, FieldDef> delimiterMap;
    for (int i = 0; i < sep; i++) {
        if (lines[(size_t)i].empty()) continue; /* skip blank definition lines */
        FieldDef fd = parse_definition(lines[(size_t)i], i + 1);

        std::map<uint32_t, FieldDef>::const_iterator ex =
            delimiterMap.find(fd.delimCp);
        if (ex != delimiterMap.end())
            fail(i + 1, "Delimiter '" + fd.delimiter +
                            "' already used for field '" + ex->second.label + "'");

        delimiterMap[fd.delimCp] = fd;
    }

    /* Records. */
    std::vector<Record> records;
    for (size_t i = (size_t)sep + 1; i < lines.size(); i++) {
        if (lines[i].empty()) continue; /* skip blank record lines */
        records.push_back(parse_record(lines[i], delimiterMap, (int)i + 1));
    }
    return records;
}

/* ------------------------------------------------------------------ */
/* JSON output                                                         */
/* ------------------------------------------------------------------ */

void json_escape_into(std::string &out, const std::string &s) {
    for (size_t i = 0; i < s.size(); i++) {
        unsigned char c = (unsigned char)s[i];
        switch (c) {
            case '"': out += "\\\""; break;
            case '\\': out += "\\\\"; break;
            case '\n': out += "\\n"; break;
            case '\r': out += "\\r"; break;
            case '\t': out += "\\t"; break;
            case '\b': out += "\\b"; break;
            case '\f': out += "\\f"; break;
            default:
                if (c < 0x20) {
                    char t[8];
                    std::snprintf(t, sizeof t, "\\u%04x", c);
                    out += t;
                } else {
                    out += (char)c;
                }
        }
    }
}

/* Shortest decimal representation that round-trips exactly. */
void fmt_double_into(std::string &out, double d) {
    char tmp[64];
    for (int prec = 15; prec <= 17; prec++) {
        std::snprintf(tmp, sizeof tmp, "%.*g", prec, d);
        if (std::strtod(tmp, NULL) == d) {
            out += tmp;
            return;
        }
    }
    std::snprintf(tmp, sizeof tmp, "%.17g", d);
    out += tmp;
}

void json_value_into(std::string &out, const Value &v) {
    char tmp[64];
    switch (v.kind) {
        case Value::STR:
            out += '"';
            json_escape_into(out, v.s);
            out += '"';
            break;
        case Value::INT:
            std::snprintf(tmp, sizeof tmp, "%lld", v.i);
            out += tmp;
            break;
        case Value::FLOAT:
            fmt_double_into(out, v.d);
            break;
        case Value::BOOL:
            out += v.b ? "true" : "false";
            break;
    }
}

std::string to_json(const std::vector<Record> &records) {
    if (records.empty()) return "[]\n";

    std::string out;
    out += "[\n";
    for (size_t i = 0; i < records.size(); i++) {
        const Record &r = records[i];
        if (r.fields.empty()) {
            out += "  {}";
        } else {
            out += "  {\n";
            for (size_t k = 0; k < r.fields.size(); k++) {
                out += "    \"";
                json_escape_into(out, r.fields[k].label);
                out += "\": ";
                json_value_into(out, r.fields[k].value);
                if (k + 1 < r.fields.size()) out += ',';
                out += '\n';
            }
            out += "  }";
        }
        if (i + 1 < records.size()) out += ',';
        out += '\n';
    }
    out += "]\n";
    return out;
}

/* ------------------------------------------------------------------ */
/* CSV output                                                          */
/* ------------------------------------------------------------------ */

void csv_escape_into(std::string &out, const std::string &s) {
    if (s.find_first_of(",\"\n") == std::string::npos) {
        out += s;
        return;
    }
    out += '"';
    for (size_t i = 0; i < s.size(); i++) {
        if (s[i] == '"')
            out += "\"\"";
        else
            out += s[i];
    }
    out += '"';
}

/* Render a value the way the Python reference's str() does. */
void csv_value_into(std::string &out, const Value &v) {
    char tmp[64];
    switch (v.kind) {
        case Value::STR:
            csv_escape_into(out, v.s);
            break;
        case Value::INT:
            std::snprintf(tmp, sizeof tmp, "%lld", v.i);
            out += tmp;
            break;
        case Value::FLOAT: {
            std::string f;
            fmt_double_into(f, v.d);
            if (f.find_first_of(".eEni") == std::string::npos) f += ".0";
            out += f;
            break;
        }
        case Value::BOOL:
            out += v.b ? "True" : "False";
            break;
    }
}

std::string to_csv(const std::vector<Record> &records) {
    if (records.empty()) return "\n";

    /* Keys in first-seen order across all records. */
    std::vector<std::string> keys;
    for (size_t i = 0; i < records.size(); i++) {
        for (size_t k = 0; k < records[i].fields.size(); k++) {
            const std::string &lab = records[i].fields[k].label;
            bool found = false;
            for (size_t q = 0; q < keys.size(); q++)
                if (keys[q] == lab) {
                    found = true;
                    break;
                }
            if (!found) keys.push_back(lab);
        }
    }

    std::string out;
    for (size_t q = 0; q < keys.size(); q++) {
        if (q) out += ',';
        csv_escape_into(out, keys[q]);
    }
    out += '\n';
    for (size_t i = 0; i < records.size(); i++) {
        for (size_t q = 0; q < keys.size(); q++) {
            if (q) out += ',';
            const Value *v = record_find(records[i], keys[q]);
            if (v) csv_value_into(out, *v);
        }
        out += '\n';
    }
    return out;
}

/* ------------------------------------------------------------------ */
/* CLI                                                                 */
/* ------------------------------------------------------------------ */

bool read_file(const std::string &path, std::string &out) {
    std::ifstream f(path.c_str(), std::ios::binary);
    if (!f) return false;
    out.assign(std::istreambuf_iterator<char>(f),
               std::istreambuf_iterator<char>());
    return true;
}

void write_stdout(const std::string &s) {
    std::fwrite(s.data(), 1, s.size(), stdout);
}

} /* namespace */

int main(int argc, char **argv) {
    if (argc < 3) {
        std::fprintf(stderr, "%s\n", USAGE);
        return 1;
    }

    std::string cmd = argv[1];
    std::string path = argv[2];

    std::string content;
    if (!read_file(path, content)) {
        std::fprintf(stderr, "Error: File not found: %s\n", path.c_str());
        return 1;
    }

    if (cmd == "parse") {
        try {
            write_stdout(to_json(parse_document(content)));
            return 0;
        } catch (const KdgError &e) {
            std::fprintf(stderr, "Parse error: %s\n", e.str().c_str());
            return 1;
        }
    }

    if (cmd == "validate") {
        try {
            parse_document(content);
            std::printf("Valid KDG document\n");
            return 0;
        } catch (const KdgError &e) {
            std::fprintf(stderr, "Invalid: %s\n", e.str().c_str());
            return 1;
        }
    }

    if (cmd == "convert") {
        std::string fmt = (argc > 3) ? argv[3] : "json";
        std::vector<Record> records;
        try {
            records = parse_document(content);
        } catch (const KdgError &e) {
            std::fprintf(stderr, "Parse error: %s\n", e.str().c_str());
            return 1;
        }
        if (fmt == "json") {
            write_stdout(to_json(records));
            return 0;
        }
        if (fmt == "csv") {
            write_stdout(to_csv(records));
            return 0;
        }
        std::fprintf(stderr, "Unknown format: %s\n", fmt.c_str());
        return 1;
    }

    std::fprintf(stderr, "Unknown command: %s\n", cmd.c_str());
    std::fprintf(stderr, "%s\n", USAGE);
    return 1;
}
