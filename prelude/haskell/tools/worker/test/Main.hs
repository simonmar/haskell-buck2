{-# LANGUAGE CPP #-}
{-# LANGUAGE OverloadedStrings #-}
-- | Tests of the worker that drive it as buck2 does. Each test group starts
-- a worker in the directory of a small generated package, and sends it one
-- request per module over its socket, with the arguments that the rules
-- send (see compile_per_module.bzl). As under buck2, the requests name files
-- relative to the worker's directory.
--
-- The tests check the files the worker writes for the rules (interfaces,
-- objects, ABI files and dep files) and how it manages its sessions: that it
-- compiles independent modules at the same time, compiles a module again
-- after an edit, compiles several targets side by side, and drops sessions
-- it no longer needs. A last group checks that a worker ends when the
-- process that started it goes away.
module Main (main) where

import Control.Concurrent (forkIO)
import Control.Concurrent.MVar
import Control.Exception (IOException, SomeException, catch, finally)
import Control.Monad (forM, forM_, unless, void, when)
import qualified Data.ByteString as B
import qualified Data.ByteString.Char8 as B8
import Data.List (isInfixOf, isPrefixOf, isSuffixOf)
import Data.Maybe (fromMaybe)
import System.Directory
import System.Environment (getEnvironment, lookupEnv)
import Data.Version (showVersion)
import System.Exit (ExitCode (..), exitFailure)
import System.Info (fullCompilerVersion)
import System.FilePath ((<.>), (</>))
import System.IO (IOMode (..), hGetLine, hPutStrLn, openFile, stderr)
import System.Posix.Process (getProcessID)
import System.Posix.Signals (nullSignal, sigKILL, signalProcess)
import System.Process
import System.Timeout (timeout)

import Test.Tasty
import Test.Tasty.HUnit

import Client
import Contract (contract)

main :: IO ()
main = do
  -- cabal puts the worker on $PATH (it is in build-tool-depends). The GHC
  -- that the requests name must be the one the worker and this test were
  -- built with. By default that is the `ghc` on $PATH; GHC overrides it.
  worker <- fromMaybe "buck2-ghc-worker" <$> lookupEnv "BUCK2_GHC_WORKER"
  ghc <- fromMaybe "ghc" <$> lookupEnv "GHC"
  version <- trim <$> readProcess ghc ["--numeric-version"] ""
  let built = showVersion fullCompilerVersion
  unless (version == built) $
    die' ("the test was built with GHC " ++ built ++ " but `" ++ ghc ++ "` is " ++ version ++ ": set GHC")
  -- The tests in a group run in order, because each builds on what the
  -- earlier ones compiled. The first group is run twice, once in session
  -- mode make and once in one-shot (see Note [One-shot sessions] in
  -- Session). The groups after it use auto, the default mode.
  defaultMain . dependentTestGroup "buck2-ghc-worker" AllFinish $
    [ withTestWorker ("one worker, over its socket, in session mode " ++ mode) mode worker ghc $ \getW ->
        [testCase "compiles a package, and again after edits" $ getW >>= \w -> scenarios (sendOwn w) (twDir w) ghc]
          ++ bootTests ghc mode getW
          ++ [ testCase "each compile removes its temporary files" $ do
                 w <- getW
                 asm <- filter (".s" `isSuffixOf`) <$> filesUnder (twDir w </> "tmp")
                 assertBool ("assembly files left: " ++ show asm) (null asm)
             , testCase "compiles another target's modules beside the first's" $ getW >>= \w -> otherTarget (twSendIn w) (twDir w) ghc
             , testCase "fails each request for a session that can't be made" $ getW >>= failedSessions . sendOwn
             , testCase "refuses a request for another GHC" $ getW >>= otherCompiler . sendOwn
             , testCase "runs a splice in an external interpreter" $ getW >>= \w -> externalInterpreter w ghc
             , testCase "drops the least recently used idle session, and compiles in new ones" $ getW >>= \w -> idleDrop w ghc
             , testCase "drops a target's session once its modules are all compiled" $ getW >>= \w -> finishedDrop w ghc
             , testCase "never finishes a target whose analysis failed" $ getW >>= \w -> unanalysed w ghc
             , testCase "reads the interfaces a module imports as ghc -c does with its OPTIONS_GHC" $ getW >>= \w -> pragmaFlags w ghc
             ]
    | mode <- ["make", "one-shot"]
    ]
      ++ [ withTestWorker "one worker in session mode auto" "auto" worker ghc $ \getW ->
             [testCase "compiles a target one-shot, and one with boot files with --make" $ getW >>= \w -> autoModes w ghc]
         , withTestWorker "a new worker's first splices, two at once" "auto" worker ghc $ \getW ->
             [testCase "both compile" $ getW >>= \w -> firstSplices (sendOwn w) (twDir w)]
         , withResource (newPackage ghc "orphan") removePathForcibly $ \getDir ->
             dependentTestGroup "a worker whose parent has gone ends" AllFinish
               [testCase (show when') $ getDir >>= \dir -> orphan when' dir worker ghc | when' <- [Idle, AfterASplice, DuringASplice]]
         ]
  where
    trim = reverse . dropWhile (`elem` ("\r\n" :: String)) . reverse
    -- The tests of a target with boot files (see cyclePackage). One-shot
    -- sessions can't compile such a target, so in that mode we only check
    -- that the worker refuses it.
    bootTests ghc mode getW
      | mode == "one-shot" = [testCase "refuses a target with boot files" $ getW >>= \w -> refusesBoots w ghc]
      | otherwise =
          [ testCase "compiles a cycle through a boot file, and again after edits" $ getW >>= \w -> cycles w ghc
          , testCase "sees the home modules around boot files as ghc -c does" $ getW >>= \w -> bootViews (sendCycle w) (twDir w </> "cycle") ghc
          ]

-- | A splice runs in an external interpreter (-fexternal-interpreter), and
-- the interpreter's process keeps running as long as its session does.
-- idleDrop, which runs next, checks that the process stops once the
-- session is dropped. The target has a second module that is never
-- compiled, so that the worker doesn't drop the session because the target
-- is finished. Where there is no /proc, we can't see the interpreter, so
-- we only check that the splice compiles.
externalInterpreter :: TestWorker -> String -> IO ()
externalInterpreter w ghc = do
  pkg <- targetOf w ghc "ext" [("A", splicing), ("B", plain)]
  (code, err) <- twSendIn w pkg (req "F.A" "F/A"){extraFlags = externalFlags pkg}
  assertBool ("a splice runs in an external interpreter: " ++ err) (code == 0)
  haveProc <- doesDirectoryExist "/proc/self"
  running <- interpreters (twDir w)
  when haveProc $ assertBool "the external interpreter runs while its session does" (not (null running))

-- | The worker drops the least recently used idle session when it has more
-- than its limit, and new sessions still work after older ones were
-- dropped. The test worker's limit is one session (see withTestWorker).
-- After externalInterpreter, a compile in a new target that also isn't
-- finished pushes the worker over that limit. The worker should then drop
-- externalInterpreter's session, which also stops its interpreter process.
--
-- Earlier tests ran splices in sessions that have since been dropped. A
-- splice in a new session must still work, which it wouldn't if, say, the
-- new session reused a dropped one's temporary paths (see Note [A temporary
-- directory per session] in Session).
idleDrop :: TestWorker -> String -> IO ()
idleDrop w ghc = do
  let dir = twDir w
  pkg <- targetOf w ghc "lru" [("A", plain'), ("B", plain)]
  (code, err) <- twSendIn w pkg (req "F.A" "F/A"){extraFlags = ["-this-unit-id", pkg]}
  assertBool ("a module compiles: " ++ err) (code == 0)
  finished <- or <$> mapM (finishedIn w) ["ext/out", "lru/out"]
  assertBool "neither target is finished" (not finished)
  -- The worker tells the interpreter to stop, but the process stops in its
  -- own time, so we wait for it.
  stopped <- poll 300 (null <$> interpreters dir)
  assertBool "a dropped session's external interpreter has stopped" stopped
  -- -DAFTER_THE_DROP gives this request flags of its own, so it gets a new
  -- session.
  writeFile (dir </> "src/T/Q.hs") "{-# LANGUAGE TemplateHaskell #-}\nmodule T.Q where\nimport Language.Haskell.TH.Syntax (lift)\nq :: Int\nq = $(lift (4 :: Int))\n"
  (qCode, qErr) <- sendOwn w (req "T.Q" "T/Q"){extraFlags = ["-dynamic", "-package", "template-haskell", "-DAFTER_THE_DROP"]}
  assertBool ("a splice compiles in a session made after others that ran splices were dropped: " ++ qErr) (qCode == 0)

-- | The worker drops a target's session as soon as the target is finished,
-- that is, once it has compiled all of the target's modules, even when the
-- session limit doesn't require it. The target has two modules, and the
-- first runs a splice in an external interpreter. After the first module,
-- the target's session is the most recently used, so the limit doesn't
-- drop it and the target isn't finished. After the second, the worker
-- should log that the target is finished, and stop its interpreter.
finishedDrop :: TestWorker -> String -> IO ()
finishedDrop w ghc = do
  pkg <- targetOf w ghc "two" [("A", splicing), ("B", plain)]
  (aCode, aErr) <- twSendIn w pkg (req "F.A" "F/A"){extraFlags = externalFlags pkg}
  assertBool ("a target's first module compiles: " ++ aErr) (aCode == 0)
  early <- finishedIn w (pkg </> "out")
  assertBool "a target with a module left isn't finished" (not early)
  (bCode, bErr) <- twSendIn w pkg (req "F.B" "F/B"){extraFlags = externalFlags pkg}
  assertBool ("a target's last module compiles: " ++ bErr) (bCode == 0)
  finished <- finishedIn w (pkg </> "out")
  assertBool "a target whose modules are all compiled is finished" finished
  stopped <- poll 300 (null <$> interpreters (twDir w))
  assertBool "a finished target's external interpreter has stopped" stopped

-- | The worker can only tell that a target is finished from GHC's analysis
-- of the target's modules. If that analysis fails, here because one module's
-- imports don't parse, the worker must never consider the target finished,
-- even though every module it was asked for has compiled.
unanalysed :: TestWorker -> String -> IO ()
unanalysed w ghc = do
  pkg <- targetOf w ghc "bad" [("A", splicing), ("Bad", "module F.Bad where\nimport\n")]
  (code, err) <- twSendIn w pkg (req "F.A" "F/A"){extraFlags = externalFlags pkg}
  assertBool ("a module beside one that doesn't parse compiles: " ++ err) (code == 0)
  finished <- finishedIn w (pkg </> "out")
  assertBool "a target whose analysis failed isn't finished" (not finished)

-- | Sources for targetOf's modules. `splicing` is an F.A with a splice,
-- which runs in an external interpreter when it is compiled with
-- externalFlags. plain' is an F.A without a splice, and plain is an F.B.
splicing, plain', plain :: String
splicing = "{-# LANGUAGE TemplateHaskell #-}\nmodule F.A where\nimport Language.Haskell.TH.Syntax (lift)\na :: Int\na = $(lift (1 :: Int))\n"
plain' = "module F.A where\na :: Int\na = 1\n"
plain = "module F.B where\nb :: Int\nb = 2\n"

-- | A module's OPTIONS_GHC must not change how other modules see the
-- interfaces they import (see Note [The flags an interface is read with]
-- in Session). F.P and F.Q share a session, and both import base's
-- toIntegralSized. F.P's OPTIONS_GHC turns interface pragmas on, so its
-- compile learns the function's arity. F.Q is compiled after it, at -O0,
-- where `ghc -c` ignores interface pragmas and so calls toIntegralSized as
-- an unknown function. We check that F.Q's code, in its Cmm dump, calls
-- toIntegralSized the same way as `ghc -c`'s does.
pragmaFlags :: TestWorker -> String -> IO ()
pragmaFlags w ghc = do
  let p = "{-# OPTIONS_GHC -fno-ignore-interface-pragmas #-}\nmodule F.P where\nimport Data.Bits (toIntegralSized)\np :: Int -> Maybe Word\np n = toIntegralSized n\n"
      q = "{-# OPTIONS_GHC -ddump-cmm -ddump-to-file #-}\nmodule F.Q where\nimport Data.Bits (toIntegralSized)\nq :: Integer -> Maybe Int\nq n = toIntegralSized n\n"
  pkg <- targetOf w ghc "prags" [("P", p), ("Q", q)]
  let dir = twDir w </> pkg
      flags = ["-this-unit-id", pkg, "-dumpdir", pkg </> "dump"]
  forM_ ["P", "Q"] $ \m -> do
    (code, err) <- twSendIn w pkg (req ("F." ++ m) ("F/" ++ m)){extraFlags = flags}
    assertBool ("F." ++ m ++ " compiles: " ++ err) (code == 0)
  createDirectoryIfMissing True (dir </> "ref")
  _ <- readCreateProcess (proc ghc ["-c", "src/F/Q.hs", "-o", "ref/Q.o", "-ohi", "ref/Q.hi", "-hide-all-packages", "-package", "base", "-dumpdir", "ref"]){cwd = Just dir} ""
  let directCall d = do
        cmm <- filter ("Q.dump-cmm" `isSuffixOf`) <$> filesUnder d
        case cmm of
          [f] -> ("toIntegralSized_info(" `isInfixOf`) <$> readFile f
          _ -> assertFailure ("one Cmm dump of F.Q under " ++ d ++ ": " ++ show cmm) >> pure False
  worker <- directCall (dir </> "dump")
  ref <- directCall (dir </> "ref")
  assertBool ("F.Q calls toIntegralSized " ++ (if ref then "directly" else "as an unknown function") ++ ", as ghc -c does") (worker == ref)

-- | The session flags for a target made by targetOf, with splices run in an
-- external interpreter.
externalFlags :: String -> [String]
externalFlags pkg = ["-this-unit-id", pkg, "-fexternal-interpreter", "-package", "template-haskell"]

-- | Make a package in a subdirectory, of the given name, of the worker's
-- directory. Its modules are F.<name> with the given sources, in place of
-- the T modules that makePackage writes. Returns the subdirectory, relative
-- to the worker's directory.
targetOf :: TestWorker -> String -> String -> [(String, String)] -> IO FilePath
targetOf w ghc name modules = do
  let dir = twDir w </> name
  makePackage ghc dir
  removePathForcibly (dir </> "src/T")
  createDirectoryIfMissing True (dir </> "src/F")
  forM_ modules $ \(m, src) -> writeFile (dir </> "src/F" </> m <.> "hs") src
  pure name

-- | Whether the worker's log says that the target with the given output
-- directory is finished. The directory is relative to the worker's
-- directory, as the requests name it.
finishedIn :: TestWorker -> FilePath -> IO Bool
finishedIn w out = elem (B8.pack ("buck2-ghc-worker: " ++ out ++ " finished")) . B8.lines <$> B.readFile (twDir w </> "worker.log")

die' :: String -> IO a
die' msg = hPutStrLn stderr msg >> exitFailure

-- | Send a request as the rules would, and return the exit code and stderr
-- that the worker answers with.
type Send = Req -> IO (Int, String)

data Req = Req
  { node :: String
  , modPath :: String
  , boot :: Bool
  , reqContract :: String
  , extraFlags :: [String]
  , compiler :: Maybe String -- a GHC to name instead of the test's
  }

-- | The arguments of a request for a module of the package in the given
-- subdirectory of the worker's directory. Paths are relative to the
-- worker's directory. For the worker's own package the subdirectory is "",
-- so that the paths have no leading "./", as buck2 gives them.
argv :: FilePath -> String -> Req -> [String]
argv pkg ghc r =
  [ "--request", "--contract", reqContract r
  , "--depfile", pkg </> "dep" </> node r <.> "dep", "--abi", abi, "--module", modPath r, "--source", src
  , "--outdir", out, "--hisuf", "hi"
  ] ++ ["--boot" | boot r]
  ++ ["--srcroot=" ++ pkg </> "src", "--mkdir=" ++ pkg </> "stubs" </> node r]
  ++ ["--", fromMaybe ghc (compiler r), "-hide-all-packages", "-package", "base", "-package-db", pkg </> "db", "-package", "p"] ++ extraFlags r
  ++ ["--", "-c", src, "-o", o, "-ohi", hi, "-stubdir", pkg </> "stubs" </> node r, "-i" ++ out]
  where
    out = pkg </> "out"
    suffix = if boot r then "-boot" else ""
    src = pkg </> "src" </> modPath r <.> ("hs" ++ suffix)
    hi = out </> modPath r <.> ("hi" ++ suffix)
    o = out </> modPath r <.> ("o" ++ suffix)
    abi = out </> modPath r <.> ("abi" ++ suffix)

req :: String -> String -> Req
req n m = Req n m False contract [] Nothing

-- | Make a package (see makePackage) in a new temporary directory, named
-- after the given string, and return the directory.
newPackage :: String -> String -> IO FilePath
newPackage ghc name = do
  tmp <- getTemporaryDirectory
  pid <- getProcessID
  let dir = tmp </> ("buck2-ghc-worker-test-" ++ show pid ++ "-" ++ name)
  removePathForcibly dir
  makePackage ghc dir
  pure dir

-- | Write the test package into the directory. T.C imports T.D, T.B imports
-- both, T.E imports nothing, and T.P imports P.Q from package p. No module
-- has a boot file (writeCycle adds one).
--
-- p is registered the way the rules register the early package db of a
-- dependency that is compiled per-module: it names no library, and its
-- import directory stays empty until a test compiles P.Q into it.
makePackage :: String -> FilePath -> IO ()
makePackage ghc dir = do
  mapM_ (createDirectoryIfMissing True) [dir </> "src/T", dir </> "out", dir </> "dep", dir </> "stubs", dir </> "p", dir </> "psrc/P", dir </> "tmp"]
  writeFile (dir </> "src/T/D.hs") "module T.D where\nnewtype D = D [Int]\ndSize :: D -> Int\ndSize (D ns) = sum ns\n"
  writeFile (dir </> "src/T/C.hs") "module T.C where\nimport T.D (D (..), dSize)\ndata C = Leaf | Node D\nsize :: C -> Int\nsize Leaf = 1\nsize (Node d) = 1 + dSize d\n"
  writeFile (dir </> "src/T/B.hs") "module T.B (total) where\nimport T.C (C (..), size)\nimport T.D (D (..))\ntotal :: Int\ntotal = size (Node (D [1, 2]))\n"
  writeFile (dir </> "src/T/E.hs") "module T.E where\ne :: Int\ne = 5\n"
  writeFile (dir </> "src/T/P.hs") "module T.P where\nimport P.Q (q)\np :: Int\np = q\n"
  writeFile (dir </> "psrc/P/Q.hs") "module P.Q where\nq :: Int\nq = 1\n"
  writeFile (dir </> "p.conf") ("name: p\nversion: 0\nid: p-0\nkey: p-0\nexposed: True\nexposed-modules: P.Q\nimport-dirs: " ++ dir </> "p" ++ "\n")
  _ <- readProcess (ghcPkgOf ghc) ["init", dir </> "db"] ""
  -- --force, because ghc-pkg refuses a package whose interfaces don't
  -- exist yet. It still warns about them, so we ignore its output.
  void $ readProcessWithExitCode (ghcPkgOf ghc) ["register", "--force", "--package-db", dir </> "db", dir </> "p.conf"] ""

-- | Rewrite the package in the directory so that T.C and T.D form an import
-- cycle, broken by a boot file. T.C gets a boot file, T.D imports T.C
-- {-# SOURCE #-}, and T.C still imports T.D.
writeCycle :: FilePath -> IO ()
writeCycle dir = do
  writeFile (dir </> "src/T/C.hs-boot") "module T.C where\ndata C\nsize :: C -> Int\n"
  writeFile (dir </> "src/T/D.hs") "module T.D where\nimport {-# SOURCE #-} T.C (C, size)\nnewtype D = D [C]\ndSize :: D -> Int\ndSize (D cs) = sum (map size cs)\n"
  writeFile (dir </> "src/T/B.hs") "module T.B (total) where\nimport T.C (C (..), size)\nimport T.D (D (..))\ntotal :: Int\ntotal = size (Node (D [Leaf, Leaf]))\n"

-- | The package in the subdirectory "cycle" of the worker's directory, whose
-- T.C and T.D form a cycle (see writeCycle). It is made the first time it is
-- needed. Returns its subdirectory, as twSendIn takes it.
--
-- Its modules are compiled with the unit id "cycle" (see sendCycle). They
-- have the same names as the worker's own package's modules, whose unit id
-- is GHC's default of "main". All the sessions share one name cache (see
-- Note [One name cache for all the sessions] in Session), so with the same
-- unit id the two packages' modules would be taken for each other.
cyclePackage :: TestWorker -> String -> IO FilePath
cyclePackage w ghc = do
  let dir = twDir w </> "cycle"
  made <- doesDirectoryExist dir
  unless made (makePackage ghc dir >> writeCycle dir)
  pure "cycle"

-- | Send a request for a module of the cycle package (see cyclePackage).
sendCycle :: TestWorker -> Send
sendCycle w r = twSendIn w "cycle" r{extraFlags = cycleUnit ++ extraFlags r}

cycleUnit :: [String]
cycleUnit = ["-this-unit-id", "cycle"]

-- | Send the request, and check that it succeeds and writes the module's
-- interface, object and ABI file to the package's out directory.
compiledIn :: Send -> FilePath -> Req -> IO ()
compiledIn send dir r = do
  (code, err) <- send r
  assertBool (node r ++ " compiles: " ++ err) (code == 0)
  let out = dir </> "out"
      suffix = if boot r then "-boot" else ""
  ok <- and <$> mapM doesFileExist [out </> modPath r <.> ("hi" ++ suffix), out </> modPath r <.> ("o" ++ suffix)]
  assertBool (node r ++ " writes its interface and object") ok
  abi <- readFile (out </> modPath r <.> ("abi" ++ suffix))
  assertBool (node r ++ " writes an ABI hash") (length (filter (/= '\n') abi) == 32)

-- | The files listed in the dep file of the request's module.
depsIn :: FilePath -> Req -> IO [String]
depsIn dir r = lines <$> readFile (dir </> "dep" </> node r <.> "dep")

-- | Check that the dep file of the request's module lists each of the given
-- files, and lists no file outside the package's own outputs.
listsIn :: FilePath -> Req -> [String] -> IO ()
listsIn dir r files = do
  deps <- depsIn dir r
  forM_ files $ \f -> assertBool (node r ++ ".dep lists " ++ f ++ ": " ++ show deps) (any (f `isInfixOf`) deps)
  assertBool (node r ++ ".dep lists only the package's own files: " ++ show deps) (all ("out/T/" `isInfixOf`) deps)

scenarios :: Send -> FilePath -> String -> IO ()
scenarios send dir ghc = do
  let out = dir </> "out"
      compiled = compiledIn send dir
      lists = listsIn dir

  -- Compile the modules in an order buck2 could send them. T.D and T.E
  -- import nothing, so they are sent at the same time. The dep files must
  -- list the ABI files of exactly the modules each one imports.
  done <- newEmptyMVar
  _ <- forkIO (compiled (req "T.E" "T/E") `finally` putMVar done ())
  compiled (req "T.D" "T/D")
  takeMVar done
  compiled (req "T.C" "T/C")
  compiled (req "T.B" "T/B")
  lists (req "T.C" "T/C") ["out/T/D.abi"]
  lists (req "T.B" "T/B") ["out/T/C.abi", "out/T/D.abi"]
  eDeps <- depsIn dir (req "T.E" "T/E")
  assertBool "T.E.dep is empty" (null eDeps)

  -- T.P imports P.Q from package p, whose interface didn't exist yet when
  -- the session was made. The session must still find it once P.Q has been
  -- compiled, as with an early package db.
  _ <- readProcess ghc ["-c", dir </> "psrc/P/Q.hs", "-this-unit-id", "p-0", "-hidir", dir </> "p", "-odir", dir </> "pobj", "-hide-all-packages", "-package", "base"] ""
  compiled (req "T.P" "T/P")

  -- A comment-only edit must leave the module's ABI hash unchanged, so that
  -- buck2 doesn't compile its importers again. From GHC 9.12, whose objects
  -- are deterministic, the object must be unchanged too.
  abi <- readFile (out </> "T/C.abi")
#if MIN_VERSION_GLASGOW_HASKELL(9,12,0,0)
  obj <- B.readFile (out </> "T/C.o")
#endif
  appendFile (dir </> "src/T/C.hs") "\n-- an edit\n"
  compiled (req "T.C" "T/C")
  abi' <- readFile (out </> "T/C.abi")
  assertBool "a comment-only edit leaves the ABI" (abi == abi')
#if MIN_VERSION_GLASGOW_HASKELL(9,12,0,0)
  obj' <- B.readFile (out </> "T/C.o")
  assertBool "a comment-only edit leaves the object" (obj == obj')
#endif

  -- A new exported definition must change the ABI hash.
  appendFile (dir </> "src/T/C.hs") "\nanother :: Int\nanother = 2\n"
  compiled (req "T.C" "T/C")
  abi'' <- readFile (out </> "T/C.abi")
  assertBool "an exported binding changes the ABI" (abi /= abi'')
  compiled (req "T.B" "T/B")

  -- A request with different flags is compiled in a new session. That
  -- session has to read T.C's and T.D's interfaces from disk, since another
  -- session compiled them.
  compiled (req "T.B" "T/B"){extraFlags = ["-DOTHER_FLAGS"]}
  lists (req "T.B" "T/B") ["out/T/C.abi", "out/T/D.abi"]

  -- A splice may not run code of its own target's modules (see Note
  -- [Template Haskell modules] in compile_per_module.bzl). T.H's splice
  -- runs T.G. T.H is compiled in a different session from T.G, so GHC
  -- loads T.G's object from the output directory, and the splice would
  -- work. The worker must still fail the compile, with a message that
  -- explains the restriction.
  let th = ["-dynamic", "-package", "template-haskell"]
  writeFile (dir </> "src/T/G.hs") "{-# LANGUAGE TemplateHaskellQuotes #-}\nmodule T.G (g) where\nimport Language.Haskell.TH (Exp, Q)\ng :: Q Exp\ng = [| 3 :: Int |]\n"
  writeFile (dir </> "src/T/H.hs") "{-# LANGUAGE TemplateHaskell #-}\nmodule T.H (h) where\nimport T.G (g)\nh :: Int\nh = $(g)\n"
  compiled (req "T.G" "T/G"){extraFlags = th}
  (hCode, hErr) <- send (req "T.H" "T/H"){extraFlags = th ++ ["-DOTHER_FLAGS"]}
  assertBool ("T.H, whose splice runs T.G, fails to compile, saying so: " ++ hErr) (hCode /= 0 && "this target's own modules" `isInfixOf` hErr)
  -- The target has its own module named Data.Bool, which is never
  -- compiled. T.I imports Data.Bool qualified with "base", and must get
  -- base's module, not the target's.
  createDirectoryIfMissing True (dir </> "src/Data")
  writeFile (dir </> "src/Data/Bool.hs") "module Data.Bool where\n"
  writeFile (dir </> "src/T/I.hs") "{-# LANGUAGE PackageImports #-}\nmodule T.I where\nimport \"base\" Data.Bool (bool)\ni :: Int\ni = bool 1 2 True\n"
  compiled (req "T.I" "T/I")

  -- The worker must compile every request, even when GHC's own check would
  -- find the module up to date (see Note [Compiling whenever buck2 asks] in
  -- Session). T.RF's splice reads a file without recording it, so GHC's
  -- check misses a change to the file. After we change it and send T.RF
  -- again, its object must change.
  writeFile (dir </> "rf-input") "one"
  writeFile (dir </> "src/T/RF.hs") "{-# LANGUAGE TemplateHaskell #-}\nmodule T.RF where\nimport Language.Haskell.TH.Syntax (lift, runIO)\nrf :: Int\nrf = $(runIO (readFile \"rf-input\") >>= lift . length)\n"
  let rfReq = (req "T.RF" "T/RF"){extraFlags = ["-dynamic", "-package", "template-haskell"]}
  compiled rfReq
  rfBefore <- B.readFile (out </> "T/RF.o")
  writeFile (dir </> "rf-input") "three"
  compiled rfReq
  rfAfter <- B.readFile (out </> "T/RF.o")
  assertBool "a module is compiled whenever it is asked to be, whatever GHC's own check" (rfBefore /= rfAfter)

  -- The stub header of a module with a foreign export must go to the
  -- request's -stubdir, as `ghc -c` puts it, and not next to the source.
  writeFile (dir </> "src/T/FE.hs") "module T.FE where\nforeign export ccall fe :: Int -> Int\nfe :: Int -> Int\nfe = (+ 1)\n"
  compiled (req "T.FE" "T/FE")
  inStubs <- doesFileExist (dir </> "stubs/T.FE/T/FE_stub.h")
  inSrc <- doesFileExist (dir </> "src/T/FE_stub.h")
  assertBool ("T.FE's stub header is in its -stubdir, not by its source: " ++ show (inStubs, inSrc)) (inStubs && not inSrc)

  -- A module with a type error fails, and the request's stderr has GHC's
  -- error, with the source location.
  writeFile (dir </> "src/T/F.hs") "module T.F where\nf :: Int\nf = \"no\"\n"
  (code, err) <- send (req "T.F" "T/F")
  assertBool ("T.F fails: " ++ show code) (code /= 0)
  assertBool ("T.F's error names its source and the problem: " ++ err) ("T/F.hs:3:5" `isInfixOf` err && "String" `isInfixOf` err)

  -- The toolchain's compiler_flags may contain RTS options for the ghc
  -- program, such as +RTS -A64m -RTS. They mean nothing to a session, and
  -- the worker must accept them.
  compiled (req "T.E" "T/E"){extraFlags = ["+RTS", "-A64m", "-RTS"]}

  -- A flag that sets state for the whole GHC process can't apply to one
  -- session alone, so the worker must refuse it and name the flag (see
  -- Note [Flags of the whole process] in Session).
  forM_ ["-fno-state-hack", "-dppr-debug"] $ \flag -> do
    (gCode, gErr) <- send (req "T.E" "T/E"){extraFlags = [flag]}
    assertBool ("a flag of the whole process is refused: " ++ show gCode ++ " " ++ gErr) (gCode /= 0 && flag `isInfixOf` gErr)

  -- A request from another version of the rules must be refused, with a
  -- message about the version.
  (code', err') <- send (req "T.E" "T/E"){reqContract = "0"}
  assertBool ("a contract mismatch is refused: " ++ show code' ++ " " ++ err') (code' /= 0 && "version" `isInfixOf` err')

-- | A target with an import cycle through a boot file (see cyclePackage)
-- compiles in the order buck2 would send it. The dep files of the modules
-- that read the boot file list its ABI file (T/C.abi-boot). The target
-- compiles again after an edit to the boot file.
cycles :: TestWorker -> String -> IO ()
cycles w ghc = do
  pkg <- cyclePackage w ghc
  let dir = twDir w </> pkg
      compiled = compiledIn (sendCycle w) dir
      lists = listsIn dir
  compiled (req "T.C-boot" "T/C"){boot = True}
  compiled (req "T.D" "T/D")
  compiled (req "T.C" "T/C")
  compiled (req "T.B" "T/B")
  lists (req "T.D" "T/D") ["out/T/C.abi-boot"]
  lists (req "T.C" "T/C") ["out/T/D.abi", "out/T/C.abi-boot"]
  lists (req "T.B" "T/B") ["out/T/C.abi", "out/T/D.abi"]

  -- Edit the boot file, then compile it and every module that reads it,
  -- in order.
  appendFile (dir </> "src/T/C.hs-boot") "\n-- an edit\n"
  compiled (req "T.C-boot" "T/C"){boot = True}
  compiled (req "T.D" "T/D")
  compiled (req "T.C" "T/C")
  compiled (req "T.B" "T/B")

-- | In session mode one-shot, the worker refuses a request for a target with
-- boot files (see cyclePackage), and says that hs-boot files are the
-- reason.
refusesBoots :: TestWorker -> String -> IO ()
refusesBoots w ghc = do
  _ <- cyclePackage w ghc
  (code, err) <- sendCycle w (req "T.D" "T/D")
  assertBool ("a target with boot files is refused: " ++ show code ++ " " ++ err) (code /= 0 && "hs-boot" `isInfixOf` err)

-- | In session mode auto, the worker makes a one-shot session for a target
-- without boot files, and a --make session for a target with them (see
-- cyclePackage). We check this in the worker's log.
autoModes :: TestWorker -> String -> IO ()
autoModes w ghc = do
  _ <- cyclePackage w ghc
  compiledIn (sendOwn w) (twDir w) (req "T.E" "T/E")
  compiledIn (sendCycle w) (twDir w </> "cycle") (req "T.C-boot" "T/C"){boot = True}
  logged <- lines <$> readFile (twDir w </> "worker.log")
  let said l = assertBool ("the worker's log says " ++ show l ++ ": " ++ show logged) (any (l `isPrefixOf`) logged)
  said "buck2-ghc-worker: a one-shot session for the flags of T/E"
  said "buck2-ghc-worker: a --make session for the flags of T/C"

-- | A new worker can run its first two splices at the same time, in two
-- sessions. The process has a single object linker, and starting it from
-- two sessions at once could hang both compiles (see Note [Starting the
-- object linker once] in Worker). Each splice waits until the other has
-- started, so both run at the same time, and their compiles then hash the
-- libraries they loaded at the same time too (see Note [Hashing the
-- libraries] in Session). A compile that never answers fails the test
-- after two minutes.
firstSplices :: Send -> FilePath -> IO ()
firstSplices send dir = do
  let th = ["-dynamic", "-package", "template-haskell"]
  results <- forM [("T.K", "T.L", "-DSPLICE_ONE"), ("T.L", "T.K", "-DSPLICE_TWO")] $ \(m, other, flag) -> do
    let path = map (\c -> if c == '.' then '/' else c) m
    writeFile (dir </> "src" </> path <.> "hs") ("{-# LANGUAGE TemplateHaskell #-}\nmodule " ++ m ++ " where\nimport Control.Concurrent (threadDelay)\nimport Language.Haskell.TH (integerL, litE, runIO)\nimport System.Directory (doesFileExist)\nk :: Int\nk = $(runIO (writeFile " ++ show (m ++ "-started") ++ " \"\" >> let go = doesFileExist " ++ show (other ++ "-started") ++ " >>= \\ok -> if ok then pure () else threadDelay 10000 >> go in go) >> litE (integerL 3))\n")
    v <- newEmptyMVar
    _ <- forkIO ((send (req m path){extraFlags = th ++ ["-package", "directory", flag]} >>= putMVar v) `finally` tryPutMVar v (1, "the compile failed"))
    pure (m, v)
  forM_ results $ \(m, v) -> do
    r <- timeout 120000000 (takeMVar v)
    case r of
      Nothing -> assertBool (m ++ " compiles, in one of two sessions at once: its splice still waits for the other's") False
      Just (code, err) -> assertBool (m ++ " compiles, in one of two sessions at once: " ++ err) (code == 0)


-- | Where modules have boot files, a compile must see each home module in
-- the form that `ghc -c` would see it (the boot interface or the full
-- module), whatever the session compiled before (see Note [Each compile's
-- home modules] in Session). The modules are written into the cycle package
-- (see cyclePackage), and the given Send sends their requests.
bootViews :: Send -> FilePath -> String -> IO ()
bootViews send dir ghc = do
  let out = dir </> "out"
      compiled r = do
        (code, err) <- send r
        assertBool (node r ++ " compiles: " ++ err) (code == 0)
      showIface f = readProcess ghc ["--show-iface", f] ""
      -- These flags give the modules below a session of their own. A
      -- session analyses its target's sources when it is made, so it has to
      -- be made after the modules have been written.
      th = ["-dynamic", "-package", "template-haskell", "-DBOOT_VIEWS"]

  -- T.SB has a boot file and runs a splice. When it is compiled again
  -- after an edit, with its previous interface still on disk, GHC must still
  -- check it against its boot file. That check gives the module's Show
  -- instance an extra binding with the name that importers of the boot file
  -- use for it (the boot file's dfun, $fxShowT), so that name must be in
  -- the new interface.
  writeFile (dir </> "src/T/SB.hs-boot") "module T.SB where\ndata T\ninstance Show T\n"
  writeFile (dir </> "src/T/SA.hs") "module T.SA where\nimport {-# SOURCE #-} T.SB (T)\nshowT :: T -> String\nshowT = show\n"
  let sb :: Int -> IO ()
      sb n = writeFile (dir </> "src/T/SB.hs") ("{-# LANGUAGE TemplateHaskell #-}\nmodule T.SB where\nimport T.SA (showT)\nimport Language.Haskell.TH.Syntax (lift)\ndata T = T\ninstance Show T where show _ = showT T\nn :: Int\nn = $(lift (" ++ show n ++ " :: Int))\n")
  sb 1
  compiled (req "T.SB-boot" "T/SB"){boot = True, extraFlags = th}
  compiled (req "T.SA" "T/SA"){extraFlags = th}
  compiled (req "T.SB" "T/SB"){extraFlags = th}
  sb 2
  compiled (req "T.SB" "T/SB"){extraFlags = th}
  sbIface <- showIface (out </> "T/SB.hi")
  assertBool "a module compiled again is checked against its boot file" ("$fxShowT" `isInfixOf` sbIface)

  -- T.YZ imports T.YA, which imports T.Y {-# SOURCE #-}. The session has
  -- already compiled the full T.Y, but T.YZ must still see T.Y's boot
  -- interface, because that is what `ghc -c` uses (T.YA's interface
  -- records that it depends on the boot file). So T.YZ's ABI hash must
  -- match that of a `ghc -c` compile.
  writeFile (dir </> "src/T/Y.hs-boot") "module T.Y where\ny :: Int\n"
  writeFile (dir </> "src/T/Y.hs") "module T.Y where\ny :: Int\ny = 42\n"
  writeFile (dir </> "src/T/YA.hs") "module T.YA where\nimport {-# SOURCE #-} T.Y (y)\na :: Int\na = y + 1\n{-# INLINE a #-}\n"
  writeFile (dir </> "src/T/YZ.hs") "module T.YZ where\nimport T.YA (a)\nz :: Int\nz = a + 1\n"
  let opt = ["-O", "-DBOOT_VIEWS"]
  compiled (req "T.Y-boot" "T/Y"){boot = True, extraFlags = opt}
  compiled (req "T.Y" "T/Y"){extraFlags = opt}
  compiled (req "T.YA" "T/YA"){extraFlags = opt}
  compiled (req "T.YZ" "T/YZ"){extraFlags = opt}
  createDirectoryIfMissing True (dir </> "ref")
  _ <- readProcess ghc (["-c", dir </> "src/T/YZ.hs", "-o", dir </> "ref/YZ.o", "-ohi", dir </> "ref/YZ.hi", "-i" ++ out, "-hide-all-packages", "-package", "base"] ++ cycleUnit ++ opt ++ determinism) ""
  let abiOf = filter ("ABI hash" `isInfixOf`) . lines
  worker <- abiOf <$> showIface (out </> "T/YZ.hi")
  reference <- abiOf <$> showIface (dir </> "ref/YZ.hi")
  assertBool ("a module below a boot file has ghc -c's ABI: " ++ show (worker, reference)) (worker == reference && not (null worker))

  -- T.RB has a boot file, and imports T.RA, whose unfolding refers back to
  -- T.RB's rb through the boot file. When T.RB is compiled, that reference
  -- must be to the T.RB being compiled, as with `ghc -c`, so that GHC sees
  -- the recursion and gives rb no unfolding (see Note [Modules above the
  -- compile's boot interface] in Session). T.RB's ABI hash must match that
  -- of a `ghc -c` compile.
  writeFile (dir </> "src/T/RB.hs-boot") "module T.RB where\nrb :: Int\n"
  writeFile (dir </> "src/T/RA.hs") "module T.RA where\nimport {-# SOURCE #-} T.RB (rb)\nra :: Int\nra = rb + 1\n{-# INLINE ra #-}\n"
  writeFile (dir </> "src/T/RB.hs") "module T.RB where\nimport T.RA (ra)\nrb :: Int\nrb = ra + 1\n"
  compiled (req "T.RB-boot" "T/RB"){boot = True, extraFlags = opt}
  compiled (req "T.RA" "T/RA"){extraFlags = opt}
  compiled (req "T.RB" "T/RB"){extraFlags = opt}
  _ <- readProcess ghc (["-c", dir </> "src/T/RB.hs", "-o", dir </> "ref/RB.o", "-ohi", dir </> "ref/RB.hi", "-i" ++ out, "-hide-all-packages", "-package", "base"] ++ cycleUnit ++ opt ++ determinism) ""
  rbWorker <- abiOf <$> showIface (out </> "T/RB.hi")
  rbReference <- abiOf <$> showIface (dir </> "ref/RB.hi")
  assertBool ("a module whose import names it back through its boot file has ghc -c's ABI: " ++ show (rbWorker, rbReference)) (rbWorker == rbReference && not (null rbWorker))

  -- T.SJ imports T.SI {-# SOURCE #-}. The session has compiled T.SI, and
  -- for that compile read T.SI's boot interface from disk, because another
  -- session compiled the boot file. T.SJ must see the boot file's Show
  -- instance, not T.SI's. Otherwise T.SJ could inline T.SI's method and
  -- refer to something the boot interface doesn't have, which makes
  -- GHC 9.14 panic (see Note [The compile's own boot interface] in
  -- Session). The test passes if T.SJ compiles.
  writeFile (dir </> "src/T/SI.hs-boot") "module T.SI where\ndata T\ninstance Show T\n"
  writeFile (dir </> "src/T/SI.hs") "module T.SI where\ndata T = T\ninstance Show T where show _ = \"T\"\n"
  writeFile (dir </> "src/T/SJ.hs") "module T.SJ where\nimport {-# SOURCE #-} T.SI (T)\nshowT :: T -> String\nshowT = show\n"
  let optSI = ["-O", "-DBOOT_INSTANCE"]
  compiled (req "T.SI-boot" "T/SI"){boot = True, extraFlags = optSI ++ ["-DBOOT_INSTANCE_BOOT"]}
  compiled (req "T.SI" "T/SI"){extraFlags = optSI}
  compiled (req "T.SJ" "T/SJ"){extraFlags = optSI}
  where
#if MIN_VERSION_GLASGOW_HASKELL(9,12,0,0)
    determinism = ["-fobject-determinism"]
#else
    determinism = []
#endif

-- | One worker compiles two targets side by side, as the targets of a build
-- share a worker, and keeps them apart even where their modules have the
-- same names.
--
-- Each target has a T.E, with different exports, and the two are compiled
-- at the same time. Then each target compiles a module that uses something
-- only its own T.E exports.
--
-- Then each target compiles a T.W. The first target's T.W runs a splice
-- that creates the file w-started and then waits for the file w-go. While
-- it waits, the other target's T.W compiles, with a warning, and only then
-- does the test create w-go. Each request's stderr must have its own
-- module's diagnostics and not the other's.
otherTarget :: (FilePath -> Send) -> FilePath -> String -> IO ()
otherTarget sendIn dir ghc = do
  makePackage ghc (dir </> "other")
  writeFile (dir </> "other/src/T/E.hs") "module T.E where\nother :: Bool\nother = True\n"
  writeFile (dir </> "other/src/T/G.hs") "module T.G where\nimport T.E (other)\ng :: Bool\ng = not other\n"
  let unit = ["-this-unit-id", "other"]
  appendFile (dir </> "src/T/E.hs") "\n-- an edit\n"
  first <- newEmptyMVar
  _ <- forkIO ((sendIn "" (req "T.E" "T/E") >>= putMVar first) `finally` tryPutMVar first (1, "the compile failed"))
  (otherCode, otherErr) <- sendIn "other" (req "T.E" "T/E"){extraFlags = unit}
  assertBool ("another target's T.E compiles: " ++ otherErr) (otherCode == 0)
  (firstCode, firstErr) <- takeMVar first
  assertBool ("T.E compiles beside another target's: " ++ firstErr) (firstCode == 0)
  (gCode, gErr) <- sendIn "other" (req "T.G" "T/G"){extraFlags = unit}
  assertBool ("another target's module imports its own T.E: " ++ gErr) (gCode == 0)
  writeFile (dir </> "src/T/J.hs") "module T.J where\nimport T.E (e)\nj :: Int\nj = e + 1\n"
  (jCode, jErr) <- sendIn "" (req "T.J" "T/J")
  assertBool ("a module imports its own target's T.E: " ++ jErr) (jCode == 0)
  writeFile (dir </> "src/T/W.hs") "{-# LANGUAGE TemplateHaskell #-}\nmodule T.W where\nimport Control.Concurrent (threadDelay)\nimport Language.Haskell.TH.Syntax (lift, runIO)\nimport System.Directory (doesFileExist)\nw :: Int\nw = $(runIO (writeFile \"w-started\" \"\" >> let go = doesFileExist \"w-go\" >>= \\ok -> if ok then pure () else threadDelay 10000 >> go in go) >> lift (1 :: Int))\n"
  writeFile (dir </> "other/src/T/W.hs") "module T.W where\nw :: Int\nw = let othersUnused = 1 :: Int in 2\n"
  mine <- newEmptyMVar
  _ <- forkIO ((sendIn "" (req "T.W" "T/W"){extraFlags = ["-dynamic", "-package", "template-haskell", "-package", "directory"]} >>= putMVar mine) `finally` tryPutMVar mine (1, "the compile threw"))
  started <- poll 300 (doesFileExist (dir </> "w-started"))
  assertBool "T.W's compile starts" started
  -- A worker that compiled one module at a time would never answer this
  -- request, since T.W waits for it. So we give up after two minutes.
  (otherWCode, otherWErr) <- fromMaybe (1, "no answer in two minutes, with T.W's compile waiting") <$> timeout 120000000 (sendIn "other" (req "T.W" "T/W"){extraFlags = unit ++ ["-Wunused-local-binds"]})
  writeFile (dir </> "w-go") ""
  (wCode, wErr) <- takeMVar mine
  assertBool ("the other target's T.W compiles, with its warning: " ++ otherWErr) (otherWCode == 0 && "othersUnused" `isInfixOf` otherWErr)
  assertBool ("T.W compiles, without the other target's warning: " ++ wErr) (wCode == 0 && not ("othersUnused" `isInfixOf` wErr))

-- | When a session can't be made, here because of a flag GHC doesn't know,
-- every request waiting for it must fail with the reason, rather than wait
-- for a session that never comes. Two requests for the same session are
-- sent at the same time.
failedSessions :: Send -> IO ()
failedSessions send = do
  vs <- forM [("T.E", "T/E"), ("T.P", "T/P")] $ \(n, m) -> do
    v <- newEmptyMVar
    _ <- forkIO ((send (req n m){extraFlags = ["-fno-such-flag"]} >>= putMVar v) `finally` tryPutMVar v (0, "the request threw"))
    pure v
  forM_ vs $ \v -> do
    r <- timeout 60000000 (takeMVar v)
    case r of
      Nothing -> assertBool "a request whose session can't be made returns" False
      Just (code, err) -> assertBool ("a request whose session can't be made fails, saying why: " ++ err) (code /= 0 && "no-such-flag" `isInfixOf` err)

-- | The worker refuses a request that names a different GHC from the one
-- it runs.
otherCompiler :: Send -> IO ()
otherCompiler send = do
  (code, err) <- send (req "T.E" "T/E"){compiler = Just "/no/such/ghc"}
  assertBool ("a request for another GHC is refused: " ++ err) (code /= 0 && "/no/such/ghc" `isInfixOf` err)

-- | The process ids of the external interpreters (iserv) that the worker
-- in the given directory started. We recognise them by their TMPDIR, which
-- is the worker's. This needs /proc, and finds nothing without it.
interpreters :: FilePath -> IO [String]
interpreters dir = do
  pids <- filter (all (`elem` ['0' .. '9'])) <$> (listDirectory "/proc" `catch` \(_ :: IOException) -> pure [])
  concat <$> forM pids (\pid -> do
    let file f = B8.unpack <$> B.readFile ("/proc" </> pid </> f)
    found <- ((\cmd env -> "iserv" `isInfixOf` cmd && ("TMPDIR=" ++ dir </> "tmp") `isInfixOf` env) <$> file "cmdline" <*> file "environ")
      `catch` \(_ :: IOException) -> pure False
    pure [pid | found])

-- | The files in a directory and below it.
filesUnder :: FilePath -> IO [FilePath]
filesUnder d = do
  entries <- map (d </>) <$> listDirectory d
  concat <$> mapM (\e -> doesDirectoryExist e >>= \isDir -> if isDir then filesUnder e else pure [e]) entries

-- | A worker running in the directory of a new package, as the tests of a
-- group see it.
data TestWorker = TestWorker
  { twDir :: FilePath
  , twProcess :: ProcessHandle
  , twSendIn :: FilePath -> Send -- for the package in the given subdirectory
  }

-- | Send a request for the package in the worker's own directory.
sendOwn :: TestWorker -> Send
sendOwn w = twSendIn w ""

-- | A group of tests, run in order, against one worker. The worker is
-- started as buck2 starts it, in the directory of a new package, and the
-- tests send it requests over its socket (see 'grpc'). Since targets share
-- a worker, a request may be for the package in any subdirectory.
--
-- The worker's session limit is one, so that the tests can check when it
-- drops sessions. It runs verbosely, logging to worker.log in its
-- directory, which some tests read.
--
-- The last test ends the worker with SIGTERM, as buck2 does. The worker must
-- exit successfully and leave no temporary files behind.
withTestWorker :: String -> String -> FilePath -> String -> (IO TestWorker -> [TestTree]) -> TestTree
withTestWorker name mode worker ghc tests =
  withResource start stop $ \getW ->
    dependentTestGroup name AllFinish (tests getW ++ [testCase "ends on SIGTERM, leaving no temporary files" (getW >>= end)])
  where
    start = do
      -- The directory is named after the initials of the group's name, to
      -- keep it short. The worker's socket is in this directory, and macOS
      -- limits a socket's path to 104 bytes, of which $TMPDIR takes about
      -- 50.
      dir <- newPackage ghc [c | c : _ <- words name]
      logH <- openFile (dir </> "worker.log") WriteMode
      (ph, sock) <- startWorkerProcess worker [] dir [("BUCK2_GHC_WORKER_SESSIONS", "1"), ("BUCK2_GHC_WORKER_VERBOSE", "1"), ("BUCK2_GHC_WORKER_SESSION_MODE", mode), ("TMPDIR", dir </> "tmp")] (UseHandle logH)
      pure (TestWorker dir ph (\pkg -> grpc sock . argv pkg ghc))
    end w = do
      terminateProcess (twProcess w)
      code <- waitForProcess (twProcess w)
      code @?= ExitSuccess
      left <- listDirectory (twDir w </> "tmp")
      assertBool ("temporary files left: " ++ show left) (null left)
    -- Clean up, whether or not the tests ended the worker.
    stop w = do
      terminateProcess (twProcess w)
      _ <- waitForProcess (twProcess w)
      removePathForcibly (twDir w)

-- | What the worker is doing when its parent goes away.
data Orphaned = Idle | AfterASplice | DuringASplice
  deriving (Eq, Show)

-- | A worker must end when its parent process exits without ending it. This
-- happens when the buck2 daemon is killed: the forkserver that started the
-- worker exits too. We check three cases:
--
-- - Idle: the worker hasn't compiled anything.
-- - AfterASplice: the worker has compiled a module that ran a splice, so it
--   has a session and the libraries that the splice loaded.
-- - DuringASplice: the worker is in the middle of a compile whose splice
--   never finishes. The worker's stderr is closed in this case, to check
--   that failing to write to stderr doesn't stop the worker from ending.
--
-- The worker's parent here is a shell script. It waits for the worker's
-- socket to appear, so that the worker has recorded its parent before the
-- parent exits. Then it waits until the test creates the file "go", or
-- until the test process itself has gone, so that a test killed part-way
-- doesn't leave a worker behind.
orphan :: Orphaned -> FilePath -> FilePath -> String -> IO ()
orphan when' dir worker ghc = do
  environment <- getEnvironment
  let sock = dir </> "w.sock"
      go = dir </> "go"
  removePathForcibly sock
  removePathForcibly go
  let stderr' = if when' == DuringASplice then "2>&-" else "2>/dev/null"
  (_, Just out, _, ph) <- createProcess (proc "sh" ["-c", "\"$0\" >/dev/null " ++ stderr' ++ " & echo $!; until [ -S \"$1\" ]; do sleep 0.1; done; until [ -e \"$2\" ] || ! kill -0 $PPID 2>/dev/null; do sleep 0.1; done", worker, sock, go]){cwd = Just dir, env = Just (("WORKER_SOCKET", sock) : filter ((/= "WORKER_SOCKET") . fst) environment), std_out = CreatePipe}
  pid <- read <$> hGetLine out
  opened <- poll 50 (doesFileExist sock)
  assertBool "the worker opened a socket" opened
  let th = ["-dynamic", "-package", "template-haskell"]
  when (when' /= Idle) $ do
    writeFile (dir </> "src/T/H.hs") "{-# LANGUAGE TemplateHaskell #-}\nmodule T.H (h) where\nimport Language.Haskell.TH (integerL, litE)\nh :: Int\nh = $(litE (integerL 3))\n"
    forM_ [(req "T.H" "T/H"){extraFlags = th ++ ["-DSPLICING"]}] $ \r -> do
      (code, err) <- grpc sock (argv "" ghc r)
      assertBool ("before its parent goes, " ++ node r ++ " compiles: " ++ err) (code == 0)
  when (when' == DuringASplice) $ do
    writeFile (dir </> "src/T/Z.hs") "{-# LANGUAGE TemplateHaskell #-}\nmodule T.Z where\nimport Control.Concurrent (threadDelay)\nimport Control.Monad (forever)\nimport Language.Haskell.TH.Syntax (lift, runIO)\nz :: Int\nz = $(runIO (writeFile \"z-started\" \"\" >> forever (threadDelay 100000)) >> lift (1 :: Int))\n"
    void . forkIO . void $ grpc sock (argv "" ghc (req "T.Z" "T/Z"){extraFlags = th ++ ["-DNEVER_DONE"]}) `catch` \(_ :: SomeException) -> pure (0, "")
    started <- poll 300 (doesFileExist (dir </> "z-started"))
    assertBool "the compile that never ends starts" started
  writeFile go ""
  _ <- waitForProcess ph
  let alive = (signalProcess nullSignal pid >> pure True) `catch` \(_ :: IOException) -> pure False
  ok <- poll 50 (not <$> alive)
  unless ok $ signalProcess sigKILL pid
  assertBool ("a worker whose parent has gone ends, " ++ show when') ok
