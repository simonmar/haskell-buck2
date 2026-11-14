{-# LANGUAGE ScopedTypeVariables #-}
-- | A GHC session for one set of session flags, in which requests compile
-- their modules concurrently. Each compile uses compileOne, the function
-- that `ghc --make -j` runs for each module. See Note [The session's state].
module Session (GhcSession, gsModules, gsOutDir, gsOneShot, SessionMode (..), Shared, newShared, newSession, endSession, compile, Node, Diagnostic (..), tryNonAsync) where

import Control.Exception (SomeAsyncException, SomeException, finally, fromException, onException, throwIO, try)
import Control.Monad (foldM, forM, unless, when)
import Control.Concurrent.MVar
import Data.Graph (SCC, flattenSCC, stronglyConnComp)
import Data.IORef
import Control.Applicative ((<|>))
import Data.Char (isDigit)
import Data.List (isPrefixOf, isSuffixOf, stripPrefix)
import qualified Data.Map as M
import Data.Maybe (fromMaybe, isJust)
import qualified Data.Set as Set
import Data.Unique (hashUnique, newUnique)
import System.Directory (createDirectory, createDirectoryIfMissing, doesDirectoryExist, doesFileExist, getTemporaryDirectory, listDirectory, removePathForcibly)
import System.Posix.Process (getProcessID)
import System.Environment (getEnvironment, lookupEnv)
import System.FilePath (dropTrailingPathSeparator, joinPath, splitDirectories, takeDirectory, (<.>), (</>))
import System.IO (hPutStrLn, stderr)
import qualified System.Process as P

import GHC
import GHC.Data.StringBuffer (hGetStringBuffer)
import GHC.Driver.Env (hscSetFlags, hsc_FC, hsc_NC, hsc_dflags, hsc_home_unit, hsc_hooks, hsc_interp, hsc_logger, hsc_mod_graph, hsc_tmpfs, hsc_type_env_vars, hsc_unit_env)
import GHC.Driver.Hooks (Hooks (..))
import GHC.Driver.Env.KnotVars (knotVarsFromModuleEnv)
import GHC.Types.TypeEnv (emptyTypeEnv)
import GHC.Unit.Module.Env (mkModuleEnv)
import GHC.Driver.Errors.Types (GhcMessage (..))
import GHC.Driver.Make (summariseFile)
import GHC.Driver.Monad (Ghc (..), Session (..))
import GHC.Driver.Pipeline (compileOne)
import qualified GHC.Data.EnumSet as EnumSet
import GHC.Driver.Session (PackageDBFlag (..), PkgDbRef (..), fFlags, flagSpecName, globalPackageDatabasePath, hasNoDebugOutput, hasPprDebug, setUnsafeGlobalDynFlags, targetProfile, ways)
import GHC.Platform.Ways (Way (..))
import GHC.Iface.Binary (CheckHiWay (..), TraceBinIFace (..), readBinIface)
import GHC.Runtime.Interpreter (stopInterp)
import GHC.Types.Error (MessageClass (..))
import GHC.Types.SourceError (throwErrors)
import GHC.Types.SourceFile (HscSource (..))
import GHC.Unit.Finder (FindResult (..), findImportedModule, findObjectLinkableMaybe, initFinderCache)
import GHC.Types.Name.Cache (NameCache)
import GHC.Unit.Finder.Types (FinderCache)
import GHC.Unit.Home (HomeUnit, homeUnitId, isHomeModule)
import GHC.Unit.Module.ModSummary (isBootSummary, msHsFilePath)
import GHC.Unit.Home.ModInfo (HomeModInfo (..), HomeModLinkable, emptyHomeModInfoLinkable, justObjects)
import GHC.Unit.Module.Deps (dep_boot_mods, dep_direct_mods)
import GHC.Unit.Module.Location (addBootSuffixLocn, addBootSuffixLocnOut)
import GHC.Unit.Env (HomeUnitEnv (..), UnitEnv (..), ue_currentUnit, ue_findHomeUnitEnv, ue_unit_dbs, ue_updateHomeUnitEnv)
import GHC.Unit.External (ExternalUnitCache, initExternalUnitCache)
import GHC.Unit.State (UnitDatabase (..), UnitState)
import GHC.Unit.Types (GenWithIsBoot (..), UnitId)
import GHC.Utils.Logger (LogFlags (..))
import GHC.Utils.Outputable (renderWithContext)
import GHC.Utils.Panic (throwGhcExceptionIO)
import GHC.Utils.TmpFs (cleanCurrentModuleTempFiles, cleanTempDirs, cleanTempFiles, forkTmpFsFrom, mergeTmpFsInto)

import Compat
import DepFile (writeDepFiles)
import Imports (importName, srcImportName)
import Interface (directDep)
import Request

-- | A GHC session, and what the worker keeps with it.
data GhcSession = GhcSession
  { gsEnv :: HscEnv -- the session's GHC environment, which each compile gives a home package table of its own
  , gsHomes :: MVar Homes -- what a --make session keeps of its home modules, locked while a compile's home package table is made
  , gsTmpDir :: FilePath -- the session's own temporary directory (see Note [A temporary directory per session])
  , gsModules :: Maybe (Set.Set Node) -- the modules and boot interfaces of the session's target, or Nothing if GHC's analysis of the target failed
  , gsOutDir :: FilePath -- the output directory of the target's modules, for the way the session builds them, which identifies the target in Worker
  , gsOneShot :: Bool -- whether the session compiles in one-shot mode (see Note [One-shot sessions])
  , gsExternal :: MVar (M.Map [String] ExternalUnitCache) -- the external package states that the compiles read interfaces into, keyed by 'interfaceKey'; all the one-shot sessions share one map
  , gsInterpLock :: Maybe (MVar ()) -- the lock that each of the session's compiles holds while it runs, or Nothing if the session's interpreter needs no lock (see 'interpreterLock')
  }

-- | Which mode the sessions compile in (see Note [One-shot sessions]).
data SessionMode
  = AutoSessions -- one-shot for a target without boot files, and --make for a target with them
  | MakeSessions -- --make for every target
  | OneShotSessions -- one-shot for every target, refusing one with boot files

-- | What the sessions share, for the whole life of the worker.
data Shared = Shared
  { shDbs :: MVar (M.Map FilePath (UnitDatabase UnitId)) -- the package databases read so far, keyed by path (see Note [One copy of each package database])
  , shExternal :: MVar (M.Map [String] ExternalUnitCache) -- the external package states of the one-shot sessions, keyed by 'interfaceKey'
  , shUnits :: MVar (M.Map [String] (UnitState, Maybe HomeUnit)) -- the unit state of the one-shot sessions, keyed by session flags (see Note [One-shot sessions])
  }

newShared :: IO Shared
newShared = Shared <$> newMVar M.empty <*> newMVar M.empty <*> newMVar M.empty

-- | A diagnostic that a compile reported: whether it is an error, and its
-- rendered text.
data Diagnostic = Diagnostic {diagIsError :: Bool, diagText :: String}

-- | Make a session for the request's session flags, in the given mode. It
-- runs GHC's dependency analysis over the target's sources, to find the
-- target's modules (see Note [The session's state]). The session shares
-- with the others the file hashes in the given finder cache (see Note
-- [Hashing the libraries]), the given name cache (see Note [One name cache
-- for all the sessions]), and everything in 'Shared'. Anything that GHC
-- logs outside a compile, which is rare, goes to the worker's stderr.
newSession :: FilePath -> FinderCache -> NameCache -> Shared -> SessionMode -> Request -> IO GhcSession
newSession libdir files names shared mode r = do
  ref <- newIORef (error "buck2-ghc-worker: the session isn't made yet")
  let session = Session ref
  unGhc (initGhcMonad (Just libdir)) session
  modifyIORef' ref (\hsc -> hsc{hsc_NC = names})
  dflags0 <- unGhc getSessionDynFlags session
  unGhc (modifyLogger (pushLogHook (\_ lf _ _ doc -> hPutStrLn stderr (renderWithContext (log_default_user_context lf) doc)))) session
  logger <- hsc_logger <$> readIORef ref
  tmp <- newTmpDir
  -- If the session can't be made, remove its temporary directory.
  (`onException` removePathForcibly tmp) $ do
    (dflags, leftover, _) <- parseDynamicFlags logger dflags0 (map noLoc (sessionFlags r ++ ["-tmpdir", tmp]))
    -- Refuse arguments that aren't flags GHC knows, as `ghc` itself would.
    unless (null leftover) $
      throwGhcExceptionIO (CmdLineError ("unrecognised flags: " ++ unwords (map unLoc leftover)))
    -- See Note [Flags of the whole process].
    let wholeProcess =
          ["-fno-state-hack" | gopt Opt_G_NoStateHack dflags]
            ++ ["-dppr-debug" | hasPprDebug dflags]
            ++ ["-dno-debug-output" | hasNoDebugOutput dflags]
            ++ ["-dinitial-unique" | initialUnique dflags /= 0]
            ++ ["-dunique-increment" | uniqueIncrement dflags /= 1]
            ++ ["-H" | isJust (ghcHeapSize dflags)]
            ++ ["-Rghc-timing" | enableTimeStats dflags]
    unless (null wholeProcess) $ do
      setUnsafeGlobalDynFlags dflags0
      throwGhcExceptionIO (CmdLineError (unwords wholeProcess ++ ": these set GHC's state for the whole worker process, not one session's; compile this target without the worker"))
    -- The hook must be set before the session's flags are. Setting the
    -- flags makes the session's interpreter, which keeps the hook that is
    -- in place at that moment.
    unless (null (reqDataDirs r)) $
      modifyIORef' ref (\hsc -> hsc{hsc_hooks = (hsc_hooks hsc){createIservProcessHook = Just (startInterpreter r)}})
    setFlags shared session dflags
    found <- concat <$> mapM sources (reqSrcRoots r)
    -- Only the modules' sources are given to GHC as targets, not the boot
    -- files. GHC finds the boot files itself, from the {-# SOURCE #-}
    -- imports. Before GHC 9.12, giving a boot file as a target leaves the
    -- module graph without the boot interfaces, and a compile needs them
    -- in the graph to find the instances of the boot interfaces it imports.
    let srcs = filter (\f -> any (`isSuffixOf` f) [".hs", ".lhs"]) found
    oneShot <- isOneShot mode (any (\f -> any (`isSuffixOf` f) [".hs-boot", ".lhs-boot"]) found)
    -- Make the target's module graph with GHC's own dependency analysis of
    -- the source tree. If the analysis fails, the graph is left empty, and
    -- the compiles of the modules at fault report the errors.
    analysed <- unGhc (do
      hsc <- getSession
      targets <- mapM (\f -> guessTarget f (Just (homeUnitId (hsc_home_unit hsc))) Nothing) srcs
      setTargets targets
      analyseTargets) session
    -- The analysis looked up the modules imported from dependencies, and
    -- most of their interfaces don't exist yet, since the interfaces in a
    -- dependency's early package db are written one by one as its modules
    -- compile. GHC's finder caches failed lookups as well as successful
    -- ones, so the compiles start with an empty finder cache, sharing only
    -- the file hashes.
    fc <- initFinderCache
    hsc0 <- readIORef ref
    let modules = Set.fromList [(ms_mod_name ms, isBootSummary ms) | ms <- mgModSummaries (hsc_mod_graph hsc0)]
    hsc <- if oneShot then oneShotEnv shared r hsc0 else pure hsc0
    external <- if oneShot then pure (shExternal shared) else newMVar M.empty
    GhcSession hsc{hsc_FC = withFileHashes files fc} <$> newMVar (Homes M.empty M.empty) <*> pure tmp <*> pure (if analysed then Just modules else Nothing) <*> pure (reqOutDir r) <*> pure oneShot <*> pure external <*> interpreterLock (hsc_dflags hsc)
  where
    sources dir = do
      entries <- listDirectory dir
      fmap concat . forM entries $ \e -> do
        let path = dir </> e
        isDir <- doesDirectoryExist path
        if isDir then sources path else pure [path]

-- | Start a session's external interpreter. The interpreter gets the
-- environment that GHC would give it, plus the variables that the request's
-- data dirs set, so that the session's splices can find the data files of
-- the libraries they run (see Note [Data files of splices] in
-- compile_per_module.bzl).
startInterpreter :: Request -> P.CreateProcess -> IO P.ProcessHandle
startInterpreter r cp = do
  env <- maybe getEnvironment pure (P.env cp)
  (_, _, _, p) <- P.createProcess cp{P.env = Just (withDataDirs r env)}
  pure p

-- | Decide whether a session compiles in one-shot mode, from the session
-- mode and whether the session's target has boot files. In mode
-- OneShotSessions, a target with boot files is an error.
isOneShot :: SessionMode -> Bool -> IO Bool
isOneShot mode boots = case mode of
  AutoSessions -> pure (not boots)
  MakeSessions -> pure False
  OneShotSessions
    | boots -> throwGhcExceptionIO (CmdLineError "this target has hs-boot files, which one-shot sessions can't compile: set the worker's session mode to auto or make")
    | otherwise -> pure True

-- | Set the session's flags. If every package database that the flags name
-- has been read already, the session is given the shared copies, so that
-- GHC doesn't read them again. Otherwise GHC reads them, and the worker
-- keeps the copies for later sessions. See Note [One copy of each package
-- database].
setFlags :: Shared -> Session -> DynFlags -> IO ()
setFlags shared session@(Session ref) dflags = do
  -- GHC only reads the package databases if the session has none yet, so
  -- giving it the shared copies first makes GHC use those.
  pathEnv <- lookupEnv "GHC_PACKAGE_PATH"
  let paths = dbPaths dflags
  known <- readMVar (shDbs shared)
  let cached = if isJust pathEnv then Nothing else mapM (`M.lookup` known) paths
  mapM_ (\c -> modifyIORef' ref (\hsc -> hsc{hsc_unit_env = withUnitDbs c (hsc_unit_env hsc)})) cached
  unGhc (setSessionDynFlags dflags >> pure ()) session
  unless (isJust cached || isJust pathEnv) $ do
    new <- fromMaybe [] . ue_unit_dbs . hsc_unit_env <$> readIORef ref
    -- If GHC also read the user's database, the databases it read don't
    -- match `paths`, and none of them are kept.
    when (map unitDatabasePath new == paths) $
      modifyMVar_ (shDbs shared) (\m -> pure (M.union m (M.fromList [(unitDatabasePath db, db) | db <- new])))

-- | Turn the session's environment into one for one-shot compiles (see Note
-- [One-shot sessions]). It uses the unit state of the first one-shot session
-- made with the same session flags, and has no module graph.
oneShotEnv :: Shared -> Request -> HscEnv -> IO HscEnv
oneShotEnv shared r hsc = do
  let dflags = hsc_dflags hsc
      ue = hsc_unit_env hsc
      unit = ue_currentUnit ue
      hue = ue_findHomeUnitEnv unit ue
  (units, home) <- sharedAt (shUnits shared) (sessionFlags r) (pure (homeUnitEnv_units hue, homeUnitEnv_home_unit hue))
  let ue' = ue_updateHomeUnitEnv (\h -> h{homeUnitEnv_units = units, homeUnitEnv_home_unit = home}) unit ue
  pure (withModuleGraph emptyMG (hscSetFlags dflags{ghcMode = OneShot} hsc{hsc_unit_env = ue'}))

-- | Look up the key in a shared map. If it isn't there, make its value with
-- the given action, and add it to the map.
sharedAt :: Ord k => MVar (M.Map k v) -> k -> IO v -> IO v
sharedAt var k make = modifyMVar var $ \m -> case M.lookup k m of
  Just v -> pure (m, v)
  Nothing -> make >>= \v -> pure (M.insert k v m, v)

-- | The key under which a compile reads interfaces into an external package
-- state. Only compiles with the same key share a state. Besides the modules
-- themselves, the interfaces that GHC reads depend on two things:
--
-- - The build configuration. Two configurations can build a module with the
--   same unit id but different interfaces.
-- - The compile's flags, which are its session's flags followed by those of
--   its module's pragmas (see Note [The flags an interface is read with]).
--   The key holds them as GHC has applied them, where it can: the set of
--   general flags (the -f flags) that are on, and the ways that change what
--   GHC reads (profiled or dynamic). Two compiles whose flags differ only in
--   order, or repeat a flag, then share a state. The flags whose effect
--   those don't record stay in the key as given.
--
-- buck2 puts each configuration's outputs under
-- buck-out/v2/art/<cell>/<configuration hash>, so that part of the output
-- directory identifies the configuration. If the output directory isn't in
-- that layout (in the worker's own tests, for example), the whole output
-- directory is used instead, so each target reads interfaces of its own.
interfaceKey :: Request -> DynFlags -> [String] -> [String]
interfaceKey r dflags pragmas =
  configuration
    : unwords ("general" : [show f | f <- EnumSet.toList (generalFlags dflags), f /= Opt_ExternalInterpreter])
    : unwords ("ways" : [show w | w <- Set.toList (ways dflags), w `elem` [WayProf, WayDyn]])
    : filter (not . recorded) (readingFlags (sessionFlags r ++ pragmas))
  where
    configuration = case break (== "art") (splitDirectories (reqOutDir r)) of
      (before, art : cell : hash : _) -> joinPath (before ++ [art, cell, hash])
      _ -> reqOutDir r
    -- Whether the flag's whole effect is among the general flags or the ways
    -- above. An -O flag sets the general flags of its level. GHC parses
    -- -fPIC apart from its other general flags, so fFlags doesn't name it.
    -- (-fexternal-interpreter is a general flag too, but readingFlags has
    -- left it out, and so does the key's set of general flags.)
    recorded f =
      f `elem` ["-dynamic", "-prof", "-debug", "-eventlog", "-fPIC", "-fno-PIC"]
        || (f == "-O" || ("-O" `isPrefixOf` f && all isDigit (drop 2 f)))
        || maybe False (`Set.member` generalNames) (stripPrefix "-fno-" f <|> stripPrefix "-f" f)
    generalNames = Set.fromList (map flagSpecName fFlags)

-- | Remove the flags that are known not to change how GHC reads an
-- interface. Every other flag is kept, so that compiles that differ in such
-- a flag read interfaces of their own.
readingFlags :: [String] -> [String]
readingFlags flags = case flags of
  f : _ : rest | f `elem` withArgument -> readingFlags rest
  f : rest | f `elem` alone || any (`isPrefixOf` f) prefixes -> readingFlags rest
  f : rest -> f : readingFlags rest
  [] -> []
  where
    -- Flags with an argument that say which unit is compiled, which
    -- packages it may import, where the outputs go, how to link, and what
    -- to tell Haddock.
    withArgument = ["-this-unit-id", "-package", "-package-id", "-package-db", "-odir", "-hidir", "-dumpdir", "-pgml", "-haddock-opts"]
    -- Flags that turn warnings off, choose the runtime system that a binary
    -- is linked with, or run splices in an external interpreter.
    alone = ["-w", "-threaded", "-fexternal-interpreter"]
    -- Flags with these prefixes say where sources and headers are, give
    -- options to the preprocessor, the C compiler and the linker, control
    -- warnings, language extensions and what GHC dumps, or set a binary's
    -- runtime options.
    prefixes = ["-i", "-I", "-D", "-U", "-optP", "-optc", "-optl", "-W", "-fwarn-", "-fno-warn-", "-X", "-ddump-", "-dsuppress-", "-rtsopts", "-with-rtsopts"]

-- | The flags that the module's OPTIONS_GHC and LANGUAGE pragmas give. As in
-- GHC, they are read from the source after preprocessing, which the module's
-- summary usually holds. If it doesn't, the source file is read.
pragmaFlags :: DynFlags -> ModSummary -> IO [String]
pragmaFlags dflags ms = do
  buf <- maybe (hGetStringBuffer file) pure (ms_hspp_buf ms)
  pure (optionsPragmas dflags buf file)
  where
    file = msHsFilePath ms

-- | The paths of the package databases that GHC reads for the given flags,
-- in the order GHC reads them (worked out as in GHC's getUnitDbRefs). The
-- user's database is left out, because GHC only reads it if it exists.
dbPaths :: DynFlags -> [FilePath]
dbPaths dflags = concatMap path (reverse (foldr flag [UserPkgDb, GlobalPkgDb] (packageDBFlags dflags)))
  where
    flag (PackageDB p) refs = p : refs
    flag NoUserPackageDB refs = filter (/= UserPkgDb) refs
    flag NoGlobalPackageDB refs = filter (/= GlobalPkgDb) refs
    flag ClearPackageDBs _ = []
    path GlobalPkgDb = [dropTrailingPathSeparator (globalPackageDatabasePath dflags)]
    path (PkgDbPath p) = [dropTrailingPathSeparator p]
    path UserPkgDb = []

-- | Give the unit environment's current unit the given package databases.
-- When the session's flags are set, GHC then uses these instead of reading
-- the databases from disk.
withUnitDbs :: [UnitDatabase UnitId] -> UnitEnv -> UnitEnv
withUnitDbs c ue = ue_updateHomeUnitEnv (\hue -> hue{homeUnitEnv_unit_dbs = Just c}) (ue_currentUnit ue) ue

-- | Remove the session's temporary files and directories, and stop its
-- external interpreter if it started one, as GHC does when a session ends.
endSession :: GhcSession -> IO ()
endSession s = do
  let hsc = gsEnv s
  cleanTempFiles (hsc_logger hsc) (hsc_tmpfs hsc)
  cleanTempDirs (hsc_logger hsc) (hsc_tmpfs hsc)
  mapM_ stopInterp (hsc_interp hsc)
  removePathForcibly (gsTmpDir s)

-- | Create a new directory for a session's temporary files, inside the
-- system's temporary directory. Its name has the worker's process ID and a
-- number unique within the process, so it is never reused (see Note [A
-- temporary directory per session]).
newTmpDir :: IO FilePath
newTmpDir = do
  base <- getTemporaryDirectory
  pid <- getProcessID
  n <- hashUnique <$> newUnique
  let dir = base </> ("buck2-ghc-worker-" ++ show pid ++ "-" ++ show n)
  createDirectory dir
  pure dir

-- | Compile the request's module, passing each diagnostic to the given
-- action, and then write the module's .abi file and dep file. It returns the
-- node that it compiled. If the session's interpreter needs a lock (see
-- 'gsInterpLock'), it holds the lock for the whole compile.
compile :: GhcSession -> (Diagnostic -> IO ()) -> Request -> IO Node
compile s report r = maybe id (\l -> withMVar l . const) (gsInterpLock s) (compileHeld s report r)

compileHeld :: GhcSession -> (Diagnostic -> IO ()) -> Request -> IO Node
compileHeld s report r = do
  mapM_ (createDirectoryIfMissing True) (reqMkdirs r)
  let hsc0 = gsEnv s
  ems <- summariseFile hsc0 (hsc_home_unit hsc0) M.empty (reqSource r) Nothing Nothing
  ms1 <- either (throwErrors . fmap GhcDriverMessage) pure ems
  -- Before GHC 9.12, summariseFile treats a boot file as an ordinary
  -- module, so we mark the summary as a boot file ourselves.
  let ms0
        | reqBoot r && ms_hsc_src ms1 /= HsBootFile = ms1{ms_hsc_src = HsBootFile, ms_location = addBootSuffixLocnOut (ms_location ms1)}
        | otherwise = ms1
  -- Write the .hie file and the stub header of foreign exports to the
  -- directories that the request's module flags give. The session's flags
  -- don't set these directories, so GHC would otherwise put the files next
  -- to the source.
  withHie <- case dropWhile (/= "-hiedir") (reqModuleArgs r) of
    _ : dir : _ -> do
      let file = dir </> reqModPath r <.> (if reqBoot r then "hie-boot" else "hie")
      createDirectoryIfMissing True (takeDirectory file)
      pure ms0{ms_location = (ms_location ms0){ml_hie_file = file}}
    _ -> pure ms0
  -- Likewise, use the object and interface files that the request names.
  -- They are where GHC would put them anyway, given the module's name and
  -- the session's -odir and -hidir, except for a Main module whose file has
  -- another name.
  let arg flag = case dropWhile (/= flag) (reqModuleArgs r) of
        _ : v : _ -> Just v
        _ -> Nothing
      loc = ms_location withHie
      withOutputs =
        withHie
          { ms_location =
              loc
                { ml_obj_file = fromMaybe (ml_obj_file loc) (arg "-o")
                , ml_hi_file = fromMaybe (ml_hi_file loc) (arg "-ohi")
                , ml_dyn_obj_file = fromMaybe (ml_dyn_obj_file loc) (arg "-dyno")
                , ml_dyn_hi_file = fromMaybe (ml_dyn_hi_file loc) (arg "-dynohi")
                }
          }
  let ms = case dropWhile (/= "-stubdir") (reqModuleArgs r) of
        _ : dir : _ -> withOutputs{ms_hspp_opts = (ms_hspp_opts withOutputs){stubDir = Just dir}}
        _ -> withOutputs
  -- The compile reads interfaces into the external package state for its
  -- flags, including those of its module's pragmas. The entries of a
  -- --make compile's home package table are cached by the same key (see
  -- Note [The flags an interface is read with]).
  key <- interfaceKey r (ms_hspp_opts ms) <$> pragmaFlags (hsc_dflags hsc0) ms
  external <- sharedAt (gsExternal s) key initExternalUnitCache
  let keyed = hsc0{hsc_unit_env = (hsc_unit_env hsc0){ue_eps = external}}
  -- A one-shot compile reads its home modules into the external state, so
  -- its home package table is empty. It must be a new empty table for each
  -- compile, because from GHC 9.14 compileOne adds the module it has
  -- compiled to the table. Its module graph is the one `ghc -c` would have.
  (hsc, below) <-
    if gsOneShot s
      then (\e -> (e, Below Set.empty Set.empty)) <$> (emptyHome keyed >>= (`withOneShotModuleGraph` ms))
      else homeView s r key (hscSetFlags (ms_hspp_opts ms) keyed) ms
  -- The compile's own temporary files (its assembly code, for example) are
  -- removed when it finishes. The temporary files that must last as long as
  -- the session are merged into the session's, as `--make -j` does for each
  -- module. The compile's diagnostics go to the request, through `report`.
  tmpfs <- forkTmpFsFrom (hsc_tmpfs hsc)
  let logger = pushLogHook (\_ lf cls _ doc -> report (Diagnostic (isError cls) (renderWithContext (log_default_user_context lf) doc))) (hsc_logger hsc)
  hmi <- compileOne hsc{hsc_tmpfs = tmpfs, hsc_logger = logger} ms 1 1 Nothing emptyHomeModInfoLinkable
    `finally` (cleanCurrentModuleTempFiles (hsc_logger hsc) tmpfs >> mergeTmpFsInto tmpfs (hsc_tmpfs hsc))
  let n = (ms_mod_name ms, if reqBoot r then IsBoot else NotBoot)
  unless (gsOneShot s) $ modifyMVar_ (gsHomes s) (pure . compiled key n below hmi)
  writeDepFiles r (hm_iface hmi)
  pure n
  where
    isError cls = case cls of
      MCDiagnostic SevError _ _ -> True
      MCFatal -> True
      _ -> False

-- | A node of the module graph: a home module, or a home module's boot
-- interface.
type Node = (ModuleName, IsBootInterface)

-- | What a --make session keeps of its home modules (see Note [Each
-- compile's home modules]):
--
-- - hIfaces: each node's interface and object, read from disk once, or kept
--   from the session's own compile of the node.
-- - hEntries: the home package table entries made from those interfaces.
--   An entry is keyed by the 'interfaceKey' of the compiles it was made for,
--   its node, and the set of boot interfaces below it. It is stored with
--   the set of nodes below it, so that it can be dropped when one of those
--   nodes is compiled again.
data Homes = Homes
  { hIfaces :: M.Map Node (ModIface, HomeModLinkable)
  , hEntries :: M.Map ([String], Node, Set.Set ModuleName) (HomeModInfo, Set.Set Node)
  }

-- | Record a module that the session has just compiled, with the
-- 'interfaceKey' of the compile and what was below the module in the
-- compile's view. The module's interface and home package table entry
-- replace those from any earlier compile of it. The entries of the modules
-- above it are dropped, since they were made from its old interface.
compiled :: [String] -> Node -> Below -> HomeModInfo -> Homes -> Homes
compiled key n below hmi h =
  Homes
    { hIfaces = M.insert n (hm_iface hmi, hm_linkable hmi) (hIfaces h)
    , hEntries = M.insert (key, n, bootsBelow below) (hmi, nodesBelow below) (M.filterWithKey (\(_, m, _) (_, nodes) -> m /= n && not (n `Set.member` nodes)) (hEntries h))
    }

-- | Give the environment the home package table that the compile of the
-- given module should see (see Note [Each compile's home modules]). The
-- environment is the session's, with the compile's flags, and the key is
-- the 'interfaceKey' of those flags. The table holds the home modules below
-- the module's imports, each in the form that `ghc -c` would see (the whole
-- module, or its boot interface), and the module's own boot interface if it
-- has one. The exceptions are the modules that the request names to link,
-- which are whole, as GHC's --make mode sees them. It also returns what is below the module's imports, for
-- 'compiled'.
homeView :: GhcSession -> Request -> [String] -> HscEnv -> ModSummary -> IO (HscEnv, Below)
homeView s r key hsc ms = modifyMVar (gsHomes s) $ \homes0 -> do
  let unit = homeUnitId (hsc_home_unit hsc)
      own = ms_mod_name ms
  -- An import that names another package (with PackageImports) isn't an
  -- import of a home module, even if a home module has the same name.
  imports <- fmap concat . forM (ms_textual_imps ms) $ \imp -> do
    let (mn, pkg) = importName imp
    found <- findImportedModule hsc mn pkg
    pure [mn | Found _ m <- [found], isHomeModule (hsc_home_unit hsc) m]
  let sources = map srcImportName (ms_srcimps ms)
  ownBoot <- if reqBoot r then pure False else doesFileExist (ml_hi_file (addBootSuffixLocn (ms_location ms)))
  homes1 <- foldM (\h mn -> ifaceOf hsc h (mn, NotBoot)) homes0 imports
  -- Work out which modules the compile sees as boot interfaces, as GHC
  -- does in rnImports. Each import's interface records the boot files
  -- below it (dep_boot_mods), and whether each is reached only through
  -- {-# SOURCE #-} imports. A module is seen whole if it is imported
  -- directly, or if anything below an import imports it whole. Otherwise
  -- it is seen as its boot interface. The module being compiled always
  -- sees its own boot interface.
  -- The modules to link are seen whole too. A module that is found only
  -- below them, which no import's record covers, takes the form it is
  -- imported in.
  let recordedBelow mn = M.fromList [(gwib_mod b, gwib_isBoot b) | (u, b) <- Set.toList (dep_boot_mods (mi_deps (fst (hIfaces homes1 M.! (mn, NotBoot))))), u == unit]
      recorded = M.unionsWith min (map recordedBelow imports ++ [M.fromList [(mn, IsBoot) | mn <- sources]])
      links = map mkModuleName (reqLinks r)
      bootness = M.fromList [(mn, NotBoot) | mn <- imports ++ links] `M.union` M.insert own IsBoot recorded
      node mn b = (mn, M.findWithDefault b mn bootness)
      roots = [node mn NotBoot | mn <- imports ++ links] ++ [node mn IsBoot | mn <- sources]
  -- Find the nodes below the compile, reading their interfaces as needed.
  -- Each node's edges go to the modules it imports, and to the modules
  -- whose boot files are recorded below it. The latter are needed because
  -- an unfolding in the node's interface may mention one of those modules
  -- even though the node doesn't import it (for example, through an INLINE
  -- function of a module it imports). Before GHC 9.14, an entry is
  -- typechecked against the table as it is when the entry is added, so
  -- those modules must already be in the table by then.
  let walk (h, graph) [] = pure (h, graph)
      walk (h, graph) (n : todo)
        | n `M.member` graph = walk (h, graph) todo
        | otherwise = do
            h' <- ifaceOf hsc h n
            let iface = fst (hIfaces h' M.! n)
            let deps =
                  [node (gwib_mod d) (gwib_isBoot d) | (u, d) <- map directDep (Set.toList (dep_direct_mods (mi_deps iface))), u == unit]
                    ++ [node (gwib_mod b) IsBoot | (u, b) <- Set.toList (dep_boot_mods (mi_deps iface)), u == unit]
            walk (h', M.insert n deps graph) (deps ++ todo)
  (homes2, graph) <- walk (homes1, M.empty) (roots ++ [(own, IsBoot) | ownBoot])
  -- Build the table in dependency order, reusing the entries made for
  -- earlier compiles that had the same boot interfaces below them. The
  -- exception is the modules above the compile's own boot interface. Their
  -- interfaces refer to the module being compiled, and the compile ties
  -- those references to itself through its knot, as `ghc -c` does. So
  -- their entries are typechecked again for this compile, as --make does.
  -- See Note [Modules above the compile's boot interface].
  knot <- newIORef emptyTypeEnv
  let withKnot e = e{hsc_type_env_vars = knotVarsFromModuleEnv (mkModuleEnv [(ms_mod ms, knot)])}
      ownBootNode = [(own, IsBoot) | ownBoot]
  env0 <- emptyHome hsc
  (homes3, env, below) <- foldM (addScc key graph ownBootNode withKnot) (homes2, env0, M.empty) (stronglyConnComp [(n, n, deps) | (n, deps) <- M.toList graph])
  pure (homes3, (withKnot env, Below (Set.unions [bootsBelow (below M.! n) | n <- roots]) (Set.unions [nodesBelow (below M.! n) | n <- roots])))

-- | What is below a node in a compile's view of the home modules, including
-- the node itself: the modules seen as boot interfaces, and all the nodes.
data Below = Below {bootsBelow :: Set.Set ModuleName, nodesBelow :: Set.Set Node}

-- | Add a strongly connected component of the compile's module graph to the
-- compile's home package table, reusing or caching entries under the given
-- 'interfaceKey'. The components below this one must have been added
-- already. A component is a single node, or several whole modules that
-- import one another through boot files. If the component is above the
-- compile's own boot interface (the third argument, which is empty if there
-- is none), its entries are typechecked with the compile's knot, for this
-- compile alone (see Note [Modules above the compile's boot interface]).
addScc :: [String] -> M.Map Node [Node] -> [Node] -> (HscEnv -> HscEnv) -> (Homes, HscEnv, M.Map Node Below) -> SCC Node -> IO (Homes, HscEnv, M.Map Node Below)
addScc key graph ownBoot withKnot (h, env, below) scc = do
  let members = flattenSCC scc
      outside = [below M.! d | m <- members, d <- graph M.! m, d `notElem` members]
      -- What is below the members, other than the members themselves. Its
      -- set of boot interfaces is part of the key of each member's entry.
      under = Below (Set.fromList [fst d | m <- members, d <- graph M.! m, snd d == IsBoot] <> Set.unions (map bootsBelow outside)) (Set.unions (map nodesBelow outside))
      selfBelow m = Below (Set.fromList [fst m | snd m == IsBoot] <> bootsBelow under) (Set.fromList members <> nodesBelow under)
      below' = foldr (\m -> M.insert m (selfBelow m)) below members
      aboveOwnBoot = any (`Set.member` nodesBelow under) ownBoot
  case mapM (\m -> fst <$> M.lookup (key, m, bootsBelow under) (hEntries h)) members of
    _ | aboveOwnBoot -> do
      (env', _) <- addHomes (withKnot env) [hIfaces h M.! m | m <- members]
      pure (h, env'{hsc_type_env_vars = hsc_type_env_vars env}, below')
    Just hmis -> do
      env' <- foldM (\e (m, hmi) -> insertHome e (fst m) hmi) env (zip members hmis)
      pure (h, env', below')
    -- The entry for the compile's own boot interface is made in the
    -- compile's table, but isn't cached for other compiles (see Note [The
    -- compile's own boot interface]).
    Nothing | members == ownBoot -> do
      (env', _) <- addHomes env [hIfaces h M.! m | m <- members]
      pure (h, env', below')
    Nothing -> do
      (env', hmis) <- addHomes env [hIfaces h M.! m | m <- members]
      let entries = foldr (\(m, hmi) -> M.insert (key, m, bootsBelow under) (hmi, nodesBelow under <> Set.fromList members)) (hEntries h) (zip members hmis)
      pure (h{hEntries = entries}, env', below')

-- | Read the node's interface and object from disk into 'hIfaces', unless
-- they are there already.
ifaceOf :: HscEnv -> Homes -> Node -> IO Homes
ifaceOf hsc h n
  | n `M.member` hIfaces h = pure h
  | otherwise = do
      found <- findImportedModule hsc (fst n) NoPkgQual
      case found of
        Found loc0 m -> do
          let loc = if snd n == IsBoot then addBootSuffixLocn loc0 else loc0
          iface <- readIface hsc (ml_hi_file loc)
          obj <- if snd n == IsBoot then pure Nothing else findObjectLinkableMaybe m loc
          pure h{hIfaces = M.insert n (iface, maybe emptyHomeModInfoLinkable justObjects obj) (hIfaces h)}
        _ -> throwGhcExceptionIO (ProgramError ("buck2-ghc-worker: no interface for home module " ++ moduleNameString (fst n)))

readIface :: HscEnv -> FilePath -> IO ModIface
readIface hsc = readBinIface (targetProfile (hsc_dflags hsc)) (hsc_NC hsc) IgnoreHiWay QuietBinIFace

-- | Like `try`, except that asynchronous exceptions (a cancelled request,
-- or the worker ending) are rethrown rather than caught.
tryNonAsync :: IO a -> IO (Either SomeException a)
tryNonAsync act = do
  result <- try act
  case result of
    Left e | Just (_ :: SomeAsyncException) <- fromException e -> throwIO e
    _ -> pure result

{- Note [The session's state]

1. The problem

To compile a module, GHC needs the interfaces of the home modules (the
modules of the same package) that the module imports. GHC has two ways to
get them:

  - One-shot mode (`ghc -c`) reads them from disk into its cache of
    external interfaces, the same cache it uses for other packages' modules.
  - --make mode expects them in the compile's home package table (HPT), and
    finds their instances (and, for Template Haskell, their objects) through
    the session's module graph.

One-shot mode is simpler for the worker, but its cache can't cope with
boot files. The cache has no notion of a module's boot interface being
replaced by the full module. Once a {-# SOURCE #-} import of B has put B's
boot interface in the cache, B's own compile sees the boot interface's
instances as another module's. And a later import of B may be given the
boot interface instead of the module.

2. The solution

So by default a session uses one-shot mode if its target has no boot files
(see Note [One-shot sessions]), and --make mode if it has. In --make mode:

  - The module graph is the result of GHC's dependency analysis of the
    whole target, which runs over the target's source tree when the
    session is made. The worker only uses the graph to tell which modules
    depend on which.
  - Each compile has an HPT of its own (see Note [Each compile's home
    modules]). It is made from what the session keeps: the home modules'
    interfaces, each read from disk once or kept from the session's own
    compile of the module, and the HPT entries made from those interfaces.

3. The road not taken

For targets with boot files, an obvious alternative is one-shot mode with a
separate cache for each compile, as each `ghc -c` process has. We tried it,
and modules with boot files then failed in ways that they don't with
`ghc -c`. A module's own boot interface's instances were reported as
duplicates, or GHC read the module's interface before it had been written.
We didn't find out why. The likely cause is the session's name cache,
which the compiles still shared.

One-shot mode also can't run a splice that links code behind a boot file
whose boot interface the compile has read, which --make mode can (see Note
[Each compile's home modules]).
-}

{- Note [One-shot sessions]

1. The problem

Each session reads the interfaces that its compiles need (those of the
prebuilt libraries, and those of the target's dependencies in the build)
into an external package state of its own. A large build makes thousands
of sessions, because the worker drops idle sessions and makes them again
when their target needs them (see Note [Dropping the idle sessions] in
Worker). Each of those sessions reads much the same interfaces again. For
example, every session reads base's interfaces.

2. The solution

A session whose target has no boot files compiles in one-shot mode, as
`ghc -c` does (see Note [The session's state]). Its compiles share their
external package state with the compiles of every other one-shot session
that read interfaces with the same flags (see Note [The flags an interface
is read with]). So an interface is read only once in the worker's life,
however many sessions use it. In one-shot mode, GHC reads the interfaces of
the target's own modules into the external state too. So the session keeps
no home package table, and its compiles write exactly what `ghc -c` writes.

This is the worker's default session mode, `auto`. The session mode is set
by BUCK2_GHC_WORKER_SESSION_MODE. Mode `make` uses --make sessions for every
target, which turns the sharing off. Mode `one-shot` uses one-shot sessions
for every target, and refuses targets with boot files. The tests use both
of these modes, so that each kind of session is tested on every target it
can compile.

3. What the shared state keeps alive

GHC typechecks an interface's declarations lazily. A declaration that
hasn't been typechecked yet keeps alive the environment of the compile
that read it, and with it the session's unit state, which is what GHC
knows about the packages and takes a few MB. So the shared state keeps
alive the unit state of every session that has read anything into it.

To bound that, the one-shot sessions with the same session flags (the
successive sessions of one target, in practice) share the unit state of
the first of them. Then the memory that the shared state keeps alive grows
with the number of targets, rather than with the number of sessions. For
the same reason, a one-shot session has no module graph, since the graph
holds the target's sources.

The shared state is never emptied, and for a large build it holds several
GB of interfaces. Replacing it with a fresh one now and then doesn't help.
An old state lives until its last session is dropped, and the fresh ones
read the same interfaces again.

4. The alternatives

One session with a home unit for each target in the build, as `ghc --make`
has with several -unit flags, would also share the interfaces, without
lazy declarations keeping sessions alive. But a module's interface would
then record the modules of other targets as home modules rather than as
modules of packages, so it would differ from what `ghc -c` writes. And each
compile would need the module graphs of its dependencies, which GHC makes
from their sources.

5. Measurements

These are the results on the bench (bench/Main.hs) at -j8, on workloads
where the worker drops sessions and makes them again, with the default
limit of 16 sessions. The command was
`cabal bench --benchmark-options='8 3 project many'`.

  workload                one-shot sessions   --make sessions
  project (94 sessions)   22.2-24.7s          32.9-40.3s
  many (330 sessions)     17.7-21.5s          59.2-78.1s

With a limit high enough that no session is dropped, the two take the same
time. The worker's peak memory was about the same either way: 5.1-5.5 GB
on project, 5.0-6.2 GB on many.
-}

{- Note [Each compile's home modules]

1. The problem

In --make mode, GHC looks up the home modules a compile needs in the
compile's home package table (HPT). The obvious design for the worker is
one HPT per session, shared by all its compiles. That doesn't work, because
of boot files.

Say module B has a boot file, B.hs-boot, and module C imports B with
{-# SOURCE #-}. When `ghc -c` compiles a module X that imports C, it can
see B in one of two forms:

  - the boot interface (from B.hs-boot), if X only reaches B through
    {-# SOURCE #-} imports;
  - the full module, if X, or anything X imports, imports B normally.

GHC decides which form to use from what the interfaces of X's imports
record (dep_boot_mods). The choice affects what X's compile sees, and so
X's interface and object.

With one shared HPT, the form X sees would depend on whether the session
happened to have compiled B already, which comes down to scheduling. X's
output would vary from build to build, and differ from `ghc -c`'s. (Since
GHC 9.14 the HPT is also mutable, so a compile could even see a module that
a concurrent compile added part-way through.)

2. The solution

Each compile gets its own HPT. It holds exactly the home modules X depends
on, each in the form `ghc -c` would use (except as in section 3), plus X's
own boot interface if it has one (GHC checks X against it).

Making an HPT entry from an interface is cheap, because GHC typechecks the
entry's contents lazily. So the session caches the entries. It reuses an
entry for any later compile that has the same boot interfaces below the
entry's module, and that reads interfaces with the same flags as the
compile the entry was made for (see Note [The flags an interface is read
with]). When the session compiles a module, it discards that module's
entries and those of everything that depends on it. Modules in an import
cycle (through boot files) are added together, as GHC's --make does (see
addHomes).

3. Template Haskell and boot files

A splice must link all the code it runs, including modules that the
compile only has as boot interfaces. GHC's linker refuses those ("cannot be
linked; it is only available as a boot module"). GHC's own --make avoids
this by compiling the splicing module after the modules behind those boot
files. The rules do the same: the module waits for them, and the request
names them with `--link` (see _linked_closure in compile_per_module.bzl).
The worker then puts them in the compile's HPT as whole modules.

So the compile doesn't see what `ghc -c` would. If it reaches a module only
through {-# SOURCE #-} imports, `ghc -c` has only that module's boot
interface. The compile's interface and object can then differ from
`ghc -c`'s, even without -O. With -O, the compile also sees that module's
unfoldings and instances. FIXME: fix this, rather than just documenting it
(see compiledAs in the props).

Before GHC 9.12, the linker leaves the modules behind boot files out
anyway, as `ghc -c` does. GHC's own --make doesn't, and we don't know why
(see the test suite's T.N, and the README's known issues).
-}

{- Note [The flags an interface is read with]

1. The problem

GHC typechecks an interface with the flags of the compile that reads it,
and the external state then keeps the result for every later compile. For
instance, at -O0 GHC ignores interface pragmas. A compile at -O0 that reads
base's Data.Bits doesn't learn the arity of toIntegralSized, so it calls
the function as an unknown one. A module with {-# OPTIONS_GHC -O2 #-} does
read the pragmas. If the -O2 module reads Data.Bits first, an -O0 compile
that shares its external state sees the arity, and calls toIntegralSized
directly.

So a module's object would depend on what the worker had compiled before
it, and would differ from `ghc -c`'s. Worse, it would differ from build to
build. After a clean build, an edit to one of a library's modules that
leaves its code the same, such as an edit to a comment, could still change
the module's object, because the worker compiles the module after different
modules this time. buck2 would then link the library again, and compile
again the Template Haskell modules that depend on it.

The flags that matter are the compile's own. They are the flags of its
session, followed by those of its module's OPTIONS_GHC pragmas, which GHC
reads as it compiles the module.

2. The solution

Each compile reads interfaces into an external package state that is kept
for its flags, including those of its module's pragmas (see
'interfaceKey'). The entries of a --make compile's home package table are
cached by the same key. The key leaves out the flags that GHC doesn't
consult when it reads an interface, so that targets and modules that
differ only in those flags share what they read. The flags left out say
where sources, headers and outputs are and which packages a module may
import, give options to the preprocessor, the C compiler and the linker,
control warnings, language extensions and what GHC dumps, choose a
binary's runtime system and its options, or run splices in an external
interpreter. Every other flag is kept. A flag that GHC doesn't consult either, but that isn't left out,
only splits the state, which costs time but doesn't affect correctness.
-}

{- Note [Modules above the compile's boot interface]

1. The problem

Say module M has a boot file, M.hs-boot, and module A imports M with
{-# SOURCE #-}, while M imports A. That is an import cycle, which the boot
file breaks. A's interface then mentions M's definitions, and so may the
unfoldings in it (the code of A's functions that GHC may inline
elsewhere).

When `ghc -c` compiles M, it reads A's interface while it typechecks M, and
ties those mentions to the M it is compiling, through the compile's "knot"
(hsc_type_env_vars). So if M inlines a function of A's that calls M.x, the
inlined code calls M's own x, and GHC correctly sees a recursion. GHC's
--make gets the same result by typechecking A again, with the knot, before
it compiles M. (GHC calls this "rehydrating"; see GHC's Note [Hydrating
Modules].)

If the worker made A's HPT entry from M's boot interface instead, the
inlined code would call the boot file's M.x, which to GHC is a different
thing, and M's interface would differ from `ghc -c`'s.

2. The solution

The worker does what --make does. When it makes the HPT for M's compile,
the entries of the modules that depend on M's boot interface (A here) are
made for that compile alone, with its knot, and aren't cached.
-}

{- Note [The compile's own boot interface]

1. The problem

GHC typechecks an HPT entry's contents lazily, against the HPT the entry
was made in, when something first needs them. Since GHC 9.14 the HPT is
mutable, and compileOne ends by adding the module it has just compiled to
the compile's own HPT (initModDetails).

So when the worker compiles M, the HPT has M's boot interface in it,
because GHC checks M against it. If the entry for that boot interface is
only typechecked after the compile, it finds the full M in the HPT, and
takes M's definitions for its own. The boot interface's instances then
become M's, unfoldings and all. A module that later imports M with
{-# SOURCE #-} and inlines one of those instances then refers to something
that the boot interface doesn't have, and GHC panics ("lookupVers1").

2. The solution

The entry for M's boot interface made for M's own compile is used by that
compile alone, and never cached. An entry for M's boot interface made for
any other compile is safe to cache, since no other compile adds M to its
HPT.
-}

{- Note [Flags of the whole process]

1. The problem

A few of GHC's flags set state for the whole process, not just for the
session they are given to. In the worker, one session's setting would then
apply to every session, or to none:

  - -fno-state-hack: the simplifier reads it from a global, which
    parseDynamicFlags sets and the first optimised compile then fixes for
    good (unsafeHasNoStateHack);
  - -dppr-debug and -dno-debug-output: the pretty-printer and GHC's tracing
    read them from globals set the same way (unsafeHasPprDebug,
    unsafeHasNoDebugOutput);
  - -dinitial-unique and -dunique-increment: only ghc's Main applies them;
  - -H and -Rghc-timing: these set the runtime's options.

2. The solution

The worker refuses to make a session with any of these flags, and
restores the globals that parsing the session's flags has just set. A
target that needs these flags must be compiled without the worker. (The
same flags in an OPTIONS_GHC pragma don't reach the globals, in `ghc -c` or
in the worker, so they are fine there.)
-}

{- Note [Compiling whenever buck2 asks]

buck2 decides when a module needs compiling again, from the module's dep
file (see Note [Early cut-off by dep files] in compile_per_module.bzl). So
the worker should compile every request it gets, and never let GHC decide
that the module is up to date.

buck2 already removes an action's previous outputs before running it, so
GHC normally finds no old interface to compare with. The worker also passes
-fforce-recomp (see sessionFlags), so that GHC compiles the module whatever
is on disk, as the compile tool does without the worker.

This matters for Template Haskell. A splice can read a file without
recording it (with runIO, and without addDependentFile), so the module's
interface doesn't list the file. After the file changed, GHC's check would
find the module up to date, and keep its old object. With -fforce-recomp,
the worker compiles such a module whenever buck2 asks for it.
-}

{- Note [A temporary directory per session]

1. The problem

To run a splice, GHC links the objects it needs into a temporary shared
library, and loads it with dlopen. The library's file name comes from a
counter in the session's temporary-file state, and each new session starts
counting again. But the dynamic linker caches libraries by path. If it has
loaded a library from a path before, dlopen returns that library again,
even if the file at that path is new.

So after the worker dropped a session (and removed its files), a new
session could create a library at a path that the old session had already
loaded. The new session's splice would get the old library, and fail to
find the new library's symbols ("During interactive linking, GHCi couldn't
find the following symbol").

2. The solution

Each session puts its temporary files in a directory of its own, which is
never reused.
-}

{- Note [Hashing the libraries]

1. The problem

For each module that runs Template Haskell, GHC records a hash of every
Haskell library (hs-libraries) and object file that the interpreter loaded
(`mkObjectUsage`), and caches the hashes in the session's finder cache.
Each library is a few megabytes, so hashing is slow, and in the worker it
would happen far too often:

  - Each session has its own cache, and a target may have several sessions
    in a build, since a dropped session is made again when it is needed
    (see Note [Dropping the idle sessions] in Worker).
  - Modules compiled at the same time in one session all miss the cache
    together, and each of them hashes every library.

2. The solution

All the sessions share one cache of hashes for the life of the worker, and
look up a hash under a lock. Then one compile hashes each library while
the others wait for it (see sharedFileHashes). Before GHC 9.12 the cache's
lookup function can't be replaced, so the sessions share the cache without
the lock, and compiles that miss it at the same time each hash the library.

Caching the hashes for the worker's whole life is safe, because the
libraries don't change while the worker lives. buck2 writes each output
only once in a build, and a worker lives for one build. (buck2 starts a
worker for each command, which the rules' tests check.)
-}

{- Note [One copy of each package database]

1. The problem

A session reads its package databases from disk when it is made. They are
the database of each library in the build, and the database of the
third-party packages, which describes hundreds of packages. A whole build
makes thousands of sessions, and each session would keep its own copy of
the databases while it lives, though most of the copies are the same.

2. The solution

The worker keeps every database it has read, keyed by path, for its whole
life. It gives a new session the copies of the session's databases, and
GHC then uses them instead of reading the databases (as it does when a
session's flags are set again). If some of a session's databases haven't
been read yet, GHC reads all of them, and the worker keeps what GHC read.

Keeping the databases for the worker's life is safe for the same reason as
in Note [Hashing the libraries]: buck2 writes each database only once in a
build. If a session would read the user's database, or the databases in
GHC_PACKAGE_PATH, which the rules don't make, the worker leaves the
session's databases to GHC.
-}

{- Note [One name cache for all the sessions]

1. The problem

GHC gives each entity that it reads from an interface a Name, made of the
entity's module, its name, and a unique number. The name cache maps each
module and name to its Name, so that every interface that mentions an
entity gives it the same Name. A session made with GHC's API has a name
cache of its own. So when many sessions read the same libraries'
interfaces, as they do in a clean build of a large project, each session
holds its own Names for all of those entities, and its own cache of them.

2. The solution

All the sessions share the name cache of the worker's own session (see
withWorker), as all the home units of a multi-unit `ghc --make` do. An
entity has the same module and name in every session, so it can have the
same Name in every session. That holds for the modules of the build's
targets too. A target's module is a home module in the target's own
sessions, and comes from a package db in its dependents' sessions, but it
is the same module, with the same unit id. GHC takes a lock to change the
cache, as it must for the threads of `--make -j`. The Names that a dropped
session read stay in the cache, but a later session would read most of
them again anyway.

One-shot sessions need the shared cache, since they share interfaces (see
Note [One-shot sessions]), and the Names in those interfaces must be the
ones that every session would make. For --make sessions, sharing the cache
saves a little. On the bench's `project` workload, a worker patched to give
each --make session a cache of its own took the same time, with 5-7% more
peak memory and 2-4% more CPU.
-}
