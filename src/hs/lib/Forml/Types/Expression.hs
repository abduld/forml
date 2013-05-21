{-# LANGUAGE FlexibleContexts     #-}
{-# LANGUAGE FlexibleInstances    #-}
{-# LANGUAGE GADTs                #-}
{-# LANGUAGE NamedFieldPuns       #-}
{-# LANGUAGE OverlappingInstances #-}
{-# LANGUAGE QuasiQuotes          #-}
{-# LANGUAGE RankNTypes           #-}
{-# LANGUAGE RecordWildCards      #-}
{-# LANGUAGE ScopedTypeVariables  #-}
{-# LANGUAGE TemplateHaskell      #-}
{-# LANGUAGE ViewPatterns         #-}
{-# LANGUAGE DeriveGeneric        #-}
{-# LANGUAGE StandaloneDeriving   #-}

module Forml.Types.Expression where

import Language.Javascript.JMacro

import Control.Applicative
import Control.Monad
import Control.Monad.State hiding (lift)
import qualified Control.Monad.Trans.State.Strict as ST

import           Text.InterpolatedString.Perl6
import           Text.Parsec                   hiding (State, label, many, parse, spaces, (<|>))
import qualified Text.Parsec                   as P
import           Text.Parsec.Expr
import           Text.Parsec.Indent            hiding (same)

import qualified Data.List         as L
import qualified Data.Map          as M
import           Data.Monoid
import           Data.String.Utils hiding (join)
import           Data.Serialize as S
import qualified Data.ByteString as B

import Forml.Javascript.Utils
import Forml.Parser.Utils
import Forml.Types.Axiom
import Forml.Types.Literal
import Forml.Types.Pattern
import Forml.Types.Symbol
import Forml.Types.Type
import Forml.Draw

import qualified GHC.Generics as G

import Prelude hiding (curry, (++))



-- Expression
-- --------------------------------------------------------------------------------

class ToLocalStat a where
    toLocal :: a -> JStat

data Lazy = Once | Every deriving (Eq, G.Generic)

data Expression d = ApplyExpression (Expression d) [Expression d]
                  | IfExpression (Expression d) (Expression d) (Maybe (Expression d))
                  | LiteralExpression Literal
                  | SymbolExpression Symbol
                  | JSExpression JExpr
                  | LazyExpression (Addr (Expression d)) Lazy
                  | FunctionExpression [Axiom (Expression d)]
                  | RecordExpression (M.Map Symbol (Expression d))
                  | InheritExpression (Expression d) (M.Map Symbol (Expression d))
                  | LetExpression [d] (Expression d)
                  | ListExpression [Expression d]
                  | AccessorExpression (Addr (Expression d)) [Symbol]
                  deriving (Eq, G.Generic)

instance (Serialize d) => Serialize (Expression d)
instance Serialize Lazy

instance Serialize JExpr where

    get = do
        result <- S.get
        return $ case parseJME result of
            Left x  -> error (show x ++ "\n\n" ++ result)
            Right x -> x

    put x = S.put . show . jsToDoc $ x

instance (Show d) => Show (Expression d) where

    show (ApplyExpression x @ (SymbolExpression (show -> f : _)) y)
        | f `elem` "abcdefghijklmnopqrstuvwxyz" = [qq|$x {sep_with " " y}|]
        | length y == 2                         = [qq|{y !! 0} $x {y !! 1}|]

    show (IfExpression a b (Just c)) = [qq|if $a then $b else $c|]
    show (IfExpression a b Nothing)  = [qq|if $a then $b|]
    show (ApplyExpression x y)    = [qq|$x {sep_with " " y}|]
    show (LiteralExpression x)    = show x
    show (SymbolExpression x)     = show x
    show (ListExpression x)       = [qq|[ {sep_with ", " x} ]|]
    show (FunctionExpression as)  = replace "\n |" "\n     |" $ [qq|(λ{sep_with "| " as})|]
    show (JSExpression x)         = "`" ++ draw x ++ "`"
    show (LazyExpression x Once)  = "lazy " ++ show x
    show (LazyExpression x Every) = "do " ++ show x
    show (LetExpression ax e)     = replace "\n |" "\n     |" $ [qq|let {sep_with "\\n| " ax} in ($e)|]
    show (RecordExpression m)     = [qq|\{ {unsep_with " = " m} \}|]
    show (InheritExpression x m)  = [qq|\{ $x with {unsep_with " = " m} \}|]
    show (AccessorExpression x m) = [qq|$x.{sep_with "." m}|]


instance (Syntax d, Show d) => Syntax (Expression d) where

    syntax = try if' <|> try infix' <|> other

        where other = try let'
                      <|> try do'
                      <|> try yield
                      <|> try lazy
                      <|> other_next

              other_next =
                      
                      try accessor_apply
                      <|> accessor_val
                      <|> try apply
                      <|> function
                      <|> inner

              inner = try accessor <|> inner_no_accessor

              inner_no_accessor =

                      try (indentPairs "(" (try (SymbolExpression . Operator <$> valid_partial_op (many1 operator))) ")")
                      <|> indentPairs "(" syntax ")"
                      <|> js
                      <|> try record
                      <|> named_key
                      <|> literal
                      <|> symbol
                      <|> try array
                      <|> list
                      
              accessor_val =

                    do string "."
                       (Addr s c (SymbolExpression x)) <- addr symbol   -- TODO or AccessorExpression
                       return (FunctionExpression
                           [EqualityAxiom
                               (Match [VarPattern "_y"] Nothing)
                               (Addr s c
                                   (AccessorExpression
                                       (Addr s c
                                           (SymbolExpression (Symbol "_y")))
                                       [x]))])         

              accessor_apply =

                    do string "."
                       (Addr s c (ApplyExpression (SymbolExpression x) xs)) <- addr apply   -- TODO or AccessorExpression
                       return (FunctionExpression
                           [EqualityAxiom
                               (Match [VarPattern "_y"] Nothing)
                               (Addr s c
                                   (ApplyExpression
                                       (AccessorExpression
                                           (Addr s c
                                               (SymbolExpression (Symbol "_y")))
                                           [x])
                                       xs))])              

              let' = withPosTemp $ do string "var" <|> string "let"
                                      whitespace1
                                      defs <- withPosTemp def
                                      spaces
                                      try (do string "in"
                                              spaces
                                              LetExpression <$> return defs <*> syntax)
                                         <|> do same
                                                LetExpression <$> return defs <*> syntax

                  where def = try syntax `sepBy1` (try comma <|> try (spaces *> same))

              do'  = do s <- getPosition
                        _ <- string "do"
                        i <- try (string "!") <|> return ""
                        P.spaces
                        l <- withPosTemp line
                        if i == "!"
                           then return$ ApplyExpression (SymbolExpression (Symbol "run")) [wrap s l]
                           else return$ wrap s l

                  where line = try bind <|> try let_bind <|> return'

                        wrap s x = LazyExpression (Addr s s (ApplyExpression (SymbolExpression (Symbol "run")) [x])) Every

                        bind = do 
                            p <- syntax
                            whitespace <* (string "<-" <|> string "←") <* whitespace
                            ex <- withPosTemp syntax
                            P.spaces *> same
                            f ex p <$> addr line          
                                  
                                  
                                  

                        let_bind = withPosTemp $ do string "let"
                                                    whitespace1
                                                    defs <- withPosTemp def
                                                    P.spaces
                                                    same
                                                    LetExpression <$> return defs <*> line

                            where def = try syntax `sepBy1` try (P.spaces *> same)

                        return' = do v <- syntax
                                     option v $ try $ unit_bind v

                        unit_bind v = do P.spaces *> same
                                         f' v <$> line

                        f ex pat zx = ApplyExpression
                                         (SymbolExpression (Operator ">>="))
                                         [ ex, (FunctionExpression
                                                    [ EqualityAxiom
                                                      (Match [pat] Nothing)
                                                      zx ]) ]

                        f' ex zx = ApplyExpression
                                         (SymbolExpression (Operator ">>"))
                                         [ ex, zx ]

              lazy  = do string "lazy"
                         whitespace1
                         LazyExpression <$> withPosTemp (addr syntax) <*> return Once

              yield = do string "yield"
                         whitespace1
                         LazyExpression <$> withPosTemp (addr syntax) <*> return Every

              if' = do

                  string "if"
                  whitespace1
                  e <- syntax
                  P.spaces
                  hStyle e <|> jStyle e

                  where

                      hStyle e = do
                          string "then"
                          whitespace1
                          P.spaces
                          jStyle e

                      jStyle e = do 
                          (Addr a b t) <- addr syntax
                          P.spaces
                          IfExpression e t <$> (else' <|> return Nothing)

                      else' = do
                          string "else"
                          whitespace1
                          P.spaces
                          Just <$> syntax

              infix' = buildExpressionParser table term

                  where table  = [ [ix "^"]
                                 , [ix "*", ix "/"]
                                 , [ Prefix neg ]
                                 , [ix "+", ix "-"]
                                 , [ Infix user_op_left AssocLeft ]
                                 , [ Infix user_op_right AssocRight ]
                                 , [ix "<", ix "<=", ix ">=", ix ">", ix "==", ix "!=", ix "isnt", ix "is"]
                                 , [ix "&&", ix "||", ix "and", ix "or" ] ]

                        ix s   = Infix (try . op $ (unwind <$> string s) <* notFollowedBy operator) AssocLeft

                        unwind "and"  = Operator "&&"
                        unwind "or"   = Operator "||"
                        unwind "is"   = Operator "=="
                        unwind "isnt" = Operator "!="
                        unwind x      = Operator x
                        
                        neg = try $ do spaces
                                       string "-"
                                       spaces
                                       return (\x -> ApplyExpression
                                                         (SymbolExpression (Operator "-"))
                                                         [LiteralExpression (IntLiteral 0), x])

                        px s   = Prefix (try neg)
                                 where neg = do spaces
                                                op <- SymbolExpression . Operator <$> string s
                                                spaces
                                                return (\x -> ApplyExpression op [x])

                        term   = try other

                        user_op_left  = try $ do spaces
                                                 op' @ (end -> x : _) <- g operator
                                                 spaces
                                                 if x /= ':'
                                                     then return $ f op'
                                                     else parserFail "Operator"

                        user_op_right = try $ do spaces
                                                 op' @ (end -> x : _) <- g operator
                                                 spaces
                                                 if x == ':'
                                                     then return $ f op'
                                                     else parserFail "Operator"

                        f op' x y = ApplyExpression (SymbolExpression (Operator op')) [x, y]

                        g = not_system . many1

                        op p   = do spaces
                                    op' <- SymbolExpression <$> p
                                    spaces

                                    return (\x y -> ApplyExpression op' [x, y])

              named_key = do x <- indentPairs "{" syntax "}"
                             return $ RecordExpression (M.fromList [(x, SymbolExpression (Symbol "true"))])


              accessor = do 
                  s <- getPosition
                  x <- indentPairs "(" syntax ")"
                       <|> js
                       <|> record
                       <|> literal
                       <|> try java_apply
                       <|> try symbol
                       <|> list
                  
                  accs s x

                  where
                      accs s x = dot_cont s x <|> get_cont s x <|> return x
                      
                      get_cont s x = do
                          string "["
                          P.spaces
                          z <- syntax `sepBy1` (optional_sep <|> try (string "][") *> return ())
                          P.spaces
                          string "]"
                          accs s (get_exp s x z)

                      get_exp s x (z:zs) =
                          get_exp s (ApplyExpression (SymbolExpression (Symbol "get")) [z, x]) zs
                      get_exp s x [] = x  

                      dot_cont s x = do
                          f <- getPosition
                          string "."
                          z <- syntax `sepBy1` string "."
                          accs s (acc_exp (Addr s f) x z)

                      acc_exp f x z = AccessorExpression (f x) z

              java_apply = ApplyExpression <$> inner_no_accessor <*> try java

                  where java = indentPairs "(" java_args ")"
                            where  java_args = do x <- syntax `sepEndBy1` comma
                                                  option x ((x ++) <$> try java)

              apply = ApplyExpression <$> inner <*> arguments

                  where arguments = try java <|> try cont <|> halt

                            where cont = do x <- whitespace *> (try (ApplyExpression <$> inner <*> java) <|> inner)
                                            option [x] ((x:) <$> try (whitespace *> (try cont <|> halt)))

                                  halt = (:[]) <$> (whitespace *> (try let'
                                                    <|> try do'
                                                    <|> try lazy
                                                    <|> try yield
                                                    <|> function))

                        java = indentPairs "(" java_args ")"
                            where  java_args = do x <- syntax `sepEndBy1` comma
                                                  option x ((x ++) <$> try arguments)

              function = withPosTemp$ do try (char '\\') <|> char 'λ'
                                         whitespace
                                         pat_fun

                  where pat_fun    = do t <- option [] ( ((:[]) <$> type_axiom <* spaces))
                                        eqs <- try eq_axiom `sepBy1` try (spaces *> string "|" <* whitespace)
                                        return $ FunctionExpression (t ++ eqs)

                        type_axiom = do string ":"
                                        P.spaces
                                        TypeAxiom <$> withPosTemp type_axiom_signature

                        eq_axiom   = do patterns <- syntax
                                        string "="
                                        P.spaces
                                        ex <- withPosTemp (addr syntax)
                                        return $ EqualityAxiom patterns ex

              js = g <$> indentPairs "`" (many $ noneOf "`") "`"
                  where p (parseJM . wrap -> Right (BlockStat [AssignStat _ x])) =
                            [jmacroE| (function() { return `(x)`; }) |]
                        p (parseJM . (++";") -> Right z) = [jmacroE| (function() { `(z)`; }) |]
                        p (parseJM . concat . L.intersperse ";" . h . split ";" -> Right x) =
                            [jmacroE| (function() { `(x)`; }) |]
                        p _ = error "\n\nJavascript parsing failed"

                        g x | last x == '!' = ApplyExpression (SymbolExpression (Symbol "run"))
                                              [JSExpression (p (take (length x - 1) x))]
                            | otherwise = JSExpression$ p x

                        h [] = []
                        h (x:[]) = ["return " ++ x]
                        h (x:xs) = x : h xs

                        wrap x = "__ans__ = " ++ x ++ ";"

              record = indentPairs "{" (try inherit <|> (RecordExpression . M.fromList <$>  pairs')) "}"

                  where pairs' = withPosTemp $ (try key_eq_val <|> try function')
                                         `sepBy` optional_sep

                        function' = do n <- syntax
                                       whitespace
                                       eqs <- try eq_axiom `sepBy1` try (spaces *> string "|" <* whitespace)
                                       return $ (n, FunctionExpression eqs)

                        eq_axiom   = do patterns <- syntax
                                        string "="
                                        spaces
                                        indented
                                        ex <- withPosTemp (addr syntax)
                                        return $ EqualityAxiom patterns ex

                        inherit = do ex <- syntax
                                     spaces *> indented
                                     string "with"
                                     spaces *> indented
                                     ps <- pairs'
                                     return $ InheritExpression ex (M.fromList ps)

                        key_eq_val = do key <- syntax
                                        whitespace
                                        string "=" <|> string ":"
                                        spaces
                                        value <- withPosTemp syntax
                                        return (key, value)

              literal = do (sourceColumn -> x) <- getPosition
                           undo x <$> syntax

              strip_indent x y = let splitted = split "\n" y
                                     r x' | strip (take x x') == "" = drop x x'
                                          | otherwise = error$ "Badly formatted string \"" ++ show splitted ++ "\""
                                 in  if length splitted > 1
                                     then head splitted ++ "\n" ++ (concat . L.intersperse "\n" . fmap r . tail $ splitted)
                                     else y

              undo z (StringLiteral x) = to_escaped . split "`" . strip_indent z $ x
              undo _ l = LiteralExpression l

              to_escaped (x:s:xs) =
                  ApplyExpression (SymbolExpression$ Operator "+++")
                                      [ ApplyExpression (SymbolExpression$ Operator "+++")
                                        [LiteralExpression $ StringLiteral x
                                          , p s ]
                                      , to_escaped xs ]
              to_escaped (l:[]) = LiteralExpression $ StringLiteral l
              to_escaped [] =  LiteralExpression $ StringLiteral ""

              p s = case parse syntax "Escaped String" s of
                      Left x -> error$ show x
                      Right x -> x

              symbol  = (SymbolExpression <$> syntax)
              

              list    = ListExpression <$> indentPairs "[" v "]"
                  where v = do whitespace
                               withPosTemp (syntax `sepBy` optional_sep)

              array   = f <$> indentAsymmetricPairs "[:" v (try (string ":]") <|> string "]")

                  where v = do whitespace
                               withPosTemp (syntax `sepBy` optional_sep)

                        f [] = RecordExpression (M.fromList [(Symbol "nil", SymbolExpression (Symbol "true"))])
                        f (x:xs) = RecordExpression (M.fromList [(Symbol "head", x), (Symbol "tail", f xs)])

class Opt a where
    opt :: a -> a

instance (Opt a, Opt b) => Opt (a, b) where
    opt (a, b) = (opt a, opt b)

instance (Opt a) => Opt [a] where
    opt x = map opt x

instance (Functor m, Opt a) => Opt (m a) where
    opt x = fmap opt x

instance Opt JStat where
    opt (ReturnStat x)      = ReturnStat (opt x)
    opt (IfStat a b c)      = IfStat (opt a) (opt b) (opt c)
    opt (WhileStat a b c)   = WhileStat a (opt b) (opt c)
    opt (ForInStat a b c d) = ForInStat a b (opt c) (opt d)
    opt (SwitchStat a b c)  = SwitchStat (opt a) (opt b) (opt c)
    opt (TryStat a b c d)   = TryStat (opt a) b (opt c) (opt d)
    opt (BlockStat xs)      = BlockStat (opt xs)
    opt (ApplStat a b)      = ApplStat (opt a) (opt b)
    opt (PPostStat a b c)   = PPostStat a b (opt c)
    opt (AssignStat a b)    = AssignStat (opt a) (opt b)
    opt (UnsatBlock a)      = opt (sat_ a)
 
    opt x = x

    -- opt (DeclStat    Ident (Maybe JLocalType)
    -- opt (AntiStat   String
    -- opt (ForeignStat Ident JLocalType
    -- opt (BreakStat


instance Opt JVal where
    opt (JList xs)   = JList (opt xs)
    opt (JHash m)    = JHash (M.map opt m)
    opt (JFunc xs x) = JFunc xs (opt x)
    opt (UnsatVal x) = opt (sat_ x)

    opt x = x

    -- opt x@(JVar _) = x
    -- opt x@(JDouble _) = x
    -- opt x@(JInt _) = x
    -- opt x@(JStr _) = x
    -- opt x@(JRegEx _) = x

instance Opt JExpr where
    opt (SelExpr e (StrI i))  = IdxExpr (opt e) (ValExpr (JStr i))  -- Closure fix - advanced mode nukes these
    opt (IdxExpr a b)         = IdxExpr (opt a) (opt b)
    opt (InfixExpr a b c)     = InfixExpr a (opt b) (opt c)
    opt (PPostExpr a b c)     = PPostExpr a b (opt c)
    opt (IfExpr a b c)        = IfExpr (opt a) (opt b) (opt c)
    opt (NewExpr a)           = NewExpr (opt a)
    opt (ApplExpr a b)        = ApplExpr (opt a) (map opt b)
    opt (TypeExpr a b c)      = TypeExpr a (opt b) c
    opt (ValExpr a)           = ValExpr (opt a)
    opt (UnsatExpr a)         = opt (sat_ a)

instance (Show d, ToLocalStat d) => ToJExpr (Expression d) where

    toJExpr (ApplyExpression (SymbolExpression (Symbol "run"))
         [LazyExpression (Addr s e (ApplyExpression (SymbolExpression (Symbol "run"))
             [JSExpression (ValExpr (UnsatVal x))])) Every]) =

        case sat_ x of
            (JFunc _ (BlockStat [ReturnStat y])) -> opt y
            (JFunc _ (BlockStat [BlockStat [ReturnStat y]])) -> opt y
            y -> [jmacroE| `(ValExpr (opt y))`() |]

    toJExpr (ApplyExpression (SymbolExpression (Symbol "run"))
         [LazyExpression (Addr s e (ApplyExpression (SymbolExpression (Symbol "run"))
             [JSExpression (ValExpr (JFunc [] (BlockStat [ReturnStat y])))])) Every]) =

        opt y

    toJExpr y @ (ApplyExpression (SymbolExpression (Symbol "run")) [JSExpression (ValExpr (UnsatVal x))]) =

        case sat_ x of
            (JFunc _ (BlockStat [ReturnStat y])) -> opt y
            (JFunc _ (BlockStat [BlockStat [ReturnStat y]])) -> opt y
            y -> [jmacroE| `(ValExpr (opt y))`() |]

    toJExpr (ApplyExpression (SymbolExpression (Symbol "run")) [x]) = 

        [jmacroE| `(x)`() |]

    toJExpr (ApplyExpression (SymbolExpression f @ (Operator _)) xs) =
        toJExpr (ApplyExpression (SymbolExpression (Symbol (to_name f))) xs)

    toJExpr (ApplyExpression (SymbolExpression f) []) = ref (to_name f)
    toJExpr (ApplyExpression f []) = [jmacroE| `(f)` |]
    toJExpr (ApplyExpression f (end -> x : xs)) = [jmacroE| `(ApplyExpression f xs)`(`(x)`) |]

    toJExpr (AccessorExpression (Addr _ _ x) []) =

        toJExpr x

    toJExpr (AccessorExpression x (reverse -> y:ys)) =

        [jmacroE| `(AccessorExpression x (reverse ys))`[`(to_name y)`] |]

    toJExpr (ListExpression x)      = toJExpr x
    toJExpr (LiteralExpression l)   = toJExpr l
    toJExpr (SymbolExpression x)    = ref (to_name x)
    toJExpr (FunctionExpression x)  = toJExpr x
    toJExpr (LazyExpression x Every) =

        toJExpr (FunctionExpression
                 [ EqualityAxiom
                   (Match [AnyPattern] Nothing)
                   x ])

    toJExpr (LazyExpression (Addr _ _ x) Once) =

        [jmacroE| (function() {
                      var y = undefined;
                      return function() {
                          if (y) {
                              return y;
                          } else {
                              y = `(x)`;
                              return y;
                          }
                      }
                  })() |]

    toJExpr (RecordExpression m)    = toJExpr (M.mapKeys to_name m)
    toJExpr (JSExpression s)        = opt s
    toJExpr (LetExpression bs ex) 
        | length bs > 0 =
            [jmacroE| (function() { `(foldl1 mappend $ map toLocal bs)`; return `(ex)` })() |]
        | otherwise =
            toJExpr ex

    toJExpr (IfExpression x y (Just z)) =

        [jmacroE| `(x)` ? `(y)` : `(z)` |]

    toJExpr (IfExpression x y Nothing) =

        [jmacroE| `(x)` ? `(y)` : function() { return {}; } |]


    toJExpr x = error $ "Unimplemented " ++ show x


