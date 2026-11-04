{-# LANGUAGE ScopedTypeVariables #-}
-- | A GHC session, in which requests compile their modules concurrently,
-- each with GHC's own compile of one module (what `--make -j` runs for each
-- module). See Note [The session's state].
module Session (GhcSession, gsModules, gsOutDir, gsOneShot, SessionMode (..), Shared, newShared, newSession, endSession, compile, Node, Diagnostic (..), tryNonAsync) where

import Control.Exception (SomeAsyncException, SomeException, finally, fromException, onException, throwIO, try)
import Control.Monad (foldM, forM, unless, when)
import Control.Concurrent.MVar
import Data.Graph (SCC, flattenSCC, stronglyConnComp)
import Data.IORef
import Data.List (isSuffixOf)
import qualified Data.Map as M
import Data.Maybe (fromMaybe, isJust)
import qualified Data.Set as Set
import Data.Unique (hashUnique, newUnique)
import System.Directory (createDirectory, createDirectoryIfMissing, doesDirectoryExist, doesFileExist, getTemporaryDirectory, listDirectory, removePathForcibly)
import System.Posix.Process (getProcessID)
import System.Environment (lookupEnv)
import System.FilePath (dropTrailingPathSeparator, joinPath, splitDirectories, takeDirectory, (<.>), (</>))
import System.IO (hPutStrLn, stderr)

import GHC
import GHC.Driver.Env (hscSetFlags, hsc_FC, hsc_NC, hsc_dflags, hsc_home_unit, hsc_interp, hsc_logger, hsc_mod_graph, hsc_tmpfs, hsc_type_env_vars, hsc_unit_env)
import GHC.Driver.Env.KnotVars (knotVarsFromModuleEnv)
import GHC.Types.TypeEnv (emptyTypeEnv)
import GHC.Unit.Module.Env (mkModuleEnv)
import GHC.Driver.Errors.Types (GhcMessage (..))
import GHC.Driver.Make (summariseFile)
import GHC.Driver.Monad (Ghc (..), Session (..))
import GHC.Driver.Pipeline (compileOne)
import GHC.Driver.Session (PackageDBFlag (..), PkgDbRef (..), globalPackageDatabasePath, hasNoDebugOutput, hasPprDebug, setUnsafeGlobalDynFlags, targetProfile, ways)
import GHC.Iface.Binary (CheckHiWay (..), TraceBinIFace (..), readBinIface)
import GHC.Runtime.Interpreter (stopInterp)
import GHC.Types.Error (MessageClass (..))
import GHC.Types.SourceError (throwErrors)
import GHC.Types.SourceFile (HscSource (..))
import GHC.Unit.Finder (FindResult (..), findImportedModule, findObjectLinkableMaybe, initFinderCache)
import GHC.Types.Name.Cache (NameCache)
import GHC.Unit.Finder.Types (FinderCache)
import GHC.Unit.Home (HomeUnit, homeUnitId, isHomeModule)
import GHC.Unit.Module.ModSummary (isBootSummary)
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

-- | One GHC session.
data GhcSession = GhcSession
  { gsEnv :: HscEnv -- GHC's, but each compile has its own home package table
  , gsHomes :: MVar Homes -- held to make a compile's home package table
  , gsTmpDir :: FilePath -- its own: see Note [A temporary directory per session]
  , gsModules :: Maybe (Set.Set Node) -- its target's modules and boot interfaces, unless GHC's analysis of them failed
  , gsOutDir :: FilePath -- its target's outputs, in the way it is built: its other sessions share it
  , gsOneShot :: Bool -- whether it compiles in one-shot mode: see Note [One-shot sessions]
  , gsInterpLock :: Maybe (MVar ()) -- held by each compile, when its external interpreter needs one: see 'interpreterLock'
  }

-- | How sessions compile: see Note [One-shot sessions].
data SessionMode
  = AutoSessions -- one-shot for a target without boot files, --make for one with
  | MakeSessions -- --make for every target
  | OneShotSessions -- one-shot for every target, refusing one with boot files

-- | What the sessions share, for the worker's life.
data Shared = Shared
  { shDbs :: MVar (M.Map FilePath (UnitDatabase UnitId)) -- the package databases read, by path: see Note [One copy of each package database]
  , shExternal :: MVar (M.Map String ExternalUnitCache) -- the external state of the one-shot sessions, by 'flavour'
  , shUnits :: MVar (M.Map [String] (UnitState, Maybe HomeUnit)) -- the unit state of the one-shot sessions, by their flags
  }

newShared :: IO Shared
newShared = Shared <$> newMVar M.empty <*> newMVar M.empty <*> newMVar M.empty

-- | A diagnostic of a compile: whether it is an error, and its text.
data Diagnostic = Diagnostic {diagIsError :: Bool, diagText :: String}

-- | Make a session for the request's flags, in the given mode, with GHC's
-- analysis of its target's modules (see Note [The session's state]). It
-- shares the given finder cache's file hashes (see Note [Hashing the
-- libraries]), the given name cache (see Note [One name cache for all the
-- sessions]), and the rest of what the sessions share. What GHC logs
-- outside a compile (rarely anything) goes to the worker's stderr.
newSession :: FilePath -> FinderCache -> NameCache -> Shared -> SessionMode -> Request -> IO GhcSession
newSession libdir files names shared mode r = do
  ref <- newIORef (error "ghc-worker: the session isn't made yet")
  let session = Session ref
  unGhc (initGhcMonad (Just libdir)) session
  modifyIORef' ref (\hsc -> hsc{hsc_NC = names})
  dflags0 <- unGhc getSessionDynFlags session
  unGhc (modifyLogger (pushLogHook (\_ lf _ _ doc -> hPutStrLn stderr (renderWithContext (log_default_user_context lf) doc)))) session
  logger <- hsc_logger <$> readIORef ref
  tmp <- newTmpDir
  -- (A session that can't be made leaves no directory.)
  (`onException` removePathForcibly tmp) $ do
    (dflags, leftover, _) <- parseDynamicFlags logger dflags0 (map noLoc (sessionFlags r ++ ["-tmpdir", tmp]))
    -- Arguments that aren't flags GHC knows, which `ghc` itself would
    -- refuse.
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
    setFlags shared session dflags
    found <- concat <$> mapM sources (reqSrcRoots r)
    -- The targets don't include the boot files, which GHC finds from the
    -- {-# SOURCE #-} imports. Before GHC 9.12, a boot file given as a
    -- target leaves the graph without boot interfaces, which a compile
    -- needs to find the instances of the boot interfaces it imports.
    let srcs = filter (\f -> any (`isSuffixOf` f) [".hs", ".lhs"]) found
    oneShot <- isOneShot mode (any (\f -> any (`isSuffixOf` f) [".hs-boot", ".lhs-boot"]) found)
    -- Make the target's module graph with GHC's own dependency analysis
    -- over the source tree. If the analysis fails, the graph is left empty,
    -- and the failing modules' own compiles report the errors.
    analysed <- unGhc (do
      hsc <- getSession
      targets <- mapM (\f -> guessTarget f (Just (homeUnitId (hsc_home_unit hsc))) Nothing) srcs
      setTargets targets
      analyseTargets) session
    -- The analysis looked for the modules imported from dependencies, and
    -- most of their interfaces aren't there yet, since an early package
    -- db's interfaces are written one by one. GHC's finder caches what it
    -- didn't find as well as what it did, so the compiles start with an
    -- empty finder cache, apart from the file hashes.
    fc <- initFinderCache
    hsc0 <- readIORef ref
    let modules = Set.fromList [(ms_mod_name ms, isBootSummary ms) | ms <- mgModSummaries (hsc_mod_graph hsc0)]
    hsc <- if oneShot then oneShotEnv shared r hsc0 else pure hsc0
    GhcSession hsc{hsc_FC = withFileHashes files fc} <$> newMVar (Homes M.empty M.empty) <*> pure tmp <*> pure (if analysed then Just modules else Nothing) <*> pure (reqOutDir r) <*> pure oneShot <*> interpreterLock (hsc_dflags hsc)
  where
    sources dir = do
      entries <- listDirectory dir
      fmap concat . forM entries $ \e -> do
        let path = dir </> e
        isDir <- doesDirectoryExist path
        if isDir then sources path else pure [path]

-- | Whether a session in the mode compiles one-shot, given whether its
-- target has boot files. Fails in one-shot mode for a target that has them.
isOneShot :: SessionMode -> Bool -> IO Bool
isOneShot mode boots = case mode of
  AutoSessions -> pure (not boots)
  MakeSessions -> pure False
  OneShotSessions
    | boots -> throwGhcExceptionIO (CmdLineError "this target has hs-boot files, which one-shot sessions can't compile: set the worker's session mode to auto or make")
    | otherwise -> pure True

-- | Set the session's flags, with the package databases GHC reads for them
-- shared with the other sessions (see Note [One copy of each package
-- database]).
setFlags :: Shared -> Session -> DynFlags -> IO ()
setFlags shared session@(Session ref) dflags = do
  -- GHC reads the databases only if the session has none.
  pathEnv <- lookupEnv "GHC_PACKAGE_PATH"
  let paths = dbPaths dflags
  known <- readMVar (shDbs shared)
  let cached = if isJust pathEnv then Nothing else mapM (`M.lookup` known) paths
  mapM_ (\c -> modifyIORef' ref (\hsc -> hsc{hsc_unit_env = withUnitDbs c (hsc_unit_env hsc)})) cached
  unGhc (setSessionDynFlags dflags >> pure ()) session
  unless (isJust cached || isJust pathEnv) $ do
    new <- fromMaybe [] . ue_unit_dbs . hsc_unit_env <$> readIORef ref
    -- Don't keep them if GHC also read the user's database.
    when (map unitDatabasePath new == paths) $
      modifyMVar_ (shDbs shared) (\m -> pure (M.union m (M.fromList [(unitDatabasePath db, db) | db <- new])))

-- | The session's environment for one-shot compiles (see Note [One-shot
-- sessions]): with the external state of its flavour, the unit state of
-- the first session made with its flags, and no module graph.
oneShotEnv :: Shared -> Request -> HscEnv -> IO HscEnv
oneShotEnv shared r hsc = do
  let dflags = hsc_dflags hsc
      ue = hsc_unit_env hsc
      unit = ue_currentUnit ue
      hue = ue_findHomeUnitEnv unit ue
  external <- sharedAt (shExternal shared) (flavour r dflags) initExternalUnitCache
  (units, home) <- sharedAt (shUnits shared) (sessionFlags r) (pure (homeUnitEnv_units hue, homeUnitEnv_home_unit hue))
  let ue' = ue_updateHomeUnitEnv (\h -> h{homeUnitEnv_units = units, homeUnitEnv_home_unit = home}) unit ue
  pure (withModuleGraph emptyMG (hscSetFlags dflags{ghcMode = OneShot} hsc{hsc_unit_env = ue'{ue_eps = external}}))

-- | The value at the key in the shared map, made and added if it has none.
sharedAt :: Ord k => MVar (M.Map k v) -> k -> IO v -> IO v
sharedAt var k make = modifyMVar var $ \m -> case M.lookup k m of
  Just v -> pure (m, v)
  Nothing -> make >>= \v -> pure (M.insert k v m, v)

-- | What the interfaces that a one-shot session reads depend on, besides
-- their modules:
--
-- - the build's configuration, since two configurations build a module with
--   the same unit id, but maybe with different interfaces;
-- - the way, and so the interfaces' suffix;
-- - whether GHC ignores interface pragmas, as it does at -O0.
--
-- buck2 puts each configuration's outputs under
-- buck-out/v2/art/<cell>/<configuration hash>. Outside that layout (in the
-- worker's own tests, say), each target has a flavour of its own.
flavour :: Request -> DynFlags -> String
flavour r dflags = unwords [configuration, hiSuf_ dflags, show (ways dflags), show (gopt Opt_IgnoreInterfacePragmas dflags)]
  where
    configuration = case break (== "art") (splitDirectories (reqOutDir r)) of
      (before, art : cell : hash : _) -> joinPath (before ++ [art, cell, hash])
      _ -> reqOutDir r

-- | The paths of the package databases that GHC reads for the flags, in
-- GHC's order (as in its getUnitDbRefs). The user's database is left out,
-- since GHC reads it only if it exists.
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

-- | The unit environment, with the given package databases for its current
-- unit, which GHC then uses instead of reading them.
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

-- | A new directory for a session's temporary files, in the system's.
newTmpDir :: IO FilePath
newTmpDir = do
  base <- getTemporaryDirectory
  pid <- getProcessID
  n <- hashUnique <$> newUnique
  let dir = base </> ("ghc-worker-" ++ show pid ++ "-" ++ show n)
  createDirectory dir
  pure dir

-- | Compile the request's module, reporting its diagnostics with the given
-- action, then write its ABI and dep files. Returns the node compiled.
compile :: GhcSession -> (Diagnostic -> IO ()) -> Request -> IO Node
compile s report r = maybe id (\l -> withMVar l . const) (gsInterpLock s) (compileHeld s report r)

compileHeld :: GhcSession -> (Diagnostic -> IO ()) -> Request -> IO Node
compileHeld s report r = do
  mapM_ (createDirectoryIfMissing True) (reqMkdirs r)
  let hsc0 = gsEnv s
  ems <- summariseFile hsc0 (hsc_home_unit hsc0) M.empty (reqSource r) Nothing Nothing
  ms1 <- either (throwErrors . fmap GhcDriverMessage) pure ems
  -- Before GHC 9.12, summariseFile treats a boot file as a module, so we
  -- mark it as a boot file ourselves.
  let ms0
        | reqBoot r && ms_hsc_src ms1 /= HsBootFile = ms1{ms_hsc_src = HsBootFile, ms_location = addBootSuffixLocnOut (ms_location ms1)}
        | otherwise = ms1
  -- Use the request's own output directories for the .hie file and the
  -- stub header of foreign exports. The session's flags have neither, so
  -- GHC would put them next to the source.
  withHie <- case dropWhile (/= "-hiedir") (reqModuleArgs r) of
    _ : dir : _ -> do
      let file = dir </> reqModPath r <.> (if reqBoot r then "hie-boot" else "hie")
      createDirectoryIfMissing True (takeDirectory file)
      pure ms0{ms_location = (ms_location ms0){ml_hie_file = file}}
    _ -> pure ms0
  -- And the request's own object and interface files, which are where GHC
  -- would put them by the module's name, except for a Main module in a file
  -- named otherwise.
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
  -- A one-shot compile reads its home modules into the external state, so
  -- its home package table is empty. It must be a new table each time,
  -- since from GHC 9.14 compileOne adds the module it compiled to the
  -- table. Its module graph is the one `ghc -c` would give it.
  (hsc, below) <-
    if gsOneShot s
      then (\e -> (e, Below Set.empty Set.empty)) <$> (emptyHome (gsEnv s) >>= (`withOneShotModuleGraph` ms))
      else homeView s r ms
  -- The compile's own temporary files (its assembly, say) are removed when
  -- it finishes. Those that last as long as the session are merged into
  -- the session's, as `--make -j` does for each module. Its diagnostics go
  -- to the request.
  tmpfs <- forkTmpFsFrom (hsc_tmpfs hsc)
  let logger = pushLogHook (\_ lf cls _ doc -> report (Diagnostic (isError cls) (renderWithContext (log_default_user_context lf) doc))) (hsc_logger hsc)
  hmi <- compileOne hsc{hsc_tmpfs = tmpfs, hsc_logger = logger} ms 1 1 Nothing emptyHomeModInfoLinkable
    `finally` (cleanCurrentModuleTempFiles (hsc_logger hsc) tmpfs >> mergeTmpFsInto tmpfs (hsc_tmpfs hsc))
  let n = (ms_mod_name ms, if reqBoot r then IsBoot else NotBoot)
  unless (gsOneShot s) $ modifyMVar_ (gsHomes s) (pure . compiled n below hmi)
  writeDepFiles r (hm_iface hmi)
  pure n
  where
    isError cls = case cls of
      MCDiagnostic SevError _ _ -> True
      MCFatal -> True
      _ -> False

-- | A home module as an interface: its boot interface or the whole module.
type Node = (ModuleName, IsBootInterface)

-- | What a session keeps of its home modules: their interfaces (and
-- objects), each read once, and the home package table entries made from
-- them. An entry is keyed by its node and the set of boot interfaces below
-- it, and kept with the set of nodes below it. See Note [Each compile's
-- home modules].
data Homes = Homes
  { hIfaces :: M.Map Node (ModIface, HomeModLinkable)
  , hEntries :: M.Map (Node, Set.Set ModuleName) (HomeModInfo, Set.Set Node)
  }

-- | Record a module compiled in the session, with what was below it in its
-- compile. Its interface and entry replace those from its last compile, and
-- the entries of the modules above it are dropped.
compiled :: Node -> Below -> HomeModInfo -> Homes -> Homes
compiled n below hmi h =
  Homes
    { hIfaces = M.insert n (hm_iface hmi, hm_linkable hmi) (hIfaces h)
    , hEntries = M.insert (n, bootsBelow below) (hmi, nodesBelow below) (M.filterWithKey (\(m, _) (_, nodes) -> m /= n && not (n `Set.member` nodes)) (hEntries h))
    }

-- | The session's environment, with the home package table that the
-- compile should see (see Note [Each compile's home modules]): the home
-- modules below its imports, and its own boot interface. Each module is in
-- the form `ghc -c` would see: whole, or as its boot interface. The
-- exceptions are the modules the request names to link, which are whole,
-- as GHC's --make sees them. Also returns what is below its imports (see
-- 'compiled').
homeView :: GhcSession -> Request -> ModSummary -> IO (HscEnv, Below)
homeView s r ms = modifyMVar (gsHomes s) $ \homes0 -> do
  let hsc = gsEnv s
      unit = homeUnitId (hsc_home_unit hsc)
      own = ms_mod_name ms
  -- An import that names another package (PackageImports) isn't of a home
  -- module, even if a home module has the same name.
  imports <- fmap concat . forM (ms_textual_imps ms) $ \imp -> do
    let (mn, pkg) = importName imp
    found <- findImportedModule hsc mn pkg
    pure [mn | Found _ m <- [found], isHomeModule (hsc_home_unit hsc) m]
  let sources = map srcImportName (ms_srcimps ms)
  ownBoot <- if reqBoot r then pure False else doesFileExist (ml_hi_file (addBootSuffixLocn (ms_location ms)))
  homes1 <- foldM (\h mn -> ifaceOf hsc h (mn, NotBoot)) homes0 imports
  -- Which modules are seen as boot interfaces, reckoned as GHC does in its
  -- rnImports: from the boot files recorded below each import, where a
  -- module imported whole anywhere is seen whole. The modules to link are
  -- whole too. A module found only below them, which no import's record
  -- covers, takes the form it is imported in.
  let recordedBelow mn = M.fromList [(gwib_mod b, gwib_isBoot b) | (u, b) <- Set.toList (dep_boot_mods (mi_deps (fst (hIfaces homes1 M.! (mn, NotBoot))))), u == unit]
      recorded = M.unionsWith min (map recordedBelow imports ++ [M.fromList [(mn, IsBoot) | mn <- sources]])
      links = map mkModuleName (reqLinks r)
      bootness = M.fromList [(mn, NotBoot) | mn <- imports ++ links] `M.union` M.insert own IsBoot recorded
      node mn b = (mn, M.findWithDefault b mn bootness)
      roots = [node mn NotBoot | mn <- imports ++ links] ++ [node mn IsBoot | mn <- sources]
  -- The modules below, each with the modules it imports and those whose
  -- boot files are recorded below it. We need the latter because an
  -- unfolding in its interface may mention one of them even though it
  -- doesn't import it (say, an INLINE function of a module it imports,
  -- which uses one). Before GHC 9.14 an entry is typechecked against the
  -- table as it is when the entry is added, so those modules must be there
  -- already.
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
  -- Build the table in dependency order, reusing the entries of earlier
  -- compiles that have the same boot interfaces below them. The exception
  -- is the modules above the compile's own boot interface. The compile
  -- ties the knot of its references to itself in their interfaces, as
  -- `ghc -c` does, so they are typechecked again for it, as --make does.
  -- See Note [Modules above the compile's boot interface].
  knot <- newIORef emptyTypeEnv
  let withKnot e = e{hsc_type_env_vars = knotVarsFromModuleEnv (mkModuleEnv [(ms_mod ms, knot)])}
      ownBootNode = [(own, IsBoot) | ownBoot]
  env0 <- emptyHome hsc
  (homes3, env, below) <- foldM (addScc graph ownBootNode withKnot) (homes2, env0, M.empty) (stronglyConnComp [(n, n, deps) | (n, deps) <- M.toList graph])
  pure (homes3, (withKnot env, Below (Set.unions [bootsBelow (below M.! n) | n <- roots]) (Set.unions [nodesBelow (below M.! n) | n <- roots])))

-- | What is below a node of a compile's view, itself included: the boot
-- interfaces, and the nodes.
data Below = Below {bootsBelow :: Set.Set ModuleName, nodesBelow :: Set.Set Node}

-- | Add a strongly connected component of the view's graph to its table.
-- The components below it must be there already. A component is one
-- module, or whole modules that import one another through boot files. The
-- members above the given boot interface are typechecked with the given
-- knot, for this compile alone (see Note [Modules above the compile's boot
-- interface]).
addScc :: M.Map Node [Node] -> [Node] -> (HscEnv -> HscEnv) -> (Homes, HscEnv, M.Map Node Below) -> SCC Node -> IO (Homes, HscEnv, M.Map Node Below)
addScc graph ownBoot withKnot (h, env, below) scc = do
  let members = flattenSCC scc
      outside = [below M.! d | m <- members, d <- graph M.! m, d `notElem` members]
      -- What is below each member, but the member itself: its key among
      -- the entries.
      under = Below (Set.fromList [fst d | m <- members, d <- graph M.! m, snd d == IsBoot] <> Set.unions (map bootsBelow outside)) (Set.unions (map nodesBelow outside))
      selfBelow m = Below (Set.fromList [fst m | snd m == IsBoot] <> bootsBelow under) (Set.fromList members <> nodesBelow under)
      below' = foldr (\m -> M.insert m (selfBelow m)) below members
      aboveOwnBoot = any (`Set.member` nodesBelow under) ownBoot
  case mapM (\m -> fst <$> M.lookup (m, bootsBelow under) (hEntries h)) members of
    _ | aboveOwnBoot -> do
      (env', _) <- addHomes (withKnot env) [hIfaces h M.! m | m <- members]
      pure (h, env'{hsc_type_env_vars = hsc_type_env_vars env}, below')
    Just hmis -> do
      env' <- foldM (\e (m, hmi) -> insertHome e (fst m) hmi) env (zip members hmis)
      pure (h, env', below')
    -- The compile's own boot interface, made in its table, isn't kept for
    -- others: see Note [The compile's own boot interface].
    Nothing | members == ownBoot -> do
      (env', _) <- addHomes env [hIfaces h M.! m | m <- members]
      pure (h, env', below')
    Nothing -> do
      (env', hmis) <- addHomes env [hIfaces h M.! m | m <- members]
      let entries = foldr (\(m, hmi) -> M.insert (m, bootsBelow under) (hmi, nodesBelow under <> Set.fromList members)) (hEntries h) (zip members hmis)
      pure (h{hEntries = entries}, env', below')

-- | Add the node's interface and object to the session's, reading them
-- from disk, if they aren't there yet.
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
        _ -> throwGhcExceptionIO (ProgramError ("ghc-worker: no interface for home module " ++ moduleNameString (fst n)))

readIface :: HscEnv -> FilePath -> IO ModIface
readIface hsc = readBinIface (targetProfile (hsc_dflags hsc)) (hsc_NC hsc) IgnoreHiWay QuietBinIFace

-- | `try`, except that asynchronous exceptions (a request cancelled, the
-- worker ending) are rethrown.
tryNonAsync :: IO a -> IO (Either SomeException a)
tryNonAsync act = do
  result <- try act
  case result of
    Left e | Just (_ :: SomeAsyncException) <- fromException e -> throwIO e
    _ -> pure result

{- Note [The session's state]

1. The problem

To compile a module, GHC needs the interfaces of the home modules (the
modules of the same package) that it imports. GHC has two ways to get them:

  - One-shot mode (`ghc -c`) reads them from disk into its cache of
    external interfaces, the same cache it uses for other packages' modules.
  - --make mode expects them in the compile's home package table (HPT), and
    finds their instances (and, for Template Haskell, their objects) through
    the session's module graph.

One-shot mode is simpler for the worker, but its cache can't cope with
boot files: it has no notion of a module's boot interface being replaced
by the full module. Once a {-# SOURCE #-} import of B has put B's boot
interface in the cache, B's own compile sees the boot interface's
instances as another module's, and a later import of B may be given the
boot interface instead of the module.

2. The solution

So a session uses one-shot mode if its target has no boot files (see Note
[One-shot sessions]), and --make mode if it has. In --make mode:

  - The module graph is GHC's dependency analysis of the whole target, made
    from its source tree when the session is made. The worker only uses it
    to tell which modules depend on which.
  - The HPT is each compile's own (see Note [Each compile's home modules]).
    It is made from what the session keeps: the home modules' interfaces,
    each read from disk once or kept from the session's own compiles, and
    the HPT entries made from them.

3. The road not taken

One-shot mode with a cache of its own for each compile, as each `ghc -c`
has, doesn't do instead. We tried it, and a module with a boot file then
failed in ways `ghc -c` doesn't: its own boot interface's instances were
duplicates, or GHC read its own interface before it was written. We
didn't find out why; the session's name cache, which the compiles still
share, is the likely cause. Nor can one-shot mode run a splice that links
code behind a boot file whose boot interface the compile has read, which
--make mode can (see Note [Each compile's home modules]).
-}

{- Note [One-shot sessions]

1. The problem

Each session reads the interfaces its compiles need (the libraries' and
those of the target's dependencies in the build) into an external package
state of its own. A large build makes thousands of sessions,
since the worker drops idle sessions and makes them again when their
target needs them (see Note [Dropping the idle sessions] in Worker), and
each session reads much the same interfaces again: base's, say, in every
one.

2. The solution

A session whose target has no boot files compiles in one-shot mode, as
`ghc -c` does (see Note [The session's state]), and shares its external
state with every other such session of the same flavour: the build's
configuration and way, and whether GHC ignores interface pragmas (see
'flavour'). An interface is then read once in the worker's life, however
many sessions use it. In one-shot mode GHC reads the target's own modules
into the external state too, so the session keeps no home package table,
and its compiles write exactly what `ghc -c` writes.

That is the worker's default session mode, auto. Mode make (--make for
every target) turns the sharing off, and mode one-shot refuses the targets
with boot files; the tests use both, to test each kind of session on every
target they can.

3. What the shared state keeps alive

GHC typechecks an interface's declarations lazily, and a declaration not
typechecked yet keeps the environment of the compile that read it, and so
its session's unit state: what GHC knows of the packages, a few MB. So the
shared state keeps alive every session that has read anything into it.
Hence the sessions of a target with the same flags share the unit state of
the first of them. That bounds what the shared state keeps alive by the
number of targets, rather than the number of sessions. For the same
reason, a one-shot session keeps no module graph, which holds the target's
sources.

The shared state is never emptied: for a large build it holds several GB
of interfaces. Replacing it with a fresh one now and then doesn't help:
an old state lives until its last session is dropped, and the fresh ones
read the same interfaces again.

4. The alternatives

A session with a home unit for each target in the build (as `ghc --make`
with several -unit flags) would share the interfaces too, without lazy
declarations keeping sessions alive. But a module's interface would then
record other targets' modules as home modules, not as a package's, and so
differ from what `ghc -c` writes. And each compile would need the module
graphs of its dependencies, which GHC makes from their sources.

5. Measurements

On the bench (bench/Main.hs) at -j8, where the worker makes sessions again
(`cabal bench --benchmark-options='8 3 project many'`, with the default
limit of 16 sessions):

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

GHC decides which from the interfaces of X's imports, which record it
(dep_boot_mods). The choice affects what X's compile sees, and so X's
interface and object.

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
entry's contents lazily. So the session caches the entries, and reuses one
for any compile that has the same boot interfaces beneath it. When the
session compiles a module, it discards that module's entries and those of
everything that depends on it. Modules in an import cycle (through boot
files) are added together, as GHC's --make does (see addHomes).

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

{- Note [Modules above the compile's boot interface]

1. The problem

Say module M has a boot file, M.hs-boot, and module A imports M with
{-# SOURCE #-}, while M imports A: a cycle, broken by the boot file. A's
interface then mentions M's things, and so may the unfoldings in it (the
code of A's that GHC may inline elsewhere).

When `ghc -c` compiles M, it reads A's interface while it typechecks M, and
ties those mentions to the M it is compiling, through the compile's "knot"
(hsc_type_env_vars). So if M inlines a function of A's that calls M.x, the
inlined code calls M's own x, and GHC correctly sees a recursion. GHC's
--make gets the same result by typechecking A again, with the knot, before
it compiles M (it calls this "rehydrating": see GHC's Note [Hydrating
Modules]).

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

So when the worker compiles M, the HPT has M's boot interface in it (GHC
checks M against it). If the entry for that boot interface is only
typechecked after the compile, it finds the full M in the HPT, and takes
M's things for its own: its instances become M's, unfoldings and all. A
module that later imports M {-# SOURCE #-} and inlines one of them then
refers to something the boot interface doesn't have, and GHC panics
("lookupVers1").

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

The worker refuses to make a session with any of these flags, and puts
back the global that parsing its flags has just set. A target that needs
them must be compiled without the worker. (The same flags in an OPTIONS_GHC
pragma don't reach the globals, in `ghc -c` or here, so they are fine.)
-}

{- Note [Compiling whenever buck2 asks]

buck2 decides when a module needs compiling again, from the module's dep
file (see Note [Early cut-off by dep files] in compile_per_module.bzl). So the
worker should compile every request it gets, and never let GHC decide that the
module is up to date.

buck2 already removes an action's previous outputs before running it, so
GHC normally finds no old interface to compare with. The worker also passes
-fforce-recomp (see sessionFlags), whatever is on disk, as does the compile
tool without the worker.

This matters for Template Haskell. A splice can read a file without
recording it (runIO, without addDependentFile), so the module's interface
doesn't list it, and GHC's check would find the module up to date after the
file changed, and keep its old object. Whenever buck2 asks for such a
module, the worker compiles it.
-}

{- Note [A temporary directory per session]

1. The problem

To run a splice, GHC links the objects it needs into a temporary shared
library, and loads it with dlopen. The library's file name comes from a
counter in the session's temporary-file state, and each new session starts
counting again. But the dynamic linker caches libraries by path: if it has
loaded a library from a path before, dlopen returns that library again,
even if the file there is new.

So after the worker dropped a session (and removed its files), a new
session could create a library at a path an old session had already
loaded. Its splice would get the old library, and fail to find the new
one's symbols ("During interactive linking, GHCi couldn't find the
following symbol").

2. The solution

Each session puts its temporary files in a directory of its own, which is
never reused.
-}

{- Note [Hashing the libraries]

1. The problem

For each module that runs Template Haskell, GHC records a hash of every
Haskell library (hs-libraries) and object the interpreter loaded
(`mkObjectUsage`), and caches the hashes in the session's finder cache.
Each library is a few megabytes, so hashing is slow, and in the worker it
would happen far too often:

  - each session has its own cache, and a target may have several sessions
    in a build (a dropped session is made again, see Worker);
  - modules compiled at the same time in one session all miss the cache
    together, and each hashes every library.

2. The solution

All the sessions share one cache of hashes for the life of the worker, and
look a hash up under a lock, so that one compile hashes each library while
the others wait for it (see sharedFileHashes). Before GHC 9.12 the cache's
lookup can't be replaced, so the sessions share the cache without the
lock, and compiles that miss it at the same time each hash the library.

Caching for the worker's whole life is safe, because the libraries don't
change while it lives: buck2 writes each output once in a build, and a
worker lives for one build (buck2 starts a worker for each command, which
the rules' tests check).
-}

{- Note [One copy of each package database]

1. The problem

A session reads its package databases from disk when it is made: each
library's own, and the third-party packages', which describe hundreds of
packages. A whole build makes thousands of sessions, and each would keep its
own copy of the databases while it lives, though most of them are the same.

2. The solution

The worker keeps every database it has read, by path, for its whole life,
and gives a new session the copies of its databases, which GHC then uses
instead of reading them (as it does when a session's flags are set again).
A session whose databases aren't all kept yet has GHC read them, and the
worker keeps those it read.

Keeping them for the worker's life is safe for the same reason as in Note
[Hashing the libraries]: buck2 writes each database once in a build. If a
session would read the user's database, or the databases of
GHC_PACKAGE_PATH, which aren't the rules', the worker leaves it to GHC.
-}

{- Note [One name cache for all the sessions]

1. The problem

GHC gives each entity it reads from an interface a Name: the entity's
module and name, and a unique number. The name cache maps each module and
name to its Name, so that every interface that mentions an entity gets the
same one. A session made with GHC's API has a name cache of its own. So
when many sessions read the same libraries' interfaces, as they do in a
clean build of a large project, each holds its own Names for all of them,
and its own cache of them.

2. The solution

All the sessions share the name cache of the worker's own session (see
withWorker), as all the home units of a multi-unit `ghc --make` do. An
entity has the same module and name in every session, and so can have the
same Name: a module of a target is home in the target's sessions and comes
from a package db in its dependents', but it is the same module, with the
same unit id. The cache takes a lock to change, as it must for the
threads of `--make -j`. The Names a dropped session read stay in the cache,
but a later session would read most of them again.

One-shot sessions need the shared cache, since they share interfaces (see
Note [One-shot sessions]): the Names in those must be the ones every
session would make. For --make sessions it saves a little: on the bench's
`project`, a worker patched to give each --make session a cache of its own
took the same time, with 5-7% more peak memory and 2-4% more CPU.
-}
