{-# LANGUAGE NoMonomorphismRestriction #-}
{-# LANGUAGE FlexibleInstances         #-}
{-# LANGUAGE FlexibleContexts          #-}
{-# LANGUAGE UndecidableInstances      #-}
{-# LANGUAGE TypeSynonymInstances      #-}
{-# LANGUAGE TupleSections             #-}
{-# LANGUAGE OverloadedStrings         #-}

module Language.Haskell.Liquid.Parse
  ( hsSpecificationP, lhsSpecificationP, specSpecificationP
  , parseSymbolToLogic
  )
  where

import Prelude hiding (error)
import Control.Monad
import Control.Arrow (second)
import Text.Parsec
import Text.Parsec.Error (newErrorMessage, Message (..))
import Text.Parsec.Pos   (newPos)

import qualified Text.Parsec.Token   as Token
import qualified Data.Text           as T
import qualified Data.HashMap.Strict as M
import qualified Data.HashSet        as S
import Data.Monoid


import Data.Char (isSpace, isAlpha, isUpper, isAlphaNum)
import Data.List (foldl', partition)

import GHC (mkModuleName)
import Text.PrettyPrint.HughesPJ    (text)

import Language.Preprocessor.Unlit (unlit)

import Language.Fixpoint.Types hiding (Error, R)

import Language.Haskell.Liquid.GHC.Misc
import Language.Haskell.Liquid.Types hiding (Axiom)
import Language.Haskell.Liquid.Misc (mapSnd)
import Language.Haskell.Liquid.Types.RefType
import Language.Haskell.Liquid.Types.Variance
import Language.Haskell.Liquid.Types.Bounds

import qualified Language.Haskell.Liquid.Measure as Measure

import Language.Fixpoint.Parse hiding (angles, refBindP, refP, refDefP)
-- import Debug.Trace


----------------------------------------------------------------------------
-- Top Level Parsing API ---------------------------------------------------
----------------------------------------------------------------------------

-------------------------------------------------------------------------------
hsSpecificationP :: SourceName -> String -> Either Error (ModName, Measure.BareSpec)
-------------------------------------------------------------------------------

hsSpecificationP = parseWithError $ do
    name <-  try (lookAhead $ skipMany (commentP >> spaces)
                           >> reserved "module" >> symbolP)
         <|> return "Main"
    liftM (mkSpec (ModName SrcImport $ mkModuleName $ symbolString name)) $ specWraps specP

-------------------------------------------------------------------------------
lhsSpecificationP :: SourceName -> String -> Either Error (ModName, Measure.BareSpec)
-------------------------------------------------------------------------------

lhsSpecificationP sn s = hsSpecificationP sn $ unlit sn s

commentP =  simpleComment (string "{-") (string "-}")
        <|> simpleComment (string "--") newlineP
        <|> simpleComment (string "\\") newlineP
        <|> simpleComment (string "#")  newlineP

simpleComment open close = open >> manyTill anyChar (try close)

newlineP = try (string "\r\n") <|> string "\n" <|> string "\r"


-- | Used to parse .spec files

--------------------------------------------------------------------------
specSpecificationP  :: SourceName -> String -> Either Error (ModName, Measure.BareSpec)
--------------------------------------------------------------------------
specSpecificationP  = parseWithError specificationP

specificationP :: Parser (ModName, Measure.BareSpec)
specificationP
  = do reserved "module"
       reserved "spec"
       name   <- symbolP
       reserved "where"
       xs     <- grabs (specP <* whiteSpace)
       return $ mkSpec (ModName SpecImport $ mkModuleName $ symbolString name) xs

---------------------------------------------------------------------------
parseWithError :: Parser a -> SourceName -> String -> Either Error a
---------------------------------------------------------------------------
parseWithError parser f s
  = case runParser (remainderP (whiteSpace >> parser)) 0 f s of
      Left e            -> Left  $ parseErrorError f e
      Right (r, "", _)  -> Right r
      Right (_, rem, _) -> Left  $ parseErrorError f $ remParseError f s rem


---------------------------------------------------------------------------
parseErrorError     :: SourceName -> ParseError -> Error
---------------------------------------------------------------------------
parseErrorError f e = ErrParse sp msg e
  where
    pos             = errorPos e
    sp              = sourcePosSrcSpan pos
    msg             = text $ "Error Parsing Specification from: " ++ f

---------------------------------------------------------------------------
remParseError       :: SourceName -> String -> String -> ParseError
---------------------------------------------------------------------------
remParseError f s r = newErrorMessage msg $ newPos f line col
  where
    msg             = Message "Leftover while parsing"
    (line, col)     = remLineCol s r

remLineCol          :: String -> String -> (Int, Int)
remLineCol src rem = (line, col)
  where
    line           = 1 + srcLine - remLine
    srcLine        = length srcLines
    remLine        = length remLines
    col            = srcCol - remCol
    srcCol         = length $ srcLines !! (line - 1)
    remCol         = length $ head remLines
    srcLines       = lines  src
    remLines       = lines  rem



----------------------------------------------------------------------------------
-- Parse to Logic  ---------------------------------------------------------------
----------------------------------------------------------------------------------

parseSymbolToLogic = parseWithError toLogicP

toLogicP
  = toLogicMap <$> many toLogicOneP

toLogicOneP
  = do reserved "define"
       (x:xs) <- many1 symbolP
       reserved "="
       e      <- exprP
       return (x, xs, e)


----------------------------------------------------------------------------------
-- Lexer Tokens ------------------------------------------------------------------
----------------------------------------------------------------------------------

dot           = Token.dot           lexer
angles        = Token.angles        lexer
stringLiteral = Token.stringLiteral lexer

----------------------------------------------------------------------------------
-- BareTypes ---------------------------------------------------------------------
----------------------------------------------------------------------------------

-- | The top-level parser for "bare" refinement types. If refinements are
-- not supplied, then the default "top" refinement is used.

bareTypeP :: Parser BareType
bareTypeP
  =  try bareAllP
 <|> bareAllS
--  <|> bareAllExprP
--  <|> bareExistsP
 <|> try bareConstraintP
 <|> try bareFunP
 <|> bareAtomP (refBindP bindP)
 <|> try (angles (do t <- parens bareTypeP
                     p <- monoPredicateP
                     return $ t `strengthen` MkUReft mempty p mempty))

bareArgP vv
  =  bareAtomP (refDefP vv)
 <|> parens bareTypeP

bareAtomP ref
  =  ref refasHoleP bbaseP
 <|> holeP
 <|> try (dummyP (bbaseP <* spaces))

refBindP :: Subable a => Parser Symbol -> Parser Expr -> Parser (Reft -> a) -> Parser a
refBindP bp rp kindP
  = braces $ do
      x  <- bp
      i  <- freshIntP
      t  <- kindP
      reserved "|"
      ra <- rp <* spaces
      let xi = intSymbol x i
      let su v = if v == x then xi else v
      return $ substa su $ t (Reft (x, ra))

refP       = refBindP bindP refaP
refDefP x  = refBindP (optBindP x)

optBindP x = try bindP <|> return x

holeP       = reserved "_" >> spaces >> return (RHole $ uTop $ Reft ("VV", hole))
holeRefP    = reserved "_" >> spaces >> return (RHole . uTop)
refasHoleP  = try refaP
           <|> (reserved "_" >> return hole)

-- FIXME: the use of `blanks = oneOf " \t"` here is a terrible and fragile hack
-- to avoid parsing:
--
--   foo :: a -> b
--   bar :: a
--
-- as `foo :: a -> b bar`..
bbaseP :: Parser (Reft -> BareType)
bbaseP
  =  holeRefP
 <|> liftM2 bLst (brackets (maybeP bareTypeP)) predicatesP
 <|> liftM2 bTup (parens $ sepBy bareTypeP comma) predicatesP
 <|> try (liftM2 bAppTy lowerIdP (sepBy1 bareTyArgP blanks))
 <|> try (liftM3 bRVar lowerIdP stratumP monoPredicateP)
 <|> liftM5 bCon locUpperIdP stratumP predicatesP (sepBy bareTyArgP blanks) mmonoPredicateP

stratumP :: Parser Strata
stratumP
  = do reserved "^"
       bstratumP
 <|> return mempty

bstratumP
  = ((:[]) . SVar) <$> symbolP

bbaseNoAppP :: Parser (Reft -> BareType)
bbaseNoAppP
  =  holeRefP
 <|> liftM2 bLst (brackets (maybeP bareTypeP)) predicatesP
 <|> liftM2 bTup (parens $ sepBy bareTypeP comma) predicatesP
 <|> try (liftM5 bCon locUpperIdP stratumP predicatesP (return []) (return mempty))
 <|> liftM3 bRVar lowerIdP stratumP monoPredicateP

maybeP p = liftM Just p <|> return Nothing

bareTyArgP
  =  -- try (RExprArg . expr <$> binderP) <|>
     try (RExprArg . fmap expr <$> locParserP integer)
 <|> try (braces $ RExprArg <$> locParserP exprP)
 <|> try bareAtomNoAppP
 <|> try (parens bareTypeP)

bareAtomNoAppP
  =  refP bbaseNoAppP
 <|> try (dummyP (bbaseNoAppP <* spaces))

bareConstraintP
  = do ct   <- braces constraintP
       t    <- bareTypeP
       return $ rrTy ct t

constraintP
  = do xts <- constraintEnvP
       t1  <- bareTypeP
       reserved "<:"
       t2  <- bareTypeP
       return $ fromRTypeRep $ RTypeRep [] [] [] ((val . fst <$> xts) ++ [dummySymbol])
                                                 (replicate (length xts + 1) mempty)
                                                 ((snd <$> xts) ++ [t1]) t2

constraintEnvP
   =  try (do xts <- sepBy tyBindNoLocP comma
              reserved "|-"
              return xts)
  <|> return []

rrTy ct = RRTy (xts ++ [(dummySymbol, tr)]) mempty OCons
  where
    tr   = ty_res trep
    xts  = zip (ty_binds trep) (ty_args trep)
    trep = toRTypeRep ct

bareAllS
  = do reserved "forall"
       ss <- angles $ sepBy1 symbolP comma
       dot
       t  <- bareTypeP
       return $ foldr RAllS t ss

bareAllP
  = do reserved "forall"
       as <- many tyVarIdP
       ps <- predVarDefsP
       dot
       t  <- bareTypeP
       return $ foldr RAllT (foldr RAllP t ps) as

tyVarIdP :: Parser Symbol
tyVarIdP = symbol <$> condIdP alphanums (isSmall . head)
           where
             alphanums = S.fromList $ ['a'..'z'] ++ ['0'..'9']

predVarDefsP
  =  try (angles $ sepBy1 predVarDefP comma)
 <|> return []

predVarDefP
  = bPVar <$> predVarIdP <*> dcolon <*> predVarTypeP

predVarIdP
  = symbol <$> tyVarIdP

bPVar p _ xts  = PV p (PVProp τ) dummySymbol τxs
  where
    (_, τ) = safeLast "bPVar last" xts
    τxs    = [ (τ, x, EVar x) | (x, τ) <- init xts ]
    safeLast _ xs@(_:_) = last xs
    safeLast msg _      = panic Nothing $ "safeLast with empty list " ++ msg

predVarTypeP :: Parser [(Symbol, BSort)]
predVarTypeP = bareTypeP >>= either parserFail return . mkPredVarType

mkPredVarType t
  | isOk      = Right $ zip xs ts
  | otherwise = Left err
  where
    isOk      = isPropBareType tOut || isHPropBareType tOut
    tOut      = ty_res trep
    trep      = toRTypeRep t
    xs        = ty_binds trep
    ts        = toRSort <$> ty_args trep
    err       = "Predicate Variable with non-Prop output sort: " ++ showpp t

xyP lP sepP rP
  = (\x _ y -> (x, y)) <$> lP <*> (spaces >> sepP) <*> rP

data ArrowSym = ArrowFun | ArrowPred

arrowP
  =   (reserved "->" >> return ArrowFun)
  <|> (reserved "=>" >> return ArrowPred)

bareFunP
  = do b  <- try bindP <|> dummyBindP
       t1 <- bareArgP b
       a  <- arrowP
       t2 <- bareTypeP
       return $ bareArrow b t1 a t2

dummyBindP = tempSymbol "db" <$> freshIntP

bbindP     = lowerIdP <* dcolon

bareArrow b t1 ArrowFun t2
  = rFun b t1 t2
bareArrow _ t1 ArrowPred t2
  = foldr (rFun dummySymbol) t2 (getClasses t1)


isPropBareType  = isPrimBareType propConName
isHPropBareType = isPrimBareType hpropConName
isPrimBareType n (RApp tc [] _ _) = val tc == n
isPrimBareType _ _                = False



getClasses t@(RApp tc ts _ _)
  | isTuple tc
  = ts
  | otherwise
  = [t]
getClasses t
  = [t]

dummyP ::  Monad m => m (Reft -> b) -> m b
dummyP fm
  = fm `ap` return dummyReft

symsP
  = do reserved "\\"
       ss <- sepBy symbolP spaces
       reserved "->"
       return $ (, dummyRSort) <$> ss
 <|> return []

dummyRSort
  = RVar "dummy" mempty

predicatesP
   =  try (angles $ sepBy1 predicate1P comma)
  <|> return []

predicate1P
   =  try (RProp <$> symsP <*> refP bbaseP)
  <|> (rPropP [] . predUReft <$> monoPredicate1P)
  <|> (braces $ bRProp <$> symsP' <*> refaP)
   where
    symsP'       = do ss    <- symsP
                      fs    <- mapM refreshSym (fst <$> ss)
                      return $ zip ss fs
    refreshSym s = intSymbol s <$> freshIntP

mmonoPredicateP
   = try (angles $ angles monoPredicate1P)
  <|> return mempty

monoPredicateP
   = try (angles monoPredicate1P)
  <|> return mempty

monoPredicate1P
   =  try (reserved "True" >> return mempty)
  <|> try (pdVar <$> parens predVarUseP)
  <|> (pdVar <$> predVarUseP)

predVarUseP
  = do (p, xs) <- funArgsP
       return   $ PV p (PVProp dummyTyId) dummySymbol [ (dummyTyId, dummySymbol, x) | x <- xs ]

funArgsP  = try realP <|> empP
  where
    empP  = (,[]) <$> predVarIdP
    realP = do (EVar lp, xs) <- splitEApp <$> funAppP
               return (lp, xs)

boundP :: Parser (Bound (Located BareType) Expr)
boundP = do
  name   <- locParserP upperIdP
  reservedOp "="
  vs     <- bvsP
  params <- many (parens tyBindP)
  args   <- bargsP
  body   <- predP
  return $ Bound name vs params args body
 where
    bargsP = try ( do reservedOp "\\"
                      xs <- many (parens tyBindP)
                      reservedOp  "->"
                      return xs
                 )
           <|> return []
    bvsP   = try ( do reserved "forall"
                      xs <- many (locParserP symbolP)
                      reserved  "."
                      return (fmap (`RVar` mempty) <$> xs)
                 )
           <|> return []

------------------------------------------------------------------------
----------------------- Wrapped Constructors ---------------------------
------------------------------------------------------------------------

bRProp []    _    = panic Nothing "Parse.bRProp empty list"
bRProp syms' expr = RProp ss $ bRVar dummyName mempty mempty r
  where
    (ss, (v, _))  = (init syms, last syms)
    syms          = [(y, s) | ((_, s), y) <- syms']
    su            = mkSubst [(x, EVar y) | ((x, _), y) <- syms']
    r             = su `subst` Reft (v, expr)

bRVar α s p r             = RVar α (MkUReft r p s)
bLst (Just t) rs r        = RApp (dummyLoc listConName) [t] rs (reftUReft r)
bLst (Nothing) rs r       = RApp (dummyLoc listConName) []  rs (reftUReft r)

bTup [t] _ r | isTauto r  = t
             | otherwise  = t `strengthen` (reftUReft r)
bTup ts rs r              = RApp (dummyLoc tupConName) ts rs (reftUReft r)


-- Temporarily restore this hack benchmarks/esop2013-submission/Array.hs fails
-- w/o it
-- TODO RApp Int [] [p] true should be syntactically different than RApp Int [] [] p
-- bCon b s [RProp _ (RHole r1)] [] _ r = RApp b [] [] $ r1 `meet` (MkUReft r mempty s)
bCon b s rs            ts p r = RApp b ts rs $ MkUReft r p s

bAppTy v ts r  = ts' `strengthen` reftUReft r
  where
    ts'        = foldl' (\a b -> RAppTy a b mempty) (RVar v mempty) ts

reftUReft r    = MkUReft r mempty mempty

predUReft p    = MkUReft dummyReft p mempty

dummyReft      = mempty

dummyTyId      = ""

------------------------------------------------------------------
--------------------------- Measures -----------------------------
------------------------------------------------------------------

data Pspec ty ctor
  = Meas    (Measure ty ctor)
  | Assm    (LocSymbol, ty)
  | Asrt    (LocSymbol, ty)
  | LAsrt   (LocSymbol, ty)
  | Asrts   ([LocSymbol], (ty, Maybe [Located Expr]))
  | Impt    Symbol
  | DDecl   DataDecl
  | Incl    FilePath
  | Invt    ty
  | IAlias  (ty, ty)
  | Alias   (RTAlias Symbol BareType)
  | EAlias  (RTAlias Symbol Expr)
  | Embed   (LocSymbol, FTycon)
  | Qualif  Qualifier
  | Decr    (LocSymbol, [Int])
  | LVars   LocSymbol
  | Lazy    LocSymbol
  | HMeas   LocSymbol
  | Axiom   LocSymbol
  | Inline  LocSymbol
  | ASize   LocSymbol
  | HBound  LocSymbol
  | PBound  (Bound ty Expr)
  | Pragma  (Located String)
  | CMeas   (Measure ty ())
  | IMeas   (Measure ty ctor)
  | Class   (RClass ty)
  | RInst   (RInstance ty)
  | Varia   (LocSymbol, [Variance])

-- | For debugging
instance Show (Pspec a b) where
  show (Meas   _) = "Meas"
  show (Assm   _) = "Assm"
  show (Asrt   _) = "Asrt"
  show (LAsrt  _) = "LAsrt"
  show (Asrts  _) = "Asrts"
  show (Impt   _) = "Impt"
  show (DDecl  _) = "DDecl"
  show (Incl   _) = "Incl"
  show (Invt   _) = "Invt"
  show (IAlias _) = "IAlias"
  show (Alias  _) = "Alias"
  show (EAlias _) = "EAlias"
  show (Embed  _) = "Embed"
  show (Qualif _) = "Qualif"
  show (Decr   _) = "Decr"
  show (LVars  _) = "LVars"
  show (Lazy   _) = "Lazy"
  show (Axiom  _) = "Axiom"
  show (HMeas  _) = "HMeas"
  show (HBound _) = "HBound"
  show (Inline _) = "Inline"
  show (Pragma _) = "Pragma"
  show (CMeas  _) = "CMeas"
  show (IMeas  _) = "IMeas"
  show (Class  _) = "Class"
  show (Varia  _) = "Varia"
  show (PBound _) = "Bound"
  show (RInst  _) = "RInst"
  show (ASize  _) = "ASize"

mkSpec :: ModName -> [Pspec (Located BareType) LocSymbol] -> (ModName, Measure.Spec (Located BareType) LocSymbol)
mkSpec name xs         = (name,)
                       $ Measure.qualifySpec (symbol name)
                       $ Measure.Spec
  { Measure.measures   = [m | Meas   m <- xs]
  , Measure.asmSigs    = [a | Assm   a <- xs]
  , Measure.sigs       = [a | Asrt   a <- xs]
                      ++ [(y, t) | Asrts (ys, (t, _)) <- xs, y <- ys]
  , Measure.localSigs  = []
  , Measure.invariants = [t | Invt   t <- xs]
  , Measure.ialiases   = [t | IAlias t <- xs]
  , Measure.imports    = [i | Impt   i <- xs]
  , Measure.dataDecls  = [d | DDecl  d <- xs]
  , Measure.includes   = [q | Incl   q <- xs]
  , Measure.aliases    = [a | Alias  a <- xs]
  , Measure.ealiases   = [e | EAlias e <- xs]
  , Measure.embeds     = M.fromList [e | Embed e <- xs]
  , Measure.qualifiers = [q | Qualif q <- xs]
  , Measure.decr       = [d | Decr d   <- xs]
  , Measure.lvars      = [d | LVars d  <- xs]
  , Measure.lazy       = S.fromList [s | Lazy   s <- xs]
  , Measure.axioms     = S.fromList [s | Axiom  s <- xs]
  , Measure.hmeas      = S.fromList [s | HMeas  s <- xs]
  , Measure.inlines    = S.fromList [s | Inline s <- xs]
  , Measure.autosize   = S.fromList [s | ASize  s <- xs]
  , Measure.hbounds    = S.fromList [s | HBound s <- xs]
  , Measure.pragmas    = [s | Pragma s <- xs]
  , Measure.cmeasures  = [m | CMeas  m <- xs]
  , Measure.imeasures  = [m | IMeas  m <- xs]
  , Measure.classes    = [c | Class  c <- xs]
  , Measure.dvariance  = [v | Varia  v <- xs]
  , Measure.rinstance  = [i | RInst  i <- xs]
  , Measure.bounds     = M.fromList [(bname i, i) | PBound i <- xs]
  , Measure.termexprs  = [(y, es) | Asrts (ys, (_, Just es)) <- xs, y <- ys]
  }

specP :: Parser (Pspec (Located BareType) LocSymbol)
specP
  = try (reservedToken "assume"       >> liftM Assm   tyBindP   )
    <|> (reservedToken "assert"       >> liftM Asrt   tyBindP   )
    <|> (reservedToken "autosize"     >> liftM ASize  asizeP    )
    <|> (reservedToken "Local"        >> liftM LAsrt  tyBindP   )
    <|> (reservedToken "axiomatize"   >> liftM Axiom  axiomP    )
    <|> try (reservedToken "measure"  >> liftM Meas   measureP  )
    <|> (reservedToken "measure"      >> liftM HMeas  hmeasureP )
    <|> (reservedToken "inline"       >> liftM Inline  inlineP  )
    <|> try (reservedToken "bound"    >> liftM PBound  boundP   )
    <|> (reservedToken "bound"        >> liftM HBound  hboundP  )
    <|> try (reservedToken "class"    >> reserved "measure" >> liftM CMeas cMeasureP)
    <|> try (reservedToken "instance" >> reserved "measure" >> liftM IMeas iMeasureP)
    <|> (reservedToken "instance"  >> liftM RInst  instanceP )
    <|> (reservedToken "class"     >> liftM Class  classP    )
    <|> (reservedToken "import"    >> liftM Impt   symbolP   )
    <|> try (reservedToken "data" >> reserved "variance " >> liftM Varia datavarianceP)
    <|> (reservedToken "data"      >> liftM DDecl  dataDeclP )
    <|> (reservedToken "include"   >> liftM Incl   filePathP )
    <|> (reservedToken "invariant" >> liftM Invt   invariantP)
    <|> (reservedToken "using"     >> liftM IAlias invaliasP )
    <|> (reservedToken "type"      >> liftM Alias  aliasP    )
    <|> (reservedToken "predicate" >> liftM EAlias ealiasP   )
    <|> (reservedToken "expression">> liftM EAlias ealiasP   )
    <|> (reservedToken "embed"     >> liftM Embed  embedP    )
    <|> (reservedToken "qualif"    >> liftM Qualif (qualifierP sortP))
    <|> (reservedToken "Decrease"  >> liftM Decr   decreaseP )
    <|> (reservedToken "LAZYVAR"   >> liftM LVars  lazyVarP  )
    <|> (reservedToken "Strict"    >> liftM Lazy   lazyVarP  )
    <|> (reservedToken "Lazy"      >> liftM Lazy   lazyVarP  )
    <|> (reservedToken "LIQUID"    >> liftM Pragma pragmaP   )
    <|> ({- DEFAULT -}                liftM Asrts  tyBindsP  )

reservedToken str = try(string str >> spaces1)

spaces1 = satisfy isSpace >> spaces


pragmaP :: Parser (Located String)
pragmaP = locParserP stringLiteral

lazyVarP :: Parser LocSymbol
lazyVarP = locParserP binderP

hmeasureP :: Parser LocSymbol
hmeasureP = locParserP binderP

axiomP :: Parser LocSymbol
axiomP = locParserP binderP

hboundP :: Parser LocSymbol
hboundP = locParserP binderP

inlineP :: Parser LocSymbol
inlineP = locParserP binderP

asizeP :: Parser LocSymbol
asizeP = locParserP binderP

decreaseP :: Parser (LocSymbol, [Int])
decreaseP = mapSnd f <$> liftM2 (,) (locParserP binderP) (spaces >> (many integer))
  where
    f     = ((\n -> fromInteger n - 1) <$>)

filePathP     :: Parser FilePath
filePathP     = angles $ many1 pathCharP
  where
    pathCharP = choice $ char <$> pathChars
    pathChars = ['a'..'z'] ++ ['A'..'Z'] ++ ['0'..'9'] ++ ['.', '/']

datavarianceP = liftM2 (,) locUpperIdP (spaces >> many varianceP)

varianceP = (reserved "bivariant"     >> return Bivariant)
        <|> (reserved "invariant"     >> return Invariant)
        <|> (reserved "covariant"     >> return Covariant)
        <|> (reserved "contravariant" >> return Contravariant)
        <?> "Invalib variance annotation\t Use one of bivariant, invariant, covariant, contravariant"

tyBindsP :: Parser ([LocSymbol], (Located BareType, Maybe [Located Expr]))
tyBindsP = xyP (sepBy (locParserP binderP) comma) dcolon termBareTypeP

tyBindNoLocP :: Parser (LocSymbol, BareType)
tyBindNoLocP = second val <$> tyBindP

tyBindP    :: Parser (LocSymbol, Located BareType)
tyBindP    = xyP xP dcolon tP
  where
    xP     = locParserP binderP
    tP     = locParserP genBareTypeP

termBareTypeP :: Parser (Located BareType, Maybe [Located Expr])
termBareTypeP
   = try termTypeP
  <|> (, Nothing) <$> locParserP genBareTypeP

termTypeP :: Parser (Located BareType, Maybe [Located Expr])
termTypeP
  = do t <- locParserP genBareTypeP
       reserved "/"
       es <- brackets $ sepBy (locParserP exprP) comma
       return (t, Just es)

invariantP :: Parser (Located BareType)
invariantP = locParserP genBareTypeP

invaliasP :: Parser (Located BareType, Located BareType)
invaliasP
  = do t  <- locParserP genBareTypeP
       reserved "as"
       ta <- locParserP genBareTypeP
       return (t, ta)

genBareTypeP
  = bareTypeP

embedP
  = xyP locUpperIdP (reserved "as") fTyConP


aliasP  = rtAliasP id     bareTypeP
ealiasP = try (rtAliasP symbol predP)
      <|> rtAliasP symbol exprP

rtAliasP :: (Symbol -> tv) -> Parser ty -> Parser (RTAlias tv ty)
rtAliasP f bodyP
  = do pos  <- getPosition
       name <- upperIdP
       spaces
       args <- sepBy aliasIdP blanks
       whiteSpace >> reservedOp "=" >> whiteSpace
       body <- bodyP
       posE <- getPosition
       let (tArgs, vArgs) = partition (isSmall . headSym) args
       return $ RTA name (f <$> tArgs) (f <$> vArgs) body pos posE

aliasIdP :: Parser Symbol
aliasIdP = condIdP alphaNums (isAlpha . head)
           where
             alphaNums = S.fromList $ ['A' .. 'Z'] ++ ['a'..'z'] ++ ['0'..'9']

measureP :: Parser (Measure (Located BareType) LocSymbol)
measureP
  = do (x, ty) <- tyBindP
       whiteSpace
       eqns    <- grabs $ measureDefP (rawBodyP <|> tyBodyP ty)
       return   $ Measure.mkM x ty eqns

cMeasureP :: Parser (Measure (Located BareType) ())
cMeasureP
  = do (x, ty) <- tyBindP
       return $ Measure.mkM x ty []

iMeasureP :: Parser (Measure (Located BareType) LocSymbol)
iMeasureP = measureP

instanceP :: Parser (RInstance (Located BareType))
instanceP
  = do c  <- locUpperIdP
       lt <- locParserP (rit <$> locUpperIdP <*> classParams)
       ts <- sepBy tyBindP semi
       return $ RI c lt ts
  where
    rit t as    = RApp t ((`RVar` mempty) <$> as) [] mempty
    classParams =  (reserved "where" >> return [])
               <|> ((:) <$> lowerIdP <*> classParams)

classP :: Parser (RClass (Located BareType))
classP
  = do sups <- supersP
       c    <- locUpperIdP
       spaces
       tvs  <- manyTill tyVarIdP (try $ reserved "where")
       ms   <- grabs tyBindP
       spaces
       return $ RClass (fmap symbol c) sups tvs ms -- sups tvs ms
  where
    superP   = locParserP (toRCls <$> bareAtomP (refBindP bindP))
    supersP  = try (((parens (superP `sepBy1` comma)) <|> fmap pure superP)
                       <* reserved "=>")
               <|> return []
    toRCls x = x

rawBodyP
  = braces $ do
      v <- symbolP
      reserved "|"
      p <- predP <* spaces
      return $ R v p

tyBodyP :: Located BareType -> Parser Body
tyBodyP ty
  = case outTy (val ty) of
      Just bt | isPropBareType bt
                -> P <$> predP
      _         -> E <$> exprP
    where outTy (RAllT _ t)    = outTy t
          outTy (RAllP _ t)    = outTy t
          outTy (RFun _ _ t _) = Just t
          outTy _              = Nothing

locUpperIdP' = locParserP upperIdP'

upperIdP' :: Parser Symbol
upperIdP' = try $ symbol <$> condIdP' (isUpper . head)

condIdP'  :: (String -> Bool) -> Parser Symbol
condIdP' f
  = do c  <- letter
       let isAlphaNumOr' c = isAlphaNum c || ('\''== c)
       cs <- many (satisfy isAlphaNumOr')
       blanks
       if f (c:cs) then return (symbol $ T.pack $ c:cs) else parserZero

binderP :: Parser Symbol
binderP    =  try $ symbol <$> idP badc
          <|> pwr <$> parens (idP bad)
  where
    idP p  = many1 (satisfy (not . p))
    badc c = (c == ':') || (c == ',') || bad c
    bad c  = isSpace c || c `elem` ("(,)" :: String)
    pwr s  = symbol $ "(" `mappend` s `mappend` ")"

grabs p = try (liftM2 (:) p (grabs p))
       <|> return []

measureDefP :: Parser Body -> Parser (Def (Located BareType) LocSymbol)
measureDefP bodyP
  = do mname   <- locParserP symbolP
       (c, xs) <- measurePatP
       whiteSpace >> reservedOp "=" >> whiteSpace
       body    <- bodyP
       whiteSpace
       let xs'  = (symbol . val) <$> xs
       return   $ Def mname [] (symbol <$> c) Nothing ((, Nothing) <$> xs') body

measurePatP :: Parser (LocSymbol, [LocSymbol])
measurePatP
  =  parens (try conPatP <|> try consPatP <|> nilPatP <|> tupPatP)
 <|> nullaryConPatP

tupPatP  = mkTupPat  <$> sepBy1 locLowerIdP comma
conPatP  = (,)       <$> locParserP dataConNameP <*> sepBy locLowerIdP whiteSpace
consPatP = mkConsPat <$> locLowerIdP  <*> colon <*> locLowerIdP
nilPatP  = mkNilPat  <$> brackets whiteSpace

nullaryConPatP = nilPatP <|> ((,[]) <$> locParserP dataConNameP)

mkTupPat zs     = (tupDataCon (length zs), zs)
mkNilPat _      = (dummyLoc "[]", []    )
mkConsPat x _ y = (dummyLoc ":" , [x, y])
tupDataCon n    = dummyLoc $ symbol $ "(" <> replicate (n - 1) ',' <> ")"


-------------------------------------------------------------------------------
--------------------------------- Predicates ----------------------------------
-------------------------------------------------------------------------------

dataConFieldsP
  =   (braces $ sepBy predTypeDDP comma)
  <|> (sepBy dataConFieldP spaces)

dataConFieldP
  = parens ( try predTypeDDP
             <|> do v <- dummyBindP
                    t <- bareTypeP
                    return (v,t)
           )
    <|> do v <- dummyBindP
           t <- bareTypeP
           return (v,t)

predTypeDDP
  = liftM2 (,) bbindP bareTypeP

dataConP
  = do x   <- locParserP dataConNameP
       spaces
       xts <- dataConFieldsP
       return (x, xts)

dataConNameP
  =  try upperIdP
 <|> pwr <$> parens (idP bad)
  where
     idP p  = many1 (satisfy (not . p))
     bad c  = isSpace c || c `elem` ("(,)" :: String)
     pwr s  = symbol $ "(" <> s <> ")"

dataSizeP
  = (brackets $ (Just . mkFun) <$> locLowerIdP)
  <|> return Nothing
  where
    mkFun s x = mkEApp (symbol <$> s) [EVar x]

dataDeclP :: Parser DataDecl
dataDeclP = try dataDeclFullP <|> dataDeclSizeP


dataDeclSizeP
  = do pos <- getPosition
       x   <- locUpperIdP'
       spaces
       fsize <- dataSizeP
       return $ D x [] [] [] [] pos fsize

dataDeclFullP
  = do pos <- getPosition
       x   <- locUpperIdP'
       spaces
       fsize <- dataSizeP
       spaces
       ts  <- sepBy tyVarIdP blanks
       ps  <- predVarDefsP
       whiteSpace >> reservedOp "=" >> whiteSpace
       dcs <- sepBy dataConP (reserved "|")
       whiteSpace
       return $ D x ts ps [] dcs pos fsize

---------------------------------------------------------------------
-- | Parsing Qualifiers ---------------------------------------------
---------------------------------------------------------------------

fTyConP :: Parser FTycon
fTyConP
  =   (reserved "int"     >> return intFTyCon)
  <|> (reserved "Integer" >> return intFTyCon)
  <|> (reserved "Int"     >> return intFTyCon)
  <|> (reserved "int"     >> return intFTyCon)
  <|> (reserved "real"    >> return realFTyCon)
  <|> (reserved "bool"    >> return boolFTyCon)
  <|> (symbolFTycon      <$> locUpperIdP)


---------------------------------------------------------------------
------------ Interacting with Fixpoint ------------------------------
---------------------------------------------------------------------

grabUpto p
  =  try (Just <$> lookAhead p)
 <|> try (eof   >> return Nothing)
 <|> (anyChar   >> grabUpto p)

betweenMany leftP rightP p
  = do z <- grabUpto leftP
       case z of
         Just _  -> liftM2 (:) (between leftP rightP p) (betweenMany leftP rightP p)
         Nothing -> return []

specWraps = betweenMany (liquidBeginP >> whiteSpace) (whiteSpace >> liquidEndP)

liquidBeginP = string liquidBegin
liquidEndP   = string liquidEnd

---------------------------------------------------------------
-- | Bundling Parsers into a Typeclass ------------------------
---------------------------------------------------------------

instance Inputable BareType where
  rr' = doParse' bareTypeP

-- instance Inputable (Measure BareType LocSymbol) where
--   rr' = doParse' measureP
