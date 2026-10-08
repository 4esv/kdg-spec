{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- KDG (Key-Delimiter Grammar) Parser - Reference Implementation
--
-- Usage:
--
--   runghc kdg.hs parse <file>           Parse KDG to JSON
--   runghc kdg.hs validate <file>        Validate KDG syntax
--   runghc kdg.hs convert <file> [fmt]   Convert to format (json, csv)
--
-- This implementation uses only the base package. This was considered
-- important. Behaviour mirrors implementations/kdg.go exactly: the definition
-- regexp, label unescape order, trailing-newline handling, record scanning,
-- wrapped values, type coercion, and every error message.
module Main (main) where

import Control.Exception (IOException, evaluate, try)
import Control.Monad (foldM)
import Data.Char (isDigit, ord, toLower)
import Data.List (findIndex, foldl', intercalate, isPrefixOf)
import Numeric (showHex)
import System.Environment (getArgs)
import System.Exit (exitFailure)
import System.IO
  ( IOMode (ReadMode)
  , hGetContents
  , hPutStrLn
  , hSetEncoding
  , openFile
  , stderr
  , utf8
  )
import System.IO.Error (isDoesNotExistError)

-- ---------------------------------------------------------------------------
-- Core types
-- ---------------------------------------------------------------------------

-- fieldDef is a field definition from the KDG header.
data FieldDef = FieldDef
  { fdType :: String
  , fdLabel :: String
  , fdDelim :: Char
  }

-- A parsed record keeps the field values in first-seen key order. The order is
-- needed for deterministic CSV headers; JSON output does not depend on it.
type Record = [(String, Value)]

-- A typed field value.
data Value
  = S String -- str
  | I Integer -- int
  | F Double -- float
  | B Bool -- bool
  | D String -- date (kept as its original string)

-- kdgError is the base error type for KDG parsing errors. line is 0 when the
-- error carries no line number (only MissingSeparator does).
data KdgError = KdgError
  { errLine :: Int
  , errMsg :: String
  }

errorText :: KdgError -> String
errorText (KdgError l m)
  | l > 0 = "Line " ++ show l ++ ": " ++ m
  | otherwise = m

validTypes :: [String]
validTypes = ["str", "int", "float", "bool", "date"]

-- Characters that cannot be delimiters.
reservedChars :: String
reservedChars = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789:\" \t\n\r"

-- ---------------------------------------------------------------------------
-- Small string helpers (base only)
-- ---------------------------------------------------------------------------

-- replaceAll replaces every non-overlapping occurrence of a substring.
replaceAll :: String -> String -> String -> String
replaceAll from to = go
  where
    go [] = []
    go s@(x : xs)
      | from `isPrefixOf` s = to ++ go (drop (length from) s)
      | otherwise = x : go xs

-- splitOn splits on a single character; "a\n" -> ["a", ""].
splitOn :: Char -> String -> [String]
splitOn c s = case break (== c) s of
  (a, []) -> [a]
  (a, _ : rest) -> a : splitOn c rest

-- ---------------------------------------------------------------------------
-- Definition parsing
-- ---------------------------------------------------------------------------

-- matchDefinition hand-rolls the reference regexp
--   ^([a-z]+):"((?:[^"\\]|\\.)*)"(.)$
-- returning (type, raw label, delimiter), or Nothing when the line does not
-- match. The raw label still contains its backslash escapes.
matchDefinition :: String -> Maybe (String, String, Char)
matchDefinition s = do
  let (typeName, afterType) = span (\c -> c >= 'a' && c <= 'z') s
  if null typeName then Nothing else Just ()
  case afterType of
    (':' : rest1) -> case rest1 of
      ('"' : rest2) -> do
        (rawLabel, rest3) <- scanLabel rest2
        case rest3 of
          [delim] -> Just (typeName, rawLabel, delim)
          _ -> Nothing
      _ -> Nothing
    _ -> Nothing

-- scanLabel consumes the quoted label, stopping at the first unescaped double
-- quote. A backslash escapes the following character verbatim.
scanLabel :: String -> Maybe (String, String)
scanLabel = go []
  where
    go acc ('\\' : c : cs) = go (c : '\\' : acc) cs
    go _ ['\\'] = Nothing
    go acc ('"' : cs) = Just (reverse acc, cs)
    go acc (c : cs) = go (c : acc) cs
    go _ [] = Nothing

-- parseDefinition parses a single field definition line.
parseDefinition :: String -> Int -> Either KdgError FieldDef
parseDefinition line lineNum =
  case matchDefinition line of
    Nothing ->
      Left (KdgError lineNum ("Invalid definition syntax: '" ++ line ++ "'"))
    Just (typeName, rawLabel, delimiter)
      | typeName `notElem` validTypes ->
          Left (KdgError lineNum ("Unknown type: '" ++ typeName ++ "'"))
      | delimiter `elem` reservedChars ->
          Left
            ( KdgError
                lineNum
                ("Invalid delimiter: '" ++ [delimiter] ++ "' (reserved character)")
            )
      | otherwise -> Right (FieldDef typeName (unescapeLabel rawLabel) delimiter)

-- Unescape the label. Order matters: \" first, then \\.
unescapeLabel :: String -> String
unescapeLabel raw =
  replaceAll "\\\\" "\\" (replaceAll "\\\"" "\"" raw)

-- ---------------------------------------------------------------------------
-- Value coercion
-- ---------------------------------------------------------------------------

-- atoi mirrors strconv.Atoi: optional sign, at least one digit, no other
-- characters, and a 64-bit range check.
atoi :: String -> Maybe Integer
atoi s = case s of
  ('-' : ds) -> do
    n <- digits ds
    if n <= 9223372036854775808 then Just (negate n) else Nothing
  ('+' : ds) -> bounded ds
  _ -> bounded s
  where
    bounded ds = do
      n <- digits ds
      if n <= 9223372036854775807 then Just n else Nothing
    digits ds = if not (null ds) && all isDigit ds then Just (read ds :: Integer) else Nothing

-- parseFloat mirrors strconv.ParseFloat for the forms the spec cares about:
-- optional sign, decimal digits with optional fraction and optional exponent,
-- plus the special values Inf/Infinity/NaN. Overflow to infinity is an error,
-- matching the reference's ErrRange.
parseFloat :: String -> Maybe Double
parseFloat s = case s of
  ('-' : r) -> fmap negate (core r)
  ('+' : r) -> core r
  _ -> core s
  where
    core t = case map toLower t of
      "inf" -> Just (1 / 0)
      "infinity" -> Just (1 / 0)
      "nan" -> Just (0 / 0)
      _ -> do
        let (mantissa, expPart) = break (\c -> c == 'e' || c == 'E') t
        m <- parseMantissa mantissa
        e <- case expPart of
          [] -> Just 0
          (_ : es) -> atoi es
        let v = m * (10 ** fromIntegral e)
        if isInfinite v then Nothing else Just v

    parseMantissa m =
      let (intPart, rest) = span isDigit m
       in case rest of
            [] | not (null intPart) -> Just (fromInteger (read intPart :: Integer))
            ('.' : frac)
              | all isDigit frac && (not (null intPart) || not (null frac)) ->
                  Just
                    ( fromInteger (read (intPart ++ frac) :: Integer)
                        / (10 ^ length frac)
                    )
            _ -> Nothing

-- validDate checks YYYY-MM-DD with years 1..9999 and a real calendar day,
-- including leap years.
validDate :: String -> Bool
validDate value = case splitOn '-' value of
  [ys, ms, ds] -> case (atoi ys, atoi ms, atoi ds) of
    (Just y, Just m, Just d) ->
      y >= 1 && y <= 9999 && m >= 1 && m <= 12 && d >= 1 && d <= daysInMonth y m
    _ -> False
  _ -> False
  where
    daysInMonth y m = case m of
      1 -> 31
      3 -> 31
      5 -> 31
      7 -> 31
      8 -> 31
      10 -> 31
      12 -> 31
      4 -> 30
      6 -> 30
      9 -> 30
      11 -> 30
      2 -> if isLeap y then 29 else 28
      _ -> 0
    isLeap y = y `mod` 4 == 0 && (y `mod` 100 /= 0 || y `mod` 400 == 0)

-- convertValue converts a string value to its typed representation.
convertValue :: String -> String -> Int -> Either KdgError Value
convertValue value typeName lineNum = case typeName of
  "str" -> Right (S value)
  "int" -> case atoi value of
    Just n -> Right (I n)
    Nothing -> Left (KdgError lineNum ("Invalid integer: '" ++ value ++ "'"))
  "float" -> case parseFloat value of
    Just f -> Right (F f)
    Nothing -> Left (KdgError lineNum ("Invalid float: '" ++ value ++ "'"))
  "bool" ->
    let lower = map toLower value
     in if lower == "true" || lower == "1"
          then Right (B True)
          else
            if lower == "false" || lower == "0"
              then Right (B False)
              else Left (KdgError lineNum ("Invalid boolean: '" ++ value ++ "'"))
  "date" ->
    if validDate value
      then Right (D value)
      else
        Left
          ( KdgError
              lineNum
              ("Invalid date (expected YYYY-MM-DD): '" ++ value ++ "'")
          )
  _ -> Left (KdgError lineNum ("Unknown type: '" ++ typeName ++ "'"))

-- ---------------------------------------------------------------------------
-- Record parsing
-- ---------------------------------------------------------------------------

-- scanWrappedValue scans a double-quoted value beginning at s[i] == '"'. It
-- returns the value and the position just after the closing quote. Backslash
-- escapes for \" and \\ are honoured; a backslash before any other character
-- is kept literally.
scanWrappedValue :: String -> Int -> Maybe (String, Int)
scanWrappedValue s = go
  where
    n = length s
    at i = s !! i
    go i
      | i >= n = Nothing
      | at i == '\\' && i + 1 < n && (at (i + 1) == '"' || at (i + 1) == '\\') =
          appendEsc (i + 2) (at (i + 1))
      | at i == '"' = Just ("", i + 1)
      | otherwise = appendEsc (i + 1) (at i)

    appendEsc i c = case go i of
      Nothing -> Nothing
      Just (rest, next) -> Just (c : rest, next)

-- parseRecord parses a single record line into a Record.
parseRecord :: String -> [(Char, FieldDef)] -> Int -> Either KdgError Record
parseRecord line delimiterMap lineNum
  | null line = Right []
  | otherwise = go 0 []
  where
    n = length line
    at i = line !! i
    isDelim c = any ((== c) . fst) delimiterMap

    go pos acc
      | pos >= n = Right (reverse acc)
      | at pos == '"' =
          case scanWrappedValue line (pos + 1) of
            Nothing -> Left (KdgError lineNum "Unterminated quoted value")
            Just (value, next) ->
              if next >= n
                then
                  Left
                    ( KdgError
                        lineNum
                        ("Missing delimiter after value '" ++ value ++ "'")
                    )
                else finish value next acc
      | otherwise =
          let start = pos
              stop = advance pos
           in if stop >= n
                then
                  Left
                    ( KdgError
                        lineNum
                        ( "No delimiter found for value starting at column "
                            ++ show start
                        )
                    )
                else finish (take (stop - start) (drop start line)) stop acc

    advance i
      | i < n && not (isDelim (at i)) = advance (i + 1)
      | otherwise = i

    finish value delimPos acc =
      let delimiter = at delimPos
       in case lookup delimiter delimiterMap of
            Nothing ->
              Left
                ( KdgError
                    lineNum
                    ("Undefined delimiter: '" ++ [delimiter] ++ "'")
                )
            Just field ->
              if any ((== fdLabel field) . fst) acc
                then
                  Left
                    ( KdgError
                        lineNum
                        ("Duplicate field in record: '" ++ fdLabel field ++ "'")
                    )
                else case convertValue value (fdType field) lineNum of
                  Left err -> Left err
                  Right converted -> go (delimPos + 1) ((fdLabel field, converted) : acc)

-- ---------------------------------------------------------------------------
-- Document parsing
-- ---------------------------------------------------------------------------

-- parse parses a KDG document into a list of records.
parseDoc :: String -> Either KdgError [Record]
parseDoc content =
  let lines0 = splitOn '\n' (replaceAll "\r\n" "\n" content)
      -- A trailing newline produces a spurious final empty element. Drop it so
      -- a document with no blank-line separator is reported as
      -- MissingSeparator instead of having its first record misread as a
      -- definition.
      ls = if not (null lines0) && last lines0 == "" then init lines0 else lines0
   in case findIndex (== "") ls of
        Nothing ->
          Left
            ( KdgError
                0
                "No blank line separator found between definitions and data"
            )
        Just sep -> do
          delimiterMap <- foldM addDef [] [(i, l) | (i, l) <- zip [0 ..] ls, i < sep]
          mapM
            (\(i, l) -> parseRecord l delimiterMap (i + 1))
            [(i, l) | (i, l) <- zip [0 ..] ls, i > sep, l /= ""]
  where
    addDef dm (i, line)
      | null line = Right dm -- skip empty lines in the definition block
      | otherwise = case parseDefinition line (i + 1) of
          Left err -> Left err
          Right field -> case lookup (fdDelim field) dm of
            Just existing ->
              Left
                ( KdgError
                    (i + 1)
                    ( "Delimiter '"
                        ++ [fdDelim field]
                        ++ "' already used for field '"
                        ++ fdLabel existing
                        ++ "'"
                    )
                )
            Nothing -> Right (dm ++ [(fdDelim field, field)])

-- ---------------------------------------------------------------------------
-- JSON output
-- ---------------------------------------------------------------------------

-- toJSON converts parsed records to a JSON string with 2-space indentation and
-- a trailing newline. It fails (like the reference encoder) for non-finite
-- numbers.
toJSON :: [Record] -> Either String String
toJSON records = do
  items <- mapM jsonRecord records
  pure $ case records of
    [] -> "[]\n"
    _ -> "[\n  " ++ intercalate ",\n  " items ++ "\n]\n"

jsonRecord :: Record -> Either String String
jsonRecord record = case record of
  [] -> Right "{}"
  fields -> do
    items <- mapM jsonField fields
    pure ("{\n" ++ intercalate ",\n" items ++ "\n  }")
  where
    jsonField (key, value) = do
      rendered <- jsonValue value
      pure ("    " ++ jsonString key ++ ": " ++ rendered)

jsonValue :: Value -> Either String String
jsonValue v = case v of
  S s -> Right (jsonString s)
  D s -> Right (jsonString s)
  I n -> Right (show n)
  B b -> Right (if b then "true" else "false")
  F d
    | isNaN d -> Left "json: unsupported value: NaN"
    | isInfinite d ->
        Left ("json: unsupported value: " ++ (if d > 0 then "+Inf" else "-Inf"))
    | otherwise -> Right (show d)

jsonString :: String -> String
jsonString s = '"' : concatMap escape s ++ "\""
  where
    escape '"' = "\\\""
    escape '\\' = "\\\\"
    escape '\n' = "\\n"
    escape '\r' = "\\r"
    escape '\t' = "\\t"
    escape c
      | c < ' ' = "\\u" ++ pad4 (showHex (ord c) "")
      | otherwise = [c]
    pad4 h = replicate (4 - length h) '0' ++ h

-- ---------------------------------------------------------------------------
-- CSV output
-- ---------------------------------------------------------------------------

-- csvValue renders a value the way the reference implementations' str() does.
csvValue :: Maybe Value -> String
csvValue Nothing = ""
csvValue (Just v) = case v of
  S s -> s
  D s -> s
  B True -> "True"
  B False -> "False"
  I n -> show n
  F d ->
    let s = show d
     in if any (`elem` ".eEni") s then s else s ++ ".0"

-- escapeCSV quotes a field containing a comma, double quote, or newline,
-- doubling internal quotes.
escapeCSV :: String -> String
escapeCSV s
  | any (`elem` ",\"\n") s = "\"" ++ replaceAll "\"" "\"\"" s ++ "\""
  | otherwise = s

-- toCSV converts parsed records to a CSV string.
toCSV :: [Record] -> String
toCSV [] = ""
toCSV records =
  intercalate "\n" (header : rows)
  where
    allKeys = foldl' addKeys [] (map (map fst) records)
    addKeys acc keys = foldl' (\a k -> if k `elem` a then a else a ++ [k]) acc keys
    header = intercalate "," (map escapeCSV allKeys)
    rows =
      [ intercalate ","
          [ escapeCSV (csvValue (lookup k record))
          | k <- allKeys
          ]
      | record <- records
      ]

-- ---------------------------------------------------------------------------
-- CLI
-- ---------------------------------------------------------------------------

usage :: String
usage = "Usage: kdg <parse|validate|convert> <file> [json|csv]"

readFileUtf8 :: FilePath -> IO String
readFileUtf8 path = do
  h <- openFile path ReadMode
  hSetEncoding h utf8
  s <- hGetContents h
  _ <- evaluate (length s)
  pure s

run :: String -> FilePath -> [String] -> IO ()
run command file rest = do
  result <- try (readFileUtf8 file)
  case result of
    Left (e :: IOException) -> do
      if isDoesNotExistError e
        then hPutStrLn stderr ("Error: File not found: " ++ file)
        else hPutStrLn stderr ("Error reading file: " ++ show e)
      exitFailure
    Right content -> case command of
      "parse" -> case parseDoc content of
        Left err -> parseError (errorText err)
        Right records -> case toJSON records of
          Left msg -> parseError msg
          Right out -> putStr out
      "validate" -> case parseDoc content of
        Left err -> do
          hPutStrLn stderr ("Invalid: " ++ errorText err)
          exitFailure
        Right _ -> putStrLn "Valid KDG document"
      "convert" -> case parseDoc content of
        Left err -> parseError (errorText err)
        Right records -> case format rest of
          "json" -> case toJSON records of
            Left msg -> parseError msg
            Right out -> putStr out
          "csv" -> putStrLn (toCSV records)
          other -> do
            hPutStrLn stderr ("Unknown format: " ++ other)
            exitFailure
      _ -> do
        hPutStrLn stderr ("Unknown command: " ++ command)
        hPutStrLn stderr usage
        exitFailure
  where
    format = \case
      (f : _) -> f
      [] -> "json"
    parseError msg = do
      hPutStrLn stderr ("Parse error: " ++ msg)
      exitFailure

main :: IO ()
main = do
  args <- getArgs
  case args of
    (command : file : rest) -> run command file rest
    _ -> do
      hPutStrLn stderr usage
      exitFailure
