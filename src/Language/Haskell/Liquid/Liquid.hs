{-# LANGUAGE NamedFieldPuns      #-}
{-# LANGUAGE TupleSections       #-}
{-# LANGUAGE ScopedTypeVariables #-}

{-@ LIQUID "--diff"     @-}

module Language.Haskell.Liquid.Liquid (
   -- * Executable command
    liquid

   -- * Single query
  , runLiquid

   -- * Ghci State
  , MbEnv
  ) where

import           Prelude hiding (error)
import           Data.Bifunctor
import           Data.Maybe
import           System.Exit
-- import           Control.DeepSeq
import           Text.PrettyPrint.HughesPJ
import           CoreSyn
-- import           Var
import           HscTypes                         (SourceError)
import           System.Console.CmdArgs.Verbosity (whenLoud, whenNormal)
import           System.Console.CmdArgs.Default
import           GHC (HscEnv)

import qualified Control.Exception as Ex
import qualified Language.Fixpoint.Types.Config as FC
import qualified Language.Haskell.Liquid.UX.DiffCheck as DC
import           Language.Fixpoint.Misc
import           Language.Fixpoint.Solver
import qualified Language.Fixpoint.Types as F
import           Language.Haskell.Liquid.Types
import           Language.Haskell.Liquid.Types.RefType (applySolution)
import           Language.Haskell.Liquid.UX.Errors
import           Language.Haskell.Liquid.UX.CmdLine
import           Language.Haskell.Liquid.UX.Tidy
import           Language.Haskell.Liquid.GHC.Interface
import           Language.Haskell.Liquid.Constraint.Generate
import           Language.Haskell.Liquid.Constraint.ToFixpoint
import           Language.Haskell.Liquid.Constraint.Types
import           Language.Haskell.Liquid.Model
import           Language.Haskell.Liquid.Transforms.Rec
import           Language.Haskell.Liquid.UX.Annotate (mkOutput)

type MbEnv = Maybe HscEnv

------------------------------------------------------------------------------
liquid :: [String] -> IO b
------------------------------------------------------------------------------
liquid args = getOpts args >>= runLiquid Nothing >>= exitWith . fst

------------------------------------------------------------------------------
-- | This fellow does the real work
------------------------------------------------------------------------------
runLiquid :: MbEnv -> Config -> IO (ExitCode, MbEnv)
------------------------------------------------------------------------------
runLiquid mE cfg = do
  z <- actOrDie $ second Just <$> getGhcInfo mE cfg (files cfg)
  case z of
    Left e -> do
      exitWithResult cfg (files cfg) $ mempty { o_result = e }
      return (resultExit e, mE)
    Right (gs, mE') -> do
      d <- checkMany cfg mempty gs
      return (ec d, mE')
  where
    ec = resultExit . o_result


------------------------------------------------------------------------------
checkMany :: Config -> Output Doc -> [GhcInfo] -> IO (Output Doc)
------------------------------------------------------------------------------
checkMany cfg d (g:gs) = do
  d' <- checkOne cfg g
  checkMany cfg (d `mappend` d') gs

checkMany _   d [] =
  return d

------------------------------------------------------------------------------
checkOne :: Config -> GhcInfo -> IO (Output Doc)
------------------------------------------------------------------------------
checkOne cfg g = do
  z <- actOrDie $ liquidOne g
  case z of
    Left e -> do
      d <- exitWithResult cfg [target g] $ mempty { o_result = e }
      return d
    Right r ->
      return r


actOrDie :: IO a -> IO (Either ErrorResult a)
actOrDie act =
    (Right <$> act)
      `Ex.catch` (\(e :: SourceError) -> handle e)
      `Ex.catch` (\(e :: Error)       -> handle e)
      `Ex.catch` (\(e :: UserError)   -> handle e)
      `Ex.catch` (\(e :: [Error])     -> handle e)

handle :: (Result a) => a -> IO (Either ErrorResult b)
handle = return . Left . result

------------------------------------------------------------------------------
liquidOne :: GhcInfo -> IO (Output Doc)
------------------------------------------------------------------------------
liquidOne info = do
  whenNormal $ donePhase Loud "Extracted Core using GHC"
  let cfg   = config info
  let tgt   = target info
  whenLoud  $ do putStrLn "**** Config **************************************************"
                 print cfg
  whenLoud  $ do putStrLn $ showpp info
                 putStrLn "*************** Original CoreBinds ***************************"
                 putStrLn $ render $ pprintCBs (cbs info)
  let cbs' = transformScope (cbs info)
  whenLoud  $ do donePhase Loud "transformRecExpr"
                 putStrLn "*************** Transform Rec Expr CoreBinds *****************"
                 putStrLn $ render $ pprintCBs cbs'
                 putStrLn "*************** Slicing Out Unchanged CoreBinds *****************"
  dc       <- prune cfg cbs' tgt info
  let cbs'' = maybe cbs' DC.newBinds dc
  let info' = maybe info (\z -> info {spec = DC.newSpec z}) dc
  let cgi   = {-# SCC "generateConstraints" #-} generateConstraints $! info' {cbs = cbs''}
  -- cgi `deepseq` whenLoud (donePhase Loud "generateConstraints")
  whenLoud  $ dumpCs cgi
  out      <- solveCs cfg tgt cgi info' dc
  whenNormal $ donePhase Loud "solve"
  let out'  = mconcat [maybe mempty DC.oldOutput dc, out]
  DC.saveResult tgt out'
  exitWithResult cfg [tgt] out'

dumpCs :: CGInfo -> IO ()
dumpCs cgi = do
  putStrLn "***************************** SubCs *******************************"
  putStrLn $ render $ pprintMany (hsCs cgi)
  putStrLn "***************************** FixCs *******************************"
  putStrLn $ render $ pprintMany (fixCs cgi)
  putStrLn "***************************** WfCs ********************************"
  putStrLn $ render $ pprintMany (hsWfs cgi)

pprintMany :: (PPrint a) => [a] -> Doc
pprintMany xs = vcat [ F.pprint x $+$ text " " | x <- xs ]

prune :: Config -> [CoreBind] -> FilePath -> GhcInfo -> IO (Maybe DC.DiffCheck)
prune cfg cbinds tgt info
  | not (null vs) = return . Just $ DC.DC (DC.thin cbinds vs) mempty sp
  | diffcheck cfg = DC.slice tgt cbinds sp
  | otherwise     = return Nothing
  where
    vs            = tgtVars sp
    sp            = spec info


solveCs :: Config -> FilePath -> CGInfo -> GhcInfo -> Maybe DC.DiffCheck -> IO (Output Doc)
solveCs cfg tgt cgi info dc
  = do finfo          <- cgInfoFInfo info cgi tgt
       F.Result r sol <- solve fx finfo
       let names = map show . DC.checkedVars <$> dc
       let warns = logErrors cgi
       let annm  = annotMap cgi
-- ORIG let res   = ferr sol r
-- ORIG let out0  = mkOutput cfg res sol annm
       let res_err = fmap (applySolution sol . cinfoError . snd) r
       res_model  <- fmap (fmap pprint . tidyError sol)
                      <$> getModels info cfg res_err
       let out0  = mkOutput cfg res_model sol annm
       return    $ out0 { o_vars    = names             }
                        { o_errors  = e2u sol <$> warns }
                        { o_result  = res_model         }
    where
       fx        = def { FC.solver      = fromJust (smtsolver cfg)
                       , FC.linear      = linear      cfg
                       , FC.newcheck    = newcheck    cfg
                       -- , FC.extSolver   = extSolver   cfg
                       , FC.eliminate   = eliminate   cfg
                       , FC.save        = saveQuery cfg
                       , FC.srcFile     = tgt
                       , FC.cores       = cores       cfg
                       , FC.minPartSize = minPartSize cfg
                       , FC.maxPartSize = maxPartSize cfg
                       , FC.elimStats   = elimStats   cfg
                       -- , FC.stats   = True
                       }
-- ORIG ferr s    = fmap (cinfoUserError s . snd)

-- ORIG cinfoUserError   :: F.FixSolution -> Cinfo -> UserError
-- ORIG cinfoUserError s =  e2u s . cinfoError -- . snd

e2u :: F.FixSolution -> Error -> UserError
e2u s = fmap F.pprint . tidyError s

-- writeCGI tgt cgi = {-# SCC "ConsWrite" #-} writeFile (extFileName Cgi tgt) str
--   where
--     str          = {-# SCC "PPcgi" #-} showpp cgi
