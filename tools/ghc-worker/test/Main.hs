{-# LANGUAGE CPP #-}
{-# LANGUAGE OverloadedStrings #-}
-- | Compiles a small package through one worker, over buck2's socket
-- protocol, one request per module as the rules send them (see
-- compile_per_module.bzl). Checks what the worker writes for the rules (the
-- interfaces and objects, and the ABI and dep files), and the session's
-- state:
--
-- - independent modules compiled at once;
-- - a module compiled again after an edit;
-- - another target's modules beside the first's;
-- - the idle sessions dropped.
--
-- The worker runs in the package's directory, and the requests name files
-- relative to it, as under buck2. Also checks that a worker whose parent
-- goes away ends.
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
  -- The worker on $PATH (build-tool-depends) and the GHC it was built with,
  -- which must be the `ghc` on $PATH too.
  worker <- fromMaybe "ghc-worker" <$> lookupEnv "GHC_WORKER"
  ghc <- fromMaybe "ghc" <$> lookupEnv "GHC"
  version <- trim <$> readProcess ghc ["--numeric-version"] ""
  let built = showVersion fullCompilerVersion
  unless (version == built) $
    die' ("the test was built with GHC " ++ built ++ " but `" ++ ghc ++ "` is " ++ version ++ ": set GHC")
  -- In order: each group's tests build on what those before did. The first
  -- group runs in the session modes make and one-shot (see Note [One-shot
  -- sessions] in Session), the second in auto, the default.
  defaultMain . dependentTestGroup "ghc-worker" AllFinish $
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
    -- The tests of a target with boot files (see cyclePackage): in one-shot
    -- mode, that it is refused.
    bootTests ghc mode getW
      | mode == "one-shot" = [testCase "refuses a target with boot files" $ getW >>= \w -> refusesBoots w ghc]
      | otherwise =
          [ testCase "compiles a cycle through a boot file, and again after edits" $ getW >>= \w -> cycles w ghc
          , testCase "sees the home modules around boot files as ghc -c does" $ getW >>= \w -> bootViews (sendCycle w) (twDir w </> "cycle") ghc
          ]

-- | A splice run by an external interpreter, whose process ends with its
-- session (where /proc shows the worker's interpreters, see idleDrop), in a
-- target with a module left to compile, so that it isn't finished.
externalInterpreter :: TestWorker -> String -> IO ()
externalInterpreter w ghc = do
  pkg <- targetOf w ghc "ext" [("A", splicing), ("B", plain)]
  (code, err) <- twSendIn w pkg (req "F.A" "F/A"){extraFlags = externalFlags pkg}
  assertBool ("a splice runs in an external interpreter: " ++ err) (code == 0)
  haveProc <- doesDirectoryExist "/proc/self"
  running <- interpreters (twDir w)
  when haveProc $ assertBool "the external interpreter runs while its session does" (not (null running))

-- | After externalInterpreter, a compile in another target, which isn't
-- finished either: the worker keeps one session (see withTestWorker),
-- so it drops the external interpreter's, the least recently used. Then
-- compiles in new sessions, which read from disk what the old ones had
-- compiled.
idleDrop :: TestWorker -> String -> IO ()
idleDrop w ghc = do
  let dir = twDir w
  pkg <- targetOf w ghc "lru" [("A", plain'), ("B", plain)]
  (code, err) <- twSendIn w pkg (req "F.A" "F/A"){extraFlags = ["-this-unit-id", pkg]}
  assertBool ("a module compiles: " ++ err) (code == 0)
  finished <- or <$> mapM (finishedIn w) ["ext/out", "lru/out"]
  assertBool "neither target is finished" (not finished)
  -- (Told to stop, which it does in its own time.)
  stopped <- poll 300 (null <$> interpreters dir)
  assertBool "a dropped session's external interpreter has stopped" stopped
  -- A splice in a new session after those that ran splices before were
  -- dropped.
  writeFile (dir </> "src/T/Q.hs") "{-# LANGUAGE TemplateHaskell #-}\nmodule T.Q where\nimport Language.Haskell.TH.Syntax (lift)\nq :: Int\nq = $(lift (4 :: Int))\n"
  (qCode, qErr) <- sendOwn w (req "T.Q" "T/Q"){extraFlags = ["-dynamic", "-package", "template-haskell", "-DAFTER_THE_DROP"]}
  assertBool ("a splice compiles in a session made after others that ran splices were dropped: " ++ qErr) (qCode == 0)

-- | A target of two modules, the first with a splice run by an external
-- interpreter: the worker keeps one session, and the target's is the
-- most recently used, so it is dropped only once the second module is
-- compiled and the target finished.
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

-- | A target with a module whose header doesn't parse, so GHC's analysis
-- of the target fails: compiling the others doesn't finish it.
unanalysed :: TestWorker -> String -> IO ()
unanalysed w ghc = do
  pkg <- targetOf w ghc "bad" [("A", splicing), ("Bad", "module F.Bad where\nimport\n")]
  (code, err) <- twSendIn w pkg (req "F.A" "F/A"){extraFlags = externalFlags pkg}
  assertBool ("a module beside one that doesn't parse compiles: " ++ err) (code == 0)
  finished <- finishedIn w (pkg </> "out")
  assertBool "a target whose analysis failed isn't finished" (not finished)

-- | F.A, whose splice runs in an external interpreter with externalFlags;
-- F.A and F.B without one.
splicing, plain', plain :: String
splicing = "{-# LANGUAGE TemplateHaskell #-}\nmodule F.A where\nimport Language.Haskell.TH.Syntax (lift)\na :: Int\na = $(lift (1 :: Int))\n"
plain' = "module F.A where\na :: Int\na = 1\n"
plain = "module F.B where\nb :: Int\nb = 2\n"

-- | The flags of a target's (targetOf's) modules, with splices run by an
-- external interpreter.
externalFlags :: String -> [String]
externalFlags pkg = ["-this-unit-id", pkg, "-fexternal-interpreter", "-package", "template-haskell"]

-- | A package of the given name below the worker's, of modules F.<name>
-- with the given sources (and none of makePackage's own); its directory.
targetOf :: TestWorker -> String -> String -> [(String, String)] -> IO FilePath
targetOf w ghc name modules = do
  let dir = twDir w </> name
  makePackage ghc dir
  removePathForcibly (dir </> "src/T")
  createDirectoryIfMissing True (dir </> "src/F")
  forM_ modules $ \(m, src) -> writeFile (dir </> "src/F" </> m <.> "hs") src
  pure name

-- | Whether the worker has said it finished the target with the given
-- output directory (relative to the worker's, as the requests name it).
finishedIn :: TestWorker -> FilePath -> IO Bool
finishedIn w out = elem (B8.pack ("ghc-worker: " ++ out ++ " finished")) . B8.lines <$> B.readFile (twDir w </> "worker.log")

die' :: String -> IO a
die' msg = hPutStrLn stderr msg >> exitFailure

-- | A request as the rules send it; the exit code and stderr it gets.
type Send = Req -> IO (Int, String)

data Req = Req
  { node :: String
  , modPath :: String
  , boot :: Bool
  , reqContract :: String
  , extraFlags :: [String]
  , compiler :: Maybe String -- another than the test's GHC
  }

-- | A request's arguments, with paths relative to the worker's directory,
-- for the package in the given directory below it ("" for the worker's
-- own: paths as buck2 gives them, with no "./").
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

-- | A package (see makePackage) in a new temporary directory, of the
-- given name.
newPackage :: String -> String -> IO FilePath
newPackage ghc name = do
  tmp <- getTemporaryDirectory
  pid <- getProcessID
  let dir = tmp </> ("ghc-worker-test-" ++ show pid ++ "-" ++ name)
  removePathForcibly dir
  makePackage ghc dir
  pure dir

-- T.C imports T.D; T.B imports both; T.E imports nothing; T.P imports P.Q
-- of package p. p is registered as the rules register a dependency's early
-- package db: without a library, and with an import directory that is
-- empty until P.Q is compiled. No module has a boot file (see writeCycle).
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
  -- It warns that the interface is missing.
  void $ readProcessWithExitCode (ghcPkgOf ghc) ["register", "--force", "--package-db", dir </> "db", dir </> "p.conf"] ""

-- | Make T.C and T.D of the package in the directory a cycle through a
-- boot file: T.C has one, T.D imports it SOURCE, and T.C imports T.D.
writeCycle :: FilePath -> IO ()
writeCycle dir = do
  writeFile (dir </> "src/T/C.hs-boot") "module T.C where\ndata C\nsize :: C -> Int\n"
  writeFile (dir </> "src/T/D.hs") "module T.D where\nimport {-# SOURCE #-} T.C (C, size)\nnewtype D = D [C]\ndSize :: D -> Int\ndSize (D cs) = sum (map size cs)\n"
  writeFile (dir </> "src/T/B.hs") "module T.B (total) where\nimport T.C (C (..), size)\nimport T.D (D (..))\ntotal :: Int\ntotal = size (Node (D [Leaf, Leaf]))\n"

-- | The package "cycle" below the worker's, its T.C and T.D a cycle (see
-- writeCycle), made if it isn't yet; its directory, as twSendIn names it.
-- Its unit id is cycle, not main as the worker's own package's, since the
-- sessions share their names (see Note [One name cache for all the
-- sessions] in Session).
cyclePackage :: TestWorker -> String -> IO FilePath
cyclePackage w ghc = do
  let dir = twDir w </> "cycle"
  made <- doesDirectoryExist dir
  unless made (makePackage ghc dir >> writeCycle dir)
  pure "cycle"

-- | A request for the cycle package (see cyclePackage).
sendCycle :: TestWorker -> Send
sendCycle w r = twSendIn w "cycle" r{extraFlags = cycleUnit ++ extraFlags r}

cycleUnit :: [String]
cycleUnit = ["-this-unit-id", "cycle"]

-- | Compile the request, which must succeed and write the module's
-- interface, object and ABI hash in the package's out directory.
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

-- | The files the request's dep file lists.
depsIn :: FilePath -> Req -> IO [String]
depsIn dir r = lines <$> readFile (dir </> "dep" </> node r <.> "dep")

-- | That the request's dep file lists each of the files, and only the
-- package's own.
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

  -- The sequence buck2 would dispatch, with D and E ready at the same time.
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

  -- An import of a dependency's module that wasn't compiled yet when the
  -- session was made.
  _ <- readProcess ghc ["-c", dir </> "psrc/P/Q.hs", "-this-unit-id", "p-0", "-hidir", dir </> "p", "-odir", dir </> "pobj", "-hide-all-packages", "-package", "base"] ""
  compiled (req "T.P" "T/P")

  -- An edit that changes nothing downstream: the same ABI, the same object.
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

  -- An edit that changes the ABI.
  appendFile (dir </> "src/T/C.hs") "\nanother :: Int\nanother = 2\n"
  compiled (req "T.C" "T/C")
  abi'' <- readFile (out </> "T/C.abi")
  assertBool "an exported binding changes the ABI" (abi /= abi'')
  compiled (req "T.B" "T/B")

  -- A module whose request has other flags: compiled in a session of its
  -- own, which reads from disk the imports that the other session compiled.
  compiled (req "T.B" "T/B"){extraFlags = ["-DOTHER_FLAGS"]}
  lists (req "T.B" "T/B") ["out/T/C.abi", "out/T/D.abi"]

  -- A Template Haskell module whose splice runs a module of the package,
  -- which per_module doesn't support (see Note [Template Haskell modules]
  -- in compile_per_module.bzl). It compiles in a session of its own too.
  -- The splice loads the module's object, which the session read from
  -- disk, so the compile fails, saying so.
  let th = ["-dynamic", "-package", "template-haskell"]
  writeFile (dir </> "src/T/G.hs") "{-# LANGUAGE TemplateHaskellQuotes #-}\nmodule T.G (g) where\nimport Language.Haskell.TH (Exp, Q)\ng :: Q Exp\ng = [| 3 :: Int |]\n"
  writeFile (dir </> "src/T/H.hs") "{-# LANGUAGE TemplateHaskell #-}\nmodule T.H (h) where\nimport T.G (g)\nh :: Int\nh = $(g)\n"
  compiled (req "T.G" "T/G"){extraFlags = th}
  (hCode, hErr) <- send (req "T.H" "T/H"){extraFlags = th ++ ["-DOTHER_FLAGS"]}
  assertBool ("T.H, whose splice runs T.G, fails to compile, saying so: " ++ hErr) (hCode /= 0 && "this target's own modules" `isInfixOf` hErr)
  -- A package-qualified import of a module whose name a home module has
  -- too: the package's, not the home module, which isn't compiled.
  createDirectoryIfMissing True (dir </> "src/Data")
  writeFile (dir </> "src/Data/Bool.hs") "module Data.Bool where\n"
  writeFile (dir </> "src/T/I.hs") "{-# LANGUAGE PackageImports #-}\nmodule T.I where\nimport \"base\" Data.Bool (bool)\ni :: Int\ni = bool 1 2 True\n"
  compiled (req "T.I" "T/I")

  -- A module compiled again after a change to a file its splice read, which
  -- GHC doesn't record: compiled all the same, as buck2 asked (GHC's own
  -- check would find it up to date), so its object has the new value.
  writeFile (dir </> "rf-input") "one"
  writeFile (dir </> "src/T/RF.hs") "{-# LANGUAGE TemplateHaskell #-}\nmodule T.RF where\nimport Language.Haskell.TH.Syntax (lift, runIO)\nrf :: Int\nrf = $(runIO (readFile \"rf-input\") >>= lift . length)\n"
  let rfReq = (req "T.RF" "T/RF"){extraFlags = ["-dynamic", "-package", "template-haskell"]}
  compiled rfReq
  rfBefore <- B.readFile (out </> "T/RF.o")
  writeFile (dir </> "rf-input") "three"
  compiled rfReq
  rfAfter <- B.readFile (out </> "T/RF.o")
  assertBool "a module is compiled whenever it is asked to be, whatever GHC's own check" (rfBefore /= rfAfter)

  -- A module with a foreign export: its stub header goes to the request's
  -- -stubdir, as `ghc -c` puts it, not next to its source.
  writeFile (dir </> "src/T/FE.hs") "module T.FE where\nforeign export ccall fe :: Int -> Int\nfe :: Int -> Int\nfe = (+ 1)\n"
  compiled (req "T.FE" "T/FE")
  inStubs <- doesFileExist (dir </> "stubs/T.FE/T/FE_stub.h")
  inSrc <- doesFileExist (dir </> "src/T/FE_stub.h")
  assertBool ("T.FE's stub header is in its -stubdir, not by its source: " ++ show (inStubs, inSrc)) (inStubs && not inSrc)

  -- A module that doesn't compile: its errors, at their source.
  writeFile (dir </> "src/T/F.hs") "module T.F where\nf :: Int\nf = \"no\"\n"
  (code, err) <- send (req "T.F" "T/F")
  assertBool ("T.F fails: " ++ show code) (code /= 0)
  assertBool ("T.F's error names its source and the problem: " ++ err) ("T/F.hs:3:5" `isInfixOf` err && "String" `isInfixOf` err)

  -- A request with options for the ghc program's runtime among its flags
  -- (the toolchain's compiler_flags may have them), which mean nothing to a
  -- session.
  compiled (req "T.E" "T/E"){extraFlags = ["+RTS", "-A64m", "-RTS"]}

  -- A request with a flag that sets GHC's state for the whole process,
  -- which one session can't have alone: refused, saying so.
  forM_ ["-fno-state-hack", "-dppr-debug"] $ \flag -> do
    (gCode, gErr) <- send (req "T.E" "T/E"){extraFlags = [flag]}
    assertBool ("a flag of the whole process is refused: " ++ show gCode ++ " " ++ gErr) (gCode /= 0 && flag `isInfixOf` gErr)

  -- A request of another version of the rules.
  (code', err') <- send (req "T.E" "T/E"){reqContract = "0"}
  assertBool ("a contract mismatch is refused: " ++ show code' ++ " " ++ err') (code' /= 0 && "version" `isInfixOf` err')

-- | A cycle through a boot file (see cyclePackage), compiled in the order
-- buck2 would, then again after an edit to its boot file.
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

  -- An edit to the boot file, then everything that reads it, in order.
  appendFile (dir </> "src/T/C.hs-boot") "\n-- an edit\n"
  compiled (req "T.C-boot" "T/C"){boot = True}
  compiled (req "T.D" "T/D")
  compiled (req "T.C" "T/C")
  compiled (req "T.B" "T/B")

-- | In session mode one-shot, a request of a target with boot files (see
-- cyclePackage): refused, saying why.
refusesBoots :: TestWorker -> String -> IO ()
refusesBoots w ghc = do
  _ <- cyclePackage w ghc
  (code, err) <- sendCycle w (req "T.D" "T/D")
  assertBool ("a target with boot files is refused: " ++ show code ++ " " ++ err) (code /= 0 && "hs-boot" `isInfixOf` err)

-- | In session mode auto, a session of a target without boot files is
-- one-shot, and one of a target with boot files (see cyclePackage) is
-- --make, as the worker's log says.
autoModes :: TestWorker -> String -> IO ()
autoModes w ghc = do
  _ <- cyclePackage w ghc
  compiledIn (sendOwn w) (twDir w) (req "T.E" "T/E")
  compiledIn (sendCycle w) (twDir w </> "cycle") (req "T.C-boot" "T/C"){boot = True}
  logged <- lines <$> readFile (twDir w </> "worker.log")
  let said l = assertBool ("the worker's log says " ++ show l ++ ": " ++ show logged) (any (l `isPrefixOf`) logged)
  said "ghc-worker: a one-shot session for the flags of T/E"
  said "ghc-worker: a --make session for the flags of T/C"

-- | The first splices of a new worker, run in two sessions at once. The
-- requests are sent together, so their sessions likely start GHC's object
-- linker, which is one per process, at the same time (see Note [Starting
-- the object linker once] in Worker); each splice waits for the other's to
-- start, so the sessions hash the objects they loaded at the same time.
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


-- | What a compile sees of modules with boot files, which must be what
-- `ghc -c` sees, whatever the session compiled before: in the cycle package
-- (see cyclePackage), whose requests the given Send makes.
bootViews :: Send -> FilePath -> String -> IO ()
bootViews send dir ghc = do
  let out = dir </> "out"
      compiled r = do
        (code, err) <- send r
        assertBool (node r ++ " compiles: " ++ err) (code == 0)
      showIface f = readProcess ghc ["--show-iface", f] ""
      -- Sessions of their own, made once the modules are written, as GHC's
      -- analysis of the target is made with the session.
      th = ["-dynamic", "-package", "template-haskell", "-DBOOT_VIEWS"]

  -- A module that runs a splice and has a boot file, compiled again after
  -- an edit, with its last compile's interface on disk. The compile is
  -- still checked against its boot file. That check gives the boot file's
  -- instance the name that the modules importing the boot file use (the
  -- boot's dfun).
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

  -- T.YZ imports T.YA, which imports T.Y's boot file, and the session has
  -- compiled T.Y itself. T.YZ is still compiled against the boot file, as
  -- `ghc -c` would compile it (an interface records the boot files below
  -- it), so its ABI is `ghc -c`'s.
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

  -- T.RB has a boot file, and imports T.RA, whose unfolding names T.RB
  -- back through the boot file. T.RB is compiled as `ghc -c` compiles it:
  -- T.RA's unfolding refers to the T.RB being compiled, so GHC finds the
  -- recursion (and gives rb no unfolding).
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

  -- T.SJ imports T.SI's boot file. Its session has compiled T.SI, and read
  -- T.SI's boot interface from disk for that compile (the boot file was
  -- compiled in another session). T.SJ sees the boot file's instance, not
  -- T.SI's, whose method it could otherwise inline (and then name a thing
  -- the boot interface hasn't, which GHC 9.14 panics at).
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

-- | Another target in the same worker, as targets share one. Its own T.E
-- is compiled at the same time as the first target's. Then each target
-- compiles a module that imports what only its own T.E exports.
--
-- Then each target compiles a T.W, at the same path relative to the
-- target. The first target's T.W runs a splice that makes the file
-- w-started, then waits for the file w-go. Meanwhile the other target's T.W
-- compiles, with a warning, and then the test makes w-go. Each request gets
-- its own module's diagnostics alone.
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
  -- (Bounded: a worker that compiled one module at a time would wait for
  -- T.W, which waits for this.)
  (otherWCode, otherWErr) <- fromMaybe (1, "no answer in two minutes, with T.W's compile waiting") <$> timeout 120000000 (sendIn "other" (req "T.W" "T/W"){extraFlags = unit ++ ["-Wunused-local-binds"]})
  writeFile (dir </> "w-go") ""
  (wCode, wErr) <- takeMVar mine
  assertBool ("the other target's T.W compiles, with its warning: " ++ otherWErr) (otherWCode == 0 && "othersUnused" `isInfixOf` otherWErr)
  assertBool ("T.W compiles, without the other target's warning: " ++ wErr) (wCode == 0 && not ("othersUnused" `isInfixOf` wErr))

-- | Requests whose session can't be made (a flag GHC doesn't know), two at
-- once: each fails, saying why, rather than waiting for a session that
-- never comes.
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

-- | A request for another GHC than the worker's is refused.
otherCompiler :: Send -> IO ()
otherCompiler send = do
  (code, err) <- send (req "T.E" "T/E"){compiler = Just "/no/such/ghc"}
  assertBool ("a request for another GHC is refused: " ++ err) (code /= 0 && "/no/such/ghc" `isInfixOf` err)

-- | The external interpreters of the package's worker, by their
-- environment, where /proc shows them.
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

-- | A worker of a new package, as the tests of a group see it.
data TestWorker = TestWorker
  { twDir :: FilePath
  , twProcess :: ProcessHandle
  , twSendIn :: FilePath -> Send -- a request for the package in a directory below
  }

-- | A request for the worker's own package.
sendOwn :: TestWorker -> Send
sendOwn w = twSendIn w ""

-- | Tests, in order, of one worker started as buck2 starts it, in a new
-- package's directory. Each request is a call of /worker.Worker/Execute on
-- its socket (see 'grpc'). The worker keeps one session, drops the others,
-- and says so in worker.log. A request may be for the package in any
-- directory below, as targets share a worker. The last test ends the worker
-- with SIGTERM, as buck2 does, which it must take quietly, removing its
-- temporary files.
withTestWorker :: String -> String -> FilePath -> String -> (IO TestWorker -> [TestTree]) -> TestTree
withTestWorker name mode worker ghc tests =
  withResource start stop $ \getW ->
    dependentTestGroup name AllFinish (tests getW ++ [testCase "ends on SIGTERM, leaving no temporary files" (getW >>= end)])
  where
    start = do
      -- Named by the initials of the group's name: the worker's socket is
      -- in this directory, and macOS limits a socket's path to 104 bytes,
      -- of which its $TMPDIR takes about 50.
      dir <- newPackage ghc [c | c : _ <- words name]
      logH <- openFile (dir </> "worker.log") WriteMode
      (ph, sock) <- startWorkerProcess worker [] dir [("GHC_WORKER_SESSIONS", "1"), ("GHC_WORKER_VERBOSE", "1"), ("GHC_WORKER_SESSION_MODE", mode), ("TMPDIR", dir </> "tmp")] (UseHandle logH)
      pure (TestWorker dir ph (\pkg -> grpc sock . argv pkg ghc))
    end w = do
      terminateProcess (twProcess w)
      code <- waitForProcess (twProcess w)
      code @?= ExitSuccess
      left <- listDirectory (twDir w </> "tmp")
      assertBool ("temporary files left: " ++ show left) (null left)
    -- (Whatever the tests did.)
    stop w = do
      terminateProcess (twProcess w)
      _ <- waitForProcess (twProcess w)
      removePathForcibly (twDir w)

-- | When a worker's parent goes away.
data Orphaned = Idle | AfterASplice | DuringASplice
  deriving (Eq, Show)

-- | A worker whose parent exits without ending it, as buck2's forkserver
-- does when the daemon is killed: the worker ends too. The parent exits:
--
-- - with nothing compiled (Idle);
-- - after a compile that ran a splice, with its sessions and the libraries
--   the splice loaded (AfterASplice);
-- - during a compile whose splice waits for a file that never comes, with
--   the worker's stderr closed, since a failure to write to it mustn't stop
--   the worker ending (DuringASplice).
--
-- The parent waits for the worker's socket, so that the worker has noted
-- its parent first. Then it waits for the file "go", which the test makes
-- when it is done with the worker, or for the test to have gone, so that a
-- test killed part-way leaves no worker.
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
