module CPi.ParserNew where

import Text.Megaparsec
import Text.Megaparsec.String
import Text.Megaparsec.Expr
import Text.Megaparsec.Prim (MonadParsec)
import qualified Text.Megaparsec.Lexer as LEX
import qualified Data.Map as M
import Control.Monad
import Data.Hashable (hash)
import Data.Maybe
import Data.Scientific (toRealFloat)
import Data.Bifunctor
-- import Control.Applicative

import CPi.AST hiding ((<|>))
import CPi.Symbolic

parseFile :: String -> String -> Either (ParseError Char Dec) (CPiModel Conc)
parseFile = runParser model

-- Species:

spaceConsumer :: Parser ()
spaceConsumer = LEX.space (void spaceChar) lineCmnt blockCmnt
  where lineCmnt  = LEX.skipLineComment "--"
        blockCmnt = LEX.skipBlockComment "{-" "-}"

lexeme :: Parser a -> Parser a
lexeme = LEX.lexeme spaceConsumer

symbol :: String -> Parser String
symbol = LEX.symbol spaceConsumer

parens :: Parser a -> Parser a
parens = between (symbol "(") (symbol ")")

brackets :: Parser a -> Parser a
brackets = between (symbol "[") (symbol "]")

braces :: Parser a -> Parser a
braces = between (symbol "{") (symbol "}")

angles :: Parser a -> Parser a
angles = between (symbol "<") (symbol ">")

semi :: Parser String
semi = symbol ";"

comma :: Parser String
comma = symbol ","

at :: Parser String
at = symbol "@"

arrow :: Parser String
arrow = symbol "->" <|> symbol "."

reservedWord :: String -> Parser ()
reservedWord w = string w *> notFollowedBy alphaNumChar *> spaceConsumer

reservedWords :: [String]
reservedWords = ["new", "species", "network", "process", "ratelaw", "0"]

symbReservedWords :: [String]
symbReservedWords = ["sin", "sinh", "asin", "asinh",
                     "cos", "cosh", "acos", "acosh",
                     "tan", "tanh", "atan", "atanh",
                     "exp", "log", "sign", "abs"]

symbIdentifier :: Parser String
symbIdentifier = (lexeme . try) (p >>= check)
  where p       = (:) <$> letterChar <*> many alphaNumChar
        check x = if x `elem` symbReservedWords
                  then fail $ "name " ++ show x
                                      ++ " cannot be used, as it is reserved"
                  else return x

identifier :: Parser String
identifier = (lexeme . try) (p >>= check)
  where p       = (:) <$> lowerChar <*> many alphaNumChar
        check x = if x `elem` reservedWords
                  then fail $ "name " ++ show x
                                      ++ " cannot be used, as it is reserved"
                  else return x

locationName :: Parser String
locationName = (lexeme . try) (p >>= check)
  where p       = (:) <$> (numberChar <|> lowerChar) <*> many alphaNumChar
        check x = if x `elem` reservedWords && x /= "0"
                  then fail $ "name " ++ show x
                                      ++ " cannot be used, as it is reserved"
                  else return x

definitionName :: Parser String
definitionName = (lexeme . try) (p >>= check)
  where p       = (:) <$> upperChar <*> many alphaNumChar
        check x = if x `elem` reservedWords
                  then fail $ "name " ++ show x
                                      ++ " cannot be used, as it is reserved"
                  else return x

number :: Parser Double
number =  LEX.signed spaceConsumer (toRealFloat <$> lexeme LEX.number)

prefix :: Parser Prefix
prefix = lexeme $ do
  name <- identifier
  location <- optional $ do
    void at
    locationName
  return $ case location of
    Just loc -> Located name (fromIntegral $ hash loc)
    Nothing  -> Unlocated name

nil :: Parser Species
nil = const Nil <$> symbol "0"

prefixGuard :: Parser (Prefix, Abstraction)
prefixGuard = do
  pref <- prefix
  abst <- optional $ parens locationName
  sp <- optional $ do
    void $ symbol "->"
    abst' <- optional $ try $ parens locationName
    spec <- atom
    let abst'' = if isNothing abst then abst' else abst
    if isJust abst && isJust abst'
    then fail "trying to bind both before and after guard"
    else return (abst'', spec)
  -- let spec = fromMaybe Nil sp
  return (pref, case sp of
    Just (abst', spec) -> case abst' of
                            Just l  -> mkAbs (fromIntegral $ hash l) spec
                            Nothing -> mkAbsBase spec
    Nothing            -> case abst of
                            Just l  -> mkAbs (fromIntegral $ hash l) Nil
                            Nothing -> mkAbsBase Nil)

guardedSum :: Parser Species
guardedSum = do
  prefSpecs <- prefixGuard `sepBy1` symbol "+"
  return $ mkSum prefSpecs

guardedSum1 :: Parser Species
guardedSum1 = do
  prefSpec <- prefixGuard
  return $ mkSum [prefSpec]

def :: Parser Species
def = do
  name <- definitionName
  (args, locs) <- fmap (fromMaybe ([], [])) $ optional $ parens $ do
    args <- identifier `sepBy` comma
    locs <- fmap (map (fromIntegral . hash) . fromMaybe []) <$> optional $ do
      _ <- semi
      locationName `sepBy` comma
    return (args, locs)
  return $ Def name args locs

atom :: Parser Species
atom = nil <|> def <|> parens species <|> guardedSum1 <|> emptyPar <|> emptySum

term :: Parser Species
term = guardedSum <|> atom <|> restrictionSimple

restrictionOver :: Parser Species -> Parser Species
restrictionOver base = do
  _ <- symbol "new"
  locs <- locationName `sepBy1` comma
  _ <- symbol "in"
  spec <- base
  return $ mkNew (map (fromIntegral . hash) locs) spec

restriction :: Parser Species
restriction = restrictionOver species

restrictionSimple :: Parser Species
restrictionSimple = restrictionOver term

emptyPar :: Parser Species
emptyPar = do
  _ <- symbol "<Empty Par>"
  return $ mkPar []

emptySum :: Parser Species
emptySum = do
  _ <- symbol "<Empty Sum>"
  return $ mkSum []

-- a version of sepBy1 which only tries to continue capturing the next term,
-- rather than committing - this prevents the parser from being confused by the
-- difference between || and |
sepBy1' :: MonadParsec e s f => f a -> f b -> f [a]
sepBy1' p sep = go
  where go = try ((:) <$> (p <* sep) <*> go) <|> ((: []) <$> p)

parallel :: Parser Species
parallel = do
  specs <- term `sepBy1'` symbol "|"
  return $ case specs of
             [spec] -> spec
             _      -> mkPar specs

species :: Parser Species
species = restriction <|> parallel

-- Processes:
processComponent :: Parser (Conc, Species)
processComponent = do
  c <- brackets number
  s <- species
  return (c, s)

affinityNetworkAppl :: Parser AffinityNetworkSpec
affinityNetworkAppl = do
  name <- definitionName
  rates <- optional $ parens $ number `sepBy` comma
  let rates' = fromMaybe [] rates
  return $ AffinityNetworkAppl name rates'

process :: Parser AbstractProcess
process = do
  components <- processComponent `sepBy` symbol "||"
  _ <- symbol "with"
  _ <- symbol "network"
  network <- affinityNetworkAppl
  return $ Process network components

-- Symbolic expressions

symbExpr :: Parser SymbolicExpr
symbExpr = makeExprParser symbTerm symbExprTable
  where symbExprTable = [ [ prefixOp "-" negate
                          , prefixOp "+" id ]
                        , [ binaryOp "**" (**)
                          , binaryOp "^" (**) ]
                        , [ binaryOp "*" (*)
                          , binaryOp "/" (/) ]
                        , [ binaryOp "+" (+)
                          , binaryOp "-" (-) ] ]
        binaryOp name f = InfixL (f <$ symbol name)
        prefixOp name f = Prefix (f <$ symbol name)

symbTerm :: Parser SymbolicExpr
symbTerm = parens symbExpr
       <|> symbol "sin"   *> (sin    <$> symbTerm)
       <|> symbol "sinh"  *> (sinh   <$> symbTerm)
       <|> symbol "asin"  *> (asin   <$> symbTerm)
       <|> symbol "asinh" *> (asinh  <$> symbTerm)
       <|> symbol "cos"   *> (cos    <$> symbTerm)
       <|> symbol "cosh"  *> (cosh   <$> symbTerm)
       <|> symbol "acos"  *> (acos   <$> symbTerm)
       <|> symbol "acosh" *> (cosh   <$> symbTerm)
       <|> symbol "tan"   *> (tan    <$> symbTerm)
       <|> symbol "tanh"  *> (tanh   <$> symbTerm)
       <|> symbol "atan"  *> (atan   <$> symbTerm)
       <|> symbol "atanh" *> (atanh  <$> symbTerm)
       <|> symbol "exp"   *> (exp    <$> symbTerm)
       <|> symbol "log"   *> (log    <$> symbTerm)
       <|> symbol "abs"   *> (abs    <$> symbTerm)
       <|> symbol "sign"  *> (signum <$> symbTerm)
       <|> val <$> number
       <|> var <$> symbIdentifier

-- Definitions:
kineticLawDef :: Parser (String, KineticLawDefinition)
kineticLawDef = do
  _ <- symbol "kinetic"
  _ <- symbol "law"
  name <- definitionName
  (params, args) <- parens $ do
    params <- symbIdentifier `sepBy` comma
    _ <- semi
    args <- symbIdentifier `sepBy` comma
    return (params, args)
  _ <- symbol "="
  body <- symbExpr
  _ <- semi
  let unboundVars = filter (`notElem` (params ++ args)) $ freeVars body
  if null unboundVars
  then return (name, KineticLawDef params args body)
  else fail $ "Definition of " ++ name ++ " which binds "
              ++ show (params ++ args) ++ " contains unbound variables."

concreteKineticLawDef :: Parser (String, RateLawFamily Conc)
concreteKineticLawDef = second concretifyKineticLaw <$> kineticLawDef

processDef :: Parser (String, AbstractProcess)
processDef = do
  _ <- symbol "process"
  name <- definitionName
  _ <- symbol "="
  p <- process
  _ <- semi
  return (name, p)

siteList :: Parser [String]
siteList = identifier `sepBy1` symbol "+"

rateLawParam :: Parser RateLawParam
rateLawParam = variable <|> value
  where variable = fmap RateLawParamVar identifier
        value    = fmap RateLawParamVal number

rateLawAppl :: Parser RateLawSpec
rateLawAppl = do
  name <- definitionName
  params <- optional $ parens $ rateLawParam `sepBy` comma
  let params' = fromMaybe [] params
  return $ RateLawAppl name params'

affinity :: Parser Affinity
affinity = do
  sites <- siteList `sepBy1` comma
  _ <- symbol "at"
  _ <- symbol "rate"
  rateLaw <- rateLawAppl
  return $ Affinity rateLaw sites

affinityNetworkDef :: Parser (String, AffinityNetworkDefinition)
affinityNetworkDef = do
  _ <- symbol "affinity"
  _ <- symbol "network"
  name <- definitionName
  rates <- optional $ parens $ identifier `sepBy` comma
  let rates' = fromMaybe [] rates
  _ <- symbol "="
  affinities <- braces $ many $ do aff <- affinity
                                   _ <- semi
                                   return aff
  return (name, AffinityNetworkDef rates' affinities)

speciesDef :: Parser (String, SpeciesDefinition)
speciesDef = do
  _ <- symbol "species"
  name <- definitionName
  argSpec <- optional $ parens $ do
    args <- identifier `sepBy` comma
    _ <- semi
    locs <- locationName `sepBy` comma
    return (args, locs)
  let (args, locs) = fromMaybe ([], []) argSpec
      locs' = map (fromIntegral . hash) locs
  _ <- symbol "="
  body <- species
  _ <- semi
  let unboundLocs = filter (`notElem` locs') $ freeLocs body
  if null unboundLocs
  then return (name, SpeciesDef args locs' body)
  else fail $ "Definition of " ++ name ++ " which binds " ++ show locs
              ++ " contains unbound locations."

definition :: Parser (CPiModel Conc)
definition = sDef <|> pDef <|> aDef <|> kDef
  where -- we use a real empty model, rather than the default template as we
        -- will combine with this as unit later
        z = Defs M.empty M.empty M.empty M.empty
        sDef = (\(n,x) -> addSpeciesDef n x z) <$> speciesDef
        pDef = (\(n,x) -> addProcessDef n x z) <$> processDef
        kDef = (\(n,x) -> addKineticLawDef n x z) <$> concreteKineticLawDef
        aDef = (\(n,x) -> addAffinityNetworkDef n x z) <$> affinityNetworkDef

model :: Parser (CPiModel Conc)
model = foldl combineModels emptyCPiModel <$> many definition
