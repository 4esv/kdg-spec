#!/usr/bin/env pwsh
<#
KDG (Key-Delimiter Grammar) Parser - PowerShell 7 implementation

Usage:
    pwsh -File kdg.ps1 parse <file>           Parse KDG to JSON
    pwsh -File kdg.ps1 validate <file>        Validate KDG syntax
    pwsh -File kdg.ps1 convert <file> [fmt]   Convert to format (json, csv)

Reproduces the canonical Go reference (implementations/kdg.go): the definition
regexp, label unescaping, CRLF normalization and trailing-empty-line handling,
record scanning, wrapped values, type coercion, JSON layout, and error messages.
#>

Set-StrictMode -Version Latest

$script:Invariant = [System.Globalization.CultureInfo]::InvariantCulture
$script:FloatStyles = [System.Globalization.NumberStyles]::AllowLeadingSign -bor [System.Globalization.NumberStyles]::AllowDecimalPoint -bor [System.Globalization.NumberStyles]::AllowExponent
$script:ValidTypes = @('str', 'int', 'float', 'bool', 'date')
# Characters that cannot be delimiters. Matches kdg.go's reservedCharList.
$script:ReservedChars = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789:"' + " `t`n`r"
# Raw string literal so the pattern is byte-identical to the other references.
$script:DefinitionPattern = '^([a-z]+):"((?:[^"\\]|\\.)*)\"(.)$'
$script:Usage = 'Usage: kdg <parse|validate|convert> <file> [json|csv]'

# Get-KdgErrorMessage renders a KDG error the way kdg.go's kdgError.Error() does.
# line is 0 for errors that carry no line number (only MissingSeparator does).
function Get-KdgErrorMessage([string]$Message, [int]$Line) {
    if ($Line -gt 0) {
        return "Line ${Line}: $Message"
    }
    return $Message
}

# Get-KdgDefinition parses a single field definition line.
function Get-KdgDefinition([string]$Line, [int]$LineNum) {
    $match = [regex]::Match($Line, $script:DefinitionPattern)
    if (-not $match.Success) {
        throw (Get-KdgErrorMessage "Invalid definition syntax: '$Line'" $LineNum)
    }

    $typeName = $match.Groups[1].Value
    $rawLabel = $match.Groups[2].Value
    $delimiter = $match.Groups[3].Value

    if ($script:ValidTypes -notcontains $typeName) {
        throw (Get-KdgErrorMessage "Unknown type: '$typeName'" $LineNum)
    }

    if ($script:ReservedChars.Contains($delimiter)) {
        throw (Get-KdgErrorMessage "Invalid delimiter: '$delimiter' (reserved character)" $LineNum)
    }

    # Unescape the label. Order matters: \" first, then \\.
    $label = $rawLabel.Replace('\"', '"').Replace('\\', '\')

    return [pscustomobject]@{
        TypeName  = $typeName
        Label     = $label
        Delimiter = $delimiter
    }
}

# ConvertFrom-KdgValue converts a string value to its typed representation.
function ConvertFrom-KdgValue([string]$Value, [string]$TypeName, [int]$LineNum) {
    switch ($TypeName) {
        'str' {
            return $Value
        }
        'int' {
            $parsed = [long]0
            if (-not [long]::TryParse($Value, [System.Globalization.NumberStyles]::AllowLeadingSign, $script:Invariant, [ref]$parsed)) {
                throw (Get-KdgErrorMessage "Invalid integer: '$Value'" $LineNum)
            }
            return $parsed
        }
        'float' {
            $parsed = [double]0
            if (-not [double]::TryParse($Value, $script:FloatStyles, $script:Invariant, [ref]$parsed)) {
                throw (Get-KdgErrorMessage "Invalid float: '$Value'" $LineNum)
            }
            return $parsed
        }
        'bool' {
            $lower = $Value.ToLowerInvariant()
            if ($lower -eq 'true' -or $lower -eq '1') {
                return $true
            }
            if ($lower -eq 'false' -or $lower -eq '0') {
                return $false
            }
            throw (Get-KdgErrorMessage "Invalid boolean: '$Value'" $LineNum)
        }
        'date' {
            $parts = $Value.Split('-')
            if ($parts.Count -eq 3) {
                $year = 0
                $month = 0
                $day = 0
                $okYear = [int]::TryParse($parts[0], [System.Globalization.NumberStyles]::AllowLeadingSign, $script:Invariant, [ref]$year)
                $okMonth = [int]::TryParse($parts[1], [System.Globalization.NumberStyles]::AllowLeadingSign, $script:Invariant, [ref]$month)
                $okDay = [int]::TryParse($parts[2], [System.Globalization.NumberStyles]::AllowLeadingSign, $script:Invariant, [ref]$day)
                if ($okYear -and $okMonth -and $okDay -and $year -ge 1 -and $year -le 9999) {
                    # The .NET DateTime constructor rejects out-of-range
                    # components (e.g. 2024-02-30), matching kdg.go's
                    # round-trip calendar check.
                    $validDate = $false
                    try {
                        $dt = [datetime]::new($year, $month, $day)
                        $validDate = ($dt.Year -eq $year -and $dt.Month -eq $month -and $dt.Day -eq $day)
                    } catch {
                        $validDate = $false
                    }
                    if ($validDate) {
                        return $Value # Return as string for JSON compatibility
                    }
                }
            }
            throw (Get-KdgErrorMessage "Invalid date (expected YYYY-MM-DD): '$Value'" $LineNum)
        }
    }

    throw (Get-KdgErrorMessage "Unknown type: '$TypeName'" $LineNum)
}

# Read-KdgWrappedValue scans a double-quoted value beginning at Line[Start] == '"'.
# Returns an object with Value and Position (just after the closing quote).
# Backslash escapes for \" and \\ are honoured per SPEC 6.2.
function Read-KdgWrappedValue([string]$Line, [int]$Start, [int]$LineNum) {
    $sb = [System.Text.StringBuilder]::new()
    $i = $Start + 1
    $length = $Line.Length

    while ($i -lt $length) {
        $c = $Line[$i]

        if ($c -eq '\' -and ($i + 1) -lt $length -and ($Line[$i + 1] -eq '"' -or $Line[$i + 1] -eq '\')) {
            [void]$sb.Append($Line[$i + 1])
            $i += 2
            continue
        }

        if ($c -eq '"') {
            return [pscustomobject]@{ Value = $sb.ToString(); Position = $i + 1 }
        }

        [void]$sb.Append($c)
        $i++
    }

    throw (Get-KdgErrorMessage 'Unterminated quoted value' $LineNum)
}

# Get-KdgRecord parses a single record line into an ordered label -> value map.
function Get-KdgRecord([string]$Line, [System.Collections.Generic.Dictionary[string, object]]$DelimiterMap, [int]$LineNum) {
    $record = [System.Collections.Specialized.OrderedDictionary]::new([System.StringComparer]::Ordinal)
    if ($Line.Length -eq 0) {
        return $record
    }

    $position = 0
    $length = $Line.Length

    while ($position -lt $length) {
        $value = ''

        # A field is value-then-delimiter. The value may be wrapped in double
        # quotes, which lets it contain delimiter characters (SPEC 6.2).
        if ($Line[$position] -eq '"') {
            $scanned = Read-KdgWrappedValue $Line $position $LineNum
            $value = $scanned.Value
            $position = $scanned.Position

            if ($position -ge $length) {
                throw (Get-KdgErrorMessage "Missing delimiter after value '$value'" $LineNum)
            }
        } else {
            $start = $position
            while ($position -lt $length -and -not $DelimiterMap.ContainsKey([string]$Line[$position])) {
                $position++
            }

            if ($position -eq $length) {
                throw (Get-KdgErrorMessage "No delimiter found for value starting at column $start" $LineNum)
            }

            $value = $Line.Substring($start, $position - $start)
        }

        $delimiter = [string]$Line[$position]

        if (-not $DelimiterMap.ContainsKey($delimiter)) {
            throw (Get-KdgErrorMessage "Undefined delimiter: '$delimiter'" $LineNum)
        }

        $field = $DelimiterMap[$delimiter]

        if ($record.Contains($field.Label)) {
            throw (Get-KdgErrorMessage "Duplicate field in record: '$($field.Label)'" $LineNum)
        }

        $record[$field.Label] = ConvertFrom-KdgValue $value $field.TypeName $LineNum
        $position++
    }

    return $record
}

# Add-KdgRecords parses a KDG document and appends its records to Out.
function Add-KdgRecords([string]$Content, [System.Collections.Generic.List[object]]$Out) {
    $lines = [System.Collections.Generic.List[string]]::new([string[]]$Content.Replace("`r`n", "`n").Split([char]10))

    # A trailing newline produces a spurious final empty element. Drop it so a
    # document with no blank-line separator is reported as MissingSeparator
    # instead of having its first record misread as a definition.
    if ($lines.Count -gt 0 -and $lines[$lines.Count - 1] -eq '') {
        $lines.RemoveAt($lines.Count - 1)
    }

    # Find the separator (blank line).
    $separatorIdx = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -eq '') {
            $separatorIdx = $i
            break
        }
    }

    if ($separatorIdx -lt 0) {
        throw (Get-KdgErrorMessage 'No blank line separator found between definitions and data' 0)
    }

    # Parse definitions.
    $delimiterMap = [System.Collections.Generic.Dictionary[string, object]]::new()
    for ($i = 0; $i -lt $separatorIdx; $i++) {
        $line = $lines[$i]
        if ($line -eq '') { # Skip empty lines in the definition block
            continue
        }

        $field = Get-KdgDefinition $line ($i + 1)

        if ($delimiterMap.ContainsKey($field.Delimiter)) {
            $existing = $delimiterMap[$field.Delimiter]
            throw (Get-KdgErrorMessage "Delimiter '$($field.Delimiter)' already used for field '$($existing.Label)'" ($i + 1))
        }

        $delimiterMap[$field.Delimiter] = $field
    }

    # Parse records.
    for ($i = $separatorIdx + 1; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        if ($line -eq '') { # Skip empty lines in the data block
            continue
        }

        $Out.Add((Get-KdgRecord $line $delimiterMap ($i + 1)))
    }
}

# Format-KdgJsonString renders a JSON string with no HTML escaping, leaving all
# non-ASCII characters raw.
function Format-KdgJsonString([string]$Value) {
    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.Append('"')

    foreach ($ch in $Value.ToCharArray()) {
        $code = [int]$ch
        if ($ch -eq '"') {
            [void]$sb.Append('\"')
        } elseif ($ch -eq '\') {
            [void]$sb.Append('\\')
        } elseif ($code -eq 10) {
            [void]$sb.Append('\n')
        } elseif ($code -eq 13) {
            [void]$sb.Append('\r')
        } elseif ($code -eq 9) {
            [void]$sb.Append('\t')
        } elseif ($code -lt 0x20) {
            [void]$sb.Append('\u' + $code.ToString('x4', $script:Invariant))
        } else {
            [void]$sb.Append($ch)
        }
    }

    [void]$sb.Append('"')
    return $sb.ToString()
}

# Format-KdgJsonValue renders a single typed value as JSON text.
function Format-KdgJsonValue($Value) {
    if ($null -eq $Value) {
        return 'null'
    }
    if ($Value -is [bool]) {
        if ($Value) { return 'true' }
        return 'false'
    }
    if ($Value -is [long] -or $Value -is [int]) {
        return $Value.ToString($script:Invariant)
    }
    if ($Value -is [double]) {
        if ([double]::IsNaN($Value)) {
            throw 'json: unsupported value: NaN'
        }
        if ([double]::IsPositiveInfinity($Value)) {
            throw 'json: unsupported value: +Inf'
        }
        if ([double]::IsNegativeInfinity($Value)) {
            throw 'json: unsupported value: -Inf'
        }
        return $Value.ToString('R', $script:Invariant)
    }
    return Format-KdgJsonString ([string]$Value)
}

# ConvertTo-KdgJson renders records as JSON: 2-space indent, trailing newline.
function ConvertTo-KdgJson([System.Collections.Generic.List[object]]$Records) {
    $sb = [System.Text.StringBuilder]::new()

    if ($Records.Count -eq 0) {
        [void]$sb.Append("[]`n")
        return $sb.ToString()
    }

    [void]$sb.Append("[`n")
    for ($i = 0; $i -lt $Records.Count; $i++) {
        $keys = @($Records[$i].Keys)

        if ($keys.Count -eq 0) {
            [void]$sb.Append('  {}')
        } else {
            [void]$sb.Append("  {`n")
            for ($j = 0; $j -lt $keys.Count; $j++) {
                $key = $keys[$j]
                [void]$sb.Append('    ')
                [void]$sb.Append((Format-KdgJsonString $key))
                [void]$sb.Append(': ')
                [void]$sb.Append((Format-KdgJsonValue $Records[$i][$key]))
                if ($j -lt $keys.Count - 1) {
                    [void]$sb.Append(',')
                }
                [void]$sb.Append("`n")
            }
            [void]$sb.Append('  }')
        }

        if ($i -lt $Records.Count - 1) {
            [void]$sb.Append(',')
        }
        [void]$sb.Append("`n")
    }
    [void]$sb.Append("]`n")

    return $sb.ToString()
}

# Format-KdgCsvValue renders a value the way the Python reference's str() does.
function Format-KdgCsvValue($Value) {
    if ($null -eq $Value) {
        return ''
    }
    if ($Value -is [bool]) {
        if ($Value) { return 'True' }
        return 'False'
    }
    if ($Value -is [long] -or $Value -is [int]) {
        return $Value.ToString($script:Invariant)
    }
    if ($Value -is [double]) {
        $s = $Value.ToString('R', $script:Invariant)
        if ($s -notmatch '[.eEni]') {
            $s += '.0'
        }
        return $s
    }
    return [string]$Value
}

# Format-KdgCsvField quotes a field containing a comma, double quote, or newline,
# doubling internal quotes.
function Format-KdgCsvField([string]$Value) {
    if ($Value.Contains(',') -or $Value.Contains('"') -or $Value.Contains("`n")) {
        return '"' + $Value.Replace('"', '""') + '"'
    }
    return $Value
}

# ConvertTo-KdgCsv renders records as CSV: header keys in first-seen order.
function ConvertTo-KdgCsv([System.Collections.Generic.List[object]]$Records) {
    if ($Records.Count -eq 0) {
        return ''
    }

    # Get all unique keys across all records, in first-seen order.
    $allKeys = [System.Collections.Generic.List[string]]::new()
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($record in $Records) {
        foreach ($key in $record.Keys) {
            if ($seen.Add([string]$key)) {
                $allKeys.Add([string]$key)
            }
        }
    }

    $lines = [System.Collections.Generic.List[string]]::new()
    $header = [System.Collections.Generic.List[string]]::new()
    foreach ($key in $allKeys) {
        $header.Add((Format-KdgCsvField $key))
    }
    $lines.Add(($header -join ','))

    foreach ($record in $Records) {
        $row = [System.Collections.Generic.List[string]]::new()
        foreach ($key in $allKeys) {
            $row.Add((Format-KdgCsvField (Format-KdgCsvValue $record[$key])))
        }
        $lines.Add(($row -join ','))
    }

    return ($lines -join "`n")
}

# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)

$scriptArgs = @($args)
if ($scriptArgs.Count -lt 2) {
    [Console]::Error.WriteLine($script:Usage)
    exit 1
}

$command = [string]$scriptArgs[0]
$filepath = [string]$scriptArgs[1]

try {
    $content = [System.IO.File]::ReadAllText($filepath)
} catch [System.IO.FileNotFoundException] {
    [Console]::Error.WriteLine("Error: File not found: $filepath")
    exit 1
} catch [System.IO.DirectoryNotFoundException] {
    [Console]::Error.WriteLine("Error: File not found: $filepath")
    exit 1
} catch {
    [Console]::Error.WriteLine("Error reading file: $($_.Exception.Message)")
    exit 1
}

if ($command -ceq 'parse') {
    $records = [System.Collections.Generic.List[object]]::new()
    try {
        Add-KdgRecords $content $records
        $json = ConvertTo-KdgJson $records
    } catch {
        [Console]::Error.WriteLine("Parse error: $($_.Exception.Message)")
        exit 1
    }
    [Console]::Out.Write($json)
    exit 0
}

if ($command -ceq 'validate') {
    $records = [System.Collections.Generic.List[object]]::new()
    try {
        Add-KdgRecords $content $records
    } catch {
        [Console]::Error.WriteLine("Invalid: $($_.Exception.Message)")
        exit 1
    }
    [Console]::Out.WriteLine('Valid KDG document')
    exit 0
}

if ($command -ceq 'convert') {
    $format = 'json'
    if ($scriptArgs.Count -gt 2) {
        $format = [string]$scriptArgs[2]
    }

    $records = [System.Collections.Generic.List[object]]::new()
    try {
        Add-KdgRecords $content $records
        if ($format -ceq 'json') {
            $out = ConvertTo-KdgJson $records
        } elseif ($format -ceq 'csv') {
            $out = ConvertTo-KdgCsv $records
        } else {
            [Console]::Error.WriteLine("Unknown format: $format")
            exit 1
        }
    } catch {
        [Console]::Error.WriteLine("Parse error: $($_.Exception.Message)")
        exit 1
    }

    if ($format -ceq 'csv') {
        [Console]::Out.WriteLine($out)
    } else {
        [Console]::Out.Write($out)
    }
    exit 0
}

[Console]::Error.WriteLine("Unknown command: $command")
[Console]::Error.WriteLine($script:Usage)
exit 1
