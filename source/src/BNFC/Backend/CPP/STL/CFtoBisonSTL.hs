{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE PatternGuards #-}
{-# LANGUAGE TupleSections #-}

{-
    BNF Converter: C++ Bison generator
    Copyright (C) 2004  Author:  Michael Pellauer

    This program is free software; you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation; either version 2 of the License, or
    (at your option) any later version.

    This program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with this program; if not, write to the Free Software
    Foundation, 51 Franklin Street, Fifth Floor, Boston, MA 02110-1335, USA
-}

{-
   **************************************************************
    BNF Converter Module

    Description   : This module generates the Bison input file using
                    STL. The main difference to CFtoBison is in handling
                    lists: by using std::vector and push_back, our rules
                    for reverting lists are the opposite to linked lists.
                    Note that because of the way bison stores results
                    the programmer can increase performance by limiting
                    the number of entry points in their grammar.

    Author        : Michael Pellauer (pellauer@cs.chalmers.se)

    License       : GPL (GNU General Public License)

    Created       : 6 August, 2003

    Modified      : 19 August, 2006, by Aarne Ranta (aarne@cs.chalmers.se)


   **************************************************************
-}


module BNFC.Backend.CPP.STL.CFtoBisonSTL
  ( cf2Bison
  , tokens, union
  , definedRules
  ) where

import Prelude'

import Data.Char  ( isUpper )
import Data.List  ( nub, intercalate )
import Data.Maybe ( fromMaybe )
import qualified Data.Map as Map

import BNFC.Backend.C.CFtoBisonC
  ( resultName, specialToks, startSymbol, typeName, unionBuiltinTokens, varName )
import BNFC.Backend.CPP.STL.STLUtils
import BNFC.Backend.Common.NamedVariables hiding (varName)
import BNFC.CF
import BNFC.Options (RecordPositions(..))
import BNFC.PrettyPrint
import BNFC.TypeChecker
import BNFC.Utils ((+++), when)

--This follows the basic structure of CFtoHappy.

-- Type declarations
type Rules       = [(NonTerminal,[(Pattern,Action)])]
type Pattern     = String
type Action      = String
type MetaVar     = String

--The environment comes from the CFtoFlex
cf2Bison :: RecordPositions -> Maybe String -> String -> CF -> SymMap -> String
cf2Bison rp inPackage name cf env
 = unlines
    [header inPackage name cf,
     render $ union inPackage (map TokenCat (positionCats cf) ++ allParserCats cf),
     maybe "" (\ns -> "%define api.prefix {" ++ ns ++ "yy}") inPackage,
     "%token _ERROR_",
     tokens user env,
     declarations cf,
     startSymbol cf,
     specialToks cf,
     "%%",
     prRules (rulesForBison rp inPackage name cf env)
    ]
  where
   user = fst (unzip (tokenPragmas cf))


positionCats cf = filter (isPositionCat cf) $ fst (unzip (tokenPragmas cf))

header :: Maybe String -> String -> CF -> String
header inPackage name cf = unlines
    [ "/* This Bison file was machine-generated by BNFC */"
    , "%{"
    , "#include <stdlib.h>"
    , "#include <stdio.h>"
    , "#include <string.h>"
    , "#include <algorithm>"
    , "#include \"Absyn.H\""
    , ""
    , "#define YYMAXDEPTH 10000000"  -- default maximum stack size is 10000, but right-recursion needs O(n) stack
    , ""
    , "typedef struct yy_buffer_state *YY_BUFFER_STATE;"
    , "int yyparse(void);"
    , "int yylex(void);"
    , "YY_BUFFER_STATE " ++ ns ++ "yy_scan_string(const char *str);"
    , "void " ++ ns ++ "yy_delete_buffer(YY_BUFFER_STATE buf);"
    , "int " ++ ns ++ "yy_mylinenumber;"  --- hack to get line number. AR 2006
    , "void " ++ ns ++ "initialize_lexer(FILE * inp);"
    , "int " ++ ns ++ "yywrap(void)"
    , "{"
    , "  return 1;"
    , "}"
    , "void " ++ ns ++ "yyerror(const char *str)"
    , "{"
    , "  extern char *"++ns++"yytext;"
    , "  fprintf(stderr,\"error: line %d: %s at %s\\n\", "
    , "    "++ns++"yy_mylinenumber, str, "++ns++"yytext);"
    , "}"
    , ""
    , definedRules cf
    , nsStart inPackage
    , unlines $ map parseResult dats
    , unlines $ map (parseMethod cf inPackage name) eps
    , nsEnd inPackage
    , "%}"
    ]
  where
    ns   = nsString inPackage
    eps  = allEntryPoints cf ++ map TokenCat (positionCats cf)
    dats = nub $ map normCat eps

definedRules :: CF -> String
definedRules cf =
    unlines [ rule f xs e | FunDef f xs e <- cfgPragmas cf ]
  where
    ctx = buildContext cf

    list = LC (const "[]") (\ t -> "List" ++ unBase t)
      where
        unBase (ListT t) = unBase t
        unBase (BaseT x) = show $ normCat $ strToCat x

    rule f xs e =
        case checkDefinition' list ctx f xs e of
        Left err -> error $ "Panic! This should have been caught already:\n" ++ err
        Right (args,(e',t)) -> unlines
            [ cppType t ++ " " ++ f ++ "_ (" ++
                intercalate ", " (map cppArg args) ++ ") {"
            , "  return " ++ cppExp e' ++ ";"
            , "}"
            ]
      where
        cppType :: Base -> String
        cppType (ListT (BaseT x)) = "List" ++ show (normCat $ strToCat x) ++ " *"
        cppType (ListT t)         = cppType t ++ " *"
        cppType (BaseT x)
            | isToken x ctx = "String"
            | otherwise     = show (normCat $ strToCat x) ++ " *"

        cppArg :: (String, Base) -> String
        cppArg (x,t) = cppType t ++ " " ++ x ++ "_"

        cppExp :: Exp -> String
        cppExp (App "[]" []) = "0"
        cppExp (App x [])
            | x `elem` xs         = x ++ "_"  -- argument
        cppExp (App t [e])
            | isToken t ctx     = cppExp e
        cppExp (App x es)
            | isUpper (head x)  = call ("new " ++ x) es
            | otherwise         = call (x ++ "_") es
        cppExp (LitInt n)       = show n
        cppExp (LitDouble x)    = show x
        cppExp (LitChar c)      = show c
        cppExp (LitString s)    = show s

        call x es = x ++ "(" ++ intercalate ", " (map cppExp es) ++ ")"


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
parseMethod :: CF -> Maybe String -> String -> Cat -> String
parseMethod cf inPackage _ cat = unlines $ concat
  [ [ cat' ++ "* p" ++ par ++ "(FILE *inp)"
    , "{"
    , "  " ++ ns ++ "yy_mylinenumber = 1;"
    , "  " ++ ns ++ "initialize_lexer(inp);"
    , "  if (yyparse())"
    , "  { /* Failure */"
    , "    return 0;"
    , "  }"
    , "  else"
    , "  { /* Success */"
    ]
  , revOpt
  , [ "    return" +++ res ++ ";"
    , "  }"
    , "}"
    , cat' ++ "* p" ++ par ++ "(const char *str)"
    , "{"
    , "  YY_BUFFER_STATE buf;"
    , "  int result;"
    , "  " ++ ns ++ "yy_mylinenumber = 1;"
    , "  " ++ ns ++ "initialize_lexer(0);"
    , "  buf = " ++ ns ++ "yy_scan_string(str);"
    , "  result = yyparse();"
    , "  " ++ ns ++ "yy_delete_buffer(buf);"
    , "  if (result)"
    , "  { /* Failure */"
    , "    return 0;"
    , "  }"
    , "  else"
    , "  { /* Success */"
    ]
  , revOpt
  , [ "    return" +++ res ++ ";"
    , "  }"
    , "}"
    ]
  ]
  where
  cat' = identCat (normCat cat)
  par  = identCat cat
  ns   = nsString inPackage
  res  = resultName cat'
  -- Vectors are snoc lists
  revOpt = when (isList cat && cat `notElem` cfgReversibleCats cf)
             [ "std::reverse(" ++ res ++ "->begin(), " ++ res ++"->end());" ]

-- | The union declaration is special to Bison/Yacc and gives the type of
-- yylval.  For efficiency, we may want to only include used categories here.
--
-- >>> let foo = Cat "Foo"
-- >>> union Nothing [foo, ListCat foo]
-- %union
-- {
--   int    _int;
--   char   _char;
--   double _double;
--   char*  _string;
--   Foo* foo_;
--   ListFoo* listfoo_;
-- }
--
-- If the given list of categories is contains coerced categories, those should
-- be normalized and duplicate removed
-- E.g. if there is both [Foo] and [Foo2] we should only print one pointer:
--    ListFoo* listfoo_;
--
-- >>> let foo2 = CoercCat "Foo" 2
-- >>> union Nothing [foo, ListCat foo, foo2, ListCat foo2]
-- %union
-- {
--   int    _int;
--   char   _char;
--   double _double;
--   char*  _string;
--   Foo* foo_;
--   ListFoo* listfoo_;
-- }
union :: Maybe String -> [Cat] -> Doc
union inPackage cats = vcat
    [ "%union"
    , codeblock 2 $ map text unionBuiltinTokens ++ map mkPointer normCats
    ]
  where
    normCats = nub (map normCat cats)
    mkPointer s = scope <> text (identCat s) <> "*" <+> text (varName s) <> ";"
    scope = text (nsScope inPackage)

--declares non-terminal types.
declarations :: CF -> String
declarations cf = concatMap typeNT $
  map TokenCat (positionCats cf) ++
  filter (not . null . rulesForCat cf) (allParserCats cf) -- don't define internal rules
  where
  typeNT nt = "%type <" ++ varName nt ++ "> " ++ identCat nt ++ "\n"

--declares terminal types.
tokens :: [UserDef] -> SymMap -> String
tokens user env = unlines $ map declTok $ Map.toList env
  where
  declTok (Keyword   s, r) = tok "" s r
  declTok (Tokentype s, r) = tok (if s `elem` user then "<_string>" else "") s r
  tok t s r = concat [ "%token", t, " ", r, "    //   ", s ]

--The following functions are a (relatively) straightforward translation
--of the ones in CFtoHappy.hs
rulesForBison :: RecordPositions -> Maybe String -> String -> CF -> SymMap -> Rules
rulesForBison rp inPackage _ cf env = map mkOne (ruleGroups cf) ++ posRules where
  mkOne (cat,rules) = constructRule rp inPackage cf env rules cat
  posRules = (`map` positionCats cf) $ \ n -> (TokenCat n,
    [( fromMaybe n $ Map.lookup (Tokentype n) env
     , concat [ "$$ = new " , n , "($1," , nsString inPackage , "yy_mylinenumber) ; YY_RESULT_" , n , "_= $$ ;" ]
     )])

-- For every non-terminal, we construct a set of rules.
constructRule ::
  RecordPositions -> Maybe String -> CF -> SymMap -> [Rule] -> NonTerminal -> (NonTerminal,[(Pattern,Action)])
constructRule rp inPackage cf env rules nt =
  (nt,[(p, generateAction rp inPackage nt (ruleName r) b m +++ result) |
     r0 <- rules,
     let (b,r) = if isConsFun (funRule r0) && elem (valCat r0) revs
                   then (True,revSepListRule r0)
                 else (False,r0),
     let (p,m) = generatePatterns cf env r b])
 where
   ruleName r = case funRule r of
     ---- "(:)" -> identCat nt
     ---- "(:[])" -> identCat nt
     z -> z
   revs = cfgReversibleCats cf
   eps = allEntryPoints cf
   isEntry nt = nt `elem` eps
   result = if isEntry nt then (nsScope inPackage ++ resultName (identCat (normCat nt))) ++ "= $$;" else ""

-- Generates a string containing the semantic action.
generateAction :: RecordPositions -> Maybe String -> NonTerminal -> Fun -> Bool -> [(MetaVar,Bool)] -> Action
generateAction rp inPackage cat f b mbs =
  reverses ++
  if isCoercion f
  then "$$ = " ++ unwords ms ++ ";"
  else if f == "[]"
  then concat ["$$ = ","new ", scope, identCatV cat, "();"]
  else if f == "(:[])"
  then concat ["$$ = ","new ", scope, identCatV cat, "() ; $$->push_back($1);"]
  else if f == "(:)" && b
  then "$1->push_back("++ lastms ++ ") ; $$ = $1 ;"
  else if f == "(:)"
  then lastms ++ "->push_back(" ++ head ms ++ ") ; $$ = " ++ lastms ++ " ;" ---- not left rec
  else if isDefinedRule f
  then concat ["$$ = ", scope, f, "_", "(", intercalate ", " ms, ");" ]
  else concat
    ["$$ = ", "new ", scope, f, "(", intercalate ", " ms, ");" ++ addLn rp]
 where
  ms = map fst mbs
  lastms = last ms
  addLn rp = if rp == RecordPositions then " $$->line_number = " ++ nsString inPackage ++ "yy_mylinenumber;" else ""  -- O.F.
  identCatV = identCat . normCat
  reverses = unwords [
    "std::reverse(" ++ m ++"->begin(),"++m++"->end()) ;" |
       (m,True) <- mbs]
  scope = nsScope inPackage

-- Generate patterns and a set of metavariables indicating
-- where in the pattern the non-terminal
generatePatterns :: CF -> SymMap -> Rule -> Bool -> (Pattern,[(MetaVar,Bool)])
generatePatterns cf env r _ = case rhsRule r of
  []  -> ("/* empty */",[])
  its -> (unwords (map mkIt its), metas its)
 where
   mkIt = \case
     Left (TokenCat s)
       | isPositionCat cf s -> typeName s
       | otherwise -> fromMaybe (typeName s) $ Map.lookup (Tokentype s) env
     Left c  -> identCat c
     Right s -> fromMaybe s $ Map.lookup (Keyword s) env
   metas its = [('$': show i,revert c) | (i,Left c) <- zip [1 :: Int ..] its]

   -- notice: reversibility with push_back vectors is the opposite
   -- of right-recursive lists!
   revert c = isList c && not (isConsFun (funRule r)) && notElem c revs
   revs = cfgReversibleCats cf

-- We have now constructed the patterns and actions,
-- so the only thing left is to merge them into one string.

prRules :: Rules -> String
prRules [] = []
prRules ((_, []):rs) = prRules rs --internal rule
prRules ((nt, (p, a) : ls):rs) =
    unwords [nt', ":" , p, "{ ", a, "}", "\n" ++ pr ls] ++ ";\n" ++ prRules rs
 where
  nt' = identCat nt
  pr []           = []
  pr ((p,a):ls)   = unlines [unwords ["  |", p, "{ ", a , "}"]] ++ pr ls
