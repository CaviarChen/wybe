--  File     : Scanner.hs
--  Author   : Peter Schachte
--  Purpose  : Lexical scanner for the Wybe language
--  Copyright: (c) 2010-2012 Peter Schachte.  All rights reserved.
--  License  : Licensed under terms of the MIT license.  See the file
--           : LICENSE in the root directory of this project.


module Scanner (Token(..), tokenPosition, floatValue, intValue, stringValue,
                charValue, identName, symbolName, showPosition, 
                StringDelim(..), BracketStyle(..), fileTokens, tokenise,
                inputTokens) where

import AST
import Data.Char
import Data.List
import Text.ParserCombinators.Parsec.Pos

-- |The tokens of the wybe language, each carrying its source position.
data Token = TokFloat Double SourcePos          -- ^A floating point number
              | TokInt Integer SourcePos        -- ^An integer
              | TokString StringDelim String SourcePos
                                                -- ^A string with its delimiter
              | TokChar Char SourcePos          -- ^A character constant
              | TokIdent String SourcePos       -- ^An identifier
              | TokLBracket BracketStyle SourcePos
                                                -- ^Some kind of left bracket
              | TokRBracket BracketStyle SourcePos
                                                -- ^Some kind of right bracket
              | TokComma SourcePos              -- ^A comma
              | TokSymbol String SourcePos      -- ^A symbol of made up of
                                                --  non-identifier chars
              | TokError String SourcePos       -- ^A lexical error
              deriving (Show)

-- |Returns the source position of a token.
tokenPosition :: Token -> SourcePos
tokenPosition (TokFloat _     pos) = pos
tokenPosition (TokInt   _     pos) = pos
tokenPosition (TokString _ _  pos) = pos
tokenPosition (TokChar _      pos) = pos
tokenPosition (TokIdent _     pos) = pos
tokenPosition (TokLBracket _  pos) = pos
tokenPosition (TokRBracket _  pos) = pos
tokenPosition (TokComma       pos) = pos
tokenPosition (TokSymbol _    pos) = pos
tokenPosition (TokError _     pos) = pos

-- |Returns the value of a float token.
floatValue :: Token -> Double
floatValue (TokFloat float _) = float
floatValue _ = shouldnt "not a float"

-- |Returns the value of an int token.
intValue :: Token -> Integer
intValue (TokInt int _) = int
intValue _ = shouldnt "not an int"

-- |Returns the value of a string token.
stringValue :: Token -> String
stringValue (TokString _ string _) = string
stringValue _ = shouldnt "not a string"

-- |Returns the value of a character constant token.
charValue :: Token -> Char
charValue (TokChar char _) = char
charValue _ = shouldnt "not a char"

-- |Returns the name of an identifier token.
identName :: Token -> String
identName (TokIdent str _) = str
identName _ = shouldnt "not an ident"

-- |Returns the name of a symbol token.
symbolName :: Token -> String
symbolName (TokSymbol str _) = str
symbolName _ = shouldnt "not a symbol"

-- |How to display a source position.
showPosition :: SourcePos -> String
showPosition pos
  = sourceName pos ++ ":" 
    ++ show (sourceLine pos) ++ ":"
    ++ show (sourceColumn pos)

-- |The different string delimiters.
data StringDelim = DoubleQuote | BackQuote | LongQuote String
                 deriving (Show)

-- |The different kinds of brackets.
data BracketStyle = Paren | Bracket | Brace
                  deriving (Show, Eq)


-- |The contents of a file as a list of tokens.
fileTokens :: FilePath -> IO [Token]
fileTokens filename =
  do content <- readFile filename
     return (tokenise (initialPos filename) content)


-- |The contents of stdin as a list of tokens.
inputTokens :: IO [Token]
inputTokens =
  do content <- getContents
     return (tokenise (initialPos "<stdin>") content)


-- |Convert a sequence of characters to a sequence of tokens.
tokenise :: SourcePos -> String -> [Token]
tokenise _ [] = []
tokenise pos str@(c:cs)
  | isSpace c || isControl c = tokenise (updatePosChar pos c) cs
  | isDigit c = scanNumberToken pos str
  | isAlpha c = let (name,rest) = span isIdentChar str
                in  multiCharTok name rest (TokIdent name pos) pos
  | otherwise = case c of
                    ',' -> singleCharTok c cs pos $ TokComma pos
                    '(' -> singleCharTok c cs pos $ TokLBracket Paren pos
                    '[' -> singleCharTok c cs pos $ TokLBracket Bracket pos
                    '{' -> singleCharTok c cs pos $ TokLBracket Brace pos
                    ')' -> singleCharTok c cs pos $ TokRBracket Paren pos
                    ']' -> singleCharTok c cs pos $ TokRBracket Bracket pos
                    '}' -> singleCharTok c cs pos $ TokRBracket Brace pos
                    '\'' -> tokeniseChar pos cs
                    '\"' -> tokeniseString DoubleQuote pos cs
                    -- backquote makes anything an identifier
                    '`' -> let (name,_:rest) = break (=='`') cs
                           in  multiCharTok name rest (TokIdent name pos) pos
                    '#' -> tokenise (setSourceColumn pos 1)
                           $ dropWhile (not . (=='\n')) cs
                    _   -> tokeniseSymbol pos str

-- |Handle a single character token and tokenize the rest of the input.
singleCharTok :: Char -> String -> SourcePos -> Token -> [Token]
singleCharTok c cs pos tok = tok:(tokenise (updatePosChar pos c) cs)

-- |Handle a mult-character token and tokenize the rest of the input.
multiCharTok :: String -> String -> Token -> SourcePos -> [Token]
multiCharTok str cs tok pos = tok:(tokenise (updatePosString pos str) cs)

-- |Handle a character constant token and tokenize the rest of the input.
tokeniseChar :: SourcePos -> String -> [Token]
tokeniseChar pos ('\\':c:'\'':rest) =
  (TokChar (escapedChar c) pos) :
  tokenise 
  (updatePosChar 
   (updatePosChar (updatePosChar (updatePosChar pos '\'') c) '\\')
   '\'')
  rest
tokeniseChar pos (c:'\'':cs) =
  (TokChar c pos):
  tokenise (updatePosChar (updatePosChar (updatePosChar pos '\'') c) '\'') cs
tokeniseChar pos chars =
    error $ showPosition pos 
    ++ ": Syntax error in single character constant beginning '" 
    ++ take 3 chars ++ "..."

-- |Handle a symbol token and tokenize the rest of the input.
tokeniseSymbol :: SourcePos -> String -> [Token]
tokeniseSymbol pos (c:cs) =
  let (sym,rest) = span isSymbolChar cs
      pos' = updatePosString pos 
  in  multiCharTok (c:sym) rest (TokSymbol (c:sym) pos) pos
tokeniseSymbol _ [] = shouldnt "empty symbol does not exist"

-- |Tokenise a delimited string and tokenize the rest of the input..
-- XXX This doesn't handle escapes within strings
tokeniseString :: StringDelim -> SourcePos -> String -> [Token]
tokeniseString delim pos cs =
  let termchar = delimChar delim
      (str,rest) = span (/= termchar) cs
  in  (TokString delim str pos):
      (if null rest then [] else tokenise (updatePosChar 
                                           (updatePosString
                                            (updatePosChar pos termchar)
                                            str)
                                           termchar) $ tail rest)

-- |Is the specified char the expected final delimiter?
delimChar DoubleQuote = '\"'
delimChar _ = shouldnt "not a delimiter character"

-- |Recognise an escaped character constant.
-- XXX doesn't currently support unicode escapes
escapedChar :: Char -> Char
escapedChar 'a' = '\a'
escapedChar 'b' = '\b'
escapedChar 'f' = '\f'
escapedChar 'n' = '\n'
escapedChar 'r' = '\r'
escapedChar 't' = '\t'
escapedChar 'v' = '\v'
escapedChar c = c

-- |Scan a number token and the rest of the input.  Handles decimal and hex
--  ints, floats with decimal point and/or e notation, and ignores embedded
--  underscores in integers. Doesn't handle negative numbers.
scanNumberToken :: SourcePos -> [Char] -> [Token]
scanNumberToken pos cs =
    -- parse integer part
    let (num,rest) = span isNumberChar cs
        num' = map toLower $ filter (/='_') num
        pos' = foldl updatePosChar pos num
    in  (case num' of
          '0':'x':hexDigits
            -> parseInteger 16 hexDigits pos
          '0':'b':binaryDigits
            -> parseInteger 2 binaryDigits pos
          '0':d:octal | isOctDigit d
            -> parseInteger 8 num' pos
          _ -> let (numPart,expPart) = span (/='e') num'
                   (wholePart,fracPart) = span (/='.') numPart
                   intTok = parseInteger 10 wholePart pos
               in case (intTok,expPart,fracPart) of
                    (TokInt int _, [], [])
                      -> intTok
                    (TokError _ _, _, _)
                      -> intTok
                    (_, 'e':expDigits, _)
                      | null expDigits || any (not . isDigit) expDigits
                      -> TokError ("Invalid float '" ++ cs ++ "'") pos
                    (_, _, '.':fracDigits)
                      | null fracDigits || any (not . isDigit) fracDigits
                      -> TokError ("Invalid float '" ++ cs ++ "'") pos
                    (TokInt intPart _, _, _) ->
                      let fracDigits =
                            if null fracPart then [] else tail fracPart
                          frac =
                            foldr
                            (\c f -> (f + fromIntegral (digitToInt c)) / 10.0)
                            0
                            fracDigits
                          expDigits =
                            if null expPart then [] else tail expPart
                          exponent =
                            foldl (\e c -> e * 10 + (digitToInt c)) 0 expDigits
                          multiplier = 10.0 ** fromIntegral exponent
                          value = (fromIntegral intPart + frac) * multiplier
                      in TokFloat value pos
                    (tok, _, _) -> shouldnt $ "unexpected token "
                                            ++ show tok
                                            ++ " when parsing a number ")
        : tokenise pos' rest


-- |Convert the string to a non-negative integer in the specified radix.  The
-- string has already been vetted to contain only alphanumeric characters.  This
-- handles radices up to 36.
parseInteger :: Integer -> [Char] -> SourcePos -> Token
parseInteger radix str pos =
    if all (<radix) charValues
    then TokInt (foldl (\num val -> num * radix + val) 0 charValues) pos
    else TokError ("Invalid integer '" ++ str ++ "'") pos
  where charValues = map alNumToInteger str


-- |Returns the integer value of the specified char which is either a digit or
-- a lower case letter.
alNumToInteger :: Char -> Integer
alNumToInteger ch
  | isDigit ch = fromIntegral $ digitToInt ch
  | otherwise  = 10 + fromIntegral (fromEnum ch - fromEnum 'a')


-- |Is this a character that can appear in an identifier?
isIdentChar :: Char -> Bool
isIdentChar ch = isAlphaNum ch || ch == '_'

-- |Is this a character that can appear in a symbol?
isSymbolChar :: Char -> Bool
isSymbolChar ch = not (isAlphaNum ch || isSpace ch || isControl ch 
                       || ch `elem` ",.([{)]}#'\"\\")

-- |Is this character part of a single (not necessarily valid) number token,
-- following a digit character?  This means any alphanumeric character or a
-- decimal point.
isNumberChar :: Char -> Bool
isNumberChar ch = isIdentChar ch || ch == '.'
