#!/usr/bin/env tclsh
# KDG (Key-Delimiter Grammar) Parser - Reference Implementation
#
# Usage:
#     tclsh kdg.tcl parse <file>           Parse KDG to JSON
#     tclsh kdg.tcl validate <file>        Validate KDG syntax
#     tclsh kdg.tcl convert <file> [fmt]   Convert to format (json, csv)
#
# This implementation has no dependencies beyond the Tcl standard library
# (Tcl 8.5 or newer).
#
# Behaviour mirrors implementations/kdg.go (the canonical reference): same
# accept/reject decisions, same error messages, same line-number prefixing.

package require Tcl 8.5

set VALID_TYPES {str int float bool date}

# Characters that cannot be delimiters (SPEC 3.4). The trailing escapes in the
# double-quoted string supply space, tab, newline and carriage return.
set RESERVED_CHARS "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789:\" \t\n\r"

# Definition-line grammar, identical to the Python/Go reference pattern.
set DEFINITION_PATTERN {^([a-z]+):"((?:[^"\\]|\\.)*)"(.)$}

# Strict whole-string integer/float grammars. They reject surrounding
# whitespace (matching Go's strconv) while allowing the decimal and scientific
# forms the reference parsers accept.
set INT_PATTERN {^[+-]?[0-9]+$}
set FLOAT_PATTERN {^[+-]?(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)(?:[eE][+-]?[0-9]+)?$}

set USAGE "Usage: kdg <parse|validate|convert> <file> \[json|csv\]"

# Raise a KDG parse error. A line of 0 means the error is document-wide
# (only MissingSeparator), so no "Line <n>: " prefix is added.
proc kdg_error {message {line 0}} {
    if {$line > 0} {
        return -code error -errorcode KDG "Line $line: $message"
    }
    return -code error -errorcode KDG $message
}

# Parse a single field definition line; returns {type_name label delimiter}.
proc parse_definition {line line_num} {
    global VALID_TYPES RESERVED_CHARS DEFINITION_PATTERN

    if {![regexp $DEFINITION_PATTERN $line -> type_name raw_label delimiter]} {
        kdg_error "Invalid definition syntax: '$line'" $line_num
    }

    if {[lsearch -exact $VALID_TYPES $type_name] < 0} {
        kdg_error "Unknown type: '$type_name'" $line_num
    }

    if {[string first $delimiter $RESERVED_CHARS] >= 0} {
        kdg_error "Invalid delimiter: '$delimiter' (reserved character)" $line_num
    }

    # Unescape the label: \" first, then \\ (order matters).
    set label [string map [list {\"} {"}] $raw_label]
    set label [string map [list "\\\\" "\\"] $label]

    return [list $type_name $label $delimiter]
}

# Return 1 if (year, month, day) is a real proleptic-Gregorian calendar day.
proc valid_date {y m d} {
    if {$m < 1 || $m > 12 || $d < 1} {
        return 0
    }
    set days_in_month {31 28 31 30 31 30 31 31 30 31 30 31}
    set max_day [lindex $days_in_month [expr {$m - 1}]]
    if {$m == 2 && (($y % 4 == 0 && $y % 100 != 0) || $y % 400 == 0)} {
        set max_day 29
    }
    return [expr {$d <= $max_day}]
}

# Escape a string into a JSON string literal, including the surrounding quotes.
proc json_string {s} {
    set out "\""
    foreach c [split $s ""] {
        switch -exact -- $c {
            "\"" { append out "\\\"" }
            "\\" { append out "\\\\" }
            "\n" { append out "\\n" }
            "\r" { append out "\\r" }
            "\t" { append out "\\t" }
            default {
                if {[scan $c %c] < 32} {
                    append out [format "\\u%04x" [scan $c %c]]
                } else {
                    append out $c
                }
            }
        }
    }
    append out "\""
    return $out
}

# Convert a raw value to a typed representation. Returns {json_text csv_text}.
proc convert_value {value type_name line_num} {
    global INT_PATTERN FLOAT_PATTERN

    switch -exact -- $type_name {
        str {
            return [list [json_string $value] $value]
        }
        int {
            if {[regexp $INT_PATTERN $value]} {
                set parsed [expr {$value + 0}]
                # Tcl has arbitrary-precision integers; bound the result to the
                # 64-bit range the Go reference accepts (strconv.Atoi).
                if {$parsed >= -9223372036854775808 && $parsed <= 9223372036854775807} {
                    return [list $parsed $parsed]
                }
            }
            kdg_error "Invalid integer: '$value'" $line_num
        }
        float {
            if {[regexp $FLOAT_PATTERN $value]} {
                set parsed [expr {double($value)}]
                # Reject Inf/NaN so JSON output stays valid.
                if {$parsed == $parsed && abs($parsed) <= 1.7976931348623157e308} {
                    return [list $parsed $parsed]
                }
            }
            kdg_error "Invalid float: '$value'" $line_num
        }
        bool {
            set lower [string tolower $value]
            if {$lower eq "true" || $lower eq "1"} {
                return [list true True]
            }
            if {$lower eq "false" || $lower eq "0"} {
                return [list false False]
            }
            kdg_error "Invalid boolean: '$value'" $line_num
        }
        date {
            set parts [split $value "-"]
            if {[llength $parts] == 3} {
                lassign $parts ys ms ds
                if {[regexp $INT_PATTERN $ys] && [regexp $INT_PATTERN $ms] && [regexp $INT_PATTERN $ds]} {
                    set y [expr {$ys + 0}]
                    set m [expr {$ms + 0}]
                    set d [expr {$ds + 0}]
                    if {$y >= 1 && $y <= 9999 && [valid_date $y $m $d]} {
                        return [list [json_string $value] $value]
                    }
                }
            }
            kdg_error "Invalid date (expected YYYY-MM-DD): '$value'" $line_num
        }
    }

    kdg_error "Unknown type: '$type_name'" $line_num
}

# Scan a double-quoted value beginning at character $start == '"'. Returns
# {value position_after_closing_quote}. Backslash escapes for \" and \\ are
# honoured (SPEC 6.2).
proc scan_wrapped_value {line start line_num} {
    set chars ""
    set n [string length $line]
    set i [expr {$start + 1}]
    while {$i < $n} {
        set c [string index $line $i]
        if {$c eq "\\" && $i + 1 < $n} {
            set next [string index $line [expr {$i + 1}]]
            if {$next eq "\"" || $next eq "\\"} {
                append chars $next
                incr i 2
                continue
            }
        }
        if {$c eq "\""} {
            return [list $chars [expr {$i + 1}]]
        }
        append chars $c
        incr i
    }
    kdg_error "Unterminated quoted value" $line_num
}

# Parse a single record line. Returns {values_dict keys_list}, where
# values_dict maps label -> {json_text csv_text} and keys_list preserves
# first-seen order.
proc parse_record {line delim_map delim_chars line_num} {
    set values [dict create]
    set keys {}
    if {$line eq ""} {
        return [list $values $keys]
    }

    set n [string length $line]
    set pos 0
    while {$pos < $n} {
        if {[string index $line $pos] eq "\""} {
            lassign [scan_wrapped_value $line $pos $line_num] value pos
            if {$pos >= $n} {
                kdg_error "Missing delimiter after value '$value'" $line_num
            }
        } else {
            set start $pos
            while {$pos < $n} {
                if {[string first [string index $line $pos] $delim_chars] >= 0} {
                    break
                }
                incr pos
            }
            if {$pos >= $n} {
                # Column is a 0-based character index, like the Go/Python refs.
                kdg_error "No delimiter found for value starting at column $start" $line_num
            }
            set value [string range $line $start [expr {$pos - 1}]]
        }

        set delimiter [string index $line $pos]
        if {![dict exists $delim_map $delimiter]} {
            kdg_error "Undefined delimiter: '$delimiter'" $line_num
        }
        lassign [dict get $delim_map $delimiter] type_name label

        if {[dict exists $values $label]} {
            kdg_error "Duplicate field in record: '$label'" $line_num
        }

        dict set values $label [convert_value $value $type_name $line_num]
        lappend keys $label
        incr pos
    }

    return [list $values $keys]
}

# Parse a KDG document into a list of records.
proc parse_document {content} {
    set normalized [string map [list "\r\n" "\n"] $content]
    set lines [split $normalized "\n"]

    # A trailing newline produces a spurious final empty element; drop one so a
    # document without a blank-line separator reports MissingSeparator instead
    # of misreading its first record as a definition.
    if {[llength $lines] > 0 && [lindex $lines end] eq ""} {
        set lines [lrange $lines 0 end-1]
    }

    set separator_idx -1
    set i 0
    foreach line $lines {
        if {$line eq ""} {
            set separator_idx $i
            break
        }
        incr i
    }
    if {$separator_idx < 0} {
        kdg_error "No blank line separator found between definitions and data" 0
    }

    set delim_map [dict create]
    set delim_chars ""
    for {set j 0} {$j < $separator_idx} {incr j} {
        set line [lindex $lines $j]
        if {$line eq ""} {
            continue
        }

        lassign [parse_definition $line [expr {$j + 1}]] type_name label delimiter
        if {[dict exists $delim_map $delimiter]} {
            lassign [dict get $delim_map $delimiter] existing_type existing_label
            kdg_error "Delimiter '$delimiter' already used for field '$existing_label'" [expr {$j + 1}]
        }
        dict set delim_map $delimiter [list $type_name $label]
        append delim_chars $delimiter
    }

    set records {}
    set n [llength $lines]
    for {set j [expr {$separator_idx + 1}]} {$j < $n} {incr j} {
        set line [lindex $lines $j]
        if {$line eq ""} {
            continue
        }
        lappend records [parse_record $line $delim_map $delim_chars [expr {$j + 1}]]
    }

    return $records
}

# Convert records to a JSON string with 2-space indentation and a trailing newline.
proc to_json {records} {
    if {[llength $records] == 0} {
        return "\[\]\n"
    }

    set out "\[\n"
    set nrec [llength $records]
    set ri 0
    foreach record $records {
        lassign $record values keys
        append out "  \{"
        if {[llength $keys] == 0} {
            append out "\}"
        } else {
            append out "\n"
            set nk [llength $keys]
            set ki 0
            foreach key $keys {
                append out "    [json_string $key]: [lindex [dict get $values $key] 0]"
                incr ki
                if {$ki < $nk} {
                    append out ","
                }
                append out "\n"
            }
            append out "  \}"
        }
        incr ri
        if {$ri < $nrec} {
            append out ","
        }
        append out "\n"
    }
    append out "\]\n"
    return $out
}

# Quote a CSV field containing a comma, double quote, or newline.
proc escape_csv {s} {
    if {[string first "," $s] >= 0 || [string first "\"" $s] >= 0 || [string first "\n" $s] >= 0} {
        return "\"[string map [list "\"" "\"\""] $s]\""
    }
    return $s
}

# Convert records to a CSV string (first-seen header order).
proc to_csv {records} {
    if {[llength $records] == 0} {
        return ""
    }

    set all_keys {}
    set seen {}
    foreach record $records {
        lassign $record values keys
        foreach key $keys {
            if {[lsearch -exact $seen $key] < 0} {
                lappend seen $key
                lappend all_keys $key
            }
        }
    }

    set lines {}
    set header {}
    foreach key $all_keys {
        lappend header [escape_csv $key]
    }
    lappend lines [join $header ","]

    foreach record $records {
        lassign $record values keys
        set row {}
        foreach key $all_keys {
            if {[dict exists $values $key]} {
                set text [lindex [dict get $values $key] 1]
            } else {
                set text ""
            }
            lappend row [escape_csv $text]
        }
        lappend lines [join $row ","]
    }

    return [join $lines "\n"]
}

# --- CLI --------------------------------------------------------------------

if {[llength $argv] < 2} {
    puts stderr $USAGE
    exit 1
}

set command [lindex $argv 0]
set filepath [lindex $argv 1]

if {![file exists $filepath]} {
    puts stderr "Error: File not found: $filepath"
    exit 1
}

if {[catch {
    set fh [open $filepath r]
    fconfigure $fh -encoding utf-8
    set content [read $fh]
    close $fh
} read_error]} {
    puts stderr "Error reading file: $read_error"
    exit 1
}

if {$command eq "parse"} {
    if {[catch {set records [parse_document $content]} err]} {
        puts stderr "Parse error: $err"
        exit 1
    }
    puts -nonewline [to_json $records]
    exit 0
} elseif {$command eq "validate"} {
    if {[catch {parse_document $content} err]} {
        puts stderr "Invalid: $err"
        exit 1
    }
    puts "Valid KDG document"
    exit 0
} elseif {$command eq "convert"} {
    set format "json"
    if {[llength $argv] >= 3} {
        set format [lindex $argv 2]
    }
    if {[catch {set records [parse_document $content]} err]} {
        puts stderr "Parse error: $err"
        exit 1
    }
    if {$format eq "json"} {
        puts -nonewline [to_json $records]
    } elseif {$format eq "csv"} {
        puts [to_csv $records]
    } else {
        puts stderr "Unknown format: $format"
        exit 1
    }
    exit 0
} else {
    puts stderr "Unknown command: $command"
    puts stderr $USAGE
    exit 1
}
