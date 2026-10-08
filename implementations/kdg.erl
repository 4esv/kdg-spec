#!/usr/bin/env escript
%%% KDG (Key-Delimited Grammar) parser - Erlang implementation.
%%%
%%% Usage:
%%%   escript implementations/kdg.erl parse <file>          Parse KDG to JSON
%%%   escript implementations/kdg.erl validate <file>       Validate KDG syntax
%%%   escript implementations/kdg.erl convert <file> [fmt]  Convert to json or csv
%%%
%%% Standard library only. Messages, exit codes and the JSON/CSV shape follow
%%% implementations/kdg.go. Floats are rendered with float_to_list/2's "short"
%%% option, so OTP 24 or newer is required.

-define(USAGE, "Usage: kdg <parse|validate|convert> <file> [json|csv]").

%% A definition line: type:"label"delimiter, where the label may contain \" and \\.
-define(DEFINITION_PATTERN, "^([a-z]+):\"((?:[^\"\\\\]|\\\\.)*)\"(.)$").

%% Float forms: optional sign, digits with an optional fraction (or a bare
%% fraction), optional exponent. This is what the Go and Python references accept.
-define(FLOAT_PATTERN, "^[+-]?([0-9]+(\\.[0-9]*)?|\\.[0-9]+)([eE][+-]?[0-9]+)?$").

main(Args) ->
    io:setopts(standard_io, [{encoding, unicode}]),
    io:setopts(standard_error, [{encoding, unicode}]),
    halt(run(Args)).

%% ------------------------------------------------------------------- CLI --

run([Command, File | Rest]) ->
    case read_file(File) of
        {ok, Content} -> dispatch(Command, Content, Rest);
        {error, Message} -> io:put_chars(standard_error, [Message, "\n"]), 1
    end;
run(_Args) ->
    io:put_chars(standard_error, [?USAGE, "\n"]),
    1.

read_file(File) ->
    case file:read_file(File) of
        {ok, Binary} ->
            case unicode:characters_to_list(Binary, utf8) of
                Characters when is_list(Characters) -> {ok, Characters};
                _ -> {error, ["Error reading file: ", File, ": invalid UTF-8"]}
            end;
        {error, enoent} ->
            {error, ["Error: File not found: ", File]};
        {error, Reason} ->
            {error, ["Error reading file: ", file:format_error(Reason)]}
    end.

dispatch("parse", Content, _Rest) ->
    case parse_safe(Content) of
        {ok, Records} ->
            io:put_chars([to_json(Records), "\n"]),
            0;
        {error, Message} ->
            io:put_chars(standard_error, ["Parse error: ", Message, "\n"]),
            1
    end;
dispatch("validate", Content, _Rest) ->
    case parse_safe(Content) of
        {ok, _Records} ->
            io:put_chars("Valid KDG document\n"),
            0;
        {error, Message} ->
            io:put_chars(standard_error, ["Invalid: ", Message, "\n"]),
            1
    end;
dispatch("convert", Content, Rest) ->
    Format =
        case Rest of
            [Requested | _] -> Requested;
            [] -> "json"
        end,
    case parse_safe(Content) of
        {ok, Records} when Format =:= "json" ->
            io:put_chars([to_json(Records), "\n"]),
            0;
        {ok, Records} when Format =:= "csv" ->
            io:put_chars([to_csv(Records), "\n"]),
            0;
        {ok, _Records} ->
            io:put_chars(standard_error, ["Unknown format: ", Format, "\n"]),
            1;
        {error, Message} ->
            io:put_chars(standard_error, ["Parse error: ", Message, "\n"]),
            1
    end;
dispatch(Command, _Content, _Rest) ->
    io:put_chars(standard_error, ["Unknown command: ", Command, "\n"]),
    io:put_chars(standard_error, [?USAGE, "\n"]),
    1.

%% ---------------------------------------------------------------- errors --

%% MissingSeparator is the only error without a line number.
throw_kdg(0, Message) ->
    throw({kdg_error, Message});
throw_kdg(LineNumber, Message) ->
    throw({kdg_error, ["Line ", integer_to_list(LineNumber), ": ", Message]}).

parse_safe(Content) ->
    try
        {ok, parse(Content)}
    catch
        throw:{kdg_error, Message} -> {error, Message}
    end.

%% --------------------------------------------------------------- parsing --

parse(Content) ->
    Lines = drop_trailing_empty(split_lines(Content)),
    case find_separator(Lines, 0) of
        none ->
            throw_kdg(0, "No blank line separator found between definitions and data");
        Separator ->
            {DefinitionLines, [_Separator | RecordLines]} = lists:split(Separator, Lines),
            DelimiterMap = parse_definitions(DefinitionLines, 1, #{}),
            parse_records(RecordLines, Separator + 2, DelimiterMap, [])
    end.

%% CRLF is normalized to LF before splitting, then the trailing empty element a
%% final newline produces is dropped once.
split_lines(Content) ->
    split_on_lf(normalize_crlf(Content, []), [], []).

normalize_crlf([$\r, $\n | Rest], Acc) -> normalize_crlf(Rest, [$\n | Acc]);
normalize_crlf([Char | Rest], Acc) -> normalize_crlf(Rest, [Char | Acc]);
normalize_crlf([], Acc) -> lists:reverse(Acc).

split_on_lf([], Current, Acc) -> lists:reverse([lists:reverse(Current) | Acc]);
split_on_lf([$\n | Rest], Current, Acc) -> split_on_lf(Rest, [], [lists:reverse(Current) | Acc]);
split_on_lf([Char | Rest], Current, Acc) -> split_on_lf(Rest, [Char | Current], Acc).

drop_trailing_empty(Lines) ->
    case lists:reverse(Lines) of
        [[] | Rest] -> lists:reverse(Rest);
        _ -> Lines
    end.

find_separator([], _Index) -> none;
find_separator([[] | _Rest], Index) -> Index;
find_separator([_Line | Rest], Index) -> find_separator(Rest, Index + 1).

parse_definitions([], _LineNumber, DelimiterMap) -> DelimiterMap;
parse_definitions([Line | Rest], LineNumber, DelimiterMap) ->
    Next =
        case Line of
            [] ->
                DelimiterMap;
            _ ->
                {Type, Label, Delimiter} = parse_definition(Line, LineNumber),
                case maps:find(Delimiter, DelimiterMap) of
                    {ok, {_Type, ExistingLabel, _Delimiter}} ->
                        throw_kdg(LineNumber, [
                            "Delimiter '", [Delimiter], "' already used for field '", ExistingLabel, "'"
                        ]);
                    error ->
                        ok
                end,
                maps:put(Delimiter, {Type, Label, Delimiter}, DelimiterMap)
        end,
    parse_definitions(Rest, LineNumber + 1, Next).

parse_definition(Line, LineNumber) ->
    case re:run(Line, ?DEFINITION_PATTERN, [{capture, all_but_first, list}, unicode]) of
        {match, [TypeName, RawLabel, [Delimiter]]} ->
            case lists:member(TypeName, ["str", "int", "float", "bool", "date"]) of
                false ->
                    throw_kdg(LineNumber, ["Unknown type: '", TypeName, "'"]);
                true ->
                    ok
            end,
            case is_reserved(Delimiter) of
                true ->
                    throw_kdg(LineNumber, [
                        "Invalid delimiter: '", [Delimiter], "' (reserved character)"
                    ]);
                false ->
                    ok
            end,
            {TypeName, unescape_label(RawLabel), Delimiter};
        nomatch ->
            throw_kdg(LineNumber, ["Invalid definition syntax: '", Line, "'"])
    end.

%% \" first, then \\.
unescape_label(RawLabel) ->
    replace_all(replace_all(RawLabel, [$\\, $"], [$"]), [$\\, $\\], [$\\]).

replace_all(Subject, Pattern, Replacement) ->
    lists:flatten(lists:join(Replacement, string:split(Subject, Pattern, all))).

%% Reserved: alphanumerics, ':', '"' and whitespace.
is_reserved(Char) when Char >= $a, Char =< $z -> true;
is_reserved(Char) when Char >= $A, Char =< $Z -> true;
is_reserved(Char) when Char >= $0, Char =< $9 -> true;
is_reserved($:) -> true;
is_reserved($") -> true;
is_reserved($\s) -> true;
is_reserved($\t) -> true;
is_reserved($\n) -> true;
is_reserved($\r) -> true;
is_reserved(_Char) -> false.

parse_records([], _LineNumber, _DelimiterMap, Acc) -> lists:reverse(Acc);
parse_records([Line | Rest], LineNumber, DelimiterMap, Acc) ->
    Next =
        case Line of
            [] -> Acc;
            _ -> [parse_record(Line, LineNumber, DelimiterMap) | Acc]
        end,
    parse_records(Rest, LineNumber + 1, DelimiterMap, Next).

%% A field is a value followed by its delimiter; the value may be wrapped in
%% double quotes, which lets it contain delimiter characters.
parse_record(Line, LineNumber, DelimiterMap) ->
    parse_record(Line, LineNumber, DelimiterMap, 0, []).

parse_record([], _LineNumber, _DelimiterMap, _Position, Acc) ->
    lists:reverse(Acc);
parse_record(Rest, LineNumber, DelimiterMap, Position, Acc) ->
    {Value, AfterValue} =
        case Rest of
            [$" | _] ->
                {Scanned, AfterQuote} = scan_wrapped(Rest, LineNumber),
                case AfterQuote of
                    [] ->
                        throw_kdg(LineNumber, [
                            "Missing delimiter after value '", Scanned, "'"
                        ]);
                    _ ->
                        {Scanned, AfterQuote}
                end;
            _ ->
                {Scanned, AfterDelimiter} = scan_raw(Rest, DelimiterMap),
                case AfterDelimiter of
                    [] ->
                        throw_kdg(LineNumber, [
                            "No delimiter found for value starting at column ",
                            integer_to_list(Position)
                        ]);
                    _ ->
                        {Scanned, AfterDelimiter}
                end
        end,
    [Delimiter | Tail] = AfterValue,
    {Type, Label, _DelimiterString} =
        case maps:find(Delimiter, DelimiterMap) of
            {ok, Definition} ->
                Definition;
            error ->
                throw_kdg(LineNumber, ["Undefined delimiter: '", [Delimiter], "'"])
        end,
    case lists:keymember(Label, 1, Acc) of
        true ->
            throw_kdg(LineNumber, ["Duplicate field in record: '", Label, "'"]);
        false ->
            ok
    end,
    TypedValue = convert_value(Value, Type, LineNumber),
    NextPosition = Position + length(Rest) - length(Tail),
    parse_record(Tail, LineNumber, DelimiterMap, NextPosition, [{Label, TypedValue} | Acc]).

%% Starting at the opening quote; returns the value and the rest after the
%% closing quote. \" and \\ are honoured per SPEC 6.2.
scan_wrapped([$" | Characters], LineNumber) ->
    scan_wrapped_chars(Characters, [], LineNumber).

scan_wrapped_chars([], _Acc, LineNumber) ->
    throw_kdg(LineNumber, "Unterminated quoted value");
scan_wrapped_chars([$\\, Char | Rest], Acc, LineNumber) when Char =:= $"; Char =:= $\\ ->
    scan_wrapped_chars(Rest, [Char | Acc], LineNumber);
scan_wrapped_chars([$" | Rest], Acc, _LineNumber) ->
    {lists:reverse(Acc), Rest};
scan_wrapped_chars([Char | Rest], Acc, LineNumber) ->
    scan_wrapped_chars(Rest, [Char | Acc], LineNumber).

%% Consumes up to the next defined delimiter.
scan_raw(Rest, DelimiterMap) ->
    scan_raw(Rest, [], DelimiterMap).

scan_raw([Char | _Rest] = Remaining, Acc, DelimiterMap) ->
    case maps:is_key(Char, DelimiterMap) of
        true -> {lists:reverse(Acc), Remaining};
        false -> scan_raw(tl(Remaining), [Char | Acc], DelimiterMap)
    end;
scan_raw([], Acc, _DelimiterMap) ->
    {lists:reverse(Acc), []}.

%% --------------------------------------------------------------- values ----

convert_value(Value, "str", _LineNumber) ->
    {str, Value};
convert_value(Value, "int", LineNumber) ->
    case parse_int(Value) of
        {ok, Integer} -> {int, Integer};
        error -> throw_kdg(LineNumber, ["Invalid integer: '", Value, "'"])
    end;
convert_value(Value, "float", LineNumber) ->
    case parse_float(Value) of
        {ok, Float} -> {float, Float};
        error -> throw_kdg(LineNumber, ["Invalid float: '", Value, "'"])
    end;
convert_value(Value, "bool", LineNumber) ->
    case string:lowercase(Value) of
        "true" -> {bool, true};
        "1" -> {bool, true};
        "false" -> {bool, false};
        "0" -> {bool, false};
        _ -> throw_kdg(LineNumber, ["Invalid boolean: '", Value, "'"])
    end;
convert_value(Value, "date", LineNumber) ->
    case is_valid_date(Value) of
        true -> {date, Value};
        false -> throw_kdg(LineNumber, ["Invalid date (expected YYYY-MM-DD): '", Value, "'"])
    end;
convert_value(_Value, TypeName, LineNumber) ->
    throw_kdg(LineNumber, ["Unknown type: '", TypeName, "'"]).

%% The specification's int form: -?[0-9]+.
parse_int(Value) ->
    {Sign, Digits} =
        case Value of
            [$- | Rest] -> {-1, Rest};
            _ -> {1, Value}
        end,
    case Digits =/= [] andalso lists:all(fun is_digit/1, Digits) of
        true -> {ok, Sign * list_to_integer(Digits)};
        false -> error
    end.

is_digit(Char) -> Char >= $0 andalso Char =< $9.

parse_float(Value) ->
    case re:run(Value, ?FLOAT_PATTERN, [{capture, none}, unicode]) of
        match -> to_float(normalize_float(Value));
        nomatch -> error
    end.

%% strtod needs a digit on both sides of the decimal point, so pad the integer
%% part, the fraction, and the missing point of "1e3"/"3." before conversion.
normalize_float(Value) ->
    {Sign, Unsigned} =
        case Value of
            [$- | Rest] -> {"-", Rest};
            [$+ | Rest] -> {"+", Rest};
            _ -> {"", Value}
        end,
    {Body, Exponent} = split_exponent(Unsigned, []),
    case string:split(Body, ".", all) of
        [IntegerPart] -> Sign ++ pad(IntegerPart) ++ ".0" ++ Exponent;
        [IntegerPart, Fraction] -> Sign ++ pad(IntegerPart) ++ "." ++ pad(Fraction) ++ Exponent
    end.

pad([]) -> "0";
pad(Digits) -> Digits.

split_exponent([Char | Rest], Acc) when Char =:= $e; Char =:= $E ->
    {lists:reverse(Acc), [Char | Rest]};
split_exponent([Char | Rest], Acc) ->
    split_exponent(Rest, [Char | Acc]);
split_exponent([], Acc) ->
    {lists:reverse(Acc), []}.

to_float(Value) ->
    case string:to_float(Value) of
        {Float, []} -> {ok, Float};
        _ -> error
    end.

is_valid_date(Value) ->
    case string:split(Value, "-", all) of
        [Year, Month, Day] ->
            case {parse_int(Year), parse_int(Month), parse_int(Day)} of
                {{ok, Y}, {ok, M}, {ok, D}} -> valid_date(Y, M, D);
                _ -> false
            end;
        _ ->
            false
    end.

valid_date(Year, Month, Day)
    when Year >= 1, Year =< 9999, Month >= 1, Month =< 12, Day >= 1 ->
    Day =< days_in_month(Year, Month);
valid_date(_Year, _Month, _Day) ->
    false.

days_in_month(Year, 2) ->
    case is_leap_year(Year) of
        true -> 29;
        false -> 28
    end;
days_in_month(_Year, Month) ->
    lists:nth(Month, [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]).

is_leap_year(Year) ->
    (Year rem 4 =:= 0 andalso Year rem 100 =/= 0) orelse Year rem 400 =:= 0.

%% --------------------------------------------------------------- output ----

%% Records are lists of {Label, TypedValue} in first-seen order, so the JSON
%% keys and the CSV header keep that order. The parsed JSON is order-insensitive;
%% kdg.go's map-based encoder sorts keys instead.
to_json([]) ->
    "[]";
to_json(Records) ->
    ["[\n", lists:join(",\n", [json_record(Record, 2) || Record <- Records]), "\n]"].

json_record([], Indent) ->
    [spaces(Indent), "{}"];
json_record(Fields, Indent) ->
    Rendered = [
        [spaces(Indent + 2), json_string(Label), ": ", json_value(Value)]
     || {Label, Value} <- Fields
    ],
    [spaces(Indent), "{\n", lists:join(",\n", Rendered), "\n", spaces(Indent), "}"].

spaces(Count) -> lists:duplicate(Count, $\s).

json_value({str, Value}) -> json_string(Value);
json_value({date, Value}) -> json_string(Value);
json_value({int, Value}) -> integer_to_list(Value);
json_value({float, Value}) -> float_to_list(Value, [short]);
json_value({bool, true}) -> "true";
json_value({bool, false}) -> "false".

json_string(Value) ->
    [$", [json_escape(Char) || Char <- Value], $"].

json_escape($") -> "\\\"";
json_escape($\\) -> "\\\\";
json_escape($\b) -> "\\b";
json_escape($\f) -> "\\f";
json_escape($\n) -> "\\n";
json_escape($\r) -> "\\r";
json_escape($\t) -> "\\t";
json_escape(Char) when Char < 32 -> lists:flatten(io_lib:format("\\u~4.16.0b", [Char]));
json_escape(Char) -> Char.

to_csv([]) ->
    "";
to_csv(Records) ->
    Keys = all_keys(Records, []),
    Header = lists:join(",", [escape_csv(Key) || Key <- Keys]),
    Rows = [
        lists:join(",", [escape_csv(csv_value(lookup(Key, Record))) || Key <- Keys])
     || Record <- Records
    ],
    lists:join("\n", [Header | Rows]).

lookup(Key, Fields) ->
    case lists:keyfind(Key, 1, Fields) of
        {_Key, Value} -> Value;
        false -> missing
    end.

all_keys([], Acc) ->
    lists:reverse(Acc);
all_keys([Fields | Rest], Acc) ->
    Next = lists:foldl(
        fun({Label, _Value}, Seen) ->
            case lists:member(Label, Seen) of
                true -> Seen;
                false -> [Label | Seen]
            end
        end,
        Acc,
        Fields
    ),
    all_keys(Rest, Next).

%% Mirrors the Python reference's str(): bools are True/False, floats keep a
%% decimal point, missing fields are empty.
csv_value(missing) -> "";
csv_value({str, Value}) -> Value;
csv_value({date, Value}) -> Value;
csv_value({int, Value}) -> integer_to_list(Value);
csv_value({float, Value}) -> float_to_list(Value, [short]);
csv_value({bool, true}) -> "True";
csv_value({bool, false}) -> "False".

escape_csv(Value) ->
    case needs_quoting(Value) of
        true -> [$"] ++ escape_quotes(Value) ++ [$"];
        false -> Value
    end.

needs_quoting(Value) ->
    lists:any(fun(Char) -> Char =:= $, orelse Char =:= $" orelse Char =:= $\n end, Value).

escape_quotes(Value) ->
    lists:flatten([case Char of $" -> "\"\""; _ -> [Char] end || Char <- Value]).
