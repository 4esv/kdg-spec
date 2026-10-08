#!/usr/bin/env perl
#
# KDG (Key-Delimiter Grammar) Parser - Perl implementation
#
# Usage:
#   perl kdg.pl parse <file>           Parse KDG to JSON
#   perl kdg.pl validate <file>        Validate KDG syntax
#   perl kdg.pl convert <file> [fmt]   Convert to format (json, csv)
#
# This implementation has no dependencies beyond the Perl core.
use strict;
use warnings;
use open qw(:std :encoding(UTF-8));

my $USAGE = 'Usage: kdg <parse|validate|convert> <file> [json|csv]';

# Same shape as the Go/Python/JavaScript reference implementations.
my $DEFINITION_PATTERN = qr/\A([a-z]+):"((?:[^"\\]|\\.)*)"(.)\z/;

my %VALID_TYPES = map { $_ => 1 } qw(str int float bool date);

# Characters that cannot be delimiters (SPEC 3.4).
my %RESERVED_CHARS;
for my $c (split //, 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789:" ' . "\t\n\r") {
    $RESERVED_CHARS{$c} = 1;
}

# Throw a KDG error that carries an optional line number. Blessed hashrefs keep
# the message and line separate so the caller can format them canonically.
sub kdg_error {
    my ($message, $line) = @_;
    return bless { message => $message, line => $line }, 'KDGError';
}

sub error_text {
    my ($err) = @_;
    if (ref $err eq 'KDGError') {
        return $err->{line} ? "Line $err->{line}: $err->{message}" : $err->{message};
    }
    my $text = "$err";
    chomp $text;
    return $text;
}

sub is_int_string {
    my ($value) = @_;
    return $value =~ /\A[+-]?[0-9]+\z/;
}

sub is_float_string {
    my ($value) = @_;
    return $value =~ /\A[+-]?(?:[0-9]+\.?[0-9]*|\.[0-9]+)(?:[eE][+-]?[0-9]+)?\z/;
}

sub is_leap_year {
    my ($year) = @_;
    return ($year % 4 == 0 && $year % 100 != 0) || $year % 400 == 0;
}

sub is_real_date {
    my ($year, $month, $day) = @_;
    return 0 if $month < 1 || $month > 12 || $day < 1;
    my @month_days = (31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31);
    my $max = $month_days[$month - 1];
    $max = 29 if $month == 2 && is_leap_year($year);
    return $day <= $max;
}

# Parse a single definition line. Returns (type_name, label, delimiter).
sub parse_definition {
    my ($line, $line_num) = @_;
    if ($line !~ $DEFINITION_PATTERN) {
        die kdg_error("Invalid definition syntax: '$line'", $line_num);
    }
    my $type_name = $1;
    my $raw_label = $2;
    my $delimiter = $3;

    if (!$VALID_TYPES{$type_name}) {
        die kdg_error("Unknown type: '$type_name'", $line_num);
    }

    if ($RESERVED_CHARS{$delimiter}) {
        die kdg_error("Invalid delimiter: '$delimiter' (reserved character)", $line_num);
    }

    # Unescape the label. Order matters: \" first, then \\.
    my $label = $raw_label;
    $label =~ s/\\"/"/g;
    $label =~ s/\\\\/\\/g;

    return ($type_name, $label, $delimiter);
}

# Convert a string value to a tagged cell [kind, value]. The tag is what lets
# the JSON writer distinguish a string "42" from an integer 42.
sub convert_value {
    my ($value, $type_name, $line_num) = @_;

    if ($type_name eq 'str') {
        return ['str', $value];
    }
    if ($type_name eq 'int') {
        die kdg_error("Invalid integer: '$value'", $line_num) unless is_int_string($value);
        return ['int', $value + 0];
    }
    if ($type_name eq 'float') {
        die kdg_error("Invalid float: '$value'", $line_num) unless is_float_string($value);
        return ['float', $value + 0];
    }
    if ($type_name eq 'bool') {
        my $lower = lc $value;
        return ['bool', 1] if $lower eq 'true' || $lower eq '1';
        return ['bool', 0] if $lower eq 'false' || $lower eq '0';
        die kdg_error("Invalid boolean: '$value'", $line_num);
    }
    if ($type_name eq 'date') {
        my @parts = split /-/, $value, -1;
        if (@parts == 3 && is_int_string($parts[0]) && is_int_string($parts[1]) && is_int_string($parts[2])) {
            my ($year, $month, $day) = ($parts[0] + 0, $parts[1] + 0, $parts[2] + 0);
            if ($year >= 1 && $year <= 9999 && is_real_date($year, $month, $day)) {
                return ['date', $value]; # Returned as its string form for JSON compatibility.
            }
        }
        die kdg_error("Invalid date (expected YYYY-MM-DD): '$value'", $line_num);
    }
    die kdg_error("Unknown type: '$type_name'", $line_num);
}

# Scan a double-quoted value starting at $line[$start] eq '"'. Returns
# (value, position_after_closing_quote). Backslash escapes for \" and \\ are
# honoured per SPEC 6.2.
sub scan_wrapped_value {
    my ($line, $start, $line_num) = @_;
    my $chars = '';
    my $length = length $line;
    my $i = $start + 1;
    while ($i < $length) {
        my $c = substr($line, $i, 1);
        if ($c eq '\\' && $i + 1 < $length && (substr($line, $i + 1, 1) eq '"' || substr($line, $i + 1, 1) eq '\\')) {
            $chars .= substr($line, $i + 1, 1);
            $i += 2;
            next;
        }
        if ($c eq '"') {
            return ($chars, $i + 1);
        }
        $chars .= $c;
        $i += 1;
    }
    die kdg_error('Unterminated quoted value', $line_num);
}

# Parse a single record line. Keeps first-seen label order in a parallel array
# because Perl hashes are unordered.
sub parse_record {
    my ($line, $delimiter_map, $line_num) = @_;
    my %values;
    my @keys;
    if ($line eq '') {
        return { values => \%values, keys => \@keys };
    }

    my $length = length $line;
    my $position = 0;
    while ($position < $length) {
        my $value;

        # A field is value-then-delimiter. The value may be wrapped in double
        # quotes, which lets it contain delimiter characters (SPEC 6.2).
        if (substr($line, $position, 1) eq '"') {
            ($value, $position) = scan_wrapped_value($line, $position, $line_num);
            if ($position >= $length) {
                die kdg_error("Missing delimiter after value '$value'", $line_num);
            }
        } else {
            my $start = $position;
            while ($position < $length && !exists $delimiter_map->{substr($line, $position, 1)}) {
                $position += 1;
            }
            if ($position == $length) {
                die kdg_error("No delimiter found for value starting at column $start", $line_num);
            }
            $value = substr($line, $start, $position - $start);
        }

        my $delimiter = substr($line, $position, 1);
        my $field = $delimiter_map->{$delimiter};
        if (!$field) {
            die kdg_error("Undefined delimiter: '$delimiter'", $line_num);
        }
        if (exists $values{$field->{label}}) {
            die kdg_error("Duplicate field in record: '$field->{label}'", $line_num);
        }

        $values{$field->{label}} = convert_value($value, $field->{type}, $line_num);
        push @keys, $field->{label};
        $position += 1;
    }

    return { values => \%values, keys => \@keys };
}

# Parse a KDG document into an arrayref of records.
sub parse_kdg {
    my ($content) = @_;
    $content =~ s/\r\n/\n/g;
    my @lines = split /\n/, $content, -1;

    # A trailing newline produces a spurious final empty element. Drop one so a
    # document with no blank-line separator is reported as MissingSeparator
    # instead of having its first record misread as a definition.
    pop @lines if @lines && $lines[-1] eq '';

    # Find the separator (blank line).
    my $separator_idx = -1;
    for my $i (0 .. $#lines) {
        if ($lines[$i] eq '') {
            $separator_idx = $i;
            last;
        }
    }
    if ($separator_idx < 0) {
        die kdg_error('No blank line separator found between definitions and data');
    }

    my %delimiter_map;
    for my $i (0 .. $separator_idx - 1) {
        my $line = $lines[$i];
        next if $line eq ''; # Skip empty lines in the definition block.

        my ($type_name, $label, $delimiter) = parse_definition($line, $i + 1);

        if (exists $delimiter_map{$delimiter}) {
            my $existing = $delimiter_map{$delimiter};
            die kdg_error("Delimiter '$delimiter' already used for field '$existing->{label}'", $i + 1);
        }

        $delimiter_map{$delimiter} = { type => $type_name, label => $label, delimiter => $delimiter };
    }

    my @records;
    for my $i ($separator_idx + 1 .. $#lines) {
        my $line = $lines[$i];
        next if $line eq ''; # Skip empty lines in the data block.

        push @records, parse_record($line, \%delimiter_map, $i + 1);
    }

    return \@records;
}

# Escape a string for a JSON string literal. Non-ASCII characters pass through
# raw (never escaped).
sub json_escape {
    my ($str) = @_;
    my $out = '';
    for my $c (split //, $str) {
        if ($c eq '"') {
            $out .= '\\"';
        } elsif ($c eq '\\') {
            $out .= '\\\\';
        } elsif ($c eq "\n") {
            $out .= '\\n';
        } elsif ($c eq "\r") {
            $out .= '\\r';
        } elsif ($c eq "\t") {
            $out .= '\\t';
        } elsif ($c eq "\x08") {
            $out .= '\\b';
        } elsif ($c eq "\x0c") {
            $out .= '\\f';
        } elsif (ord($c) < 0x20) {
            $out .= sprintf('\\u%04x', ord($c));
        } else {
            $out .= $c;
        }
    }
    return $out;
}

# Render a float the way Python's str() does: keep a decimal point so an
# integral float like 42.0 does not collapse to 42.
sub float_text {
    my ($number) = @_;
    my $text = "$number";
    $text .= '.0' if $text !~ /[.eE]/;
    return $text;
}

sub cell_json {
    my ($cell) = @_;
    my ($kind, $value) = @$cell;
    if ($kind eq 'str' || $kind eq 'date') {
        return '"' . json_escape($value) . '"';
    }
    if ($kind eq 'bool') {
        return $value ? 'true' : 'false';
    }
    if ($kind eq 'int') {
        return "$value";
    }
    if ($kind eq 'float') {
        return float_text($value);
    }
    return 'null';
}

sub record_json {
    my ($record) = @_;
    my @keys = @{ $record->{keys} };
    return '  {}' unless @keys;

    my @fields;
    for my $key (@keys) {
        push @fields, '    "' . json_escape($key) . '": ' . cell_json($record->{values}{$key});
    }
    return "  {\n" . join(",\n", @fields) . "\n  }";
}

# Serialize records as JSON with 2-space indentation (no trailing newline).
sub to_json {
    my ($records) = @_;
    return '[]' unless @$records;

    my @parts = map { record_json($_) } @$records;
    return "[\n" . join(",\n", @parts) . "\n]";
}

# Render a value the way Python's str() does.
sub csv_value {
    my ($cell) = @_;
    return '' unless defined $cell;
    my ($kind, $value) = @$cell;
    if ($kind eq 'bool') {
        return $value ? 'True' : 'False';
    }
    if ($kind eq 'float') {
        return float_text($value);
    }
    return "$value";
}

sub escape_csv {
    my ($str) = @_;
    if ($str =~ /[,"\n]/) {
        $str =~ s/"/""/g;
        return '"' . $str . '"';
    }
    return $str;
}

sub to_csv {
    my ($records) = @_;
    return '' unless @$records;

    my @all_keys;
    my %seen;
    for my $record (@$records) {
        for my $key (@{ $record->{keys} }) {
            next if $seen{$key};
            $seen{$key} = 1;
            push @all_keys, $key;
        }
    }

    my @lines = (join(',', map { escape_csv($_) } @all_keys));
    for my $record (@$records) {
        push @lines, join(',', map { escape_csv(csv_value($record->{values}{$_})) } @all_keys);
    }
    return join("\n", @lines);
}

# --- CLI ---

if (@ARGV < 2) {
    print STDERR "$USAGE\n";
    exit 1;
}

my ($command, $filepath) = @ARGV;

if (!-e $filepath) {
    print STDERR "Error: File not found: $filepath\n";
    exit 1;
}

my $content;
{
    open(my $fh, '<:encoding(UTF-8)', $filepath)
        or do {
            print STDERR "Error reading file: $!\n";
            exit 1;
        };
    local $/;
    $content = <$fh>;
    close $fh;
}
$content = '' unless defined $content;

if ($command eq 'parse') {
    my $records = eval { parse_kdg($content) };
    if ($@) {
        print STDERR 'Parse error: ' . error_text($@) . "\n";
        exit 1;
    }
    print to_json($records), "\n";
    exit 0;
}

if ($command eq 'validate') {
    my $ok = eval { parse_kdg($content); 1 };
    if ($ok) {
        print "Valid KDG document\n";
        exit 0;
    }
    print STDERR 'Invalid: ' . error_text($@) . "\n";
    exit 1;
}

if ($command eq 'convert') {
    my $format = @ARGV > 2 ? $ARGV[2] : 'json';
    my $records = eval { parse_kdg($content) };
    if ($@) {
        print STDERR 'Parse error: ' . error_text($@) . "\n";
        exit 1;
    }
    if ($format eq 'json') {
        print to_json($records), "\n";
        exit 0;
    }
    if ($format eq 'csv') {
        print to_csv($records), "\n";
        exit 0;
    }
    print STDERR "Unknown format: $format\n";
    exit 1;
}

print STDERR "Unknown command: $command\n";
print STDERR "$USAGE\n";
exit 1;
