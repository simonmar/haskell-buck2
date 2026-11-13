{-# LANGUAGE CPP #-}
-- GHC 9.14 deprecates replacing an environment's home package table, and
-- emptyHome has to do that to give an environment an empty table.
{-# OPTIONS_GHC -Wno-deprecations #-}
-- | Wrappers for the parts of the GHC API that differ between the GHC
-- versions that the worker can be built with (9.6 to 10.1). Keeping the CPP
-- in this module lets the rest of the worker do without it.
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
  , optionsPragmas
  , useUnitDbs
  , unitDbsRead
  , LocationFile (..)
  , setLocationFile
  , summariseSource
  , throwDriverErrors
  , pkgDbRefPath
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
import GHC.Unit.Env (UnitEnv (..))
import GHC.Unit.State (UnitDatabase (..))
import GHC.Unit.Types (UnitId)
import GHC.Driver.Errors.Types (DriverMessages, GhcMessage (..))
import GHC.Driver.Make (summariseFile)
import GHC.Driver.Env (hsc_home_unit)
import GHC.Driver.Session (PkgDbRef (..))
import GHC.Types.SourceError (throwErrors)
#if MIN_VERSION_ghc(10,0,0)
import GHC.Data.OsPath (unsafeDecodeUtf)
import GHC.Driver.Env (hsc_dflags)
#endif
import qualified Data.Map as M
#if MIN_VERSION_ghc(10,1,0)
import Data.IORef (newIORef)
#endif
#if MIN_VERSION_ghc(9,12,0)
import GHC.Data.OsPath (unsafeEncodeUtf)
#endif
#if MIN_VERSION_ghc(10,1,0)
import GHC.Unit.External.Database (lookupExternalUnitDatabases)
import GHC.Unit.External.Index (cacheExternalUnitDatabase, readExternalUnitDatabases)
#else
import GHC.Unit.Env (HomeUnitEnv (..), ue_currentUnit, ue_unit_dbs, ue_updateHomeUnitEnv)
#endif
import GHC.Types.Error (isEmptyMessages)
import GHC.Data.StringBuffer (StringBuffer)
import GHC.Parser.Header (getOptions)
#if MIN_VERSION_ghc(9,14,0)
import GHC.Types.Error (mkUnknownDiagnostic)
import GHC.Driver.Downsweep (downsweepThunk)
import GHC.Driver.Config.Parser (initParserOpts, supportedLanguagePragmas)
import GHC.Driver.Env (hscUpdateHPT, hsc_HPT, setModuleGraph)
import GHC.Unit.Home.PackageTable (addHomeModInfoToHpt, emptyHomePackageTable)
import Control.Monad (forM)
#if MIN_VERSION_ghc(10,0,0)
import GHC.Types.SourceError (initSourceErrorContext)
#endif
#else
import GHC.Driver.Env (hscUpdateHPT, hsc_mod_graph)
import GHC.Driver.Config.Parser (initParserOpts)
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

-- | Make a finder cache to hold the file hashes that all the sessions share
-- (see Note [Hashing the libraries] in Session). From GHC 9.12, it looks up
-- each hash under a lock, so that when two compiles need the same hash at
-- the same time, only one of them computes it. Before GHC 9.12, the finder
-- cache's `lookupFileCache` can't be replaced, so there is no lock.
sharedFileHashes :: IO FinderCache
sharedFileHashes = do
  fc <- initFinderCache
#if MIN_VERSION_ghc(9,12,0)
  lock <- newMVar ()
  pure fc{lookupFileCache = \f -> withMVar lock (\_ -> lookupFileCache fc f)}
#else
  pure fc
#endif

-- | Make a session's finder cache (the second argument) use the shared file
-- hashes of the first, which 'sharedFileHashes' made, instead of its own.
withFileHashes :: FinderCache -> FinderCache -> FinderCache
#if MIN_VERSION_ghc(9,12,0)
withFileHashes shared fc = fc{lookupFileCache = lookupFileCache shared}
#else
withFileHashes shared fc = fc{fcFileCache = fcFileCache shared}
#endif

-- | Give the environment an empty home package table of its own. Before
-- GHC 9.14 the table is an immutable value. From 9.14 it is mutable, so a
-- new table has to be created.
emptyHome :: HscEnv -> IO HscEnv
#if MIN_VERSION_ghc(9,14,0)
emptyHome hsc = (\hpt -> hscUpdateHPT (const hpt) hsc) <$> emptyHomePackageTable
#else
emptyHome = pure . hscUpdateHPT (const emptyHomePackageTable)
#endif

-- | Replace the environment's module graph.
withModuleGraph :: ModuleGraph -> HscEnv -> HscEnv
#if MIN_VERSION_ghc(9,14,0)
withModuleGraph = setModuleGraph
#else
withModuleGraph mg hsc = hsc{hsc_mod_graph = mg}
#endif

-- | Give the environment the module graph that `ghc -c` would have when it
-- compiles the given module in one-shot mode. From GHC 9.14, that is the
-- graph of the modules below the module, which GHC only builds if the
-- compile needs it. For example, a module with explicit level imports needs
-- it to find out at which levels it sees an instance. Before GHC 9.14,
-- `ghc -c` has no module graph, so the environment is left as it is.
withOneShotModuleGraph :: HscEnv -> ModSummary -> IO HscEnv
#if MIN_VERSION_ghc(9,14,0)
withOneShotModuleGraph hsc ms = (`setModuleGraph` hsc) <$> downsweepThunk hsc ms
#else
withOneShotModuleGraph hsc _ = pure hsc
#endif

-- | Add a module's entry to the environment's home package table. Before
-- GHC 9.14 this returns an environment with a new table. From 9.14 the table
-- is mutable, and this changes it in place.
insertHome :: HscEnv -> ModuleName -> HomeModInfo -> IO HscEnv
#if MIN_VERSION_ghc(9,14,0)
insertHome hsc _ hmi = addHomeModInfoToHpt hmi (hsc_HPT hsc) >> pure hsc
#else
insertHome hsc mn hmi = pure (hscUpdateHPT (\hpt -> addToHpt hpt mn hmi) hsc)
#endif

-- | Add home modules to the environment's home package table, making their
-- entries from their interfaces. The modules are either a single module, or
-- a group of modules that import one another through boot files. Each
-- module's entry is typechecked lazily, against the table with the whole
-- group in it, so that the modules can refer to one another. GHC's --make
-- does the same for a cycle of modules once it has compiled them (see
-- typecheckLoop in GHC). It returns the new environment and the entries.
addHomes :: HscEnv -> [(ModIface, HomeModLinkable)] -> IO (HscEnv, [HomeModInfo])
#if MIN_VERSION_ghc(9,14,0)
-- The table is mutable, so when a module's entry is typechecked, which
-- happens lazily, it finds the entries of the whole group in the table.
addHomes hsc mods = do
  hmis <- forM mods $ \(iface, linkable) -> do
    details <- initModDetails hsc iface
    let hmi = HomeModInfo iface details linkable
    addHomeModInfoToHpt hmi (hsc_HPT hsc)
    pure hmi
  pure (hsc, hmis)
#else
addHomes hsc mods = do
  -- Each module's details are typechecked against the table that holds all
  -- the modules' entries, so the table and the details are made together
  -- with fixIO. That works because a table entry is strict in everything
  -- except its details, and nothing forces the details while the table is
  -- being made.
  (env, details) <- fixIO $ \ ~(_, details) -> do
    let env = hscUpdateHPT (\hpt -> addListToHpt hpt [(moduleName (mi_module iface), HomeModInfo iface (details !! k) linkable) | (k, (iface, linkable)) <- zip [0 ..] mods]) hsc
    (,) env <$> mapM (initModDetails env . fst) mods
  pure (env, [HomeModInfo iface d linkable | ((iface, linkable), d) <- zip mods details])
#endif

-- | Make the lock that a session's compiles take in turn, or return Nothing
-- if they need none. The compiles of a session run concurrently and share
-- the session's external interpreter, if the flags ask for one. Before GHC
-- 9.12, GHC sends the interpreter a message and then reads its reply
-- without taking a lock, so two compiles could read each other's replies.
-- One way this shows up is as a panic in mallocStrings. From GHC 9.12, GHC
-- locks the interpreter itself, so the compiles need no lock of their own.
#if MIN_VERSION_ghc(9,12,0)
interpreterLock :: DynFlags -> IO (Maybe a)
interpreterLock _ = pure Nothing
#else
interpreterLock :: DynFlags -> IO (Maybe (MVar ()))
interpreterLock dflags = if gopt Opt_ExternalInterpreter dflags then Just <$> newMVar () else pure Nothing
#endif

-- | Read the flags that the OPTIONS_GHC and LANGUAGE pragmas at the head of
-- a module's source give, parsing the source with the given flags. The file
-- name is only used in GHC's messages. (From GHC 9.14, the parser also needs
-- the list of supported extensions, and from GHC 10.0 the context in which
-- to report errors.)
optionsPragmas :: DynFlags -> StringBuffer -> FilePath -> [String]
#if MIN_VERSION_ghc(10,0,0)
optionsPragmas dflags buf file = map unLoc (snd (getOptions (initParserOpts dflags) (initSourceErrorContext dflags) (supportedLanguagePragmas dflags) buf file))
#elif MIN_VERSION_ghc(9,14,0)
optionsPragmas dflags buf file = map unLoc (snd (getOptions (initParserOpts dflags) (supportedLanguagePragmas dflags) buf file))
#else
optionsPragmas dflags buf file = map unLoc (snd (getOptions (initParserOpts dflags) buf file))
#endif

-- | Give a new session's unit environment the package databases that the
-- worker has read already. When the session's flags are set, GHC then uses
-- these instead of reading the databases from disk (see Note [One copy of
-- each package database] in Session).
useUnitDbs :: [UnitDatabase UnitId] -> UnitEnv -> IO UnitEnv

-- | The package databases at the given paths that GHC read when the
-- session's flags were set, if it read all of them.
unitDbsRead :: [FilePath] -> UnitEnv -> IO (Maybe [UnitDatabase UnitId])

#if MIN_VERSION_ghc(10,1,0)
-- From GHC 10.1, a unit environment has a cache of the databases that GHC
-- has read, keyed by path (ue_uic). GHC looks there before it reads a
-- database. Each session has a cache of its own, so the worker adds the
-- databases to the session's cache, and looks there for the ones GHC read.
-- If GHC also read the user's database, it is in the cache too, but the
-- worker doesn't keep it, because it isn't one of the paths.
useUnitDbs dbs ue = ue <$ mapM_ (cacheExternalUnitDatabase (ue_uic ue)) dbs
unitDbsRead paths ue = do
  cached <- readExternalUnitDatabases (ue_uic ue)
  pure (mapM (\p -> lookupExternalUnitDatabases (unsafeEncodeUtf p) cached) paths)
#else
-- Before GHC 10.1, the current unit's databases are kept in its home unit
-- environment, and GHC reads them only if there are none there yet. If GHC
-- also read the user's database, the databases it read don't match the
-- paths, and none of them are returned.
useUnitDbs dbs ue = pure (ue_updateHomeUnitEnv (\hue -> hue{homeUnitEnv_unit_dbs = Just dbs}) (ue_currentUnit ue) ue)
unitDbsRead paths ue = pure $ case ue_unit_dbs ue of
  Just dbs | map unitDatabasePath dbs == paths -> Just dbs
  _ -> Nothing
#endif

-- | The output files of a module's location.
data LocationFile = HiFile | DynHiFile | ObjFile | DynObjFile | HieFile

-- | Set one of the output files of a module's location. From GHC 9.12, the
-- location's fields are OsPaths. GHC 10.0 removed the pattern synonym that
-- let them be set as FilePaths.
setLocationFile :: LocationFile -> FilePath -> ModLocation -> ModLocation
#if MIN_VERSION_ghc(9,12,0)
setLocationFile file path loc = case file of
  HiFile -> loc{ml_hi_file_ospath = p}
  DynHiFile -> loc{ml_dyn_hi_file_ospath = p}
  ObjFile -> loc{ml_obj_file_ospath = p}
  DynObjFile -> loc{ml_dyn_obj_file_ospath = p}
  HieFile -> loc{ml_hie_file_ospath = p}
  where
    p = unsafeEncodeUtf path
#else
setLocationFile file path loc = case file of
  HiFile -> loc{ml_hi_file = path}
  DynHiFile -> loc{ml_dyn_hi_file = path}
  ObjFile -> loc{ml_obj_file = path}
  DynObjFile -> loc{ml_dyn_obj_file = path}
  HieFile -> loc{ml_hie_file = path}
#endif

-- | Summarise a module's source file, as GHC's dependency analysis does,
-- without any summaries from before. From GHC 10.1, summariseFile keeps its
-- cache of summaries in an IORef.
summariseSource :: HscEnv -> FilePath -> IO (Either DriverMessages ModSummary)
#if MIN_VERSION_ghc(10,1,0)
summariseSource hsc src = do
  cache <- newIORef M.empty
  summariseFile hsc (hsc_home_unit hsc) cache src Nothing Nothing
#else
summariseSource hsc src = summariseFile hsc (hsc_home_unit hsc) M.empty src Nothing Nothing
#endif

-- | Throw the driver's errors as a SourceError. From GHC 10.0, a
-- SourceError carries the context in which to report its messages.
throwDriverErrors :: HscEnv -> DriverMessages -> IO a
#if MIN_VERSION_ghc(10,0,0)
throwDriverErrors hsc = throwErrors (initSourceErrorContext (hsc_dflags hsc)) . fmap GhcDriverMessage
#else
throwDriverErrors _ = throwErrors . fmap GhcDriverMessage
#endif

-- | The path of the package database that a -package-db flag names, or
-- Nothing for the global and the user's databases. From GHC 10.0, the path
-- is an OsPath.
pkgDbRefPath :: PkgDbRef -> Maybe FilePath
#if MIN_VERSION_ghc(10,0,0)
pkgDbRefPath (PkgDbPath p) = Just (unsafeDecodeUtf p)
#else
pkgDbRefPath (PkgDbPath p) = Just p
#endif
pkgDbRefPath _ = Nothing
