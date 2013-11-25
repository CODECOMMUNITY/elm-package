{-# LANGUAGE OverloadedStrings #-}
module Registry.Generate.Elm (generate) where

import Control.Monad.Error
import Control.Applicative ((<$>),(<*>))
import qualified Data.Aeson as Json
import qualified Data.Map as Map
import qualified Data.List as List
import qualified Data.Char as Char
import qualified Data.Maybe as Maybe
import qualified Data.Either as Either
import qualified Data.ByteString.Lazy.Char8 as BS
import qualified System.FilePath as FP
import qualified System.Directory as Dir
import System.FilePath ((</>), (<.>))
import Text.Parsec

import Model.Documentation
import qualified Registry.Utils as Utils

generate :: FilePath -> ErrorT String IO [FilePath]
generate directory =
    do json <- liftIO $ BS.readFile $ directory </> Utils.json
       case mapM docToElm =<< Json.eitherDecode json of
         Left err -> throwError err
         Right docs -> liftIO $ mapM (writeDocs directory) docs

writeDocs :: FilePath -> (String,String) -> IO FilePath
writeDocs directory (name, code) =
  do writeFile fileName code
     return fileName
  where
    fileName = directory </> map (\c -> if c == '.' then '-' else c) name <.> "elm"

docToElm :: Document -> Either String (String,String)
docToElm doc =
  do contents <- either (Left . show) Right $ parse (parseDoc []) name (structure doc)
     case Either.partitionEithers $ map (contentToElm (getEntries doc)) contents of
       ([], code) ->
           Right . (,) name $
           unlines [ "import open Docs"
                   , "import Search"
                   , "import Window"
                   , ""
                   , "main = documentation " ++ show name ++ " entries <~ Window.dimensions ~ Search.box ~ Search.results"
                   , ""
                   , "entries ="
                   , "  [ " ++ List.intercalate "\n  , " code ++ "\n  ]"
                   ]
       (missing, _) ->
           Left $ "In module " ++ name ++ ", could not find documentation for: " ++ List.intercalate ", " missing
  where
    name = moduleName doc
    entries = getEntries doc

    parseDoc contents =
        choice [ eof >> return contents
               , do try (string "@docs")
                    whitespace
                    values <- sepBy1 (var <|> op) comma
                    parseDoc (contents ++ map Value values)
               , do let stop = eof <|> try (string "@docs" >> return ())
                    md <- manyTill anyChar (lookAhead stop)
                    parseDoc (contents ++ [Markdown md])
               ]

    var = (:) <$> letter <*> many (alphaNum <|> oneOf "_'")
    op = do char '(' >> whitespace
            operator <- many1 (satisfy Char.isSymbol <|> oneOf "+-/*=.$<>:&|^?%#@~!")
            whitespace >> char ')'
            return operator

    comma = try (whitespace >> char ',') >> whitespace
    whitespace = many (satisfy (`elem` " \n\r"))

getEntries :: Document -> Map.Map String Entry
getEntries doc =
    Map.fromList $ map (\entry -> (name entry, entry)) (entries doc)

contentToElm :: Map.Map String Entry -> Content -> Either String String
contentToElm entries content =
    case content of
      Markdown md -> Right $ "flip width [markdown|<style>h1,h2,h3,h4 {font-weight:normal;} h1 {font-size:24px;} h2 {font-size:20px;}</style>" ++ md ++ "|]"
      Value name ->
          case Map.lookup name entries of
            Nothing -> Left name
            Just entry ->
                Right $ unwords [ "entry"
                                , show name
                                , show (raw entry)
                                , case assocPrec entry of
                                    Nothing -> "Nothing"
                                    Just ap -> "(" ++ show (Just ap) ++ ")"
                                , "[markdown|" ++ comment entry ++ "|]"
                                ]
