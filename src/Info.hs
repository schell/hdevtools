module Info
    ( getIdentifierInfo
    , getType
    ) where

import Control.Monad (liftM)
import Data.Generics (GenericQ, mkQ)
import Data.List (find, sortBy, intersperse)
import Data.Maybe (catMaybes, fromMaybe)
import Data.Typeable (Typeable)
import GHC.SYB.Utils (everythingStaged, Stage(TypeChecker))
import MonadUtils (liftIO)
import qualified CoreUtils
import qualified Desugar
import qualified GHC
import qualified HscTypes
import qualified NameSet
import qualified Outputable
import qualified PprTyThing
import qualified Pretty
import qualified TcHsSyn
import qualified TcRnTypes

getIdentifierInfo :: FilePath -> String -> GHC.Ghc (Either String String)
getIdentifierInfo file identifier =
    withModSummary file $ \m -> do
        GHC.setContext [GHC.IIModule (GHC.ms_mod m)]
        GHC.handleSourceError (return . Left . show) $
            liftM Right (infoThing identifier)

getType :: FilePath -> (Int, Int) -> GHC.Ghc (Either String [((Int, Int, Int, Int), String)])
getType file (line, col) =
    withModSummary file $ \m -> do
        p <- GHC.parseModule m
        typechecked <- GHC.typecheckModule p
        types <- processTypeCheckedModule typechecked (line, col)
        return (Right types)

withModSummary :: String -> (HscTypes.ModSummary -> GHC.Ghc (Either String a)) -> GHC.Ghc (Either String a)
withModSummary file action = do
    let noPhase = Nothing
    target <- GHC.guessTarget file noPhase
    GHC.setTargets [target]

    let handler err = GHC.printException err >> return GHC.Failed
    flag <- GHC.handleSourceError handler (GHC.load GHC.LoadAllTargets)
    case flag of
        GHC.Failed -> return (Left "Error loading targets")
        GHC.Succeeded -> do
            modSummary <- getModuleSummary file
            case modSummary of
                Nothing -> return (Left "Module not found in module graph")
                Just m -> action m

getModuleSummary :: FilePath -> GHC.Ghc (Maybe GHC.ModSummary)
getModuleSummary file = do
    moduleGraph <- GHC.getModuleGraph
    case find (moduleSummaryMatchesFilePath file) moduleGraph of
        Nothing -> return Nothing
        Just moduleSummary -> return (Just moduleSummary)

moduleSummaryMatchesFilePath :: FilePath -> GHC.ModSummary -> Bool
moduleSummaryMatchesFilePath file moduleSummary =
    let location = GHC.ms_location moduleSummary
        location_file = GHC.ml_hs_file location
    in case location_file of
        Just f -> f == file
        Nothing -> False

------------------------------------------------------------------------------
-- Most of the following code was taken from the source code of 'ghc-mod' (with
-- some stylistic changes)
--
-- ghc-mod:
--     http://www.mew.org/~kazu/proj/ghc-mod/
--     https://github.com/kazu-yamamoto/ghc-mod/

processTypeCheckedModule :: GHC.TypecheckedModule -> (Int, Int) -> GHC.Ghc [((Int, Int, Int, Int), String)]
processTypeCheckedModule tcm (line, col) = do
    let tcs = GHC.tm_typechecked_source tcm
        bs = listifySpans tcs (line, col) :: [GHC.LHsBind GHC.Id]
        es = listifySpans tcs (line, col) :: [GHC.LHsExpr GHC.Id]
        ps = listifySpans tcs (line, col) :: [GHC.LPat GHC.Id]
    bts <- mapM (getTypeLHsBind tcm) bs
    ets <- mapM (getTypeLHsExpr tcm) es
    pts <- mapM (getTypeLPat tcm) ps
    return $ map toTup $ sortBy cmp $ catMaybes $ concat [ets, bts, pts]
    where
    cmp (a, _) (b, _)
        | a `GHC.isSubspanOf` b = LT
        | b `GHC.isSubspanOf` a = GT
        | otherwise = EQ

toTup :: (GHC.SrcSpan, GHC.Type) -> ((Int, Int, Int, Int), String)
toTup (spn, typ) = (fourInts spn, pretty typ)

fourInts :: GHC.SrcSpan -> (Int, Int, Int, Int)
fourInts = fromMaybe (0, 0, 0, 0) . getSrcSpan

getSrcSpan :: GHC.SrcSpan -> Maybe (Int, Int, Int, Int)
getSrcSpan (GHC.RealSrcSpan spn) =
    Just (GHC.srcSpanStartLine spn
         , GHC.srcSpanStartCol spn
         , GHC.srcSpanEndLine spn
         , GHC.srcSpanEndCol spn)
getSrcSpan _ = Nothing

getTypeLHsBind :: GHC.TypecheckedModule -> GHC.LHsBind GHC.Id -> GHC.Ghc (Maybe (GHC.SrcSpan, GHC.Type))
getTypeLHsBind _ (GHC.L spn GHC.FunBind{GHC.fun_matches = GHC.MatchGroup _ typ}) = return $ Just (spn, typ)
getTypeLHsBind _ _ = return Nothing

getTypeLHsExpr :: GHC.TypecheckedModule -> GHC.LHsExpr GHC.Id -> GHC.Ghc (Maybe (GHC.SrcSpan, GHC.Type))
getTypeLHsExpr tcm e = do
    hs_env <- GHC.getSession
    (_, mbe) <- liftIO $ Desugar.deSugarExpr hs_env modu rn_env ty_env e
    return ()
    case mbe of
        Nothing -> return Nothing
        Just expr -> return $ Just (GHC.getLoc e, CoreUtils.exprType expr)
    where
    modu = GHC.ms_mod $ GHC.pm_mod_summary $ GHC.tm_parsed_module tcm
    rn_env = TcRnTypes.tcg_rdr_env $ fst $ GHC.tm_internals_ tcm
    ty_env = TcRnTypes.tcg_type_env $ fst $ GHC.tm_internals_ tcm

getTypeLPat :: GHC.TypecheckedModule -> GHC.LPat GHC.Id -> GHC.Ghc (Maybe (GHC.SrcSpan, GHC.Type))
getTypeLPat _ (GHC.L spn pat) = return $ Just (spn, TcHsSyn.hsPatType pat)

listifySpans :: Typeable a => GHC.TypecheckedSource -> (Int, Int) -> [GHC.Located a]
listifySpans tcs lc = listifyStaged TypeChecker p tcs
    where
    p (GHC.L spn _) = GHC.isGoodSrcSpan spn && spn `GHC.spans` lc

listifyStaged :: Typeable r => Stage -> (r -> Bool) -> GenericQ [r]
listifyStaged s p = everythingStaged s (++) [] ([] `mkQ` (\x -> [x | p x]))

pretty :: GHC.Type -> String
pretty =
    Pretty.showDocWith Pretty.OneLineMode
    . Outputable.withPprStyleDoc (Outputable.mkUserStyle Outputable.neverQualify Outputable.AllTheWay)
    . PprTyThing.pprTypeForUser False

------------------------------------------------------------------------------
-- The following code was taken from GHC's ghc/InteractiveUI.hs (with some
-- stylistic changes)

infoThing :: String -> GHC.Ghc String
infoThing str = do
    names <- GHC.parseName str
    mb_stuffs <- mapM GHC.getInfo names
    let filtered = filterOutChildren (\(t,_f,_i) -> t) (catMaybes mb_stuffs)
    unqual <- GHC.getPrintUnqual
    return $ Outputable.showSDocForUser unqual $
        Outputable.vcat (intersperse (Outputable.text "") $ map (pprInfo False) filtered)

  -- Filter out names whose parent is also there Good
  -- example is '[]', which is both a type and data
  -- constructor in the same type
filterOutChildren :: (a -> HscTypes.TyThing) -> [a] -> [a]
filterOutChildren get_thing xs
  = filter (not . has_parent) xs
  where
    all_names = NameSet.mkNameSet (map (GHC.getName . get_thing) xs)
    has_parent x = case HscTypes.tyThingParent_maybe (get_thing x) of
                     Just p  -> GHC.getName p `NameSet.elemNameSet` all_names
                     Nothing -> False

pprInfo :: PprTyThing.PrintExplicitForalls -> (HscTypes.TyThing, GHC.Fixity, [GHC.Instance]) -> Outputable.SDoc
pprInfo pefas (thing, fixity, insts) =
    PprTyThing.pprTyThingInContextLoc pefas thing
        Outputable.$$ show_fixity fixity
        Outputable.$$ Outputable.vcat (map GHC.pprInstance insts)
    where
    show_fixity fix
        | fix == GHC.defaultFixity = Outputable.empty
        | otherwise                = Outputable.ppr fix Outputable.<+> Outputable.ppr (GHC.getName thing)