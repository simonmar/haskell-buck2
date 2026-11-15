{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
-- | Property tests that check that building through the worker gives the
-- same results as a plain `ghc -c`. We generate histories of a small
-- package, and build each history step by step through the worker, as
-- buck2 would build it. After each build, we compare the results with a
-- clean build of the same sources, with one `ghc -c` per module.
--
-- A history is a package, sometimes a second package p that it depends on,
-- and a sequence of builds, with edits to the sources before each one.
--
-- - The main package has modules M0..Mn, each importing some of the
--   modules before it. Some modules have a boot file, which modules before
--   them import {-# SOURCE #-}. Some have a Template Haskell splice, which
--   may only run template-haskell's code (see Note [Template Haskell
--   modules] in compile_per_module.bzl).
-- - p has modules P0..Pk, which the main package imports through p's early
--   package db, as the rules arrange for a dependency compiled per-module.
--   The db names no library, and its import directory is the one that p's
--   interfaces are written to as each module compiles. Sometimes p's
--   modules are named M0..Mk instead, so that a module of p can have the
--   same name as one of the main package. Only the unit id then tells them
--   apart, for example in the usages that the dep files are made from.
--
-- Each build gets a fresh worker, as each buck2 build does. The test sends
-- it the modules and boot files that buck2 would compile: those never
-- compiled before, and those whose source has changed since they were last
-- compiled, or a file that their dep file lists has (the early cut-off of
-- Note [Early cut-off by dep files] in compile_per_module.bzl). Each one is
-- sent once everything it imports is done, with independent ones sent at
-- the same time. A module with a failed import isn't sent. After each
-- build, every module and boot file must agree with the clean build on
-- whether it compiles, on its ABI hash, and on its object (from GHC 9.12,
-- whose objects are deterministic).
--
-- The worker and GHC are found as in the test suite (BUCK2_GHC_WORKER, GHC).
-- The command-line options are tasty's: --hedgehog-tests N runs N histories
-- (30 by default), and a failure prints how to run it again
-- (--hedgehog-replay).
module Main (main) where

import Control.Applicative ((<|>))
import Control.Concurrent (forkIO)
import Control.Concurrent.MVar
import Control.Exception (SomeException, catch, throwIO, try)
import Control.Monad (forM, forM_, replicateM, unless, when)
import Control.Monad.IO.Class (liftIO)
import qualified Data.ByteString as B
import Data.IORef
import Data.List (intercalate, sort)
import qualified Data.Map as M
import Data.Maybe (fromMaybe, isJust)
import Data.Version (showVersion, versionBranch)
import System.Directory
import System.Environment (lookupEnv)
import System.Exit (ExitCode (..), exitFailure)
import System.FilePath ((<.>), (</>))
import System.Info (fullCompilerVersion)
import System.IO (IOMode (..), hPutStrLn, openFile, stderr)
import System.Timeout (timeout)
import System.Posix.Process (getProcessID)
import System.Process

import Hedgehog
import qualified Hedgehog.Gen as Gen
import qualified Hedgehog.Range as Range
import Test.Tasty (TestTree, adjustOption, askOption, defaultMain, localOption, testGroup)
import Test.Tasty.Hedgehog (HedgehogTestLimit (..), testPropertyNamed)

import Client
import Contract (contract)

-- * Histories

data Ty = TInt | TInteger
  deriving (Eq, Show)

-- | A generated module. Modules are identified by keys: the main package's
-- from 0, and p's from 100 (see pkgP). The fields are:
--
-- - mImports: the modules it imports, all qualified. A module may import
--   modules of its own package with lower keys, and a module of the main
--   package may also import any module of p.
-- - mSourceImports: the modules it imports {-# SOURCE #-}. Each has a
--   higher key and a boot file.
-- - mValues: its exported values, each with a number for its name, a type,
--   and the constant in its definition. Value 0 also adds up value 0 of
--   each import, and value t of each import that has one. A module with
--   SOURCE imports also exports an INLINE value t, the sum of the SOURCE
--   imports' values 0, and for each SOURCE import a function that shows
--   the import's type T.
-- - mBoot: whether it has a boot file, which declares its value 0 and a
--   type T with a Show instance.
-- - mSplice: if it has a Template Haskell splice, the number that the
--   splice lifts.
-- - mComments and mBootComments: how many comment-only edits have been made
--   to it and to its boot file.
-- - mBroken: whether it has a type error.
-- - mOwnFlags: whether its requests have an extra flag, so that it compiles
--   in a session of its own, as a Template Haskell module does in the rules
--   because its package flags differ.
-- - mReexports: the imports whose value 0 it re-exports. Its importers'
--   value 0 adds those too. GHC then records a usage of the module that
--   defines the value in the importers' interfaces, though they don't
--   import that module.
-- - mOptions: the flags of its OPTIONS_GHC pragma, if any (see
--   optionFlags). They change how its compile reads and writes interfaces,
--   or give the same setting in another way, so that compiles whose flags
--   differ share the worker's interfaces only when they should (see
--   'interfaceKey' in the worker's Session).
data Mod = Mod
  { mImports :: [Int]
  , mSourceImports :: [Int]
  , mValues :: [(Int, Ty, Int)]
  , mBoot :: Bool
  , mSplice :: Maybe Int
  , mComments :: Int
  , mBootComments :: Int
  , mBroken :: Bool
  , mOwnFlags :: Bool
  , mReexports :: [Int]
  , mOptions :: [String]
  }
  deriving (Eq, Show)

data Edit
  = Comment Int
  | BootComment Int
  | Body Int Int Int -- the module, the value, and the value's new constant
  | AddValue Int
  | RemoveValue Int
  | Retype Int -- change the type of value 0, which the boot file declares too
  | AddImport Int Int
  | RemoveImport Int Int
  | AddSourceImport Int Int
  | RemoveSourceImport Int Int
  | Break Int -- add a type error, or remove it if there is one
  | AddReexport Int Int
  | RemoveReexport Int Int
  | SetOptions Int [String] -- replace the flags of its OPTIONS_GHC pragma
  deriving (Show)

-- | A build: the edits made before it, and whether its worker drops
-- sessions as soon as they are idle (a session limit of 0).
data Build = Build {bEdits :: [Edit], bEagerDrop :: Bool}
  deriving (Show)

-- | A history: whether its compiles optimise (-O), its modules keyed as
-- described at Mod, and its builds.
data History = History {hOptimise :: Bool, hModules :: [(Int, Mod)], hBuilds :: [Build]}
  deriving (Show)

-- | Generate a history. Its modules have boot files only if the argument is
-- True.
genHistory :: Bool -> Gen History
genHistory bootsAllowed = do
  -- Each count has a constant part and a part that grows with Hedgehog's
  -- size parameter. The size grows by one with each test, so it stays
  -- small over the default 30 histories, and a history needs several
  -- builds and edits to be worth running whatever its size. A long run
  -- (--hedgehog-tests 500, say) reaches the larger sizes, and with them
  -- longer chains of imports and more edits between builds.
  n <- grow 2 6 6
  pn <- Gen.frequency [(1, pure 0), (2, Gen.int (Range.constant 1 3))]
  -- p's modules. Their keys start from pkgClash when they should have the
  -- same names as the main package's (see modName).
  pbase <- Gen.element [pkgP, pkgClash]
  let pkeys = [pbase + j | j <- [0 .. pn - 1]]
  pmods <- forM [0 .. pn - 1] $ \i -> do
    imports <- Gen.subsequence (take i pkeys)
    k <- Gen.int (Range.constant 1 3)
    values <- forM [0 .. k - 1] $ \v -> (,,) v <$> Gen.element [TInt, TInteger] <*> Gen.int (Range.linear 0 9)
    reexports <- Gen.subsequence imports
    pure (Mod imports [] values False Nothing 0 0 False False reexports [])
  boots <- forM [0 .. n - 1] $ \i -> if i == 0 || not bootsAllowed then pure False else Gen.frequency [(2, pure False), (1, pure True)]
  mods <- forM [0 .. n - 1] $ \i -> do
    own' <- if i == 0 then pure [] else Gen.subsequence [0 .. i - 1]
    fromP <- Gen.subsequence pkeys
    let imports = own' ++ fromP
    sourceImports <- Gen.subsequence [j | j <- [i + 1 .. n - 1], boots !! j]
    k <- Gen.int (Range.constant 1 3)
    values <- forM [0 .. k - 1] $ \v -> (,,) v <$> Gen.element [TInt, TInteger] <*> Gen.int (Range.linear 0 9)
    splice <- Gen.frequency [(3, pure Nothing), (1, Just <$> Gen.int (Range.constant 0 9))]
    own <- Gen.frequency [(2, pure False), (1, pure True)]
    reexports <- Gen.subsequence imports
    options <- Gen.frequency [(3, pure []), (1, genOptions)]
    pure (Mod imports sourceImports values (boots !! i) splice 0 0 False own reexports options)
  buildCount <- grow 2 6 4
  builds <- replicateM buildCount (Build <$> (grow 1 4 3 >>= \k -> replicateM k (genEdit ([0 .. n - 1] ++ pkeys))) <*> Gen.bool)
  History <$> Gen.bool <*> pure (zip [0 ..] mods ++ zip pkeys pmods) <*> pure builds
  where
    grow lo hi extra = (+) <$> Gen.int (Range.constant lo hi) <*> Gen.int (Range.linear 0 extra)

-- | The flags that a module's OPTIONS_GHC pragma may have. Some change how
-- its compile reads interfaces (-O0 and -fignore-interface-pragmas ignore
-- the unfoldings in them) or writes its own (-fomit-interface-pragmas
-- leaves them out). Others give the same setting as GHC's default, or as
-- another flag here, or don't matter to interfaces at all. A pragma may
-- also give a flag twice, or the same flags in another order than another
-- module's.
optionFlags :: [String]
optionFlags =
  [ "-O0"
  , "-O"
  , "-fignore-interface-pragmas"
  , "-fno-ignore-interface-pragmas"
  , "-fomit-interface-pragmas"
  , "-fno-omit-interface-pragmas"
  , "-w"
  , "-fno-warn-orphans"
  ]

genOptions :: Gen [String]
genOptions = Gen.list (Range.constant 1 3) (Gen.element optionFlags)

-- | pkgP is the lowest key of p's modules, and the main package's modules
-- have lower keys. p's modules with keys from pkgClash up are named
-- M0, M1 and so on, like the main package's (see modName).
pkgP, pkgClash :: Int
pkgP = 100
pkgClash = 200

inP :: Int -> Bool
inP i = i >= pkgP

-- | Generate an edit to one or two of the modules with the given keys.
genEdit :: [Int] -> Gen Edit
genEdit keys =
  Gen.choice
    [ Comment <$> m
    , BootComment <$> m
    , Body <$> m <*> Gen.int (Range.linear 0 3) <*> Gen.int (Range.linear 0 9)
    , AddValue <$> m
    , RemoveValue <$> m
    , Retype <$> m
    , AddImport <$> m <*> m
    , RemoveImport <$> m <*> m
    , AddSourceImport <$> m <*> m
    , RemoveSourceImport <$> m <*> m
    , Break <$> m
    , AddReexport <$> m <*> m
    , RemoveReexport <$> m <*> m
    , SetOptions <$> m <*> Gen.frequency [(1, pure []), (2, genOptions)]
    ]
  where
    m = Gen.element keys

-- | Apply an edit to the modules. An edit that doesn't make sense, such as
-- one that removes a value or import that the module doesn't have, changes
-- nothing. Then any edit applies to any package, so a history that
-- Hedgehog has shrunk, removing some modules, is still valid.
applyEdit :: M.Map Int Mod -> Edit -> M.Map Int Mod
applyEdit mods e = case e of
  Comment i -> at i $ \m -> m{mComments = mComments m + 1}
  BootComment i -> at i $ \m -> if mBoot m then m{mBootComments = mBootComments m + 1} else m
  Body i v c -> at i $ \m -> m{mValues = [if k == v then (k, t, c) else (k, t, x) | (k, t, x) <- mValues m]}
  AddValue i -> at i $ \m -> m{mValues = mValues m ++ [(1 + maximum [k | (k, _, _) <- mValues m], TInt, 0)]}
  RemoveValue i -> at i $ \m -> if length (mValues m) > 1 then m{mValues = init (mValues m)} else m
  Retype i -> at i $ \m -> m{mValues = [if k == 0 then (k, flip' t, x) else (k, t, x) | (k, t, x) <- mValues m]}
  AddImport i j -> if j < i && inP i == inP j || inP j && not (inP i) then at i (\m -> m{mImports = add j (mImports m)}) else mods
  RemoveImport i j -> at i $ \m -> m{mImports = filter (/= j) (mImports m)}
  AddSourceImport i j -> if j > i && not (inP i) && maybe False mBoot (M.lookup j mods) then at i (\m -> m{mSourceImports = add j (mSourceImports m)}) else mods
  RemoveSourceImport i j -> at i $ \m -> m{mSourceImports = filter (/= j) (mSourceImports m)}
  Break i -> at i $ \m -> m{mBroken = not (mBroken m)}
  AddReexport i j -> at i $ \m -> if j `elem` mImports m then m{mReexports = add j (mReexports m)} else m
  RemoveReexport i j -> at i $ \m -> m{mReexports = filter (/= j) (mReexports m)}
  SetOptions i fs -> at i $ \m -> m{mOptions = fs}
  where
    at i f = M.adjust f i mods
    add j js = if j `elem` js then js else sort (j : js)
    flip' TInt = TInteger
    flip' TInteger = TInt

-- * Sources

-- | A node of the build: a module, or its boot file.
type Node = (Int, Bool)

nodes :: M.Map Int Mod -> [Node]
nodes mods = concat [[(i, True) | mBoot m] ++ [(i, False)] | (i, m) <- M.toList mods]

-- | The nodes whose outputs a node's compile reads, and so has to wait for.
-- A boot file reads none. A module reads its imports, the boot files of its
-- SOURCE imports, and its own boot file.
--
-- A module of the main package also waits for every module of p that its
-- imports from p depend on, directly or indirectly, since GHC may read
-- their interfaces too. The rules make it wait for these in the same way
-- (see Note [Compiling against dependencies module by module] in
-- compile_per_module.bzl).
nodeDeps :: M.Map Int Mod -> Node -> [Node]
nodeDeps _ (_, True) = []
nodeDeps mods (i, False) =
  [(j, False) | j <- mImports m] ++ [(j, True) | j <- mSourceImports m] ++ [(i, True) | mBoot m]
    ++ (if inP i then [] else [(j, False) | j <- belowInP mods [x | x <- mImports m, inP x]])
  where
    m = mods M.! i

-- | The given modules of p, and every module of p that they import,
-- directly or indirectly.
belowInP :: M.Map Int Mod -> [Int] -> [Int]
belowInP mods = go []
  where
    go visited [] = visited
    go visited (x : xs)
      | x `elem` visited = go visited xs
      | otherwise = go (x : visited) (mImports (mods M.! x) ++ xs)

nodeName :: Node -> String
nodeName (i, boot) = modName i ++ (if boot then "-boot" else "")

modName :: Int -> String
modName i
  | i >= pkgClash = "M" ++ show (i - pkgClash)
  | inP i = "P" ++ show (i - pkgP)
  | otherwise = "M" ++ show i

-- | The alias that a module imports another module as. Modules use aliases,
-- not module names, to refer to their imports' values, because a module of
-- p may have the same name as one of the main package's.
alias :: Int -> String
alias j = "X" ++ show j

-- | The directories of the sources and outputs of a node's package. The
-- outputs of both packages are under one configuration's directory, laid
-- out as buck2 lays them out, so that the worker's one-shot sessions for the
-- two packages share their external state (see 'interfaceKey' in the
-- worker's Session).
srcDir, outDir :: Int -> FilePath
srcDir i = if inP i then "psrc" else "src"
outDir i = "art" </> "root" </> "cfg" </> if inP i then "pout" else "out"

suffix :: Node -> String
suffix (_, boot) = if boot then "-boot" else ""

source :: Node -> FilePath
source n@(i, _) = srcDir i </> modName i <.> ("hs" ++ suffix n)

value :: Int -> Int -> String
value j k = "v" ++ show j ++ "_" ++ show k

tyName :: Ty -> String
tyName TInt = "Int"
tyName TInteger = "Integer"

render :: M.Map Int Mod -> Node -> String
render mods (i, True) =
  let m = mods M.! i
      t = case [vt | (0, vt, _) <- mValues m] of
        vt : _ -> vt
        [] -> TInt
   in unlines ["module " ++ modName i ++ " where", "-- edit " ++ show (mBootComments m), value i 0 ++ " :: " ++ tyName t, "data " ++ ty i, "instance Show " ++ ty i]
render mods (i, False) =
  unlines $
    ["{-# OPTIONS_GHC " ++ unwords (mOptions m) ++ " #-}" | not (null (mOptions m))]
      ++ ["{-# LANGUAGE TemplateHaskell #-}" | isJust (mSplice m)]
      ++ ["{-# LANGUAGE PackageImports #-}" | fromP]
      ++ ["module " ++ modName i ++ " (" ++ intercalate ", " exports ++ ") where"]
      ++ ["import qualified " ++ (if fromP && inP j then "\"p\" " else "") ++ modName j ++ " as " ++ alias j | j <- mImports m]
      ++ ["import {-# SOURCE #-} qualified " ++ modName j ++ " as " ++ alias j | j <- mSourceImports m]
      ++ ["import Language.Haskell.TH.Syntax (lift)" | isJust (mSplice m)]
      ++ ["-- edit " ++ show (mComments m)]
      ++ concat
        [ [ value i k ++ " :: " ++ tyName t
          , value i k ++ " = " ++ show c ++ concat [" + fromIntegral " ++ alias j ++ "." ++ v | k == 0, j <- mImports m, v <- value j 0 : ["t" ++ show j | hasT j] ++ [value r 0 | r <- reexported j]]
          ]
        | (k, t, c) <- mValues m
        ]
      ++ concat [["t" ++ show i ++ " :: Integer", "t" ++ show i ++ " = 0" ++ concat [" + fromIntegral " ++ alias j ++ "." ++ value j 0 | j <- mSourceImports m], "{-# INLINE t" ++ show i ++ " #-}"] | hasT i]
      ++ concat [[shows' j ++ " :: " ++ alias j ++ "." ++ ty j ++ " -> String", shows' j ++ " = show"] | j <- mSourceImports m]
      ++ concat [["data " ++ ty i ++ " = " ++ ty i, "instance Show " ++ ty i ++ " where show _ = " ++ show (ty i)] | mBoot m]
      ++ concat [["s" ++ show i ++ " :: Integer", "s" ++ show i ++ " = $(lift (" ++ show j ++ " :: Integer))"] | Just j <- [mSplice m]]
      ++ (if mBroken m then ["broken :: Int", "broken = \"not an Int\""] else [])
  where
    m = mods M.! i
    exports = [value i k | (k, _, _) <- mValues m] ++ ["t" ++ show i | hasT i] ++ map shows' (mSourceImports m) ++ [ty i | mBoot m] ++ ["s" ++ show i | isJust (mSplice m)] ++ [alias r ++ "." ++ value r 0 | r <- reexported i]
    hasT j = not (null (mSourceImports (mods M.! j)))
    -- A re-export of an import that an edit removed is dropped.
    reexported j = let mj = mods M.! j in [r | r <- mReexports mj, r `elem` mImports mj]
    fromP = not (inP i) && any inP (mImports m)
    shows' j = "show" ++ show i ++ "_" ++ show j

-- | The type a module with a boot file declares in both.
ty :: Int -> String
ty i = "T" ++ show i

-- | commonFlags are the flags of every compile in the history, and
-- nodeFlags are the flags specific to a node's package and module.
commonFlags :: History -> [String]
commonFlags h =
  ["-hide-all-packages", "-package", "base"]
    ++ (if hOptimise h then ["-O"] else ["-O0"])
    -- GHC is dynamically linked, so to run a splice it loads dynamic
    -- objects, which -dynamic makes.
    ++ ["-dynamic" | any (isJust . mSplice . snd) (hModules h)]

nodeFlags :: M.Map Int Mod -> Node -> [String]
nodeFlags mods (i, _)
  | inP i = ["-this-unit-id", "p", "-i" ++ outDir pkgP]
  | otherwise =
      ["-DOWN_SESSION" | mOwnFlags m]
        ++ (if isJust (mSplice m) then ["-package", "template-haskell"] else [])
        ++ (if any (inP . fst) (M.toList mods) then ["-package-db", "pdb", "-package", "p"] else [])
        ++ ["-iout"]
  where
    m = mods M.! i

-- * Running a history

-- | The result of a build for one node. Compiled holds the node's ABI hash,
-- its object, and the usages of imports that its interface records. Failed
-- holds the compile's errors. Blocked means the node wasn't compiled because
-- something it imports failed.
data Outcome = Compiled String B.ByteString [String] | Failed String | Blocked
  deriving (Eq)

describe :: Outcome -> String
describe (Compiled abi _ us) = "compiled, ABI " ++ abi ++ (if null us then "" else ", usages " ++ intercalate "; " us)
describe (Failed err) = "failed: " ++ take 400 err
describe Blocked = "not compiled (an import failed)"

isCompiled :: Outcome -> Bool
isCompiled (Compiled _ _ _) = True
isCompiled _ = False

-- | How to run the histories: the worker, GHC, and working directory;
-- whether to compare objects (which are deterministic from GHC 9.12) or
-- else the usages that interfaces record; and whether the worker uses
-- one-shot sessions rather than --make ones.
data Config = Config {cWorker :: FilePath, cGhc :: String, cDir :: FilePath, cObjects :: Bool, cOneShot :: Bool}

-- | Counts of what a history's builds did. The coverage checks in
-- historyProp use them to make sure the generated histories exercise the
-- cases they are meant to.
data Stats = Stats {sSkipped :: Int, sRecompiled :: Int, sFailed :: Int, sBlocked :: Int}

-- | For each node, the source the worker last compiled it from, and the
-- contents at that time of each file its dep file lists. This is how the
-- test decides, as buck2 would, whether a node is up to date.
type LastOk = M.Map Node (String, [(FilePath, Maybe B.ByteString)])

-- | Run each build of the history through the worker, and as a clean
-- build, and compare them. Returns a description of the first build where
-- they disagree, if there is one.
runHistory :: Config -> History -> IO (Either String (), Stats)
runHistory cfg h = do
  stats <- newIORef (Stats 0 0 0 0)
  let dir = cDir cfg
  removePathForcibly dir
  mapM_ (createDirectoryIfMissing True . (dir </>)) ["w/src", "w" </> outDir 0, "w/psrc", "w" </> outDir pkgP, "w/dep", "w/tmp", "ref"]
  -- Register p's early package db (see the module's description) for the
  -- worker's builds. Each clean build registers its own.
  registerP cfg (dir </> "w") [i | (i, _) <- hModules h, inP i]
  lastOk <- newIORef M.empty
  let go _ _ [] = pure (Right ())
      go mods n (b : rest) = do
        let mods' = foldl applyEdit mods (bEdits b)
            built = mods'
        forM_ (nodes built) $ \node -> writeFileIfChanged (dir </> "w" </> source node) (render built node)
        (worker, skipped) <- workerBuild cfg h b built lastOk stats
        ref <- refBuild cfg h built
        case [(node, w, r) | (node, w) <- M.toList worker, let r = ref M.! node, not (agree w r)] of
          [] -> go mods' (n + 1) rest
          diffs ->
            pure . Left $
              unlines $
                ("after build " ++ show (n :: Int) ++ ":")
                  : [nodeName node ++ ": through the worker " ++ describe w ++ (if node `elem` skipped then " (skipped as up to date)" else "") ++ "; with ghc -c " ++ describe r | (node, w, r) <- diffs]
  result <- go (M.fromList (hModules h)) 1 (hBuilds h)
  (,) result <$> readIORef stats
  where
    agree (Compiled a o u) (Compiled a' o' u') = a == a' && (if cObjects cfg then o == o' else u == u')
    agree (Failed _) (Failed _) = True
    agree Blocked Blocked = True
    agree _ _ = False

-- | If p has modules, register its early package db in the given directory.
-- The db names no library, and its import directory is the one that p's
-- interfaces are written to.
registerP :: Config -> FilePath -> [Int] -> IO ()
registerP _ _ [] = pure ()
registerP cfg dir ps = do
  let conf = dir </> "p.conf"
  removePathForcibly (dir </> "pdb")
  writeFile conf ("name: p\nversion: 0\nid: p\nkey: p\nexposed: True\nexposed-modules: " ++ unwords (map modName ps) ++ "\nimport-dirs: " ++ dir </> outDir pkgP ++ "\n")
  _ <- readProcess (ghcPkgOf (cGhc cfg)) ["init", dir </> "pdb"] ""
  -- --force, because ghc-pkg refuses a package whose interfaces don't
  -- exist yet. It still warns about them, so we ignore its output.
  _ <- readProcessWithExitCode (ghcPkgOf (cGhc cfg)) ["register", "--force", "--package-db", dir </> "pdb", conf] ""
  pure ()

writeFileIfChanged :: FilePath -> String -> IO ()
writeFileIfChanged path s = do
  old <- (Just <$> readFile' path) `catchAny` pure Nothing
  unless (old == Just s) (writeFile path s)
  where
    readFile' p = do t <- readFile p; length t `seq` pure t

-- | Sort the nodes into layers, so that each node's dependencies are all in
-- earlier layers. Also returns the nodes that couldn't be placed, because
-- they are in a cycle or depend on one.
layers :: (Node -> [Node]) -> [Node] -> ([[Node]], [Node])
layers deps = go M.empty
  where
    go _ [] = ([], [])
    go done pending =
      let ready = [n | n <- pending, all (`M.member` done) (deps n)]
       in if null ready then ([], pending) else let (rest, left) = go (M.union done (M.fromList [(n, ()) | n <- ready])) (filter (`notElem` ready) pending) in (ready : rest, left)

-- | Run one build through a fresh worker. Each node is sent as soon as the
-- nodes it waits for are done, as buck2 sends them. Returns each node's
-- outcome, and the nodes that were skipped because they were up to date.
workerBuild :: Config -> History -> Build -> M.Map Int Mod -> IORef LastOk -> IORef Stats -> IO (M.Map Node Outcome, [Node])
workerBuild cfg h b mods lastOk stats = do
  let wdir = cDir cfg </> "w"
  -- Each build overwrites the worker's log, so after a failure the log of
  -- the failing build is left to look at.
  logH <- openFile (wdir </> "worker.log") WriteMode
  let mode = if cOneShot cfg then "one-shot" else "make"
  withWorkerProcess (cWorker cfg) [] wdir ([("TMPDIR", wdir </> "tmp"), ("BUCK2_GHC_WORKER_VERBOSE", "1"), ("BUCK2_GHC_WORKER_SESSION_MODE", mode)] ++ [("BUCK2_GHC_WORKER_SESSIONS", "0") | bEagerDrop b]) (UseHandle logH) $ \sock -> do
      skippedRef <- newIORef []
      vars <- M.fromList <$> forM (nodes mods) (\node -> (,) node <$> newEmptyMVar)
      let result node = readMVar (vars M.! node) >>= either (\(e :: SomeException) -> throwIO e) pure
      forM_ (nodes mods) $ \node -> forkIO $ do
        r <- try $ do
          deps <- mapM result (nodeDeps mods node)
          decide wdir sock skippedRef (all isCompiled deps) node
        putMVar (vars M.! node) r
      (,) . M.fromList <$> forM (nodes mods) (\node -> (,) node <$> result node) <*> readIORef skippedRef
  where
    count = update stats
    -- Each node's compile runs in a thread of its own, so the shared
    -- records must be updated atomically.
    update r f = atomicModifyIORef' r (\x -> (f x, ()))
    decide wdir sock skippedRef depsOk node
      | not depsOk = do
          update lastOk (M.delete node)
          count (\st -> st{sBlocked = sBlocked st + 1})
          pure Blocked
      | otherwise = do
          let src = render mods node
          previous <- M.lookup node <$> readIORef lastOk
          upToDate <- case previous of
            Just (s, deps) | s == src -> and <$> mapM (\(f, c) -> (== c) <$> contents (wdir </> f)) deps
            _ -> pure False
          if upToDate
            then count (\st -> st{sSkipped = sSkipped st + 1}) >> update skippedRef (node :) >> current wdir node
            else do
              -- Compiling one of these modules takes a second or two, so a
              -- request that takes minutes means the worker has hung.
              answer <- timeout 120000000 (grpc sock (request node))
              (code, err) <- maybe (fail ("the worker didn't answer " ++ nodeName node ++ " in two minutes (see " ++ (wdir </> "worker.log") ++ ")")) pure answer
              when (isJust previous) $ count (\st -> st{sRecompiled = sRecompiled st + 1})
              if code /= 0
                then do
                  update lastOk (M.delete node)
                  count (\st -> st{sFailed = sFailed st + 1})
                  pure (Failed err)
                else do
                  deps <- lines <$> readFile (wdir </> depFile node)
                  cs <- mapM (contents . (wdir </>)) deps
                  update lastOk (M.insert node (src, zip deps cs))
                  current wdir node
    contents f = (Just <$> B.readFile f) `catchAny` pure Nothing
    current wdir node@(i, _) = do
      let out ext = wdir </> outDir i </> modName i <.> (ext ++ suffix node)
      us <- if cObjects cfg then pure [] else usagesOf <$> readProcess (cGhc cfg) ["--show-iface", out "hi"] ""
      Compiled . trim <$> readFile (out "abi") <*> B.readFile (out "o") <*> pure us
    -- Named after the package as well as the module, since a module of
    -- each package may have the same name.
    depFile node@(i, _) = "dep" </> (if inP i then "p-" else "") ++ nodeName node <.> "dep"
    request node@(i, boot) =
      [ "--request", "--contract", contract
      , "--depfile", depFile node, "--abi", outDir i </> modName i <.> ("abi" ++ suffix node), "--module", modName i
      , "--source", source node, "--outdir", outDir i, "--hisuf", "hi", "--srcroot=" ++ srcDir i
      ] ++ ["--boot" | boot]
      ++ ["--hidir=p=" ++ outDir pkgP | not (inP i)]
      ++ ["--", cGhc cfg] ++ commonFlags h ++ nodeFlags mods node
      ++ ["--", "-c", source node, "-o", outDir i </> modName i <.> ("o" ++ suffix node), "-ohi", outDir i </> modName i <.> ("hi" ++ suffix node)]

-- | A clean build of the same sources, with one `ghc -c` per node.
refBuild :: Config -> History -> M.Map Int Mod -> IO (M.Map Node Outcome)
refBuild cfg h mods = do
  let rdir = cDir cfg </> "ref"
  removePathForcibly rdir
  mapM_ (createDirectoryIfMissing True . (rdir </>)) ["src", outDir 0, "psrc", outDir pkgP]
  registerP cfg rdir [i | i <- M.keys mods, inP i]
  forM_ (nodes mods) $ \node -> writeFile (rdir </> source node) (render mods node)
  outcomes <- newIORef M.empty
  forM_ (concat (fst (layers (nodeDeps mods) (nodes mods)))) $ \node@(i, _) -> do
    done <- readIORef outcomes
    outcome <-
      if any (\d -> not (maybe False isCompiled (M.lookup d done))) (nodeDeps mods node)
        then pure Blocked
        else do
          let flags = commonFlags h ++ nodeFlags mods node ++ ["-fobject-determinism" | cObjects cfg]
          (code, _, err) <- readCreateProcessWithExitCode (proc (cGhc cfg) (["-c", source node, "-odir", outDir i, "-hidir", outDir i] ++ flags)){cwd = Just rdir} ""
          case code of
            ExitSuccess -> do
              iface <- readProcess (cGhc cfg) ["--show-iface", rdir </> outDir i </> modName i <.> ("hi" ++ suffix node)] ""
              Compiled (abiOf iface) <$> B.readFile (rdir </> outDir i </> modName i <.> ("o" ++ suffix node)) <*> pure (if cObjects cfg then [] else usagesOf iface)
            _ -> pure (Failed err)
    modifyIORef' outcomes (M.insert node outcome)
  readIORef outcomes
  where
    abiOf iface = case [w | l <- lines iface, "ABI" : "hash:" : w : _ <- [words l]] of
      a : _ -> a
      [] -> "?"

-- | The usages of imported modules in the text that `ghc --show-iface`
-- prints, which are lines of the form "import -/ M hash". Since GHC 9.14 the
-- first of them is on the "usages:" line itself. Before GHC 9.12, whose
-- objects aren't deterministic and so aren't compared, the usages show what
-- a module was compiled against, which its ABI hash doesn't.
usagesOf :: String -> [String]
usagesOf iface = [unwords u | l <- lines iface, u@("import" : "-/" : _) <- [dropWhile (/= "import") (words l)]]

catchAny :: forall a. IO a -> IO a -> IO a
catchAny a b = (try a :: IO (Either SomeException a)) >>= either (const b) pure

trim :: String -> String
trim = reverse . dropWhile (`elem` ("\r\n " :: String)) . reverse

main :: IO ()
main = do
  worker <- fromMaybe "buck2-ghc-worker" <$> lookupEnv "BUCK2_GHC_WORKER"
  ghc <- fromMaybe "ghc" <$> lookupEnv "GHC"
  version <- trim <$> readProcess ghc ["--numeric-version"] ""
  when (version /= showVersion fullCompilerVersion) $ do
    hPutStrLn stderr ("the props were built with GHC " ++ showVersion fullCompilerVersion ++ " but `" ++ ghc ++ "` is " ++ version ++ ": set GHC")
    exitFailure
  tmp <- getTemporaryDirectory
  pid <- getProcessID
  let v = versionBranch fullCompilerVersion
      cfg = Config worker ghc (tmp </> ("buck2-ghc-worker-props-" ++ show pid)) (v >= [9, 12]) False
      -- Each property has a directory of its own, because tasty runs them
      -- at the same time.
      oneShotCfg = cfg{cOneShot = True, cDir = cDir cfg ++ "-one-shot"}
      bootCycleCfg = cfg{cDir = cDir cfg ++ "-boot-cycle"}
      bootCycle2Cfg = cfg{cDir = cDir cfg ++ "-boot-cycle-2"}
  -- If a property fails, its directory is kept, so that we can look at
  -- what the failing history built.
  let tree = adjustOption (\(HedgehogTestLimit n) -> HedgehogTestLimit (n <|> Just 30)) . askOption $ \(HedgehogTestLimit n) ->
        -- Test both of the worker's explicit session modes (see Note
        -- [One-shot sessions] in the worker's Session), rather than the
        -- default, auto, which mixes them. With --make sessions the
        -- histories may have boot files. With one-shot sessions they have
        -- none, since the worker refuses targets with boot files in that
        -- mode.
        testGroup
          "a history built through the worker agrees with clean ghc -c builds"
          [ testPropertyNamed "with --make sessions" "historyMake" (historyProp cfg (maybe 30 fromIntegral n))
          , testPropertyNamed "with one-shot sessions" "historyOneShot" (historyProp oneShotCfg (maybe 30 fromIntegral n))
          , fixed (testPropertyNamed "a boot file cycle rebuilt with -O" "bootCycle" (fixedHistory bootCycleCfg bootCycle))
          , fixed (testPropertyNamed "a second boot file cycle rebuilt with -O" "bootCycle2" (fixedHistory bootCycle2Cfg bootCycle2))
          ]
  defaultMain tree `catch` \code -> do
    when (code == ExitSuccess) (mapM_ (removePathForcibly . cDir) [cfg, oneShotCfg, bootCycleCfg, bootCycle2Cfg])
    throwIO code

-- | Run a property that doesn't generate anything only once. main sets
-- tasty-hedgehog's test limit for all the properties, and that limit
-- overrides a property's own withTests, so we set it back to 1 here.
fixed :: TestTree -> TestTree
fixed = localOption (HedgehogTestLimit (Just 1))

-- | A property that the given history, built through a worker of the given
-- configuration, agrees with clean builds. Nothing is generated, so it
-- only needs to run once (see 'fixed').
fixedHistory :: Config -> History -> Property
fixedHistory cfg h = withTests 1 . property $ do
  (result, _) <- liftIO (runHistory cfg h)
  either (\err -> annotate err >> failure) (const success) result

-- | A fixed history with import cycles through boot files. M1 imports M4
-- through M4's boot file, and M4 imports M1. M0 imports M1 through M1's
-- boot file. M5 imports M0, and M2, which imports M1. With -O, after another
-- edit to a comment in M0, M5 must compile in the second build as it did in
-- the first.
bootCycle :: History
bootCycle =
  History
    { hOptimise = True
    , hModules =
        [ (0, plain{mSourceImports = [1]})
        , (1, plain{mSourceImports = [4], mBoot = True})
        , (2, plain{mImports = [1]})
        , (3, plain)
        , (4, plain{mImports = [1], mBoot = True})
        , (5, plain{mImports = [0, 2]})
        ]
    , hBuilds = [Build [Comment 0] False, Build [Comment 0] False]
    }
  where
    plain = Mod [] [] [(0, TInt, 0)] False Nothing 0 0 False False [] []

-- | A second fixed history with a boot file cycle. M1 imports M2 through
-- M2's boot file, and M1's INLINE value t1 uses M2. M2 imports M0, which
-- imports M1 through M1's boot file. M3 imports M1. M5 imports M2, and also
-- M3, through an edit before the first build. With -O, M3's interface has an
-- unfolding that mentions M2 through t1, though M3 doesn't import M2. After
-- an edit to a comment in M0, M5 must compile in the second build as it did
-- in the first.
bootCycle2 :: History
bootCycle2 =
  History
    { hOptimise = True
    , hModules =
        [ (0, plain{mSourceImports = [1]})
        , (1, plain{mSourceImports = [2], mBoot = True, mSplice = Just 1})
        , (2, plain{mImports = [0], mBoot = True})
        , (3, plain{mImports = [1], mSplice = Just 6})
        , (4, plain)
        , (5, plain{mImports = [2]})
        ]
    , hBuilds = [Build [AddImport 5 3] False, Build [Comment 0] False]
    }
  where
    plain = Mod [] [] [(0, TInt, 0)] False Nothing 0 0 False False [] []

-- | The property that generated histories built through the worker agree
-- with clean builds. The argument is the number of histories to run, which
-- decides whether the coverage minimums are checked.
historyProp :: Config -> Int -> Property
historyProp cfg tests =
  -- Allow only a few shrinks, since each one runs a whole history, which
  -- takes a minute or more.
  withShrinks 30 . property $ do
    h <- forAll (genHistory (not (cOneShot cfg)))
    (result, st) <- liftIO (runHistory cfg h)
    -- Check how often the histories include the cases they are meant to
    -- test, judged from the package as first generated. A minimum catches a
    -- generator that has stopped producing a case. Each minimum is far
    -- enough below the case's usual share that 30 histories fall short of
    -- one only about once in 3,000 runs. With fewer than 30 histories, the
    -- cases are only counted, not checked.
    let mods = M.fromList (hModules h)
        ms = M.elems mods
        sourced j = not (null (mSourceImports (mods M.! j)))
        cover' p l b = if tests >= 30 then cover p l b else classify l b
    cover' 50 "a module skipped as up to date" (sSkipped st > 0)
    cover' 40 "a module compiled again" (sRecompiled st > 0)
    cover' 25 "a module failed" (sFailed st > 0)
    cover' 15 "a module blocked by a failed import" (sBlocked st > 0)
    cover' 25 "a module with a session of its own" (any mOwnFlags ms)
    unless (cOneShot cfg) $ do
      cover' 25 "a boot file" (any mBoot ms)
      cover' 10 "a SOURCE import" (any (not . null . mSourceImports) ms)
      cover' 10 "an import of a module with SOURCE imports" (any (any sourced . filter (not . inP) . mImports) ms)
    cover' 10 "a splice" (any (isJust . mSplice . snd) (hModules h))
    unless (cOneShot cfg) $ classify "a splice in a module with a boot file" (any (\m -> mBoot m && isJust (mSplice m)) ms)
    cover' 10 "an import from p" (any (any inP . mImports) ms)
    cover' 10 "a module of p with the name of one of the main package" (any (\i -> i >= pkgClash && i - pkgClash < M.size (M.filterWithKey (\k _ -> not (inP k)) mods)) (M.keys mods))
    cover' 10 "a value used through a re-export" (any (any (\j -> any (`elem` mImports (mods M.! j)) (mReexports (mods M.! j))) . mImports) ms)
    cover' 45 "sessions dropped as soon as idle" (any bEagerDrop (hBuilds h))
    cover' 25 "a module with OPTIONS_GHC flags" (any (not . null . mOptions) ms)
    case result of
      Right () -> success
      Left err -> annotate err >> failure
