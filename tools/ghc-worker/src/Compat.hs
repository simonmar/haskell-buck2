{-# LANGUAGE CPP #-}
-- GHC 9.14 deprecates replacing the home package table, which emptyHome
-- does with an empty one.
{-# OPTIONS_GHC -Wno-deprecations #-}
-- | What differs between the GHC versions the worker builds with (9.6 to
-- 9.14), so that the rest of it needs no CPP.
module Compat
  ( analyseTargets
  , sharedFileHashes
  , withFileHashes
  , emptyHome
  , withModuleGraph
  , withOneShotModuleGraph
  , insertHome
  , addHomes
  , interpreterLock
  ) where

#if MIN_VERSION_ghc(9,12,0)
import Control.Concurrent.MVar (newMVar, withMVar)
#else
import Control.Concurrent.MVar (MVar, newMVar)
#endif

import GHC
import GHC.Unit.Finder (initFinderCache)
import GHC.Unit.Finder.Types (FinderCache (..))
import GHC.Driver.Main (initModDetails)
import GHC.Unit.Home.ModInfo (HomeModInfo (..), HomeModLinkable)
import GHC.Types.Error (isEmptyMessages)
#if MIN_VERSION_ghc(9,14,0)
import GHC.Types.Error (mkUnknownDiagnostic)
import GHC.Driver.Downsweep (downsweepThunk)
import GHC.Driver.Env (hscUpdateHPT, hsc_HPT, setModuleGraph)
import GHC.Unit.Home.PackageTable (addHomeModInfoToHpt, emptyHomePackageTable)
import Control.Monad (forM)
#else
import GHC.Driver.Env (hscUpdateHPT, hsc_mod_graph)
import GHC.Unit.Home.ModInfo (addListToHpt, addToHpt, emptyHomePackageTable)
import System.IO (fixIO)
#endif

-- | Run GHC's dependency analysis of the session's targets, and return
-- whether it found no errors. If it found any, GHC leaves the session's
-- module graph empty.
analyseTargets :: Ghc Bool
#if MIN_VERSION_ghc(9,14,0)
analyseTargets = isEmptyMessages . fst <$> depanalE mkUnknownDiagnostic Nothing [] True
#else
analyseTargets = isEmptyMessages . fst <$> depanalE [] True
#endif

-- | A finder cache whose file hashes the sessions share. From GHC 9.12 it
-- looks each hash up under a lock. Before that, the finder cache's
-- `lookupFileCache` can't be replaced. See Note [Hashing the libraries] in
-- Session.
sharedFileHashes :: IO FinderCache
sharedFileHashes = do
  fc <- initFinderCache
#if MIN_VERSION_ghc(9,12,0)
  lock <- newMVar ()
  pure fc{lookupFileCache = \f -> withMVar lock (\_ -> lookupFileCache fc f)}
#else
  pure fc
#endif

-- | A session's finder cache with the shared file hashes (see
-- sharedFileHashes).
withFileHashes :: FinderCache -> FinderCache -> FinderCache
#if MIN_VERSION_ghc(9,12,0)
withFileHashes shared fc = fc{lookupFileCache = lookupFileCache shared}
#else
withFileHashes shared fc = fc{fcFileCache = fcFileCache shared}
#endif

-- | The environment with an empty home package table of its own: a value
-- before GHC 9.14, a mutable table since.
emptyHome :: HscEnv -> IO HscEnv
#if MIN_VERSION_ghc(9,14,0)
emptyHome hsc = (\hpt -> hscUpdateHPT (const hpt) hsc) <$> emptyHomePackageTable
#else
emptyHome = pure . hscUpdateHPT (const emptyHomePackageTable)
#endif

-- | The environment with the given module graph.
withModuleGraph :: ModuleGraph -> HscEnv -> HscEnv
#if MIN_VERSION_ghc(9,14,0)
withModuleGraph = setModuleGraph
#else
withModuleGraph mg hsc = hsc{hsc_mod_graph = mg}
#endif

-- | The environment for a one-shot compile of the module, with the module
-- graph that `ghc -c` would give it. From GHC 9.14 that is the graph below
-- the module, made only if the compile needs it (to find at which levels a
-- module with explicit level imports sees an instance, say). Before 9.14
-- there is none.
withOneShotModuleGraph :: HscEnv -> ModSummary -> IO HscEnv
#if MIN_VERSION_ghc(9,14,0)
withOneShotModuleGraph hsc ms = (`setModuleGraph` hsc) <$> downsweepThunk hsc ms
#else
withOneShotModuleGraph hsc _ = pure hsc
#endif

-- | Add an entry to the environment's home package table.
insertHome :: HscEnv -> ModuleName -> HomeModInfo -> IO HscEnv
#if MIN_VERSION_ghc(9,14,0)
insertHome hsc _ hmi = addHomeModInfoToHpt hmi (hsc_HPT hsc) >> pure hsc
#else
insertHome hsc mn hmi = pure (hscUpdateHPT (\hpt -> addToHpt hpt mn hmi) hsc)
#endif

-- | Add home modules, read from their interfaces, to the environment's home
-- package table. They are either one module, or modules that import one
-- another through boot files. Each is typechecked lazily against the table
-- with all of them in it, as GHC's --make does for a cycle of modules once
-- it is compiled (typecheckLoop).
addHomes :: HscEnv -> [(ModIface, HomeModLinkable)] -> IO (HscEnv, [HomeModInfo])
#if MIN_VERSION_ghc(9,14,0)
-- The table is mutable, so a module's typechecking finds the others there
-- when it is forced.
addHomes hsc mods = do
  hmis <- forM mods $ \(iface, linkable) -> do
    details <- initModDetails hsc iface
    let hmi = HomeModInfo iface details linkable
    addHomeModInfoToHpt hmi (hsc_HPT hsc)
    pure hmi
  pure (hsc, hmis)
#else
addHomes hsc mods = do
  -- The table's entries are strict but for their details, which nothing
  -- forces while they are made.
  (env, details) <- fixIO $ \ ~(_, details) -> do
    let env = hscUpdateHPT (\hpt -> addListToHpt hpt [(moduleName (mi_module iface), HomeModInfo iface (details !! k) linkable) | (k, (iface, linkable)) <- zip [0 ..] mods]) hsc
    (,) env <$> mapM (initModDetails env . fst) mods
  pure (env, [HomeModInfo iface d linkable | ((iface, linkable), d) <- zip mods details])
#endif

-- | A lock for the concurrent compiles of a session whose splices run in an
-- external interpreter, which they share. Before GHC 9.12, GHC sends the
-- interpreter a message and reads its reply without a lock, so two compiles
-- could read each other's replies (a panic in mallocStrings, say). GHC 9.12
-- locks the interpreter itself.
#if MIN_VERSION_ghc(9,12,0)
interpreterLock :: DynFlags -> IO (Maybe a)
interpreterLock _ = pure Nothing
#else
interpreterLock :: DynFlags -> IO (Maybe (MVar ()))
interpreterLock dflags = if gopt Opt_ExternalInterpreter dflags then Just <$> newMVar () else pure Nothing
#endif
