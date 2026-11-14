{-# LANGUAGE CPP #-}
-- | The module graph of a target compiled per-module, from GHC's own
-- dependency analysis of its sources (see compile_per_module in
-- prelude/haskell/compile_per_module.bzl).
--
-- > per_module_deps [--libdir=DIR] OUT NODE=SOURCE... -- GHC_FLAGS...
--
-- Each NODE=SOURCE is one of the target's nodes, as the rules name it, and
-- its source: a module, or a boot file as "Mod-boot". The GHC flags are the
-- target's, without the compiler. This program runs the analysis itself,
-- with the GHC code that it is linked with, which is the same version as
-- the GHC that compiles the target. DIR is that GHC's libdir (see Libdir).
--
-- OUT is a JSON object with a member for each node. Each has:
--
-- - "imports": the target's nodes that it depends on: its imports, and a
--   module's own boot file, which GHC checks the module against;
-- - "external": the modules it imports from other units, as [unit id,
--   module];
-- - "th": whether it may run code at compile time: a splice, or an ANN
--   pragma, which GHC also evaluates with its interpreter.
module Main (main) where

import Control.Monad (forM, unless)
import Control.Monad.IO.Class (liftIO)
import Data.Char (isSpace, ord, toLower)
import Data.List (intercalate, isPrefixOf, isSuffixOf, nub, tails)
import qualified Data.Map as M
import Data.Maybe (mapMaybe)
import System.Environment (getArgs)
import System.Exit (ExitCode (..), exitWith)
import System.FilePath (normalise)
import System.IO (hPutStrLn, stderr)
import Text.Printf (printf)

import GHC
import GHC.Data.StringBuffer (StringBuffer (..), lexemeToString)
import GHC.Driver.Env (hsc_dflags, hsc_home_unit)
import GHC.Driver.Ppr (showSDoc)
import GHC.Driver.Session (defaultFatalMessager, defaultFlushOut, xopt)
import GHC.Iface.Errors (cannotFindModule)
import qualified GHC.LanguageExtensions as LangExt
import GHC.Unit.Finder (FindResult (..), findImportedModule)
import GHC.Unit.Home (homeUnitId)
import GHC.Unit.Module.ModSummary (isBootSummary, ms_imps)
import GHC.Unit.Types (unitString)
import GHC.Utils.Outputable (ppr)
#if MIN_VERSION_ghc(9,8,0)
import GHC.Driver.Config.Diagnostic (initIfaceMessageOpts)
import GHC.Iface.Errors.Ppr (missingInterfaceErrorDiagnostic)
#endif

import Imports (importLocated, importName, srcImportName)
import Libdir (takeLibdir)
import Request (withoutRts)

main :: IO ()
main = do
  (libdir, args) <- takeLibdir "per_module_deps" =<< getArgs
  case break (== "--") args of
    (out : nodes, _ : flags) | Just sources <- mapM node nodes -> writeFile out =<< analyse libdir sources (withoutRts flags)
    _ -> hPutStrLn stderr "usage: per_module_deps [--libdir=DIR] OUT NODE=SOURCE... -- GHC_FLAGS..." >> exitWith (ExitFailure 2)
  where
    node arg = case break (== '=') arg of
      (n, '=' : src) -> Just (n, src)
      _ -> Nothing

analyse :: FilePath -> [(String, FilePath)] -> [String] -> IO String
analyse libdir sources flags = defaultErrorHandler defaultFatalMessager defaultFlushOut $ runGhc (Just libdir) $
  handleSourceError (\e -> printException e >> liftIO (exitWith (ExitFailure 1))) $ do
    dflags0 <- getSessionDynFlags
    logger <- getLogger
    (dflags, leftover, _) <- parseDynamicFlags logger dflags0 (map noLoc flags)
    unless (null leftover) . liftIO $ do
      hPutStrLn stderr ("per_module_deps: not GHC flags: " ++ unwords (map unLoc leftover))
      exitWith (ExitFailure 2)
    -- In GHC's mode for `ghc -M`, the finder takes a dependency's module to
    -- be in its package's only import directory without looking: in an
    -- early package db, the interface isn't there yet.
    _ <- setSessionDynFlags dflags{ghcMode = MkDepend}
    unit <- homeUnitId . hsc_home_unit <$> getSession
    -- The boot files aren't targets: GHC finds them next to their modules,
    -- from the {-# SOURCE #-} imports.
    setTargets =<< mapM (\(_, src) -> guessTarget src (Just unit) Nothing) [s | s@(_, src) <- sources, not ("-boot" `isSuffixOf` src)]
    summaries <- mgModSummaries <$> depanal [] False
    hsc <- getSession
    let byPath = M.fromList [(normalise src, n) | (n, src) <- sources]
    named <- liftIO . forM summaries $ \ms -> case ml_hs_file (ms_location ms) >>= \src -> M.lookup (normalise src) byPath of
      Just n -> pure (n, ms)
      Nothing -> do
        hPutStrLn stderr ("per_module_deps: GHC's dependency analysis found " ++ moduleNameString (ms_mod_name ms) ++ " in " ++ maybe "no file" id (ml_hs_file (ms_location ms)) ++ ", which isn't one of the target's sources")
        exitWith (ExitFailure 1)
    let isBoot ms = isBootSummary ms == IsBoot
        -- The node of each home module, and of its boot file.
        nodeOf = M.fromList [(ms_mod_name ms, n) | (n, ms) <- named, not (isBoot ms)]
        bootOf = M.fromList [(ms_mod_name ms, n) | (n, ms) <- named, isBoot ms]
        -- An import that names another package (PackageImports) isn't of a
        -- home module, even if a home module has the same name.
        home mn pkg = case pkg of
          OtherPkg _ -> Nothing
          _ -> M.lookup mn nodeOf
    nodes <- liftIO . forM named $ \(n, ms) -> do
      -- With the imports of the module's plugins.
      let imports = ms_imps ms
          opts = ms_hspp_opts ms
          own = [b | not (isBoot ms), Just b <- [M.lookup (ms_mod_name ms) bootOf]]
      external <- forM [i | i <- imports, let (mn, pkg) = importName i, home mn pkg == Nothing] $ \i -> do
        let (mn, pkg) = importName i
        found <- findImportedModule hsc mn pkg
        case found of
          Found _ m -> pure (unitString (moduleUnit m), moduleNameString (moduleName m))
          _ -> notFound hsc (importLocated i) found
      text <- maybe (readFile (ms_hspp_file ms)) (\b -> pure (lexemeToString b (len b))) (ms_hspp_buf ms)
      let th = not (isBoot ms) && (xopt LangExt.TemplateHaskell opts || xopt LangExt.QuasiQuotes opts || hasAnn text)
      pure
        ( n
        , nub (mapMaybe (uncurry home . importName) imports ++ mapMaybe (\i -> M.lookup (srcImportName i) bootOf) (ms_srcimps ms) ++ own)
        , external
        , th
        )
    pure (render nodes)

-- | Fail as GHC does when it can't find an imported module, at the import.
notFound :: HscEnv -> Located ModuleName -> FindResult -> IO a
notFound hsc (L loc mn) found = do
  let dflags = hsc_dflags hsc
#if MIN_VERSION_ghc(9,8,0)
      doc = missingInterfaceErrorDiagnostic (initIfaceMessageOpts dflags) (cannotFindModule hsc mn found)
#else
      doc = cannotFindModule hsc mn found
#endif
  hPutStrLn stderr (showSDoc dflags (ppr loc) ++ ": error:\n" ++ unlines (map ("    " ++) (lines (showSDoc dflags doc))))
  exitWith (ExitFailure 1)

-- | Whether the (preprocessed) source has an ANN pragma, whose name, like
-- any pragma's, may be in any case.
hasAnn :: String -> Bool
hasAnn text = or [isAnn (dropWhile isSpace (drop 3 t)) | t <- tails text, "{-#" `isPrefixOf` t]
  where
    isAnn s = map toLower (take 3 s) == "ann" && all isSpace (take 1 (drop 3 s))

render :: [(String, [String], [(String, String)], Bool)] -> String
render nodes = "{" ++ intercalate ",\n" (map node nodes) ++ "}\n"
  where
    node (n, imports, external, th) =
      str n ++ ": {"
        ++ intercalate ", "
          ["\"imports\": " ++ list (map str imports), "\"external\": " ++ list [list [str u, str m] | (u, m) <- external], "\"th\": " ++ if th then "true" else "false"]
        ++ "}"
    list xs = "[" ++ intercalate ", " xs ++ "]"
    str s = "\"" ++ concatMap char s ++ "\""
    char c
      | c == '"' || c == '\\' = ['\\', c]
      | ord c < 0x20 = printf "\\u%04x" (ord c)
      | otherwise = [c]
