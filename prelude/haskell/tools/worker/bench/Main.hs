-- | A benchmark that builds generated packages in several ways, and reports
-- the time and memory that each way takes. The ways, as BENCH_WAYS names
-- them, are:
--
-- - make: one `ghc --make -jN` for the whole workload. For a workload of
--   several targets, this is one multi-unit build, which neither buck2 nor
--   cabal does. So it shows the best that one GHC process can do, rather
--   than being a practical alternative.
-- - per-target: one `ghc --make` per target, as the rules compile a target
--   without per_module. This is only run for workloads of several targets.
--   Each target is compiled once the targets it depends on are, at most N
--   at a time, and without -j, since the rules don't pass one.
-- - ghc-c: one `ghc -c` per module, as the rules compile per-module without
--   the worker.
-- - worker: through the worker, in its default session mode.
-- - worker-make: through the worker, with --make sessions only.
--
-- With ghc-c and the workers, each module is compiled as soon as the
-- modules it imports have been, whether they are in its own target or
-- another (early package dbs let the rules do this too). At most N modules
-- compile at a time, as when buck2 runs the modules' actions with -j N. A
-- fresh worker gets one request per module, with the arguments the rules
-- send.
--
-- Each way builds the workload from scratch, then again after each of a few
-- edits (see edits). On each rebuild, it compiles what it would compile in
-- practice:
--
-- - make: whatever GHC's own recompilation check finds out of date.
-- - per-target: the edited module's target, and each target with a
--   dependency whose interfaces changed, each from scratch, as buck2 runs
--   them.
-- - ghc-c and the workers: the edited module, and each module with an
--   import whose ABI changed, as buck2 decides from the dep files.
--
-- For each build, the bench reports:
--
-- - the wall time;
-- - the CPU time of the worker or GHC processes, and their children;
-- - where a single process does the build, its peak memory, its largest
--   live heap and the wall time it spent collecting garbage, from its RTS
--   statistics. The live heap is only measured at major collections, so it
--   varies from run to run;
-- - for the worker, the number of sessions it made;
-- - for the builds that the bench schedules itself (all but make), the
--   critical path: the least time the build could take with unlimited
--   cores (see schedule);
-- - for make and the workers, the CPU time of the process's mutator and of
--   its collections.
--
-- usage: bench [N] [REPETITIONS] [WORKLOAD...]
--
-- N defaults to 8 and REPETITIONS to 1. The worker and GHC are found as in the
-- test suite (BUCK2_GHC_WORKER, GHC). GHC_FLAGS gives the compiles' flags, -O
-- by default. BUCK2_GHC_WORKER_RTS gives the worker's RTS options, by default
-- those that the rules give the shared worker. The worker inherits the bench's
-- environment, so its own settings, such as BUCK2_GHC_WORKER_SESSIONS, can be
-- set there. BENCH_WAYS lists the ways to build, by default all of them, in
-- the order above. The workloads are:
--
-- - wide: many modules, none of which imports another.
-- - deep: layers of modules, each importing every module of the layer
--   below.
-- - th: modules with splices that run only template-haskell's code. They
--   are compiled with -dynamic, because GHC is dynamically linked and so
--   loads dynamic objects to run a splice.
-- - th-heavy: th, with a large set of packages exposed, whose libraries
--   GHC's interpreter loads before it runs any splice.
-- - many: many targets, in layers, each depending on two targets of the
--   layer below. Each target is a chain of modules, which import large
--   interfaces of the ghc package as well as modules of the targets it
--   depends on. So many targets are part-built at once, as in a clean build
--   of a large project. This is the workload that tests the worker's
--   memory.
-- - project: the same targets as many, but each with a few layers of
--   several modules rather than a chain, which is more like a project's
--   libraries.
-- - chain: ten targets, each depending on the one before, as in a stack of
--   libraries, and each with layers of a few modules. A `ghc --make` per
--   target must build them one at a time. But from the target below, a
--   module only imports the module in the same place there, so per-module
--   builds of the targets can overlap.
module Main (main) where

import Control.Concurrent (forkIO)
import Control.Concurrent.MVar
import Control.Concurrent.QSem
import Control.Exception (SomeException, bracket_, finally, try)
import Control.Monad (forM, forM_, unless, when)
import qualified Data.ByteString as B
import Data.IORef
import Data.List (isInfixOf)
import qualified Data.Map as M
import qualified Data.Set as Set
import Data.Maybe (fromMaybe)
import GHC.Clock (getMonotonicTime)
import System.Directory
import System.Environment (getArgs, lookupEnv)
import System.Exit (ExitCode (..), exitFailure)
import System.FilePath ((<.>), (</>))
import System.IO (BufferMode (..), IOMode (..), hPutStrLn, hSetBuffering, stderr, stdout, withFile)
import System.Posix.Process (ProcessTimes (..), getProcessID, getProcessTimes)
import System.Posix.Unistd (SysVar (..), getSysVar)
import System.Process
import Text.Printf (printf)
import Text.Read (readMaybe)

import Client
import Contract (contract)
import Interface (abiHash, readInterface)

-- | A generated workload: its targets, and the flags its compiles need
-- beyond the common ones.
data Workload = Workload {wName :: String, wTargets :: [Target], wFlags :: [String]}

-- | A target of a workload. tDir is the target's subdirectory of the
-- workload's directory, which is also its unit id. It is empty for a
-- workload of one target. tDeps are the targets it depends on. tModules are
-- its modules, each with its name, the names of the modules it imports
-- (from any target), and its source.
data Target = Target {tDir :: FilePath, tDeps :: [FilePath], tModules :: [(String, [String], String)]}

workloads :: [Workload]
workloads =
  [ one "wide" [(m i, [], body m i []) | i <- [1 .. 200 :: Int]] []
  , one "deep" [(l k i, below k, body (l k) i (below k)) | k <- [1 .. 20 :: Int], i <- [1 .. 8]] []
  , one "th" splicers th
    -- The same modules, but with the ghc and Cabal packages exposed. The
    -- interpreter loads the libraries of these and all the packages they
    -- depend on before it runs any splice.
  , one "th-heavy" splicers (th ++ ["-package", "ghc", "-package", "Cabal"])
  , layered "many" "Many" 12 1 tiers
  , layered "project" "Project" 4 4 tiers
  , layered "chain" "Chain" 8 2 ([(k, 1) | k <- [1 .. 10]], \k i -> [(k - 1, i) | k > 1])
  ]
  where
    one name modules = Workload name [Target "" [] modules]
    m i = "W" ++ show i
    l k i = "L" ++ show k ++ "_" ++ show i
    s i = "S" ++ show i
    splicers = [(s i, [], splicing i) | i <- [1 .. 100 :: Int]]
    th = ["-dynamic", "-package", "template-haskell"]
    below k = [l (k - 1) j | k > 1, j <- [1 .. 8 :: Int]]
    -- The splices run only template-haskell's code, because per-module
    -- compiles can't run code of the build's own modules (see Note
    -- [Template Haskell modules] in compile_per_module.bzl).
    splicing i = case lines (body s i []) of
      header : rest -> unlines (["{-# LANGUAGE TemplateHaskell #-}", header, "import Language.Haskell.TH"] ++ rest ++ ["$(sequence [funD (mkName (\"g\" ++ show k)) [clause [] (normalB (litE (integerL (k * " ++ show i ++ ")))) []] | k <- [1 .. 20 :: Integer]])"])
      [] -> ""
    -- Three layers of ten targets. Target i of layer k depends on targets i
    -- and i + 1 (wrapping around) of the layer below.
    tiers = ([(k, i) | k <- [1 .. 3], i <- [1 .. 10]], \k i -> [(k - 1, i') | k > 1, i' <- [i, i `mod` 10 + 1 :: Int]])
    -- A workload of the targets (k, i) in `targets`, where `lower k i` gives
    -- the targets that (k, i) depends on. Each target has `depth` layers of
    -- `width` modules. A module imports every module of the layer below it
    -- in its own target, and the module in the same place in each target
    -- that its target depends on. So a target's modules can start
    -- compiling while the targets it depends on are still being compiled.
    layered name prefix depth width (targets, lower) =
      Workload name [Target (t k i) (deps k i) [(c k i a b, imports k i a b, heavy (c k i a) b (imports k i a b)) | a <- [1 .. depth], b <- [1 .. width]] | (k, i) <- targets] ["-package", "ghc"]
      where
        t :: Int -> Int -> FilePath
        t k i = name ++ show k ++ "t" ++ show i
        c :: Int -> Int -> Int -> Int -> String
        c k i a b = prefix ++ show k ++ "T" ++ show i ++ "L" ++ show a ++ "M" ++ show b
        deps k i = [t k' i' | (k', i') <- lower k i]
        imports k i a b = [c k i (a - 1) b' | a > 1, b' <- [1 .. width]] ++ [c k' i' a b | (k', i') <- lower k i]
    -- A module that uses GHC's API. GHC's interfaces are many and large,
    -- and every session has to read them, as the sessions of a real project
    -- read the interfaces of its libraries.
    heavy name i imports = case lines (body name i imports) of
      header : rest ->
        unlines $
          [header, "import qualified GHC"]
            ++ rest
            ++ [ "flags :: GHC.Ghc GHC.DynFlags"
               , "flags = GHC.getSessionDynFlags"
               , "modName :: GHC.ModuleName"
               , "modName = GHC.mkModuleName " ++ show (name i)
               , "graph :: GHC.Ghc [GHC.ModSummary]"
               , "graph = GHC.mgModSummaries <$> GHC.getModuleGraph"
               ]
      [] -> ""

-- | A module of a realistic size: a data type with derived instances, and
-- functions over it. Its `total` also uses the `total` of each import.
body :: (Int -> String) -> Int -> [String] -> String
body name i imports =
  unlines $
    ["module " ++ name i ++ " where", "import qualified Data.Map.Strict as Map"]
      ++ ["import qualified " ++ d | d <- imports]
      ++ [ "data T = A Int | B String | C [T] | D (Map.Map Int T) deriving (Show, Eq, Ord)"
         , "size :: T -> Int"
         , "size (A n) = n"
         , "size (B s) = length s"
         , "size (C ts) = sum (map size ts)"
         , "size (D m) = Map.foldr (\\t n -> n + size t) 0 m"
         , "build :: Int -> T"
         , "build 0 = A " ++ show i
         , "build n = C [D (Map.fromList [(k, build (n - 1)) | k <- [1 .. 3]]), B (show n)]"
         , "total :: Int"
         , "total = size (build 4)" ++ concat [" + " ++ d ++ ".total" | d <- imports]
         ]

-- | An edit before a rebuild: a label that describes it, the target and
-- name of the module it changes, and the module's source after the edit and
-- as generated.
data Edit = Edit {eLabel :: String, eTarget :: Target, eModule :: String, eSource :: String, eOriginal :: String}

-- | The edits made before the rebuilds. They are made in turn, each on top
-- of those before:
--
-- - A comment in the first module of the first target, which the rest of
--   the workload builds on. The module's ABI stays the same.
-- - A new definition in the same module. This changes its ABI, so the
--   modules that import it compile again, but their own ABIs don't change.
-- - A new definition in the last module of the last target, which nothing
--   imports, as with most edits to a project's own code.
--
-- The Template Haskell workloads get no edits. Their modules import none of
-- the others, so an edit would only compile the module it changes.
edits :: Workload -> [Edit]
edits w
  | "template-haskell" `elem` wFlags w = []
  | otherwise = case (wTargets w, reverse (wTargets w)) of
      (first : _, final : _)
        | (bottom, _, bsrc) : _ <- tModules first
        , (top, _, tsrc) : _ <- reverse (tModules final) ->
            [ Edit "a comment at the bottom" first bottom (bsrc ++ comment) bsrc
            , Edit "a new definition at the bottom" first bottom (bsrc ++ comment ++ definition) bsrc
            , Edit "a new definition at the top" final top (tsrc ++ definition) tsrc
            ]
      _ -> []
  where
    comment = "-- an edit\n"
    definition = "edited :: Int\nedited = 1\n"

sourceOf :: Target -> String -> FilePath
sourceOf t name = tDir t </> "src" </> name <.> "hs"

-- | What a build took.
data Measure = Measure
  { mWall :: Double
  , mCpu :: Double
  , mPeakMB :: Maybe Double -- the process's peak memory, as its RTS reports it
  , mLiveMB :: Maybe Double -- its largest live heap at a major collection
  , mGcS :: Maybe Double -- the wall time it spent collecting garbage
  , mSessions :: Maybe Int -- the sessions the worker made
  , mPathS :: Maybe Double -- the critical path (see schedule)
  , mSplit :: Maybe (Double, Double) -- the CPU time of the process's mutator and GC
  }

main :: IO ()
main = do
  -- Flush each line, so that a run's progress shows up when the output
  -- goes to a file.
  hSetBuffering stdout LineBuffering
  args <- getArgs
  let (n, reps, names) = case args of
        a : b : rest | Just x <- readMaybe a, Just y <- readMaybe b -> (x, y, rest)
        a : rest | Just x <- readMaybe a -> (x, 1, rest)
        rest -> (8, 1, rest)
      chosen = [w | w <- workloads, null names || wName w `elem` names]
  when (null chosen) $ hPutStrLn stderr ("no such workload: " ++ unwords names) >> exitFailure
  worker <- fromMaybe "buck2-ghc-worker" <$> lookupEnv "BUCK2_GHC_WORKER"
  ghc <- fromMaybe "ghc" <$> lookupEnv "GHC"
  flags <- maybe ["-O"] words <$> lookupEnv "GHC_FLAGS"
  -- The default is the RTS options that the rules give the shared worker (see
  -- per_module_worker_rts_options in prelude/haskell/per_module_worker.bzl).
  rts <- maybe ["-A64m", "-n4m", "-qn8", "-I5"] words <$> lookupEnv "BUCK2_GHC_WORKER_RTS"
  ways <- maybe ["make", "per-target", "ghc-c", "worker", "worker-make"] words <$> lookupEnv "BENCH_WAYS"
  printf "%-6s %-52s %8s %8s %9s %9s %8s %9s %8s  %s\n" "" "" "wall" "cpu" "peak MB" "live MB" "GC" "sessions" "path" "mut/GC cpu"
  forM_ chosen $ \w -> forM_ [1 .. reps :: Int] $ \_ -> withWorkload ghc w $ \dir -> do
    let common = ["-hide-all-packages", "-package", "base", "-package", "containers"] ++ wFlags w ++ flags
        -- Build from scratch, then rebuild after each edit, the edits
        -- accumulating. Afterwards, restore the original sources for the
        -- next way.
        run way how build what = when (way `elem` ways) $ do
          clean dir w
          fst <$> build Nothing >>= report w how
          forM_ (edits w) $ \e -> do
            writeFile (dir </> sourceOf (eTarget e) (eModule e)) (eSource e)
            (m, k) <- build (Just (eModule e))
            report w ("  after " ++ eLabel e ++ ": " ++ show k ++ " " ++ what) m
          forM_ (edits w) $ \e -> writeFile (dir </> sourceOf (eTarget e) (eModule e)) (eOriginal e)
    run "make" ("ghc --make -j" ++ show n) (make dir ghc n common w) "modules"
    when (length (wTargets w) > 1) $ run "per-target" ("ghc --make per target, " ++ show n ++ " at once") (perTarget dir ghc n common w) "targets"
    run "ghc-c" ("ghc -c, " ++ show n ++ " at once") (perModule dir ghc n common w) "modules"
    run "worker" ("worker, " ++ show n ++ " at once") (viaWorker dir worker rts ghc n common [] w) "modules"
    run "worker-make" ("worker --make, " ++ show n ++ " at once") (viaWorker dir worker rts ghc n common [("BUCK2_GHC_WORKER_SESSION_MODE", "make")] w) "modules"
  where
    report w how m =
      printf "%-6s %-52s %7.1fs %7.1fs %9s %9s %8s %9s %8s  %s\n" (wName w) how (mWall m) (mCpu m) (shown (mPeakMB m)) (shown (mLiveMB m)) (seconds (mGcS m)) (maybe "" show (mSessions m)) (seconds (mPathS m)) (maybe "" (\(a, b) -> printf "%.1fs/%.1fs" a b) (mSplit m) :: String)
    shown = maybe "" (\x -> show (round x :: Int))
    seconds = maybe "" (printf "%.1fs") :: Maybe Double -> String

-- | Write the workload's sources to a new temporary directory, and run the
-- action in it. If the workload has several targets, each one is
-- registered in the package database db before anything is compiled, with
-- its output directory as its import directory, as the rules register a
-- dependency's early package db.
withWorkload :: String -> Workload -> (FilePath -> IO a) -> IO a
withWorkload ghc w k = do
  tmp <- getTemporaryDirectory
  pid <- getProcessID
  let dir = tmp </> ("buck2-ghc-worker-bench-" ++ show pid)
  (setup dir >> k dir) `finally` removePathForcibly dir
  where
    setup dir = do
      removePathForcibly dir
      createDirectoryIfMissing True (dir </> "tmp")
      forM_ (wTargets w) $ \t -> do
        mapM_ (createDirectoryIfMissing True . (dir </>)) [tDir t </> "src", outDir t, tDir t </> "dep"]
        forM_ (tModules t) $ \(name, _, src) -> writeFile (dir </> tDir t </> "src" </> name <.> "hs") src
      _ <- readProcess (ghcPkgOf ghc) ["init", dir </> "db"] ""
      forM_ [t | t <- wTargets w, not (null (tDir t))] $ \t -> do
        let conf = dir </> tDir t <.> "conf"
        writeFile conf $
          unlines
            [ "name: " ++ tDir t, "version: 0", "id: " ++ tDir t, "key: " ++ tDir t, "exposed: True"
            , "exposed-modules: " ++ unwords [name | (name, _, _) <- tModules t]
            , "import-dirs: " ++ dir </> outDir t
            ]
        -- --force, because ghc-pkg refuses a package whose interfaces don't
        -- exist yet.
        (code, _, err) <- readProcessWithExitCode (ghcPkgOf ghc) ["register", "--force", "--package-db", dir </> "db", conf] ""
        unless (code == ExitSuccess) $ hPutStrLn stderr err >> exitFailure

-- | Remove every target's outputs and dep files.
clean :: FilePath -> Workload -> IO ()
clean dir w = forM_ (wTargets w) $ \t -> forM_ [outDir t, tDir t </> "dep"] $ \d -> do
  removePathForcibly (dir </> d)
  createDirectoryIfMissing True (dir </> d)

-- | Run the action, and return its wall time and CPU time with its result.
-- The CPU time only counts the child processes that the action waits for.
timed :: IO a -> IO (Double, Double, a)
timed act = do
  tick <- fromIntegral <$> getSysVar ClockTick
  let cpu = (\t -> fromIntegral (fromEnum (childUserTime t) + fromEnum (childSystemTime t)) / tick) <$> getProcessTimes
  c0 <- cpu
  t0 <- getMonotonicTime
  a <- act
  t1 <- getMonotonicTime
  c1 <- cpu
  pure (t1 - t0, c1 - c0, a)

-- | The RTS options that make GHC write its statistics to the given file.
rtsStats :: FilePath -> [String]
rtsStats file = ["+RTS", "-t" ++ file, "--machine-readable", "-RTS"]

readRtsSplit :: FilePath -> IO (Maybe (Double, Double))
readRtsSplit file = do
  text <- readFile file
  let stats = fromMaybe [] (readMaybe (unlines (drop 1 (lines text))) :: Maybe [(String, String)])
      value k = readMaybe =<< lookup k stats :: Maybe Double
  pure ((,) <$> value "mut_cpu_seconds" <*> value "GC_cpu_seconds")

readWorkerSplit :: FilePath -> IO (Maybe (Double, Double))
readWorkerSplit file = do
  ls <- lines <$> readFile file
  -- Force the whole file, so that it is closed before the next build
  -- overwrites it.
  length ls `seq` pure $ case [(m, g) | l <- ls, ["buck2-ghc-worker:", "CPU", "mutator", m, "ms,", "GC", g, "ms"] <- [words l]] of
    (m, g) : _ -> (,) <$> ms m <*> ms g
    [] -> Nothing
  where
    ms = fmap ((/ 1000) . fromIntegral) . (readMaybe :: String -> Maybe Int)

-- | Read the peak memory and largest live heap, in MB, and the seconds spent
-- collecting garbage, from the file that 'rtsStats' makes GHC write.
readRtsStats :: FilePath -> IO (Maybe Double, Maybe Double, Maybe Double)
readRtsStats file = do
  text <- readFile file
  -- The file has GHC's command line on its first line, and then a list of
  -- named values.
  let stats = fromMaybe [] (readMaybe (unlines (drop 1 (lines text))) :: Maybe [(String, String)])
      value k = readMaybe =<< lookup k stats :: Maybe Double
      mb k = (/ 2 ^ (20 :: Int)) <$> value k
  pure (mb "max_mem_in_use_bytes", mb "max_live_bytes", value "GC_wall_seconds")

-- | Read from a verbose worker's log the peak memory and largest live heap,
-- in MB, and the seconds spent collecting garbage, which the worker logs as
-- it ends if it runs with +RTS -T (see shutdown in Worker). Also count the
-- sessions it made, from the line it logs for each.
readWorkerLog :: FilePath -> IO (Maybe Double, Maybe Double, Maybe Double, Int)
readWorkerLog file = do
  ls <- lines <$> readFile file
  let memory = [(peak, live, gc) | l <- ls, ["buck2-ghc-worker:", "peak", "memory", peak, "MB,", "max", "live", live, "MB,", "GC", gc, "ms"] <- [words l]]
      number = fmap fromIntegral . (readMaybe :: String -> Maybe Int)
  pure $ case memory of
    (peak, live, gc) : _ -> (number peak, number live, (/ 1000) <$> number gc, sessions ls)
    [] -> (Nothing, Nothing, Nothing, sessions ls)
  where
    sessions = length . filter ("session for the flags" `isInfixOf`)

-- | Build the workload with one `ghc --make`. After an edit, GHC's own
-- recompilation check decides what to compile again. Also returns the
-- number of modules that GHC compiled.
make :: FilePath -> String -> Int -> [String] -> Workload -> Maybe String -> IO (Measure, Int)
make dir ghc n common w _ = do
  let stats = dir </> "make.stats"
      unit t = ["-no-link", "-i" ++ tDir t </> "src", "-odir", outDir t, "-hidir", outDir t] ++ common ++ concat [["-package-id", d] | d <- tDeps t] ++ [tDir t </> "src" </> name <.> "hs" | (name, _, _) <- tModules t]
  targets <- case wTargets w of
    [t] -> pure (unit t)
    ts -> forM ts $ \t -> do
      let file = dir </> tDir t <.> "unit"
      writeFile file (unwords (["-this-unit-id", tDir t] ++ unit t))
      pure ("-unit @" ++ file)
  (wall, cpu, (code, out, err)) <- timed $ readCreateProcessWithExitCode (proc ghc (["--make", "-j" ++ show n, "-no-link"] ++ concatMap words targets ++ rtsStats stats)){cwd = Just dir} ""
  unless (code == ExitSuccess) $ hPutStrLn stderr err >> exitFailure
  (peak, live, gc) <- readRtsStats stats
  split <- readRtsSplit stats
  pure (Measure wall cpu peak live gc Nothing Nothing split, length (filter ("Compiling " `isInfixOf`) (lines out)))

-- | Build each target with a `ghc --make` of its own. After an edit, build
-- the targets that buck2 would: the edited module's target, and each target
-- with a dependency whose interfaces changed, each from scratch. Also
-- returns the number of targets built.
perTarget :: FilePath -> String -> Int -> [String] -> Workload -> Maybe String -> IO (Measure, Int)
perTarget dir ghc n common w edit = do
  changed <- newMVar Set.empty
  count <- newIORef (0 :: Int)
  let job t = do
        dirty <- (\ch -> any (`Set.member` ch) (tDeps t)) <$> readMVar changed
        if maybe True (`elem` [name | (name, _, _) <- tModules t]) edit || dirty
          then do
            before <- interfaces t
            removePathForcibly (dir </> outDir t)
            createDirectoryIfMissing True (dir </> outDir t)
            r <- compile t
            after <- interfaces t
            when (after /= before) $ modifyMVar_ changed (pure . Set.insert (tDir t))
            atomicModifyIORef' count (\k -> (k + 1, ()))
            pure r
          else pure (True, "")
  (wall, cpu, path) <- timed $ schedule n [(tDir t, tDeps t, job t) | t <- wTargets w]
  k <- readIORef count
  pure (Measure wall cpu Nothing Nothing Nothing Nothing (Just path) Nothing, k)
  where
    compile t = do
      let out = outDir t
      (code, _, err) <- readCreateProcessWithExitCode (proc ghc (["--make", "-no-link", "-i" ++ tDir t </> "src", "-odir", out, "-hidir", out] ++ compileFlags common t ++ [tDir t </> "src" </> name <.> "hs" | (name, _, _) <- tModules t])){cwd = Just dir} ""
      pure (code == ExitSuccess, err)
    -- The target's interfaces, which are the outputs that its dependents'
    -- actions read. If they change, buck2 runs the dependents again.
    interfaces t = forM [name | (name, _, _) <- tModules t] $ \name -> do
      let f = dir </> outDir t </> name <.> "hi"
      exists <- doesFileExist f
      if exists then Just <$> B.readFile f else pure Nothing

-- | Build each module with a `ghc -c` of its own. After each compile, write
-- the module's ABI file from its interface, as the compile tool does. The
-- bench reads the interface in its own process, so this costs less here
-- than with the compile tool.
perModule :: FilePath -> String -> Int -> [String] -> Workload -> Maybe String -> IO (Measure, Int)
perModule dir ghc n common w edit = do
  libdir <- takeWhile (/= '\n') <$> readProcess ghc ["--print-libdir"] ""
  (wall, cpu, (path, k)) <- timed $ dispatch dir n w edit $ \t name -> do
    (code, _, err) <- readCreateProcessWithExitCode (proc ghc (compileFlags common t ++ ["-fforce-recomp"] ++ compileArgs t name)){cwd = Just dir} ""
    when (code == ExitSuccess) $ do
      iface <- readInterface libdir (dir </> outDir t </> name <.> "hi")
      writeFile (dir </> outDir t </> name <.> "abi") (show (abiHash iface))
    pure (code == ExitSuccess, err)
  pure (Measure wall cpu Nothing Nothing Nothing Nothing (Just path) Nothing, k)

-- | Build the workload through a fresh worker, started in the workload's
-- directory with the given environment variables. Each module is sent to it
-- as a request, and the worker is ended as buck2 ends it.
viaWorker :: FilePath -> FilePath -> [String] -> String -> Int -> [String] -> [(String, String)] -> Workload -> Maybe String -> IO (Measure, Int)
viaWorker dir worker rts ghc n common settings w edit = do
  let logFile = dir </> "worker.log"
  (wall, cpu, (path, k)) <- timed $ withFile logFile WriteMode $ \logH ->
    withWorkerProcess worker (["+RTS", "-T"] ++ rts ++ ["-RTS"]) dir ([("TMPDIR", dir </> "tmp"), ("BUCK2_GHC_WORKER_VERBOSE", "1")] ++ settings) (UseHandle logH) $ \sock ->
      dispatch dir n w edit (\t name -> (\(code, err) -> (code == 0, err)) <$> grpc sock (workerRequest ghc common t name))
  (peak, live, gc, sessions) <- readWorkerLog logFile
  split <- readWorkerSplit logFile
  pure (Measure wall cpu peak live gc (Just sessions) (Just path) split, k)

-- | The arguments of a module's request, as the rules send them.
workerRequest :: String -> [String] -> Target -> String -> [String]
workerRequest ghc common t name =
  [ "--request", "--contract", contract
  , "--depfile", tDir t </> "dep" </> name <.> "dep", "--abi", outDir t </> name <.> "abi", "--module", name, "--source", tDir t </> "src" </> name <.> "hs"
  , "--outdir", outDir t, "--hisuf", "hi", "--srcroot=" ++ tDir t </> "src"]
  ++ ["--", ghc] ++ compileFlags common t ++ ["--"] ++ compileArgs t name

-- | The directory that a target's compiles write to. It follows the layout
-- of buck2's output directories, which the worker uses to tell which
-- targets' one-shot sessions can share the interfaces they read (see
-- 'interfaceKey' in Session).
outDir :: Target -> FilePath
outDir t = "buck-out" </> "v2" </> "art" </> "bench" </> "0" </> tDir t </> "out"

-- | compileFlags are the flags that all of a target's compiles share, as the
-- rules give them. compileArgs are the arguments for one module's compile:
-- its source and output files.
compileFlags :: [String] -> Target -> [String]
compileFlags common t =
  common ++ ["-i" ++ outDir t] ++ concat [["-this-unit-id", tDir t] | not (null (tDir t))]
    ++ concat [["-package-db", "db", "-package-id", d] | d <- tDeps t]

compileArgs :: Target -> String -> [String]
compileArgs t name = ["-c", src, "-o", out "o", "-ohi", out "hi"]
  where
    src = tDir t </> "src" </> name <.> "hs"
    out ext = outDir t </> name <.> ext

-- | Run each module's compile once the modules it imports are compiled, at
-- most n at a time. After an edit to a module, run only the compiles that
-- buck2 would: the edited module's, and each one with an import whose ABI
-- file changed (see Note [Early cut-off by dep files] in
-- compile_per_module.bzl). Returns the critical path and the number of
-- modules compiled.
dispatch :: FilePath -> Int -> Workload -> Maybe String -> (Target -> String -> IO (Bool, String)) -> IO (Double, Int)
dispatch root n w edit compile = do
  changed <- newMVar Set.empty
  count <- newIORef (0 :: Int)
  let job t name imports = do
        dirty <- (\ch -> any (`Set.member` ch) imports) <$> readMVar changed
        if maybe True (== name) edit || dirty
          then do
            let abi = root </> outDir t </> name <.> "abi"
            before <- readAbi abi
            r <- compile t name
            after <- readAbi abi
            when (after /= before) $ modifyMVar_ changed (pure . Set.insert name)
            atomicModifyIORef' count (\k -> (k + 1, ()))
            pure r
          else pure (True, "")
  path <- schedule n [(name, imports, job t name imports) | t <- wTargets w, (name, imports, _) <- tModules t]
  (,) path <$> readIORef count
  where
    readAbi f = do
      exists <- doesFileExist f
      if exists then Just <$> B.readFile f else pure Nothing

-- | Run each job once the jobs it waits for are done, at most n at a time.
-- A job is a key, the keys of the jobs it waits for, and an action, which
-- returns whether it succeeded and, if not, the error. An action that
-- throws counts as failed, so that the jobs waiting for it still run. If
-- any job failed, the bench prints the first few errors and exits once all
-- the jobs have run.
--
-- Returns the critical path: the longest total time of a chain of jobs,
-- each waiting for the one before, using the time each job actually took.
-- However many slots there were, the jobs couldn't finish sooner. Jobs that
-- share a machine or a worker run slower when more run at once, so the
-- critical path measured with one job at a time is the more accurate
-- bound.
schedule :: (Ord k, Show k) => Int -> [(k, [k], IO (Bool, String))] -> IO Double
schedule n jobs = do
  slots <- newQSem n
  done <- M.fromList <$> forM jobs (\(k, _, _) -> (,) k <$> newEmptyMVar)
  forM_ jobs $ \(k, after, job) -> forkIO $ do
    before <- maximum . (0 :) . map snd <$> mapM (readMVar . (done M.!)) after
    (result, took) <- bracket_ (waitQSem slots) (signalQSem slots) $ do
      start <- getMonotonicTime
      result <- either (\e -> (False, show (e :: SomeException))) id <$> try job
      end <- getMonotonicTime
      pure (result, end - start)
    putMVar (done M.! k) (result, before + took)
  results <- forM jobs $ \(k, _, _) -> (,) k <$> readMVar (done M.! k)
  let failed = [(k, err) | (k, ((False, err), _)) <- results]
  unless (null failed) $ mapM_ (\(k, err) -> hPutStrLn stderr (show k ++ ": " ++ err)) (take 3 failed) >> exitFailure
  pure (maximum (0 : map (snd . snd) results))
