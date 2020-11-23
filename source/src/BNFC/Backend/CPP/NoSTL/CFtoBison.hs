{-# LANGUAGE OverloadedStrings #-}

{-
    BNF Converter: Bison generator
    Copyright (C) 2004  Author:  Michael Pellauer

    Description   : This module generates the Bison input file.
                    Note that because of the way bison stores results
                    the programmer can increase performance by limiting
                    the number of entry points in their grammar.

    Author        : Michael Pellauer
    Created       : 6 August, 2003
-}

module BNFC.Backend.CPP.NoSTL.CFtoBison (cf2Bison) where

import Data.Char  ( toLower )
import Data.List  ( intersperse, nub )
import Data.Maybe ( fromMaybe )
import qualified Data.Map as Map

import BNFC.CF
import BNFC.Backend.Common.NamedVariables hiding (varName)
import BNFC.Backend.C.CFtoBisonC
  ( resultName, specialToks, startSymbol, typeName, varName )
import BNFC.Backend.CPP.STL.CFtoBisonSTL ( tokens, union, definedRules )
import BNFC.PrettyPrint
import BNFC.Utils ( (+++) )

--This follows the basic structure of CFtoHappy.

-- Type declarations
type Rules       = [(NonTerminal,[(Pattern,Action)])]
type Pattern     = String
type Action      = String
type MetaVar     = String

--The environment comes from the CFtoFlex
cf2Bison :: String -> CF -> SymMap -> String
cf2Bison name cf env
 = unlines
    [header name cf,
     render $ union Nothing (allParserCats cf),
     "%token _ERROR_",
     tokens user env,
     declarations cf,
     startSymbol cf,
     specialToks cf,
     "%%",
     prRules (rulesForBison name cf env)
    ]
  where
   user = fst (unzip (tokenPragmas cf))

header :: String -> CF -> String
header name cf = unlines
    [ "/* This Bison file was machine-generated by BNFC */"
    , "%{"
    , "#include <stdlib.h>"
    , "#include <stdio.h>"
    , "#include <string.h>"
    , "#include \"Absyn.H\""
    , ""
    , "#define YYMAXDEPTH 10000000"  -- default maximum stack size is 10000, but right-recursion needs O(n) stack
    , ""
    , "int yyparse(void);"
    , "int yylex(void);"
    , "int yy_mylinenumber;"  --- hack to get line number. AR 2006
    , "void initialize_lexer(FILE * inp);"
    , "int yywrap(void)"
    , "{"
    , "  return 1;"
    , "}"
    , "void yyerror(const char *str)"
    , "{"
    , "  extern char *yytext;"
    , "  fprintf(stderr,\"error: line %d: %s at %s\\n\", "
    , "    yy_mylinenumber + 1, str, yytext);"
    , "}"
    , ""
    , definedRules cf
    , concatMap reverseList $ filter isList $ allParserCatsNorm cf
    , unlines $ map parseResult dats
    , unlines $ map (parseMethod cf name) eps
    , "%}"
    ]
  where
  eps  = allEntryPoints cf
  dats = nub $ map normCat eps



-- | Generates declaration and initialization of the @YY_RESULT@ for a parser.
--
--   Different parsers (for different precedences of the same category)
--   share such a declaration.
--
--   Expects a normalized category.
parseResult :: Cat -> String
parseResult cat =
  "static " ++ cat' ++ "*" +++ resultName cat' +++ "= 0;"
  where
  cat' = identCat cat


--This generates a parser method for each entry point.
parseMethod :: CF -> String -> Cat -> String
parseMethod cf _ cat = unlines
  [
   dat ++"* p" ++ par ++ "(FILE *inp)",
   "{",
   "  initialize_lexer(inp);",
   "  if (yyparse())",
   "  { /* Failure */",
   "    return 0;",
   "  }",
   "  else",
   "  { /* Success */",
   "    return" +++ res ++ ";",
   "  }",
   "}"
  ]
 where
  dat  = identCat (normCat cat)
  par  = identCat cat
  res0   = resultName dat
  revRes = "reverse" ++ dat ++ "(" ++ res0 ++ ")"
  res    = if cat `elem` cfgReversibleCats cf then revRes else res0

--This method generates list reversal functions for each list type.
reverseList :: Cat -> String
reverseList c = unlines
 [
  c' ++ "* reverse" ++ c' ++ "(" ++ c' +++ "*l)",
  "{",
  "  " ++ c' +++"*prev = 0;",
  "  " ++ c' +++"*tmp = 0;",
  "  while (l)",
  "  {",
  "    tmp = l->" ++ v ++ ";",
  "    l->" ++ v +++ "= prev;",
  "    prev = l;",
  "    l = tmp;",
  "  }",
  "  return prev;",
  "}"
 ]
 where
  c' = identCat (normCat c)
  v = (map toLower c') ++ "_"

--declares non-terminal types.
declarations :: CF -> String
declarations cf = concatMap (typeNT cf) (allParserCats cf)
 where --don't define internal rules
   typeNT cf nt | rulesForCat cf nt /= [] = "%type <" ++ varName nt ++ "> " ++ identCat nt ++ "\n"
   typeNT _ _ = ""

--The following functions are a (relatively) straightforward translation
--of the ones in CFtoHappy.hs
rulesForBison :: String -> CF -> SymMap -> Rules
rulesForBison _ cf env = map mkOne $ ruleGroups cf where
  mkOne (cat,rules) = constructRule cf env rules cat

-- For every non-terminal, we construct a set of rules.
constructRule :: CF -> SymMap -> [Rule] -> NonTerminal -> (NonTerminal,[(Pattern,Action)])
constructRule cf env rules nt = (nt,[(p,(generateAction (ruleName r) b m) +++ result) |
     r0 <- rules,
     let (b,r) = if isConsFun (funRule r0) && elem (valCat r0) revs
                   then (True,revSepListRule r0)
                 else (False,r0),
     let (p,m) = generatePatterns cf env r])
 where
   ruleName r = case funName $ funRule r of
     "(:)" -> identCat (normCat nt)
     "(:[])" -> identCat (normCat nt)
     z -> z
   revs = cfgReversibleCats cf
   eps = allEntryPoints cf
   isEntry nt = if elem nt eps then True else False
   result = if isEntry nt then (resultName (identCat (normCat nt))) ++ "= $$;" else ""

-- Generates a string containing the semantic action.
generateAction :: Fun -> Bool -> [MetaVar] -> Action
generateAction f b ms =
  if isCoercion f
  then (unwords ms) ++ ";"
  else if f == "[]"
  then "0;"
  else if isDefinedRule f
  then concat [ f, "_", "(", concat $ intersperse ", " ms', ");" ]
  else concat ["new ", f, "(", (concat (intersperse ", " ms')), ");"]
 where
  ms' = if b then reverse ms else ms

-- Generate patterns and a set of metavariables indicating
-- where in the pattern the non-terminal
generatePatterns :: CF -> SymMap -> Rule -> (Pattern,[MetaVar])
generatePatterns cf env r = case rhsRule r of
  []  -> ("/* empty */",[])
  its -> (unwords (map mkIt its), metas its)
 where
   mkIt i = case i of
     Left (TokenCat s) -> fromMaybe (typeName s) $ Map.lookup (Tokentype s) env
     Left  c -> identCat c
     Right s -> fromMaybe s $ Map.lookup (Keyword s) env
   metas its = [revIf c ('$': show i) | (i,Left c) <- zip [1 :: Int ..] its]
   revIf c m = if (not (isConsFun (funRule r)) && elem c revs)
                 then ("reverse" ++ (identCat (normCat c)) ++ "(" ++ m ++ ")")
               else m  -- no reversal in the left-recursive Cons rule itself
   revs = cfgReversibleCats cf

-- We have now constructed the patterns and actions,
-- so the only thing left is to merge them into one string.

prRules :: Rules -> String
prRules [] = []
prRules ((_, []):rs) = prRules rs --internal rule
prRules ((nt,((p,a):ls)):rs) =
  (unwords [nt', ":" , p, "{ $$ =", a, "}", "\n" ++ pr ls]) ++ ";\n" ++ prRules rs
 where
  nt' = identCat nt
  pr []           = []
  pr ((p,a):ls)   = (unlines [(concat $ intersperse " " ["  |", p, "{ $$ =", a , "}"])]) ++ pr ls
