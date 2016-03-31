-- | Parse glyph files in Muse-CGH's text format.

{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TupleSections #-}

module Longhand.Parse (
    -- * Glyph File Parsing
    parseGlyphFiles
  , parseGlyphFile
  , parseGlyphData
  ) where

import Control.Applicative
import Control.Exception

import Data.Attoparsec.ByteString
import Data.Attoparsec.ByteString.Char8
import Data.Attoparsec.Combinator

import Data.Bifunctor
import Data.Char
import Data.Data
import Data.Either
import Data.List
import Data.Typeable

import Data.ByteString (ByteString)
import qualified Data.ByteString as B

import Data.CharMap.Strict (CharMap)
import qualified Data.CharMap.Strict as M

import Diagrams.Prelude (P2, mkP2)

import GHC.Generics

import Longhand.Types

--------------------------------------------------------------------------------
-- Glyph File Parsing ----------------------------------------------------------
--------------------------------------------------------------------------------

parseGlyphFiles :: [(FilePath, [Char])]
                -> IO (Either [(FilePath, String)] GlyphMap)
parseGlyphFiles pairs = do
  results <- mapM parse pairs
  let (errs, glyphs) = partitionEithers results
  return $ case errs of
    [] -> Right $ M.fromList $ concat glyphs
    _  -> Left  $ errs
  where
    parse (f, cs) = do
      result <- parseGlyphFile f
      return $ case result of
        Left  err -> Left (f, err)
        Right out -> Right $ map (\c -> (c, out)) cs


parseGlyphFile :: FilePath -> IO (Either String Glyph)
parseGlyphFile = fmap parseGlyphData . B.readFile

parseGlyphData :: ByteString -> Either String Glyph
parseGlyphData = parseOnly editingP

--------------------------------------------------------------------------------
-- Parse Muse-CGH Glyph Text File Format ---------------------------------------
--------------------------------------------------------------------------------

editingP :: Parser Glyph
editingP = scalaTypeP "Editing" $ glyphP <* comma <* listP (signed decimal)

glyphP :: Parser Glyph
glyphP = scalaTypeP "Letter" $ do
  strokes <- listP glyphStrokeP
  kind    <- option LowerCaseLetter (comma *> glyphKindP)
  let (main, hats) = breakStrokes strokes
  let (head, body, tail) = groupMainStrokes kind main
  return $ Glyph
    { glyphKind = kind
    , glyphHead = head
    , glyphBody = body
    , glyphTail = tail
    , glyphHats = hats
    }

glyphKindP :: Parser GlyphKind
glyphKindP = (UpperCaseLetter <$ (string "Uppercase" <|> string "UpperCase"))
         <|> (LowerCaseLetter <$ (string "Lowercase" <|> string "LowerCase"))
         <|> (PunctuationMark <$ string "PunctuationMark")

glyphStrokeP :: Parser (GlyphStroke, Bool)
glyphStrokeP = scalaTypeP "LetterSeg" $ do
  curve         <- glyphCurveP <* comma
  startWidth    <- double      <* comma
  endWidth      <- double      <* comma
  _alignTangent <- boolP       <* comma
  isBreak       <- boolP
  return $ (, isBreak) $ GlyphStroke
    { glyphStrokeCurve      = curve
    , glyphStrokeType       = LerpStroke
    , glyphStrokeStartWidth = startWidth
    , glyphStrokeEndWidth   = endWidth
    }

glyphCurveP :: Parser GlyphCurve
glyphCurveP = scalaTypeP "CubicCurve" $ do
  st <- vec2P <* comma
  c1 <- vec2P <* comma
  c2 <- vec2P <* comma
  ed <- vec2P
  return $ GlyphCurve
    { glyphCurveStartPoint    = st
    , glyphCurveControlPoint1 = c1
    , glyphCurveControlPoint2 = c2
    , glyphCurveEndPoint      = ed
    }

vec2P :: Parser (P2 Double)
vec2P = scalaTypeP "Vec2" $ do
  x <- double <* comma
  y <- double
  return $ mkP2 x (-y)


breakStrokes :: [(GlyphStroke, Bool)] -> ([GlyphStroke], [GlyphStroke])
breakStrokes strokes = case secondary of
  []     -> (main, [])
  (x:xs) -> (main ++ [x], xs)
  where
    (main, secondary) = bimap (fst <$>) (fst <$>) $ break snd strokes

groupMainStrokes :: GlyphKind -> [GlyphStroke]
                 -> (Maybe GlyphStroke, [GlyphStroke], Maybe GlyphStroke)
groupMainStrokes LowerCaseLetter strokes = (head, body, tail)
  where
    (head, rest) = case strokes of
      []     -> (Nothing, [])
      (x:xs) -> (Just x, xs)
    (body, tail) = case rest of
      []    -> ([], Nothing)
      (_:_) -> (init rest, Just $ last rest)
groupMainStrokes _ strokes = (Nothing, strokes, Nothing)

--------------------------------------------------------------------------------
-- Scala Type Parsers ----------------------------------------------------------
--------------------------------------------------------------------------------

boolP :: Parser Bool
boolP = (True  <$ string "true")
    <|> (False <$ string "false")

listP :: Parser a -> Parser [a]
listP = scalaTypeP' (string "List" <|> string "Vector") . (`sepBy` comma)


scalaTypeP :: ByteString -> Parser a -> Parser a
scalaTypeP = scalaTypeP' . string

scalaTypeP' :: Parser b -> Parser a -> Parser a
scalaTypeP' name args = name *> parens args

--------------------------------------------------------------------------------
-- Misc Parsing Utilities ------------------------------------------------------
--------------------------------------------------------------------------------

between :: Parser a -> Parser b -> Parser c -> Parser c
between start stop inner = start *> inner <* stop

parens :: Parser a -> Parser a
parens = between lparen rparen


lparen :: Parser Char
lparen = char '('

rparen :: Parser Char
rparen = char ')'

comma :: Parser Char
comma = char ',' <* skipMany space

