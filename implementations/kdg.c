/* kdg.c - KDG (Key-Delimited Grammar) parser in C99, standard library only.
 *
 * CLI (mirrors implementations/kdg.go):
 *   kdg parse <file>            Parse KDG to JSON on stdout, exit 0
 *   kdg validate <file>         Print "Valid KDG document" or "Invalid: ..."
 *   kdg convert <file> [json|csv]
 *
 * The parsing behaviour (definition grammar, label unescaping, trailing
 * newline handling, record scanning, wrapped values, type coercion and error
 * messages) intentionally reproduces the Go reference implementation.
 */
#include <ctype.h>
#include <errno.h>
#include <limits.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define USAGE "Usage: kdg <parse|validate|convert> <file> [json|csv]"

/* ------------------------------------------------------------------ */
/* Error state                                                         */
/* ------------------------------------------------------------------ */

/* No KDGError detail string is longer than this for the test vectors; the
 * content of a definition line contributes at most one line. */
static char g_err[8192];
static int g_err_line; /* 0 == no line prefix (only MissingSeparator) */
static char g_errstr[8300];

static int set_err(int line, const char *fmt, ...) {
    va_list ap;
    g_err_line = line;
    va_start(ap, fmt);
    vsnprintf(g_err, sizeof g_err, fmt, ap);
    va_end(ap);
    return -1;
}

static const char *err_string(void) {
    if (g_err_line > 0)
        snprintf(g_errstr, sizeof g_errstr, "Line %d: %s", g_err_line, g_err);
    else
        snprintf(g_errstr, sizeof g_errstr, "%s", g_err);
    return g_errstr;
}

/* ------------------------------------------------------------------ */
/* Small helpers                                                       */
/* ------------------------------------------------------------------ */

static char *xstrndup(const char *s, size_t n) {
    char *p = malloc(n + 1);
    memcpy(p, s, n);
    p[n] = '\0';
    return p;
}

static char *xstrdup(const char *s) { return xstrndup(s, strlen(s)); }

/* Growable, always NUL-terminated byte buffer. */
typedef struct {
    char *data;
    size_t len;
    size_t cap;
} Buf;

static void buf_init(Buf *b) {
    b->cap = 64;
    b->len = 0;
    b->data = malloc(b->cap);
    b->data[0] = '\0';
}

static void buf_reserve(Buf *b, size_t extra) {
    if (b->len + extra + 1 > b->cap) {
        while (b->len + extra + 1 > b->cap)
            b->cap *= 2;
        b->data = realloc(b->data, b->cap);
    }
}

static void buf_put(Buf *b, const char *s, size_t n) {
    buf_reserve(b, n);
    memcpy(b->data + b->len, s, n);
    b->len += n;
    b->data[b->len] = '\0';
}

static void buf_puts(Buf *b, const char *s) { buf_put(b, s, strlen(s)); }

static void buf_putc(Buf *b, char c) {
    buf_reserve(b, 1);
    b->data[b->len++] = c;
    b->data[b->len] = '\0';
}

static void buf_free(Buf *b) { free(b->data); }

/* ------------------------------------------------------------------ */
/* UTF-8                                                               */
/* ------------------------------------------------------------------ */

/* Decode one rune at *i, advancing *i. Invalid sequences become U+FFFD and
 * consume a single byte, matching Go's []rune conversion. */
static uint32_t utf8_decode(const char *s, size_t len, size_t *i) {
    unsigned char b = (unsigned char)s[*i];
    if (b < 0x80) {
        (*i)++;
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
        (*i)++;
        return 0xFFFD;
    }
    if (*i + (size_t)need >= len) {
        (*i)++;
        return 0xFFFD;
    }
    for (int k = 1; k <= need; k++) {
        unsigned char c = (unsigned char)s[*i + k];
        if ((c & 0xC0) != 0x80) {
            (*i)++;
            return 0xFFFD;
        }
        cp = (cp << 6) | (c & 0x3F);
    }
    if ((need == 1 && cp < 0x80) || (need == 2 && cp < 0x800) ||
        (need == 3 && (cp < 0x10000 || cp > 0x10FFFF)) ||
        (cp >= 0xD800 && cp <= 0xDFFF)) {
        (*i)++;
        return 0xFFFD;
    }
    *i += (size_t)need + 1;
    return cp;
}

/* Encode cp as UTF-8, returning the number of bytes written (1..4). */
static int utf8_encode(uint32_t cp, char out[4]) {
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

typedef struct {
    uint32_t cp;
    size_t off;
    size_t len;
} Rune;

static Rune *build_runes(const char *s, size_t n, int *count) {
    Rune *rs = malloc(sizeof(Rune) * (n + 1));
    int c = 0;
    size_t i = 0;
    while (i < n) {
        size_t start = i;
        uint32_t cp = utf8_decode(s, n, &i);
        rs[c].cp = cp;
        rs[c].off = start;
        rs[c].len = i - start;
        c++;
    }
    *count = c;
    return rs;
}

/* ------------------------------------------------------------------ */
/* Types and definitions                                               */
/* ------------------------------------------------------------------ */

typedef struct {
    char *type;
    char *label;
    uint32_t delim_cp;
    char delim_utf8[4];
    int delim_len;
} FieldDef;

typedef struct {
    FieldDef *d;
    int n;
    int cap;
} DefMap;

static FieldDef *def_find(DefMap *m, uint32_t cp) {
    for (int i = 0; i < m->n; i++)
        if (m->d[i].delim_cp == cp)
            return &m->d[i];
    return NULL;
}

static int is_valid_type(const char *t) {
    return !strcmp(t, "str") || !strcmp(t, "int") || !strcmp(t, "float") ||
           !strcmp(t, "bool") || !strcmp(t, "date");
}

/* Characters that cannot be delimiters (SPEC 3.3). */
static int is_reserved(uint32_t c) {
    if (c >= 'a' && c <= 'z') return 1;
    if (c >= 'A' && c <= 'Z') return 1;
    if (c >= '0' && c <= '9') return 1;
    return c == ':' || c == '"' || c == ' ' || c == '\t' || c == '\n' ||
           c == '\r';
}

/* Replace every occurrence of *from* (flen bytes) with *to* (tlen bytes),
 * scanning left to right without overlap (Go's strings.ReplaceAll). */
static char *replace_all(const char *s, const char *from, size_t flen,
                         const char *to, size_t tlen) {
    Buf b;
    buf_init(&b);
    size_t n = strlen(s);
    size_t i = 0;
    while (i + flen <= n) {
        if (memcmp(s + i, from, flen) == 0) {
            buf_put(&b, to, tlen);
            i += flen;
        } else {
            buf_putc(&b, s[i]);
            i++;
        }
    }
    while (i < n) {
        buf_putc(&b, s[i]);
        i++;
    }
    return b.data; /* owned by caller */
}

/* Parse a single field definition line. Returns 0 on success, -1 on error. */
static int parse_definition(const char *s, size_t n, int lineNum, FieldDef *out) {
    size_t i = 0;
    while (i < n && s[i] >= 'a' && s[i] <= 'z') i++;
    if (i == 0 || i >= n || s[i] != ':')
        return set_err(lineNum, "Invalid definition syntax: '%s'", s);

    char *type = xstrndup(s, i);
    i++; /* past ':' */

    if (i >= n || s[i] != '"') {
        free(type);
        return set_err(lineNum, "Invalid definition syntax: '%s'", s);
    }
    i++; /* past opening quote */

    int nr;
    Rune *rs = build_runes(s, n, &nr);
    int open_idx = -1;
    for (int k = 0; k < nr; k++) {
        if (rs[k].off == i - 1) { /* opening quote precedes the label */
            open_idx = k;
            break;
        }
    }
    if (open_idx < 0 || nr < 2) {
        free(type);
        free(rs);
        return set_err(lineNum, "Invalid definition syntax: '%s'", s);
    }

    int close_idx = nr - 2;
    if (close_idx < open_idx + 1 || rs[close_idx].cp != '"') {
        free(type);
        free(rs);
        return set_err(lineNum, "Invalid definition syntax: '%s'", s);
    }

    /* The label must be a sequence of (non-quote, non-backslash) runes and
     * backslash escapes: group 2 of the reference regexp. */
    for (int k = open_idx + 1; k < close_idx;) {
        uint32_t cp = rs[k].cp;
        if (cp == '\\') {
            if (k + 1 >= close_idx) {
                free(type);
                free(rs);
                return set_err(lineNum, "Invalid definition syntax: '%s'", s);
            }
            k += 2;
        } else if (cp == '"') {
            free(type);
            free(rs);
            return set_err(lineNum, "Invalid definition syntax: '%s'", s);
        } else {
            k++;
        }
    }

    if (!is_valid_type(type)) {
        int r = set_err(lineNum, "Unknown type: '%s'", type);
        free(type);
        free(rs);
        return r;
    }

    uint32_t dc = rs[nr - 1].cp;
    if (is_reserved(dc)) {
        char db[4];
        int l = utf8_encode(dc, db);
        db[l] = '\0';
        int r = set_err(lineNum, "Invalid delimiter: '%s' (reserved character)", db);
        free(type);
        free(rs);
        return r;
    }

    size_t lab_off = rs[open_idx + 1].off;
    size_t lab_end = rs[close_idx].off;
    char *raw = xstrndup(s + lab_off, lab_end - lab_off);
    free(rs);

    /* Unescape order matters: \" first, then \\. */
    char *step = replace_all(raw, "\\\"", 2, "\"", 1);
    char *label = replace_all(step, "\\\\", 2, "\\", 1);
    free(step);
    free(raw);

    out->type = type;
    out->label = label;
    out->delim_cp = dc;
    out->delim_len = utf8_encode(dc, out->delim_utf8);
    return 0;
}

/* ------------------------------------------------------------------ */
/* Values                                                              */
/* ------------------------------------------------------------------ */

enum { V_STR = 0, V_INT = 1, V_FLOAT = 2, V_BOOL = 3 };

typedef struct {
    int kind;
    char *str;
    long long i;
    double d;
    int b;
} Value;

static int parse_int_str(const char *s, long long *out) {
    const char *p = s;
    int neg = 0;
    if (*p == '+' || *p == '-') {
        neg = (*p == '-');
        p++;
    }
    if (!isdigit((unsigned char)*p))
        return 0;
    unsigned long long v = 0;
    for (; *p; p++) {
        if (!isdigit((unsigned char)*p))
            return 0;
        unsigned d = (unsigned)(*p - '0');
        if (v > (ULLONG_MAX - d) / 10)
            return 0;
        v = v * 10 + d;
    }
    if (neg) {
        if (v > (unsigned long long)LLONG_MAX + 1ULL)
            return 0;
        if (v == (unsigned long long)LLONG_MAX + 1ULL)
            *out = LLONG_MIN;
        else
            *out = -(long long)v;
    } else {
        if (v > (unsigned long long)LLONG_MAX)
            return 0;
        *out = (long long)v;
    }
    return 1;
}

static int ci_eq(const char *a, const char *b) {
    while (*a && *b) {
        if (tolower((unsigned char)*a) != tolower((unsigned char)*b))
            return 0;
        a++;
        b++;
    }
    return *a == '\0' && *b == '\0';
}

static int days_in_month(int y, int m) {
    static const int dm[12] = {31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31};
    if (m == 2 && (y % 4 == 0 && (y % 100 != 0 || y % 400 == 0)))
        return 29;
    return dm[m - 1];
}

/* Convert a string value to its typed representation. */
static int convert_value(const char *value, const char *type, int lineNum,
                         Value *out) {
    if (!strcmp(type, "str")) {
        out->kind = V_STR;
        out->str = xstrdup(value);
        return 0;
    }

    if (!strcmp(type, "int")) {
        long long v;
        if (!parse_int_str(value, &v))
            return set_err(lineNum, "Invalid integer: '%s'", value);
        out->kind = V_INT;
        out->i = v;
        return 0;
    }

    if (!strcmp(type, "float")) {
        if (*value == '\0' || isspace((unsigned char)value[0]))
            return set_err(lineNum, "Invalid float: '%s'", value);
        errno = 0;
        char *end = NULL;
        double d = strtod(value, &end);
        if (end == value || *end != '\0' || errno == ERANGE)
            return set_err(lineNum, "Invalid float: '%s'", value);
        out->kind = V_FLOAT;
        out->d = d;
        return 0;
    }

    if (!strcmp(type, "bool")) {
        if (ci_eq(value, "true") || !strcmp(value, "1")) {
            out->kind = V_BOOL;
            out->b = 1;
            return 0;
        }
        if (ci_eq(value, "false") || !strcmp(value, "0")) {
            out->kind = V_BOOL;
            out->b = 0;
            return 0;
        }
        return set_err(lineNum, "Invalid boolean: '%s'", value);
    }

    if (!strcmp(type, "date")) {
        const char *p1 = strchr(value, '-');
        const char *p2 = p1 ? strchr(p1 + 1, '-') : NULL;
        if (p1 && p2 && !strchr(p2 + 1, '-')) {
            char *e0 = xstrndup(value, (size_t)(p1 - value));
            char *e1 = xstrndup(p1 + 1, (size_t)(p2 - p1 - 1));
            char *e2 = xstrdup(p2 + 1);
            long long y = 0, m = 0, d = 0;
            int ok = parse_int_str(e0, &y) && parse_int_str(e1, &m) &&
                     parse_int_str(e2, &d);
            free(e0);
            free(e1);
            free(e2);
            if (ok && y >= 1 && y <= 9999 && m >= 1 && m <= 12 && d >= 1 &&
                d <= days_in_month((int)y, (int)m)) {
                out->kind = V_STR;
                out->str = xstrdup(value);
                return 0;
            }
        }
        return set_err(lineNum, "Invalid date (expected YYYY-MM-DD): '%s'", value);
    }

    return set_err(lineNum, "Unknown type: '%s'", type);
}

/* ------------------------------------------------------------------ */
/* Records                                                             */
/* ------------------------------------------------------------------ */

typedef struct {
    char *label;
    Value v;
} Field;

typedef struct {
    Field *f;
    int n;
    int cap;
} Record;

static void record_add(Record *r, char *label, Value v) {
    if (r->n == r->cap) {
        r->cap = r->cap ? r->cap * 2 : 8;
        r->f = realloc(r->f, sizeof(Field) * (size_t)r->cap);
    }
    r->f[r->n].label = label;
    r->f[r->n].v = v;
    r->n++;
}

static int record_has(Record *r, const char *label) {
    for (int i = 0; i < r->n; i++)
        if (!strcmp(r->f[i].label, label))
            return 1;
    return 0;
}

static Value *record_find(Record *r, const char *label) {
    for (int i = 0; i < r->n; i++)
        if (!strcmp(r->f[i].label, label))
            return &r->f[i].v;
    return NULL;
}

/* Parse a single record line. Returns 0 on success, -1 on error. */
static int parse_record(const char *s, size_t n, int lineNum, DefMap *dm,
                        Record *out) {
    if (n == 0)
        return 0;

    int nr;
    Rune *rs = build_runes(s, n, &nr);
    size_t pos = 0;

    while (pos < (size_t)nr) {
        Buf val;
        buf_init(&val);

        if (rs[pos].cp == '"') {
            /* Wrapped value: honours \" and \\ escapes; a backslash before
             * any other rune is kept literally (SPEC 6.2). */
            size_t i = pos + 1;
            int closed = 0;
            while (i < (size_t)nr) {
                uint32_t c = rs[i].cp;
                if (c == '\\' && i + 1 < (size_t)nr &&
                    (rs[i + 1].cp == '"' || rs[i + 1].cp == '\\')) {
                    char tmp[4];
                    int l = utf8_encode(rs[i + 1].cp, tmp);
                    buf_put(&val, tmp, (size_t)l);
                    i += 2;
                    continue;
                }
                if (c == '"') {
                    closed = 1;
                    i++;
                    break;
                }
                char tmp[4];
                int l = utf8_encode(c, tmp);
                buf_put(&val, tmp, (size_t)l);
                i++;
            }
            if (!closed) {
                buf_free(&val);
                free(rs);
                return set_err(lineNum, "Unterminated quoted value");
            }
            pos = i;
            if (pos >= (size_t)nr) {
                int r = set_err(lineNum, "Missing delimiter after value '%s'",
                                val.data);
                buf_free(&val);
                free(rs);
                return r;
            }
        } else {
            size_t start = pos;
            while (pos < (size_t)nr && !def_find(dm, rs[pos].cp))
                pos++;
            if (pos == (size_t)nr) {
                buf_free(&val);
                free(rs);
                return set_err(
                    lineNum,
                    "No delimiter found for value starting at column %d",
                    (int)start);
            }
            for (size_t k = start; k < pos; k++) {
                char tmp[4];
                int l = utf8_encode(rs[k].cp, tmp);
                buf_put(&val, tmp, (size_t)l);
            }
        }

        uint32_t dc = rs[pos].cp;
        FieldDef *fd = def_find(dm, dc);
        if (!fd) {
            char db[4];
            int l = utf8_encode(dc, db);
            db[l] = '\0';
            int r = set_err(lineNum, "Undefined delimiter: '%s'", db);
            buf_free(&val);
            free(rs);
            return r;
        }

        if (record_has(out, fd->label)) {
            int r = set_err(lineNum, "Duplicate field in record: '%s'",
                            fd->label);
            buf_free(&val);
            free(rs);
            return r;
        }

        Value v;
        if (convert_value(val.data, fd->type, lineNum, &v) != 0) {
            buf_free(&val);
            free(rs);
            return -1;
        }
        buf_free(&val);
        record_add(out, fd->label, v);
        pos++;
    }

    free(rs);
    return 0;
}

/* ------------------------------------------------------------------ */
/* Document                                                            */
/* ------------------------------------------------------------------ */

typedef struct {
    Record *r;
    int n;
    int cap;
} Doc;

typedef struct {
    char *s;
    size_t n;
} Line;

static int parse_document(const char *content, size_t clen, Doc *doc) {
    doc->n = 0;
    doc->cap = 0;
    doc->r = NULL;

    /* Normalise CRLF to LF. */
    char *norm = malloc(clen + 1);
    size_t j = 0;
    for (size_t i = 0; i < clen; i++) {
        if (content[i] == '\r' && i + 1 < clen && content[i + 1] == '\n')
            continue;
        norm[j++] = content[i];
    }
    norm[j] = '\0';
    size_t nlen = j;

    /* Split on LF; each segment gets a NUL terminator. */
    int lcount = 1;
    for (size_t i = 0; i < nlen; i++)
        if (norm[i] == '\n')
            lcount++;
    Line *lines = malloc(sizeof(Line) * (size_t)lcount);
    int li = 0;
    size_t start = 0;
    for (size_t i = 0; i <= nlen; i++) {
        if (i == nlen || norm[i] == '\n') {
            lines[li].s = norm + start;
            lines[li].n = i - start;
            if (i < nlen)
                norm[i] = '\0';
            li++;
            start = i + 1;
        }
    }

    /* A trailing newline produces a spurious final empty element; drop it. */
    if (lcount > 0 && lines[lcount - 1].n == 0)
        lcount--;

    /* First blank line is the section separator. */
    int sep = -1;
    for (int i = 0; i < lcount; i++) {
        if (lines[i].n == 0) {
            sep = i;
            break;
        }
    }
    if (sep < 0) {
        set_err(0, "No blank line separator found between definitions and data");
        free(lines);
        free(norm);
        return -1;
    }

    /* Definitions. */
    DefMap dm;
    dm.d = NULL;
    dm.n = 0;
    dm.cap = 0;
    for (int i = 0; i < sep; i++) {
        if (lines[i].n == 0)
            continue;
        FieldDef fd;
        if (parse_definition(lines[i].s, lines[i].n, i + 1, &fd) != 0) {
            free(lines);
            free(norm);
            return -1;
        }
        FieldDef *ex = def_find(&dm, fd.delim_cp);
        if (ex) {
            char db[4];
            int l = utf8_encode(fd.delim_cp, db);
            db[l] = '\0';
            set_err(i + 1, "Delimiter '%s' already used for field '%s'", db,
                    ex->label);
            free(fd.type);
            free(fd.label);
            free(lines);
            free(norm);
            return -1;
        }
        if (dm.n == dm.cap) {
            dm.cap = dm.cap ? dm.cap * 2 : 8;
            dm.d = realloc(dm.d, sizeof(FieldDef) * (size_t)dm.cap);
        }
        dm.d[dm.n++] = fd;
    }

    /* Records. */
    for (int i = sep + 1; i < lcount; i++) {
        if (lines[i].n == 0)
            continue;
        Record rec;
        rec.f = NULL;
        rec.n = 0;
        rec.cap = 0;
        if (parse_record(lines[i].s, lines[i].n, i + 1, &dm, &rec) != 0) {
            free(lines);
            free(norm);
            return -1;
        }
        if (doc->n == doc->cap) {
            doc->cap = doc->cap ? doc->cap * 2 : 8;
            doc->r = realloc(doc->r, sizeof(Record) * (size_t)doc->cap);
        }
        doc->r[doc->n++] = rec;
    }

    free(lines);
    free(norm);
    return 0;
}

/* ------------------------------------------------------------------ */
/* JSON output                                                         */
/* ------------------------------------------------------------------ */

static void json_escape_into(Buf *b, const char *s) {
    for (const unsigned char *p = (const unsigned char *)s; *p; p++) {
        unsigned char c = *p;
        switch (c) {
            case '"': buf_puts(b, "\\\""); break;
            case '\\': buf_puts(b, "\\\\"); break;
            case '\n': buf_puts(b, "\\n"); break;
            case '\r': buf_puts(b, "\\r"); break;
            case '\t': buf_puts(b, "\\t"); break;
            case '\b': buf_puts(b, "\\b"); break;
            case '\f': buf_puts(b, "\\f"); break;
            default:
                if (c < 0x20) {
                    char t[8];
                    snprintf(t, sizeof t, "\\u%04x", c);
                    buf_puts(b, t);
                } else {
                    buf_putc(b, (char)c);
                }
        }
    }
}

/* Shortest decimal representation that round-trips exactly. */
static void fmt_double(Buf *b, double d) {
    char tmp[64];
    for (int prec = 15; prec <= 17; prec++) {
        snprintf(tmp, sizeof tmp, "%.*g", prec, d);
        if (strtod(tmp, NULL) == d) {
            buf_puts(b, tmp);
            return;
        }
    }
    snprintf(tmp, sizeof tmp, "%.17g", d);
    buf_puts(b, tmp);
}

static void json_value_into(Buf *b, const Value *v) {
    char tmp[64];
    switch (v->kind) {
        case V_STR:
            buf_putc(b, '"');
            json_escape_into(b, v->str);
            buf_putc(b, '"');
            break;
        case V_INT:
            snprintf(tmp, sizeof tmp, "%lld", v->i);
            buf_puts(b, tmp);
            break;
        case V_FLOAT:
            fmt_double(b, v->d);
            break;
        case V_BOOL:
            buf_puts(b, v->b ? "true" : "false");
            break;
    }
}

static void output_json(Doc *doc) {
    if (doc->n == 0) {
        fputs("[]\n", stdout);
        return;
    }

    Buf b;
    buf_init(&b);
    buf_puts(&b, "[\n");
    for (int i = 0; i < doc->n; i++) {
        Record *r = &doc->r[i];
        if (r->n == 0) {
            buf_puts(&b, "  {}");
        } else {
            buf_puts(&b, "  {\n");
            for (int k = 0; k < r->n; k++) {
                buf_puts(&b, "    \"");
                json_escape_into(&b, r->f[k].label);
                buf_puts(&b, "\": ");
                json_value_into(&b, &r->f[k].v);
                if (k + 1 < r->n)
                    buf_putc(&b, ',');
                buf_putc(&b, '\n');
            }
            buf_puts(&b, "  }");
        }
        if (i + 1 < doc->n)
            buf_putc(&b, ',');
        buf_putc(&b, '\n');
    }
    buf_puts(&b, "]\n");
    fputs(b.data, stdout);
    buf_free(&b);
}

/* ------------------------------------------------------------------ */
/* CSV output                                                          */
/* ------------------------------------------------------------------ */

static void csv_escape_into(Buf *b, const char *s) {
    if (!strpbrk(s, ",\"\n")) {
        buf_puts(b, s);
        return;
    }
    buf_putc(b, '"');
    for (const char *p = s; *p; p++) {
        if (*p == '"')
            buf_puts(b, "\"\"");
        else
            buf_putc(b, *p);
    }
    buf_putc(b, '"');
}

/* Render a value the way the Python reference's str() does. */
static void csv_value_into(Buf *b, const Value *v) {
    char tmp[64];
    switch (v->kind) {
        case V_STR:
            csv_escape_into(b, v->str);
            break;
        case V_INT:
            snprintf(tmp, sizeof tmp, "%lld", v->i);
            buf_puts(b, tmp);
            break;
        case V_FLOAT: {
            Buf f;
            buf_init(&f);
            fmt_double(&f, v->d);
            if (!strpbrk(f.data, ".eEni"))
                buf_puts(&f, ".0");
            buf_puts(b, f.data);
            buf_free(&f);
            break;
        }
        case V_BOOL:
            buf_puts(b, v->b ? "True" : "False");
            break;
    }
}

static void output_csv(Doc *doc) {
    if (doc->n == 0) {
        fputs("\n", stdout);
        return;
    }

    /* Keys in first-seen order across all records. */
    char **keys = malloc(sizeof(char *));
    int nk = 0, capk = 1;
    for (int i = 0; i < doc->n; i++) {
        for (int k = 0; k < doc->r[i].n; k++) {
            const char *lab = doc->r[i].f[k].label;
            int found = 0;
            for (int q = 0; q < nk; q++)
                if (!strcmp(keys[q], lab)) {
                    found = 1;
                    break;
                }
            if (!found) {
                if (nk == capk) {
                    capk *= 2;
                    keys = realloc(keys, sizeof(char *) * (size_t)capk);
                }
                keys[nk++] = (char *)lab;
            }
        }
    }

    Buf b;
    buf_init(&b);
    for (int q = 0; q < nk; q++) {
        if (q)
            buf_putc(&b, ',');
        csv_escape_into(&b, keys[q]);
    }
    buf_putc(&b, '\n');
    for (int i = 0; i < doc->n; i++) {
        for (int q = 0; q < nk; q++) {
            if (q)
                buf_putc(&b, ',');
            Value *v = record_find(&doc->r[i], keys[q]);
            if (v)
                csv_value_into(&b, v);
        }
        buf_putc(&b, '\n');
    }
    fputs(b.data, stdout);
    buf_free(&b);
    free(keys);
}

/* ------------------------------------------------------------------ */
/* CLI                                                                 */
/* ------------------------------------------------------------------ */

static int read_file(const char *path, char **out, size_t *outlen) {
    FILE *f = fopen(path, "rb");
    if (!f)
        return -1;
    size_t cap = 65536;
    size_t len = 0;
    char *buf = malloc(cap);
    size_t r;
    while ((r = fread(buf + len, 1, cap - len, f)) > 0) {
        len += r;
        if (len == cap) {
            cap *= 2;
            buf = realloc(buf, cap);
        }
    }
    fclose(f);
    if (len == cap)
        buf = realloc(buf, cap + 1);
    buf[len] = '\0';
    *out = buf;
    *outlen = len;
    return 0;
}

int main(int argc, char **argv) {
    if (argc < 3) {
        fprintf(stderr, "%s\n", USAGE);
        return 1;
    }

    const char *cmd = argv[1];
    const char *path = argv[2];

    char *content;
    size_t clen;
    if (read_file(path, &content, &clen) != 0) {
        fprintf(stderr, "Error: File not found: %s\n", path);
        return 1;
    }

    if (!strcmp(cmd, "parse")) {
        Doc doc;
        if (parse_document(content, clen, &doc) != 0) {
            fprintf(stderr, "Parse error: %s\n", err_string());
            return 1;
        }
        output_json(&doc);
        return 0;
    }

    if (!strcmp(cmd, "validate")) {
        Doc doc;
        if (parse_document(content, clen, &doc) != 0) {
            fprintf(stderr, "Invalid: %s\n", err_string());
            return 1;
        }
        printf("Valid KDG document\n");
        return 0;
    }

    if (!strcmp(cmd, "convert")) {
        const char *fmt = argc > 3 ? argv[3] : "json";
        Doc doc;
        if (parse_document(content, clen, &doc) != 0) {
            fprintf(stderr, "Parse error: %s\n", err_string());
            return 1;
        }
        if (!strcmp(fmt, "json")) {
            output_json(&doc);
            return 0;
        }
        if (!strcmp(fmt, "csv")) {
            output_csv(&doc);
            return 0;
        }
        fprintf(stderr, "Unknown format: %s\n", fmt);
        return 1;
    }

    fprintf(stderr, "Unknown command: %s\n", cmd);
    fprintf(stderr, "%s\n", USAGE);
    return 1;
}
