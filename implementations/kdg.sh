#!/usr/bin/env bash
#
# KDG (Key-Delimiter Grammar) Parser - Bash Implementation
#
# Usage:
#   kdg.sh parse <file>           Parse KDG to JSON
#   kdg.sh validate <file>        Validate KDG syntax
#   kdg.sh convert <file> [fmt]   Convert to format (json, csv)
#
# This implementation has no dependencies beyond bash. It targets bash 3.2
# (the macOS system bash): no associative arrays, no ${var,,}, no mapfile.
# Behaviour mirrors implementations/kdg.go exactly.

# ---------------------------------------------------------------------------
# Globals
# ---------------------------------------------------------------------------

KDG_ERR_MSG=""
KDG_ERR_LINE=0

# Document lines (LF separated, one trailing empty element already dropped).
LINES=()

# Field definitions: parallel indexed arrays.
D_COUNT=0
D_CHAR=()
D_TYPE=()
D_LABEL=()

# Scratch outputs from parse_definition / scan_wrapped / convert_value.
PD_DELIM=""
PD_TYPE=""
PD_LABEL=""
SW_VALUE=""
SW_NEXT=0
CV_VALUE=""

# Fields of every record, in insertion order.
F_COUNT=0
F_KEY=()
F_TYPE=()
F_VAL=()

# One entry per record: index of its first field in the F_* arrays.
REC_COUNT=0
REC_START=()

# Global first-seen key order (for the CSV header).
K_COUNT=0
K_NAME=()

USAGE="Usage: kdg <parse|validate|convert> <file> [json|csv]"

# Characters that may not be used as delimiters (byte-identical to kdg.go's
# reservedCharList). Membership is tested with exact substring matching because
# bash `case` bracket ranges like [a-z] are locale-collated and would match
# uppercase letters under e.g. en_US.UTF-8.
RESERVED_CHAR_LIST=$'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789:" \t\r\n'
ASCII_LOWER="abcdefghijklmnopqrstuvwxyz"

# ---------------------------------------------------------------------------
# Errors
# ---------------------------------------------------------------------------

set_error() {
    KDG_ERR_MSG="$1"
    KDG_ERR_LINE="$2"
}

format_error() {
    if [ "$KDG_ERR_LINE" -gt 0 ] 2>/dev/null; then
        printf 'Line %s: %s' "$KDG_ERR_LINE" "$KDG_ERR_MSG"
    else
        printf '%s' "$KDG_ERR_MSG"
    fi
}

# ---------------------------------------------------------------------------
# Definitions
# ---------------------------------------------------------------------------

# A reserved character may not be used as a delimiter.
is_reserved() {
    if [ -z "$1" ]; then
        return 1
    fi
    case "$RESERVED_CHAR_LIST" in
        *"$1"*) return 0 ;;
        *) return 1 ;;
    esac
}

# Parse one definition line. On success sets PD_TYPE / PD_LABEL / PD_DELIM.
# Mirrors kdg.go parseDefinition (same regex, same unescape order, same errors).
parse_definition() {
    local line="$1" lineno="$2"
    local n=${#line} i=0 c

    # type = [a-z]+
    while [ "$i" -lt "$n" ]; do
        c=${line:$i:1}
        case "$ASCII_LOWER" in
            *"$c"*) i=$((i + 1)) ;;
            *) break ;;
        esac
    done

    # ^([a-z]+):  followed by  "
    if [ "$i" -eq 0 ] || [ "$i" -ge "$n" ] || [ "${line:$i:1}" != ":" ]; then
        set_error "Invalid definition syntax: '$line'" "$lineno"
        return 1
    fi

    local type_name=${line:0:$i}
    local p=$((i + 1))
    if [ "${line:$p:1}" != '"' ]; then
        set_error "Invalid definition syntax: '$line'" "$lineno"
        return 1
    fi
    p=$((p + 1))

    # quoted_label = [^"\\]* ( \\. [^"\\]* )*   (keep the raw escapes for now)
    local raw=""
    while [ "$p" -lt "$n" ]; do
        c=${line:$p:1}
        if [ "$c" = '\' ]; then
            if [ $((p + 1)) -ge "$n" ]; then
                set_error "Invalid definition syntax: '$line'" "$lineno"
                return 1
            fi
            raw="${raw}${c}${line:$((p + 1)):1}"
            p=$((p + 2))
            continue
        fi
        if [ "$c" = '"' ]; then
            break
        fi
        raw="${raw}${c}"
        p=$((p + 1))
    done

    if [ "$p" -ge "$n" ]; then
        set_error "Invalid definition syntax: '$line'" "$lineno"
        return 1
    fi

    # (.)$ : exactly one character remains after the closing quote.
    local rest_pos=$((p + 1))
    if [ $((n - rest_pos)) -ne 1 ]; then
        set_error "Invalid definition syntax: '$line'" "$lineno"
        return 1
    fi
    local delimiter=${line:$rest_pos:1}

    case "$type_name" in
        str|int|float|bool|date) ;;
        *)
            set_error "Unknown type: '$type_name'" "$lineno"
            return 1
            ;;
    esac

    if is_reserved "$delimiter"; then
        set_error "Invalid delimiter: '$delimiter' (reserved character)" "$lineno"
        return 1
    fi

    # Unescape the label. Order matters: \" first, then \\.
    local label=${raw//\\\"/\"}
    label=${label//\\\\/\\}

    PD_TYPE="$type_name"
    PD_LABEL="$label"
    PD_DELIM="$delimiter"
    return 0
}

# Index of a delimiter in D_CHAR, or -1.
delim_index() {
    local c="$1" k
    for ((k = 0; k < D_COUNT; k++)); do
        if [ "${D_CHAR[$k]}" = "$c" ]; then
            printf '%s' "$k"
            return 0
        fi
    done
    printf '%s' "-1"
    return 0
}

has_delim() {
    local c="$1" k
    for ((k = 0; k < D_COUNT; k++)); do
        if [ "${D_CHAR[$k]}" = "$c" ]; then
            return 0
        fi
    done
    return 1
}

# ---------------------------------------------------------------------------
# Values
# ---------------------------------------------------------------------------

# Scan a double-quoted value starting at line[start] == '". Sets SW_VALUE /
# SW_NEXT. Mirrors kdg.go scanWrappedValue.
scan_wrapped() {
    local line="$1" start="$2" lineno="$3"
    local n=${#line} i=$((start + 1)) c nxt
    local out=""

    while [ "$i" -lt "$n" ]; do
        c=${line:$i:1}
        if [ "$c" = '\' ] && [ $((i + 1)) -lt "$n" ]; then
            nxt=${line:$((i + 1)):1}
            if [ "$nxt" = '"' ] || [ "$nxt" = '\' ]; then
                out="${out}${nxt}"
                i=$((i + 2))
                continue
            fi
        fi
        if [ "$c" = '"' ]; then
            SW_VALUE="$out"
            SW_NEXT=$((i + 1))
            return 0
        fi
        out="${out}${c}"
        i=$((i + 1))
    done

    set_error "Unterminated quoted value" "$lineno"
    return 1
}

# True (0) when the string is Atoi-compatible: ^[+-]?[0-9]+$
is_int_str() {
    [[ $1 =~ ^[+-]?[0-9]+$ ]]
}

# Validate an ISO date against kdg.go's rules (year 1..9999, real calendar day).
validate_date() {
    local value="$1" lineno="$2"

    # Must have exactly two dashes (three components).
    case "$value" in
        *-*-*) ;;
        *)
            set_error "Invalid date (expected YYYY-MM-DD): '$value'" "$lineno"
            return 1
            ;;
    esac
    case "$value" in
        *-*-*-*)
            set_error "Invalid date (expected YYYY-MM-DD): '$value'" "$lineno"
            return 1
            ;;
    esac

    local y m d rest
    y=${value%%-*}
    rest=${value#*-}
    m=${rest%%-*}
    d=${rest#*-}

    if ! is_int_str "$y" || ! is_int_str "$m" || ! is_int_str "$d"; then
        set_error "Invalid date (expected YYYY-MM-DD): '$value'" "$lineno"
        return 1
    fi

    local Y=$((10#$y)) M=$((10#$m)) D=$((10#$d))
    if [ "$Y" -lt 1 ] || [ "$Y" -gt 9999 ]; then
        set_error "Invalid date (expected YYYY-MM-DD): '$value'" "$lineno"
        return 1
    fi
    if [ "$M" -lt 1 ] || [ "$M" -gt 12 ]; then
        set_error "Invalid date (expected YYYY-MM-DD): '$value'" "$lineno"
        return 1
    fi
    if [ "$D" -lt 1 ]; then
        set_error "Invalid date (expected YYYY-MM-DD): '$value'" "$lineno"
        return 1
    fi

    local max
    case "$M" in
        1|3|5|7|8|10|12) max=31 ;;
        4|6|9|11) max=30 ;;
        2)
            if [ $((Y % 4)) -eq 0 ] && { [ $((Y % 100)) -ne 0 ] || [ $((Y % 400)) -eq 0 ]; }; then
                max=29
            else
                max=28
            fi
            ;;
    esac

    if [ "$D" -gt "$max" ]; then
        set_error "Invalid date (expected YYYY-MM-DD): '$value'" "$lineno"
        return 1
    fi
    return 0
}

# Convert a raw value to its typed form. Sets CV_VALUE. Mirrors kdg.go
# convertValue.
convert_value() {
    local value="$1" type_name="$2" lineno="$3"

    case "$type_name" in
        str)
            CV_VALUE="$value"
            return 0
            ;;
        int)
            if ! is_int_str "$value"; then
                set_error "Invalid integer: '$value'" "$lineno"
                return 1
            fi
            local neg=0 v="$value"
            case "$v" in
                -*) neg=1; v=${v#-} ;;
                +*) v=${v#+} ;;
            esac
            while [ "${v#0}" != "$v" ]; do
                v=${v#0}
            done
            if [ -z "$v" ]; then
                v=0
            fi
            if [ "$neg" -eq 1 ] && [ "$v" != "0" ]; then
                CV_VALUE="-$v"
            else
                CV_VALUE="$v"
            fi
            return 0
            ;;
        float)
            if [[ ! $value =~ ^[+-]?([0-9]+(\.[0-9]*)?|\.[0-9]+)([eE][+-]?[0-9]+)?$ ]]; then
                set_error "Invalid float: '$value'" "$lineno"
                return 1
            fi
            # Normalise to a valid JSON number: drop a leading '+', strip
            # leading zeros in the integer part, and make a bare '.5' / '5.'
            # well-formed.
            local v="$value" exp=""
            case "$v" in
                +*) v=${v#+} ;;
            esac
            case "$v" in
                *[eE]*)
                    exp="${v#*[eE]}"
                    v="${v%%[eE]*}"
                    ;;
            esac
            local sign=""
            case "$v" in
                -*) sign="-"; v=${v#-} ;;
            esac
            local ipart fpart
            case "$v" in
                *.*)
                    ipart="${v%%.*}"
                    fpart="${v#*.}"
                    ;;
                *)
                    ipart="$v"
                    fpart=""
                    ;;
            esac
            while [ "${ipart#0}" != "$ipart" ]; do
                ipart=${ipart#0}
            done
            if [ -z "$ipart" ]; then
                ipart=0
            fi
            while [ "${fpart%0}" != "$fpart" ]; do
                fpart=${fpart%0}
            done
            if [ -n "$fpart" ]; then
                v="${sign}${ipart}.${fpart}"
            else
                v="${sign}${ipart}"
            fi
            if [ -n "$exp" ]; then
                v="${v}e${exp}"
            fi
            CV_VALUE="$v"
            return 0
            ;;
        bool)
            case "$value" in
                [Tt][Rr][Uu][Ee]|1)
                    CV_VALUE="true"
                    return 0
                    ;;
                [Ff][Aa][Ll][Ss][Ee]|0)
                    CV_VALUE="false"
                    return 0
                    ;;
            esac
            set_error "Invalid boolean: '$value'" "$lineno"
            return 1
            ;;
        date)
            if ! validate_date "$value" "$lineno"; then
                return 1
            fi
            CV_VALUE="$value"
            return 0
            ;;
        *)
            set_error "Unknown type: '$type_name'" "$lineno"
            return 1
            ;;
    esac
}

# ---------------------------------------------------------------------------
# Records
# ---------------------------------------------------------------------------

add_key() {
    local key="$1" k
    for ((k = 0; k < K_COUNT; k++)); do
        if [ "${K_NAME[$k]}" = "$key" ]; then
            return 0
        fi
    done
    K_NAME[$K_COUNT]="$key"
    K_COUNT=$((K_COUNT + 1))
    return 0
}

# Parse one record line into the F_* arrays. Mirrors kdg.go parseRecord.
parse_record() {
    local line="$1" lineno="$2" recindex="$3"
    local n=${#line} pos=0
    local value start c delim idx j

    while [ "$pos" -lt "$n" ]; do
        c=${line:$pos:1}
        if [ "$c" = '"' ]; then
            if ! scan_wrapped "$line" "$pos" "$lineno"; then
                return 1
            fi
            value="$SW_VALUE"
            pos="$SW_NEXT"
            if [ "$pos" -ge "$n" ]; then
                set_error "Missing delimiter after value '$value'" "$lineno"
                return 1
            fi
        else
            start=$pos
            while [ "$pos" -lt "$n" ]; do
                c=${line:$pos:1}
                if has_delim "$c"; then
                    break
                fi
                pos=$((pos + 1))
            done
            if [ "$pos" -eq "$n" ]; then
                set_error "No delimiter found for value starting at column $start" "$lineno"
                return 1
            fi
            value=${line:$start:$((pos - start))}
        fi

        delim=${line:$pos:1}
        idx=$(delim_index "$delim")
        if [ "$idx" -lt 0 ]; then
            set_error "Undefined delimiter: '$delim'" "$lineno"
            return 1
        fi

        local label="${D_LABEL[$idx]}" typ="${D_TYPE[$idx]}"

        j=${REC_START[$recindex]}
        while [ "$j" -lt "$F_COUNT" ]; do
            if [ "${F_KEY[$j]}" = "$label" ]; then
                set_error "Duplicate field in record: '$label'" "$lineno"
                return 1
            fi
            j=$((j + 1))
        done

        if ! convert_value "$value" "$typ" "$lineno"; then
            return 1
        fi

        F_KEY[$F_COUNT]="$label"
        F_TYPE[$F_COUNT]="$typ"
        F_VAL[$F_COUNT]="$CV_VALUE"
        F_COUNT=$((F_COUNT + 1))

        add_key "$label"

        pos=$((pos + 1))
    done

    return 0
}

# ---------------------------------------------------------------------------
# Document parsing
# ---------------------------------------------------------------------------

# Read a file into LINES, normalising CRLF and matching kdg.go's line handling
# (split on LF, drop one trailing empty element).
read_lines() {
    LINES=()
    local line
    # `read` consumes the final newline, so a normal LF-terminated file yields
    # no spurious trailing empty element (equivalent to Go's explicit drop).
    while IFS= read -r line; do
        LINES+=("${line%$'\r'}")
    done < "$1"
    # A file without a final newline leaves its last line pending.
    if [ -n "$line" ]; then
        LINES+=("$line")
    fi
}

parse() {
    local file="$1"
    read_lines "$file"
    local n=${#LINES[@]}

    # Find the separator (first blank line).
    local sep=-1 i
    for ((i = 0; i < n; i++)); do
        if [ "${LINES[$i]}" = "" ]; then
            sep=$i
            break
        fi
    done
    if [ "$sep" -lt 0 ]; then
        set_error "No blank line separator found between definitions and data" 0
        return 1
    fi

    # Parse definitions.
    D_COUNT=0
    D_CHAR=()
    D_TYPE=()
    D_LABEL=()
    for ((i = 0; i < sep; i++)); do
        local defline="${LINES[$i]}"
        if [ -z "$defline" ]; then
            continue
        fi
        if ! parse_definition "$defline" $((i + 1)); then
            return 1
        fi
        local k existing=-1
        for ((k = 0; k < D_COUNT; k++)); do
            if [ "${D_CHAR[$k]}" = "$PD_DELIM" ]; then
                existing=$k
                break
            fi
        done
        if [ "$existing" -ge 0 ]; then
            set_error "Delimiter '$PD_DELIM' already used for field '${D_LABEL[$existing]}'" $((i + 1))
            return 1
        fi
        D_CHAR[$D_COUNT]="$PD_DELIM"
        D_TYPE[$D_COUNT]="$PD_TYPE"
        D_LABEL[$D_COUNT]="$PD_LABEL"
        D_COUNT=$((D_COUNT + 1))
    done

    # Parse records.
    F_COUNT=0
    F_KEY=()
    F_TYPE=()
    F_VAL=()
    REC_COUNT=0
    REC_START=()
    K_COUNT=0
    K_NAME=()
    for ((i = sep + 1; i < n; i++)); do
        local recline="${LINES[$i]}"
        if [ -z "$recline" ]; then
            continue
        fi
        REC_START[$REC_COUNT]="$F_COUNT"
        if ! parse_record "$recline" $((i + 1)) "$REC_COUNT"; then
            return 1
        fi
        REC_COUNT=$((REC_COUNT + 1))
    done

    return 0
}

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------

json_escape() {
    local s="$1"
    s=${s//\\/\\\\}
    s=${s//\"/\\\"}
    s=${s//$'\t'/\\t}
    s=${s//$'\r'/\\r}
    s=${s//$'\n'/\\n}
    printf '%s' "$s"
}

emit_json_value() {
    local type_name="$1" val="$2"
    case "$type_name" in
        str|date)
            printf '"%s"' "$(json_escape "$val")"
            ;;
        int|float|bool)
            printf '%s' "$val"
            ;;
    esac
}

emit_json() {
    if [ "$REC_COUNT" -eq 0 ]; then
        printf '[]\n'
        return 0
    fi

    printf '[\n'
    local r=0
    while [ "$r" -lt "$REC_COUNT" ]; do
        printf '  {\n'
        local start=${REC_START[$r]} end k
        if [ "$r" -lt $((REC_COUNT - 1)) ]; then
            end=${REC_START[$((r + 1))]}
        else
            end=$F_COUNT
        fi
        k=$start
        local first=1
        while [ "$k" -lt "$end" ]; do
            if [ "$first" -eq 1 ]; then
                first=0
            else
                printf ',\n'
            fi
            printf '    "%s": ' "$(json_escape "${F_KEY[$k]}")"
            emit_json_value "${F_TYPE[$k]}" "${F_VAL[$k]}"
            k=$((k + 1))
        done
        printf '\n  }'
        if [ "$r" -lt $((REC_COUNT - 1)) ]; then
            printf ','
        fi
        printf '\n'
        r=$((r + 1))
    done
    printf ']\n'
    return 0
}

csv_escape() {
    local s="$1"
    case "$s" in
        *","*|*'"'*|*$'\n'*)
            s=${s//\"/\"\"}
            printf '"%s"' "$s"
            ;;
        *)
            printf '%s' "$s"
            ;;
    esac
}

csv_value() {
    local type_name="$1" val="$2"
    case "$type_name" in
        bool)
            if [ "$val" = "true" ]; then
                printf 'True'
            else
                printf 'False'
            fi
            ;;
        float)
            case "$val" in
                *[.eEni]*) printf '%s' "$val" ;;
                *) printf '%s.0' "$val" ;;
            esac
            ;;
        *)
            printf '%s' "$val"
            ;;
    esac
}

emit_csv() {
    if [ "$REC_COUNT" -eq 0 ]; then
        printf '\n'
        return 0
    fi

    local header="" k
    for ((k = 0; k < K_COUNT; k++)); do
        local e
        e=$(csv_escape "${K_NAME[$k]}")
        if [ "$k" -eq 0 ]; then
            header="$e"
        else
            header="$header,$e"
        fi
    done
    printf '%s\n' "$header"

    local r=0
    while [ "$r" -lt "$REC_COUNT" ]; do
        local start=${REC_START[$r]} end f
        if [ "$r" -lt $((REC_COUNT - 1)) ]; then
            end=${REC_START[$((r + 1))]}
        else
            end=$F_COUNT
        fi

        local row=""
        for ((k = 0; k < K_COUNT; k++)); do
            local key="${K_NAME[$k]}" val=""
            f=$start
            while [ "$f" -lt "$end" ]; do
                if [ "${F_KEY[$f]}" = "$key" ]; then
                    val=$(csv_value "${F_TYPE[$f]}" "${F_VAL[$f]}")
                    break
                fi
                f=$((f + 1))
            done
            local e
            e=$(csv_escape "$val")
            if [ "$k" -eq 0 ]; then
                row="$e"
            else
                row="$row,$e"
            fi
        done
        printf '%s\n' "$row"
        r=$((r + 1))
    done
    return 0
}

# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

usage() {
    printf '%s\n' "$USAGE" >&2
}

main() {
    if [ "$#" -lt 2 ]; then
        usage
        exit 1
    fi

    local command="$1" filepath="$2"

    if [ ! -e "$filepath" ]; then
        printf 'Error: File not found: %s\n' "$filepath" >&2
        exit 1
    fi

    case "$command" in
        parse)
            if ! parse "$filepath"; then
                printf 'Parse error: %s\n' "$(format_error)" >&2
                exit 1
            fi
            emit_json
            exit 0
            ;;
        validate)
            if parse "$filepath"; then
                printf 'Valid KDG document\n'
                exit 0
            fi
            printf 'Invalid: %s\n' "$(format_error)" >&2
            exit 1
            ;;
        convert)
            local format="json"
            if [ "$#" -gt 2 ]; then
                format="$3"
            fi
            if ! parse "$filepath"; then
                printf 'Parse error: %s\n' "$(format_error)" >&2
                exit 1
            fi
            case "$format" in
                json)
                    emit_json
                    ;;
                csv)
                    emit_csv
                    ;;
                *)
                    printf 'Unknown format: %s\n' "$format" >&2
                    exit 1
                    ;;
            esac
            exit 0
            ;;
        *)
            printf 'Unknown command: %s\n' "$command" >&2
            usage
            exit 1
            ;;
    esac
}

main "$@"
