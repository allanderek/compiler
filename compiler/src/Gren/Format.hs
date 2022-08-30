{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedLists #-}
{-# LANGUAGE TypeApplications #-}
{-# OPTIONS_GHC -Wno-error=unused-matches #-}

module Gren.Format (toByteStringBuilder) where

import AST.Source qualified as Src
import Control.Monad (join)
import Data.Bifunctor (second)
import Data.ByteString.Builder qualified as B
import Data.Char qualified as Char
import Data.List qualified as List
import Data.List.NonEmpty (NonEmpty ((:|)), nonEmpty)
import Data.List.NonEmpty qualified as NonEmpty
import Data.Map.Strict (Map)
import Data.Map.Strict qualified as Map
import Data.Maybe (catMaybes)
import Data.Name (Name)
import Data.Semigroup (sconcat)
import Data.Utf8 qualified as Utf8
import Parse.Primitives qualified as P
import Reporting.Annotation qualified as A
import Text.PrettyPrint.Avh4.Block (Block)
import Text.PrettyPrint.Avh4.Block qualified as Block
import Text.Printf (printf)

toByteStringBuilder :: Src.Module -> B.Builder
toByteStringBuilder module_ =
  Block.render (formatModule module_)

--
-- Data structure extras
--

repair :: [(a, b)] -> a -> (a, [(b, a)])
repair [] a' = (a', [])
repair ((first, b) : rest) a' =
  (first, repairHelp b rest a')
  where
    repairHelp b1 [] a1 = [(b1, a1)]
    repairHelp b1 ((a1, b2) : rest') a2 =
      (b1, a1) : repairHelp b2 rest' a2

--
-- Helper functions
--

utf8 :: Utf8.Utf8 any -> Block.Line
utf8 = Block.lineFromBuilder . Utf8.toBuilder

addBlankLines :: Int -> Block -> Block
addBlankLines n block =
  Block.stack $
    NonEmpty.prependList
      (replicate n Block.blankLine)
      (NonEmpty.singleton block)

spaceOrStack :: NonEmpty Block -> Block
spaceOrStack = Block.rowOrStack (Just Block.space)

spaceOrIndent :: NonEmpty Block -> Block
spaceOrIndent = Block.rowOrIndent (Just Block.space)

spaceOrIndent' :: Bool -> NonEmpty Block -> Block
spaceOrIndent' forceMultiline = Block.rowOrIndent' forceMultiline (Just Block.space)

{-# INLINE group #-}
group :: Char -> Char -> Char -> Bool -> [Block] -> Block
group open _ close _ [] = Block.line $ Block.char7 open <> Block.char7 close
group open sep close forceMultiline (first : rest) =
  Block.rowOrStack' forceMultiline (Just Block.space) $
    Block.prefix 2 (Block.char7 open <> Block.space) first
      :| fmap (Block.prefix 2 (Block.char7 sep <> Block.space)) (rest)
      ++ [Block.line (Block.char7 close)]

{-# INLINE surround #-}
surround :: Char -> Char -> Block -> Block
surround open close block =
  Block.rowOrStack
    Nothing
    [ Block.prefix 1 (Block.char7 open) block,
      Block.line $ Block.char7 close
    ]

{-# INLINE parens #-}
parens :: Block -> Block
parens = surround '(' ')'

extendedGroup :: Char -> Char -> Char -> Char -> Char -> Block -> NonEmpty (Block.Line, Block) -> Block
extendedGroup open baseSep sep fieldSep close base fields =
  case fields of
    (single :| []) ->
      spaceOrStack
        [ spaceOrIndent
            [ spaceOrIndent
                [ Block.line $ Block.char7 open,
                  base
                ],
              formatField baseSep single
            ],
          Block.line $ Block.char7 close
        ]
    (first :| rest) ->
      Block.stack
        [ spaceOrIndent
            [ Block.line $ Block.char7 open,
              base
            ],
          Block.indent $
            Block.stack $
              formatField baseSep first
                :| fmap (formatField sep) rest,
          Block.line $ Block.char7 close
        ]
  where
    formatField sep' (key, value) =
      spaceOrIndent
        [ Block.line $
            Block.char7 sep'
              <> Block.space
              <> key
              <> Block.space
              <> Block.char7 fieldSep,
          value
        ]

--
-- AST -> Block
--
formatModule :: Src.Module -> Block
formatModule (Src.Module name exports docs imports values unions aliases binops effects) =
  -- TODO: implement actual formating
  Block.stack $
    NonEmpty.fromList $
      catMaybes
        [ Just $
            spaceOrIndent $
              NonEmpty.fromList $
                catMaybes
                  [ Just $ Block.line $ Block.string7 moduleKeyword,
                    Just $ Block.line $ maybe (Block.string7 "Main") (utf8 . A.toValue) name,
                    formatEffectsModuleWhereClause effects,
                    formatExposing $ A.toValue exports
                  ],
          case docs of
            Src.NoDocs _ -> Nothing
            Src.YesDocs moduleDocs _ ->
              Just $
                Block.stack
                  [ Block.blankLine,
                    formatDocComment moduleDocs
                  ],
          Just $ Block.stack $ Block.blankLine :| fmap formatImport imports,
          let defs =
                fmap snd $
                  List.sortOn fst $
                    concat @[]
                      [ fmap (formatWithDocComment valueName formatValue . A.toValue) <$> values,
                        fmap (formatWithDocComment unionName formatUnion . A.toValue) <$> unions,
                        fmap (formatWithDocComment aliasName formatAlias . A.toValue) <$> aliases,
                        case effects of
                          Src.NoEffects -> []
                          Src.Ports ports -> fmap (formatWithDocComment portName formatPort) <$> ports
                          Src.Manager _ _ -> []
                      ]
           in fmap Block.stack $ nonEmpty $ fmap (addBlankLines 2) defs
        ]
  where
    moduleKeyword =
      case effects of
        Src.NoEffects -> "module"
        Src.Ports _ -> "port module"
        Src.Manager _ _ -> "effect module"

    defDocs :: Map Name Src.DocComment
    defDocs =
      case docs of
        Src.NoDocs _ -> Map.empty
        Src.YesDocs _ defs -> Map.fromList defs

    valueName (Src.Value name_ _ _ _) = A.toValue name_
    unionName (Src.Union name_ _ _) = A.toValue name_
    aliasName (Src.Alias name_ _ _) = A.toValue name_
    portName (Src.Port name_ _) = A.toValue name_

    formatWithDocComment :: (a -> Name) -> (a -> Block) -> a -> Block
    formatWithDocComment getName render a =
      case Map.lookup (getName a) defDocs of
        Nothing -> render a
        Just docs_ ->
          Block.stack
            [ formatDocComment docs_,
              render a
            ]

formatEffectsModuleWhereClause :: Src.Effects -> Maybe Block
formatEffectsModuleWhereClause = \case
  Src.NoEffects -> Nothing
  Src.Ports _ -> Nothing
  Src.Manager _ manager -> Just $ formatManager manager

formatManager :: Src.Manager -> Block
formatManager manager =
  spaceOrIndent
    [ Block.line $ Block.string7 "where",
      group '{' ',' '}' False $
        fmap (formatPair . second A.toValue) $
          case manager of
            Src.Cmd cmd ->
              [("command", cmd)]
            Src.Sub sub ->
              [("subscription", sub)]
            Src.Fx cmd sub ->
              [ ("command", cmd),
                ("subscription", sub)
              ]
    ]
  where
    formatPair (key, name) =
      Block.line $
        sconcat
          [ Block.string7 key,
            Block.string7 " = ",
            utf8 name
          ]

formatExposing :: Src.Exposing -> Maybe Block
formatExposing = \case
  Src.Open -> Just $ Block.line $ Block.string7 "exposing (..)"
  Src.Explicit [] -> Nothing
  Src.Explicit exposed ->
    Just $
      spaceOrIndent
        [ Block.line $ Block.string7 "exposing",
          group '(' ',' ')' False $ fmap formatExposed exposed
        ]

formatExposed :: Src.Exposed -> Block
formatExposed = \case
  Src.Lower name -> Block.line $ utf8 $ A.toValue name
  Src.Upper name privacy -> Block.line $ utf8 $ A.toValue name
  Src.Operator _ name -> Block.line $ Block.char7 '(' <> utf8 name <> Block.char7 ')'

formatImport :: Src.Import -> Block
formatImport (Src.Import name alias exposing) =
  spaceOrIndent $
    NonEmpty.fromList $
      catMaybes
        [ Just $ Block.line $ Block.string7 "import",
          Just $ Block.line $ utf8 $ A.toValue name,
          fmap formatImportAlias alias,
          formatExposing exposing
        ]
  where
    formatImportAlias :: Name -> Block
    formatImportAlias name' = Block.line $ Block.string7 "as" <> Block.space <> utf8 name'

formatDocComment :: Src.DocComment -> Block
formatDocComment (Src.DocComment doc) =
  Block.line $
    Block.string7 "{-|"
      <> Block.lineFromBuilder (P.snippetToBuilder doc)
      <> Block.string7 "-}"

formatValue :: Src.Value -> Block
formatValue (Src.Value name args body type_) =
  formatBasicDef (A.toValue name) (fmap A.toValue args) (A.toValue body) (fmap A.toValue type_)

formatBasicDef :: Name -> [Src.Pattern_] -> Src.Expr_ -> Maybe Src.Type_ -> Block
formatBasicDef name args body type_ =
  Block.stack $
    NonEmpty.fromList $
      catMaybes
        [ fmap (formatTypeAnnotation Nothing name) type_,
          Just $
            spaceOrIndent $
              Block.line (utf8 name)
                :| fmap (patternParensProtectSpaces . formatPattern) args
                ++ [ Block.line $ Block.char7 '='
                   ],
          Just $ Block.indent $ exprParensNone $ formatExpr body
        ]

formatTypeAnnotation :: Maybe String -> Name -> Src.Type_ -> Block
formatTypeAnnotation prefix name t =
  spaceOrIndent
    [ Block.line $ withPrefix $ utf8 name <> Block.space <> Block.char7 ':',
      typeParensNone $ formatType t
    ]
  where
    withPrefix a =
      case prefix of
        Nothing -> a
        Just prefixString ->
          Block.string7 prefixString <> Block.char7 ' ' <> a

formatUnion :: Src.Union -> Block
formatUnion (Src.Union name args ctors) =
  Block.stack $
    spaceOrIndent
      [ Block.line (Block.string7 "type"),
        spaceOrIndent $
          Block.line (utf8 $ A.toValue name)
            :| fmap (Block.line . utf8 . A.toValue) args
      ]
      :| fmap Block.indent formatCtors
  where
    formatCtors =
      case ctors of
        [] -> []
        (first : rest) -> formatCtor '=' first : fmap (formatCtor '|') rest

    formatCtor open (name', args') =
      spaceOrIndent $
        Block.line (Block.char7 open <> Block.space <> utf8 (A.toValue name'))
          :| fmap (typeParensProtectSpaces . formatType . A.toValue) args'

formatAlias :: Src.Alias -> Block
formatAlias (Src.Alias name args type_) =
  Block.stack
    [ spaceOrIndent
        [ Block.line (Block.string7 "type alias"),
          spaceOrIndent $
            Block.line (utf8 $ A.toValue name)
              :| fmap (Block.line . utf8 . A.toValue) args,
          Block.line (Block.char7 '=')
        ],
      Block.indent $ typeParensNone $ formatType (A.toValue type_)
    ]

formatPort :: Src.Port -> Block
formatPort = \case
  Src.Port name type_ ->
    formatTypeAnnotation (Just "port") (A.toValue name) (A.toValue type_)

data ExpressionBlock
  = NoExpressionParens Block
  | ExpressionContainsInfixOps Block
  | ExpressionContainsSpaces Block
  | ExpressionHasAmbiguousEnd Block

-- "no parens"
exprParensNone :: ExpressionBlock -> Block
exprParensNone = \case
  NoExpressionParens block -> block
  ExpressionContainsInfixOps block -> block
  ExpressionContainsSpaces block -> block
  ExpressionHasAmbiguousEnd block -> block

exprParensProtectInfixOps :: ExpressionBlock -> Block
exprParensProtectInfixOps = \case
  NoExpressionParens block -> block
  ExpressionContainsInfixOps block -> parens block
  ExpressionContainsSpaces block -> block
  ExpressionHasAmbiguousEnd block -> parens block

exprParensProtectSpaces :: ExpressionBlock -> Block
exprParensProtectSpaces = \case
  NoExpressionParens block -> block
  ExpressionContainsInfixOps block -> parens block
  ExpressionContainsSpaces block -> parens block
  ExpressionHasAmbiguousEnd block -> parens block

formatExpr :: Src.Expr_ -> ExpressionBlock
formatExpr = \case
  Src.Chr char ->
    NoExpressionParens $
      formatString StringStyleChar char
  Src.Str string ->
    NoExpressionParens $
      formatString StringStyleSingleQuoted string
  Src.Int int ->
    NoExpressionParens $
      Block.line $
        Block.string7 (show int)
  Src.Float float ->
    NoExpressionParens $
      Block.line $
        utf8 float
  Src.Var _ name ->
    NoExpressionParens $
      Block.line $
        utf8 name
  Src.VarQual _ ns name ->
    NoExpressionParens $
      Block.line $
        utf8 ns <> Block.char7 '.' <> utf8 name
  Src.Array exprs ->
    NoExpressionParens $
      group '[' ',' ']' True $
        fmap (exprParensNone . formatExpr . A.toValue) exprs
  Src.Op name ->
    NoExpressionParens $
      Block.line $
        Block.char7 '(' <> utf8 name <> Block.char7 ')'
  Src.Negate expr ->
    NoExpressionParens $
      Block.prefix 1 (Block.char7 '-') $
        exprParensProtectSpaces $
          formatExpr $
            A.toValue expr
  Src.Binops rest' last_ ->
    let (first, rest) = repair rest' last_
     in ExpressionContainsInfixOps $
          spaceOrIndent' forceMultiline $
            exprParensProtectInfixOps (formatExpr $ A.toValue first)
              :| fmap formatPair rest
    where
      -- for now we just use multiline formatting for specific operators,
      -- since we don't yet track where the linebreaks are in the source
      forceMultiline = any (opForcesMultiline . A.toValue . snd) rest'
      formatPair (op, expr) =
        Block.prefix
          4
          (utf8 (A.toValue op) <> Block.space)
          (exprParensProtectInfixOps $ formatExpr $ A.toValue expr)
  Src.Lambda [] body ->
    formatExpr $ A.toValue body
  Src.Lambda (arg1 : args) body ->
    ExpressionHasAmbiguousEnd $
      spaceOrIndent
        [ Block.prefix 1 (Block.char7 '\\') $
            spaceOrStack $
              join
                [ fmap (patternParensProtectSpaces . formatPattern . A.toValue) (arg1 :| args),
                  pure $ Block.line $ Block.string7 "->"
                ],
          exprParensNone $ formatExpr $ A.toValue body
        ]
  Src.Call fn [] ->
    formatExpr $ A.toValue fn
  Src.Call fn args ->
    ExpressionContainsSpaces $
      spaceOrIndent $
        exprParensProtectInfixOps (formatExpr $ A.toValue fn)
          :| fmap (exprParensProtectSpaces . formatExpr . A.toValue) args
  Src.If [] else_ ->
    formatExpr $ A.toValue else_
  Src.If (if_ : elseifs) else_ ->
    ExpressionHasAmbiguousEnd $
      Block.stack $
        NonEmpty.fromList $
          mconcat
            [ List.singleton $ formatIfClause "if" if_,
              fmap (formatIfClause "else if") elseifs,
              List.singleton $
                Block.stack
                  [ Block.line $ Block.string7 "else",
                    Block.indent $ exprParensNone $ formatExpr $ A.toValue else_
                  ]
            ]
    where
      formatIfClause :: String -> (Src.Expr, Src.Expr) -> Block
      formatIfClause keyword_ (predicate, body) =
        Block.stack
          [ spaceOrStack
              [ spaceOrIndent
                  [ Block.line $ Block.string7 keyword_,
                    exprParensNone $ formatExpr $ A.toValue predicate
                  ],
                Block.line $ Block.string7 "then"
              ],
            Block.indent $ exprParensNone $ formatExpr $ A.toValue body
          ]
  Src.Let [] body ->
    formatExpr $ A.toValue body
  Src.Let (def1 : defs) body ->
    ExpressionHasAmbiguousEnd $
      Block.stack
        [ Block.line (Block.string7 "let"),
          Block.indent $ Block.stack $ NonEmpty.intersperse Block.blankLine $ fmap (formatDef . A.toValue) (def1 :| defs),
          Block.line (Block.string7 "in"),
          exprParensNone $ formatExpr (A.toValue body)
        ]
  Src.Case subject branches ->
    ExpressionHasAmbiguousEnd $
      Block.stack $
        spaceOrStack
          [ spaceOrIndent
              [ Block.line (Block.string7 "case"),
                exprParensNone $ formatExpr (A.toValue subject)
              ],
            Block.line (Block.string7 "of")
          ]
          :| List.intersperse Block.blankLine (fmap (Block.indent . formatCaseBranch) branches)
    where
      formatCaseBranch (pat, expr) =
        Block.stack
          [ spaceOrStack
              [ patternParensNone $ formatPattern (A.toValue pat),
                Block.line $ Block.string7 "->"
              ],
            Block.indent $ exprParensNone $ formatExpr $ A.toValue expr
          ]
  Src.Accessor field ->
    NoExpressionParens $
      Block.line $
        Block.char7 '.' <> utf8 field
  Src.Access expr field ->
    NoExpressionParens $
      Block.addSuffix (Block.char7 '.' <> utf8 (A.toValue field)) (exprParensProtectSpaces $ formatExpr $ A.toValue expr)
  Src.Update base [] ->
    formatExpr $ A.toValue base
  Src.Update base (first : rest) ->
    NoExpressionParens $
      extendedGroup
        '{'
        '|'
        ','
        '='
        '}'
        (exprParensNone $ formatExpr $ A.toValue base)
        (fmap formatField $ first :| rest)
    where
      formatField (field, expr) =
        ( utf8 $ A.toValue field,
          exprParensNone $ formatExpr (A.toValue expr)
        )
  Src.Record fields ->
    NoExpressionParens $
      group '{' ',' '}' True $
        fmap formatField fields
    where
      formatField (name, expr) =
        spaceOrIndent
          [ Block.line $ utf8 (A.toValue name) <> Block.space <> Block.char7 '=',
            exprParensNone $ formatExpr (A.toValue expr)
          ]

opForcesMultiline :: Name -> Bool
opForcesMultiline op =
  op == Utf8.fromChars "|>"
    || op == Utf8.fromChars "<|"

formatDef :: Src.Def -> Block
formatDef = \case
  Src.Define name args body ann ->
    formatBasicDef (A.toValue name) (fmap A.toValue args) (A.toValue body) (fmap A.toValue ann)
  Src.Destruct pat body ->
    Block.stack
      [ spaceOrIndent
          [ patternParensProtectSpaces $ formatPattern $ A.toValue pat,
            Block.line $ Block.char7 '='
          ],
        Block.indent $ exprParensNone $ formatExpr $ A.toValue body
      ]

data TypeBlock
  = NoTypeParens Block
  | TypeContainsArrow Block
  | TypeContainsSpaces Block

typeParensNone :: TypeBlock -> Block
typeParensNone = \case
  NoTypeParens block -> block
  TypeContainsArrow block -> block
  TypeContainsSpaces block -> block

typeParensProtectArrows :: TypeBlock -> Block
typeParensProtectArrows = \case
  NoTypeParens block -> block
  TypeContainsArrow block -> parens block
  TypeContainsSpaces block -> block

typeParensProtectSpaces :: TypeBlock -> Block
typeParensProtectSpaces = \case
  NoTypeParens block -> block
  TypeContainsArrow block -> parens block
  TypeContainsSpaces block -> parens block

formatType :: Src.Type_ -> TypeBlock
formatType = \case
  Src.TLambda left right ->
    TypeContainsArrow $
      spaceOrStack
        -- TODO: don't indent nested multiline lambdas
        [ typeParensProtectArrows $ formatType (A.toValue left),
          Block.prefix
            3
            (Block.string7 "-> ")
            (typeParensNone $ formatType $ A.toValue right)
        ]
  Src.TVar name ->
    NoTypeParens $
      Block.line (utf8 name)
  Src.TType _ name [] ->
    NoTypeParens $
      Block.line (utf8 name)
  Src.TType _ name args ->
    TypeContainsSpaces $
      spaceOrIndent $
        Block.line (utf8 name)
          :| fmap (typeParensProtectSpaces . formatType . A.toValue) args
  Src.TTypeQual _ ns name [] ->
    NoTypeParens $
      Block.line (utf8 ns <> Block.char7 '.' <> utf8 name)
  Src.TTypeQual _ ns name args ->
    TypeContainsSpaces $
      spaceOrIndent $
        Block.line (utf8 ns <> Block.char7 '.' <> utf8 name)
          :| fmap (typeParensProtectSpaces . formatType . A.toValue) args
  Src.TRecord fields Nothing ->
    NoTypeParens $
      group '{' ',' '}' True $
        fmap formatField fields
    where
      formatField (name, type_) =
        spaceOrIndent
          [ Block.line $ utf8 (A.toValue name) <> Block.space <> Block.char7 ':',
            typeParensNone $ formatType (A.toValue type_)
          ]
  Src.TRecord [] (Just base) ->
    NoTypeParens $
      Block.line $
        utf8 $
          A.toValue base
  Src.TRecord (first : rest) (Just base) ->
    NoTypeParens $
      extendedGroup
        '{'
        '|'
        ','
        ':'
        '}'
        (Block.line $ utf8 $ A.toValue base)
        (fmap formatField $ first :| rest)
    where
      formatField (field, type_) =
        ( utf8 $ A.toValue field,
          typeParensNone $ formatType $ A.toValue type_
        )

data PatternBlock
  = NoPatternParens Block
  | PatternContainsSpaces Block

patternParensNone :: PatternBlock -> Block
patternParensNone = \case
  NoPatternParens block -> block
  PatternContainsSpaces block -> block

patternParensProtectSpaces :: PatternBlock -> Block
patternParensProtectSpaces = \case
  NoPatternParens block -> block
  PatternContainsSpaces block -> parens block

formatPattern :: Src.Pattern_ -> PatternBlock
formatPattern = \case
  Src.PAnything ->
    NoPatternParens $
      Block.line $
        Block.char7 '_'
  Src.PVar name ->
    NoPatternParens $
      Block.line $
        utf8 name
  Src.PRecord fields ->
    NoPatternParens $
      group '{' ',' '}' False $
        fmap (formatField . A.toValue) fields
    where
      formatField = \case
        Src.RFPattern name pat ->
          spaceOrIndent
            [ Block.line $ utf8 (A.toValue name) <> Block.space <> Block.char7 '=',
              patternParensNone $ formatPattern (A.toValue pat)
            ]
  Src.PAlias pat name ->
    PatternContainsSpaces $
      spaceOrIndent
        [ patternParensProtectSpaces $ formatPattern (A.toValue pat),
          Block.line $ Block.string7 "as " <> utf8 (A.toValue name)
        ]
  Src.PCtor _ name [] ->
    NoPatternParens $
      Block.line (utf8 name)
  Src.PCtor _ name args ->
    PatternContainsSpaces $
      spaceOrIndent $
        Block.line (utf8 name)
          :| fmap (patternParensProtectSpaces . formatPattern . A.toValue) args
  Src.PCtorQual _ ns name [] ->
    NoPatternParens $
      Block.line (utf8 ns <> Block.char7 '.' <> utf8 name)
  Src.PCtorQual _ ns name args ->
    PatternContainsSpaces $
      spaceOrIndent $
        Block.line (utf8 ns <> Block.char7 '.' <> utf8 name)
          :| fmap (patternParensProtectSpaces . formatPattern . A.toValue) args
  Src.PArray items ->
    NoPatternParens $
      group '[' ',' ']' False $
        fmap (patternParensNone . formatPattern . A.toValue) items
  Src.PChr char ->
    NoPatternParens $
      formatString StringStyleChar char
  Src.PStr string ->
    NoPatternParens $
      formatString StringStyleSingleQuoted string
  Src.PInt int ->
    NoPatternParens $
      Block.line $
        Block.string7 (show int)

data StringStyle
  = StringStyleChar
  | StringStyleSingleQuoted
  | StringStyleTripleQuoted
  deriving (Eq)

formatString :: StringStyle -> Utf8.Utf8 any -> Block
formatString style s' =
  case style of
    StringStyleChar ->
      stringBox (Block.char7 '\'') id
    StringStyleSingleQuoted ->
      stringBox (Block.char7 '"') id
    StringStyleTripleQuoted ->
      stringBox (Block.string7 "\"\"\"") escapeMultiQuote
  where
    s = Utf8.toChars s'

    stringBox :: Block.Line -> (String -> String) -> Block
    stringBox quotes escaper =
      Block.line $ quotes <> Block.stringUtf8 (escaper $ concatMap fix s) <> quotes

    fix = \case
      '\n' | style == StringStyleTripleQuoted -> ['\n']
      '\n' -> "\\n"
      '\t' -> "\\t"
      '\\' -> "\\\\"
      '\"' | style == StringStyleSingleQuoted -> "\\\""
      '\'' | style == StringStyleChar -> "\\\'"
      c | not $ Char.isPrint c -> hex c
      ' ' -> [' ']
      c | Char.isSpace c -> hex c
      c -> [c]

    hex char =
      "\\u{" ++ printf "%04X" (Char.ord char) ++ "}"

    escapeMultiQuote =
      let step okay quotes remaining =
            case remaining of
              [] ->
                reverse $ concat (replicate quotes "\"\\") ++ okay
              next : rest ->
                if next == '"'
                  then step okay (quotes + 1) rest
                  else
                    if quotes >= 3
                      then step (next : (concat $ replicate quotes "\"\\") ++ okay) 0 rest
                      else
                        if quotes > 0
                          then step (next : (replicate quotes '"') ++ okay) 0 rest
                          else step (next : okay) 0 rest
       in step "" 0
