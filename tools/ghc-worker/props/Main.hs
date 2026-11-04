{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
-- | Property tests of the worker against a plain `ghc -c`. We generate
-- histories of a small package, and build each again and again through the
-- worker, as buck2 would build it, each time comparing it with a clean
-- one-shot build of the same sources.
--
-- A history is a package, perhaps a package p that it depends on, and a
-- sequence of builds, with edits to the sources before each.
--
-- - The package has modules M0..Mn, each importing some of those before
--   it. Some have a boot file that modules before them import
--   {-# SOURCE #-}. Some have a Template Haskell splice that runs a module
--   it imports.
-- - p has modules P0..Pk, which the package's modules import through p's
--   early package db, as the rules have it: it has no library, and its
--   import directory is the one p's interfaces are written to one by one.
--   p's modules are sometimes named M0..Mk instead, like the main
--   package's. A module of each package may then have the same name, which
--   only its unit tells apart (as in the usages of the dep files).
-- - On Linux, a splice may run p's code too. Its compile loads that from p's
--   library, linked as the rules link one, through p's final package db.
--   The library calls a native library, which depends on another, and no
--   library has a RUNPATH.
--
-- Each build has a fresh worker, as each buck2 build does, and the test
-- sends it the modules and boot files that buck2 would compile: those never
-- compiled, and those whose source, or a file their dep file lists, changed
-- since they were last compiled (the early cut-off of Note [Early cut-off
-- by dep files] in compile_per_module.bzl). Each is sent once what it
-- imports is done, with independent ones at the same time. One whose
-- import failed isn't sent. After each build, every module and boot file
-- must agree with the clean build: whether it compiles, its ABI hash, and
-- its object (with GHC 9.12 and later, whose objects are deterministic).
--
-- The worker and GHC are as in the test suite (GHC_WORKER, GHC). The
-- options are tasty's: --hedgehog-tests N runs N histories (30 by default),
-- and a failure says how to run it again (--hedgehog-replay).
module Main (main) where

import Control.Applicative ((<|>))
import Control.Concurrent (forkIO)
import Control.Concurrent.MVar
import Control.Exception (SomeException, catch, throwIO, try)
import Control.Monad (forM, forM_, unless, when)
import Control.Monad.IO.Class (liftIO)
import qualified Data.ByteString as B
import Data.IORef
import Data.List (intercalate, sort, sortOn)
import qualified Data.Map as M
import Data.Maybe (fromMaybe, isJust)
import Data.Version (showVersion, versionBranch)
import System.Directory
import System.Environment (lookupEnv)
import System.Exit (ExitCode (..), exitFailure)
import System.FilePath (takeDirectory, (<.>), (</>))
import System.Info (fullCompilerVersion, os)
import System.IO (IOMode (..), hPutStrLn, openFile, stderr)
import System.Timeout (timeout)
import System.Posix.Process (getProcessID)
import System.Process

import Hedgehog
import qualified Hedgehog.Gen as Gen
import qualified Hedgehog.Range as Range
import Test.Tasty (adjustOption, askOption, defaultMain, testGroup)
import Test.Tasty.Hedgehog (HedgehogTestLimit (..), testPropertyNamed)

import Client
import Contract (contract)

-- * Histories

data Ty = TInt | TInteger
  deriving (Eq, Show)

-- | A module:
--
-- - the modules it imports (qualified): of its own package, those before
--   it; of p (whose keys are 100 and up), any, from a module of the main
--   package;
-- - those it imports {-# SOURCE #-}, which come after it and have a boot
--   file;
-- - its exported values, each with a name number, a type and the constant
--   in its definition. Value 0 also adds the value 0 of each import, and
--   the value t of each import that has one. A module with SOURCE imports
--   also exports an INLINE value t, the sum of their values 0, and for
--   each SOURCE import a function that shows the import's type T;
-- - whether it has a boot file, which declares its value 0 and its type T
--   with a Show instance;
-- - the import whose value 0 a Template Haskell splice of it uses, if it
--   has one. The splice evaluates a value of p. It only links a value of
--   the package's own, without evaluating it, since the package's values
--   may form a cycle through SOURCE imports;
-- - the numbers of comment-only edits made to it and to its boot file;
-- - whether it has a type error;
-- - whether its requests have flags of their own (as a Template Haskell
--   module's package flags differ), so that it compiles in a session of
--   its own;
-- - the imports whose value 0 it re-exports, which its importers' value 0
--   adds too: GHC records their usage of the module that defines it, which
--   they don't import.
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
  }
  deriving (Eq, Show)

data Edit
  = Comment Int
  | BootComment Int
  | Body Int Int Int -- module, value, new constant
  | AddValue Int
  | RemoveValue Int
  | Retype Int -- value 0, which the boot file declares too
  | AddImport Int Int
  | RemoveImport Int Int
  | AddSourceImport Int Int
  | RemoveSourceImport Int Int
  | Break Int -- or mend
  | AddReexport Int Int
  | RemoveReexport Int Int
  deriving (Show)

-- | A build: the edits before it, and whether its worker drops sessions as
-- soon as they are idle.
data Build = Build {bEdits :: [Edit], bEagerDrop :: Bool}
  deriving (Show)

-- | Whether it optimises, the modules by key (the main package's from 0,
-- p's from pkgP), and the builds.
data History = History {hOptimise :: Bool, hModules :: [(Int, Mod)], hBuilds :: [Build]}
  deriving (Show)

-- | A history, with boot files if allowed.
genHistory :: Bool -> Gen History
genHistory bootsAllowed = do
  -- Constant ranges: Hedgehog scales linear ones with its size, which
  -- stays small over a few dozen tests, and the histories need builds and
  -- edits to be worth running.
  n <- Gen.int (Range.constant 2 6)
  pn <- Gen.frequency [(1, pure 0), (2, Gen.int (Range.constant 1 3))]
  -- p's modules, named as the main package's or not.
  pbase <- Gen.element [pkgP, pkgClash]
  let pkeys = [pbase + j | j <- [0 .. pn - 1]]
  pmods <- forM [0 .. pn - 1] $ \i -> do
    imports <- Gen.subsequence (take i pkeys)
    k <- Gen.int (Range.constant 1 3)
    values <- forM [0 .. k - 1] $ \v -> (,,) v <$> Gen.element [TInt, TInteger] <*> Gen.int (Range.linear 0 9)
    reexports <- Gen.subsequence imports
    pure (Mod imports [] values False Nothing 0 0 False False reexports)
  boots <- forM [0 .. n - 1] $ \i -> if i == 0 || not bootsAllowed then pure False else Gen.frequency [(2, pure False), (1, pure True)]
  mods <- forM [0 .. n - 1] $ \i -> do
    own' <- if i == 0 then pure [] else Gen.subsequence [0 .. i - 1]
    fromP <- Gen.subsequence pkeys
    let imports = own' ++ fromP
    k <- Gen.int (Range.constant 1 3)
    values <- forM [0 .. k - 1] $ \v -> (,,) v <$> Gen.element [TInt, TInteger] <*> Gen.int (Range.linear 0 9)
    -- A splice of p's code is twice as likely as one of the package's own.
    -- Either way, it uses a module it imports.
    splice <- Gen.frequency ([(3, pure Nothing)] ++ [(1, Just <$> Gen.element own') | not (null own')] ++ [(2, Just <$> Gen.element fromP) | pSplices, not (null fromP)])
    -- A module with a splice gets no SOURCE imports, since compiledAs would
    -- drop its splice. (An edit may still add one later.)
    sourceImports <- if isJust splice then pure [] else Gen.subsequence [j | j <- [i + 1 .. n - 1], boots !! j]
    own <- Gen.frequency [(2, pure False), (1, pure True)]
    reexports <- Gen.subsequence imports
    pure (Mod imports sourceImports values (boots !! i) splice 0 0 False own reexports)
  builds <- Gen.list (Range.constant 2 6) (Build <$> Gen.list (Range.constant 1 4) (genEdit ([0 .. n - 1] ++ pkeys)) <*> Gen.bool)
  History <$> Gen.bool <*> pure (zip [0 ..] mods ++ zip pkeys pmods) <*> pure builds

-- | The key of p's first module; the main package's modules have lower
-- keys. p's modules from pkgClash on are named like the main package's (see
-- modName).
pkgP, pkgClash :: Int
pkgP = 100
pkgClash = 200

inP :: Int -> Bool
inP i = i >= pkgP

-- | An edit to the modules with the given keys.
genEdit :: [Int] -> Gen Edit
genEdit keys =
  Gen.frequency $
    map ((,) 1)
    [ Comment <$> m
    , BootComment <$> m
    -- Value 0 most often, since the other modules' values and the splices
    -- use it.
    , Body <$> m <*> Gen.frequency [(3, pure 0), (1, Gen.int (Range.linear 1 3))] <*> Gen.int (Range.linear 0 9)
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
    ]
      -- And value 0 of a module of p, which changes p's library under the
      -- splices that run it. Often, since that only tests anything with a
      -- splice of p's code too, and a build of its module afterwards.
      ++ [(4, Body <$> Gen.element ps <*> pure 0 <*> Gen.int (Range.linear 0 9)) | let ps = filter inP keys, not (null ps)]
  where
    m = Gen.element keys

-- | Apply an edit to the package. An edit that doesn't apply (to a value or
-- import that a module doesn't have, say) changes nothing, so that a shrunk
-- history is still a history.
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

-- | What a node's compile reads the results of: a boot file, nothing; a
-- module, its imports, the boot files of its SOURCE imports, and its own.
--
-- A module that runs a splice also waits for the whole modules behind the
-- boot files below its imports, which its splice may link, as the rules
-- have it (see Note [Template Haskell modules] in compile_per_module.bzl, and
-- linksOf).
--
-- A module of the main package also waits for the modules of p below those
-- it imports from p, whose interfaces GHC reads with theirs, as the rules
-- have it (see Note [Compiling against dependencies module by module] in
-- compile_per_module.bzl).
nodeDeps :: M.Map Int Mod -> Links -> Node -> [Node]
nodeDeps _ _ (_, True) = []
nodeDeps mods ls (i, False) =
  [(j, False) | j <- mImports m] ++ [(j, True) | j <- mSourceImports m] ++ [(i, True) | mBoot m]
    ++ (if inP i then [] else [(j, False) | j <- belowInP mods [x | x <- mImports m, inP x]])
    ++ [(k, False) | k <- ls M.! i]
    -- And for all of p, whose library its splice loads (see linkP).
    ++ (if splicesP m then [(j, False) | j <- M.keys mods, inP j] else [])
  where
    m = mods M.! i

-- | Whether splices may run p's code. Only on Linux, where p's native
-- libraries and its library are ELF libraries (see buildC and linkP), since
-- the rules only support that there (see _native_ghci_libs in haskell.bzl).
pSplices :: Bool
pSplices = os == "linux"

-- | Whether a module's splice runs p's code. Its compile then loads p's
-- library (see linkP) through p's final package db.
splicesP :: Mod -> Bool
splicesP m = maybe False inP (mSplice m)

-- | The modules each module's splice may link past boot files.
type Links = M.Map Int [Int]

-- | Each module's links (see 'links'), with cycles of waits broken as the
-- rules break them (_registration_order in compile_per_module.bzl). Of the
-- modules left waiting, the first by name stops waiting for the others.
linksOf :: M.Map Int Mod -> Links
linksOf mods = go (M.fromList [(i, links mods i) | i <- M.keys mods])
  where
    go ls = case sortOn modName [i | (i, False) <- left, any (`elem` leftMods) (ls M.! i)] of
      [] -> ls
      i : _ -> go (M.insert i (filter (`notElem` leftMods) (ls M.! i)) ls)
      where
        left = snd (layers (nodeDeps mods ls) (nodes mods))
        leftMods = [j | (j, False) <- left]

-- | For a module that runs a splice, the modules that its splice may link
-- past boot files, as the rules name them (_linked_closure in
-- compile_per_module.bzl). They are the modules of its own package whose
-- boot files are in its closure, or in turn in the closure of one of those.
-- They don't include the module itself, or modules that import it, which
-- can't be compiled before it.
links :: M.Map Int Mod -> Int -> [Int]
links mods i
  | isJust (mSplice (mods M.! i)) = [k | (k, True) <- linked, (k, False) `elem` linked]
  | otherwise = []
  where
    linked = go (closure i) [k | (k, True) <- closure i]
    go seen [] = seen
    go seen (k : todo)
      | k == i || (k, False) `elem` seen || (i, False) `elem` closure k = go seen todo
      | otherwise =
          let new = [d | d <- (k, False) : closure k, d `notElem` seen, d /= (i, False)]
           in go (seen ++ new) ([b | (b, True) <- new] ++ todo)
    -- The nodes below a module, as the rules have them: the modules of its
    -- package, each whole, or as its boot file (True) below a SOURCE
    -- import. A boot file imports nothing.
    closure x = walk [] (edges x)
    walk seen [] = seen
    walk seen (d@(y, boot) : ds)
      | d `elem` seen = walk seen ds
      | boot = walk (d : seen) ds
      | otherwise = walk (d : seen) (edges y ++ ds)
    edges y = let my = mods M.! y in [(z, False) | z <- mImports my, inP z == inP i] ++ [(z, True) | z <- mSourceImports my, inP z == inP i]

-- | The modules of p below the given ones of p.
belowInP :: M.Map Int Mod -> [Int] -> [Int]
belowInP mods = go []
  where
    go visited [] = visited
    go visited (x : xs)
      | x `elem` visited = go visited xs
      | otherwise = go (x : visited) (mImports (mods M.! x) ++ xs)

-- | The modules behind the boot files below the given modules.
linkedPastBoots :: M.Map Int Mod -> [Int] -> [Int]
linkedPastBoots mods = go [] []
  where
    go _ found [] = found
    go visited found (x : xs)
      | x `elem` visited = go visited found xs
      | otherwise = let mx = mods M.! x in go (x : visited) (mSourceImports mx ++ found) (mImports mx ++ mSourceImports mx ++ xs)

-- | The package as a build compiles it. It drops the splices that would
-- link past a boot file, unless this GHC can do that both one-shot and in
-- the worker:
--
-- - GHC 9.14.1's one-shot mode can't: it links the splice's code without
--   the module behind the boot file.
-- - Before GHC 9.12, neither can (see the worker's README).
-- - GHC 9.12's one-shot mode can, but not when the compile has read the
--   boot interface itself: when the module imports one {-# SOURCE #-}, or,
--   with -O, when an unfolding mentions one.
--
-- It also drops the splices of a module that imports one {-# SOURCE #-}.
-- FIXME: the rules have such a module wait for the module behind that boot
-- file, and name it with --link. The worker then gives the compile that
-- module whole, where `ghc -c` reads the boot interface, so the module's ABI
-- hash differs from `ghc -c`'s, even without -O.
compiledAs :: Config -> History -> M.Map Int Mod -> M.Map Int Mod
compiledAs cfg h mods = M.map (\m -> if linksPast m && not (oneShotLinks m) || not (null (mSourceImports m)) then m{mSplice = Nothing} else m) mods
  where
    linksPast m = not (null (linkedPastBoots mods (mImports m)))
    oneShotLinks m = cBootSplices cfg && not (hOptimise h) && null (mSourceImports m)

nodeName :: Node -> String
nodeName (i, boot) = modName i ++ (if boot then "-boot" else "")

modName :: Int -> String
modName i
  | i >= pkgClash = "M" ++ show (i - pkgClash)
  | inP i = "P" ++ show (i - pkgP)
  | otherwise = "M" ++ show i

-- | The name a module imports another as: a module of p may have the name
-- of one of its own package.
alias :: Int -> String
alias j = "X" ++ show j

-- | Where a node's package's sources and outputs are, and its dep files.
-- The outputs are under one configuration's directory, as buck2 lays them
-- out, so that the worker's one-shot sessions of both packages share their
-- external state (see 'flavour' in the worker's Session).
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
    ["{-# LANGUAGE TemplateHaskell #-}" | isJust (mSplice m)]
      ++ ["{-# LANGUAGE PackageImports #-}" | fromP]
      ++ ["module " ++ modName i ++ " (" ++ intercalate ", " exports ++ ") where"]
      ++ ["import qualified " ++ (if fromP && inP j then "\"p\" " else "") ++ modName j ++ " as " ++ alias j | j <- mImports m]
      ++ ["import {-# SOURCE #-} qualified " ++ modName j ++ " as " ++ alias j | j <- mSourceImports m]
      ++ ["import Language.Haskell.TH.Syntax (lift)" | isJust (mSplice m)]
      ++ ["foreign import ccall unsafe \"pc_value\" pcValue :: Int" | callsC]
      ++ ["-- edit " ++ show (mComments m)]
      ++ concat
        [ [ value i k ++ " :: " ++ tyName t
          , value i k ++ " = " ++ show c ++ concat [" + fromIntegral " ++ alias j ++ "." ++ v | k == 0, j <- mImports m, v <- value j 0 : ["t" ++ show j | hasT j] ++ [value r 0 | r <- reexported j]] ++ concat [" + fromIntegral pcValue" | k == 0, callsC]
          ]
        | (k, t, c) <- mValues m
        ]
      ++ concat [["t" ++ show i ++ " :: Integer", "t" ++ show i ++ " = 0" ++ concat [" + fromIntegral " ++ alias j ++ "." ++ value j 0 | j <- mSourceImports m], "{-# INLINE t" ++ show i ++ " #-}"] | hasT i]
      ++ concat [[shows' j ++ " :: " ++ alias j ++ "." ++ ty j ++ " -> String", shows' j ++ " = show"] | j <- mSourceImports m]
      ++ concat [["data " ++ ty i ++ " = " ++ ty i, "instance Show " ++ ty i ++ " where show _ = " ++ show (ty i)] | mBoot m]
      -- A splice of p's code evaluates it, and its values can't form a cycle
      -- (p has no boot files). So a splice that ran a stale library would
      -- make a different object from the clean build's.
      ++ concat [["s" ++ show i ++ " :: Integer", "s" ++ show i ++ " = $(lift (" ++ (if inP j then "fromIntegral " ++ alias j ++ "." ++ value j 0 else "fromIntegral (length [" ++ alias j ++ "." ++ value j 0 ++ "])") ++ " :: Integer))"] | Just j <- [mSplice m]]
      ++ (if mBroken m then ["broken :: Int", "broken = \"not an Int\""] else [])
  where
    m = mods M.! i
    exports = [value i k | (k, _, _) <- mValues m] ++ ["t" ++ show i | hasT i] ++ map shows' (mSourceImports m) ++ [ty i | mBoot m] ++ ["s" ++ show i | isJust (mSplice m)] ++ [alias r ++ "." ++ value r 0 | r <- reexported i]
    hasT j = not (null (mSourceImports (mods M.! j)))
    -- A re-export of an import that an edit removed is dropped.
    reexported j = let mj = mods M.! j in [r | r <- mReexports mj, r `elem` mImports mj]
    fromP = not (inP i) && any inP (mImports m)
    -- p's first module calls a function of p's native library.
    callsC = inP i && i == minimum [k | k <- M.keys mods, inP k]
    shows' j = "show" ++ show i ++ "_" ++ show j

-- | The type a module with a boot file declares in both.
ty :: Int -> String
ty i = "T" ++ show i

-- | The flags of every compile, and those of a node's own.
commonFlags :: History -> [String]
commonFlags h =
  ["-hide-all-packages", "-package", "base"]
    ++ (if hOptimise h then ["-O"] else ["-O0"])
    -- GHC, being dynamically linked, loads dynamic objects for a splice.
    ++ ["-dynamic" | any (isJust . mSplice . snd) (hModules h)]

nodeFlags :: M.Map Int Mod -> Node -> [String]
nodeFlags mods (i, _)
  | inP i = ["-this-unit-id", "p", "-i" ++ outDir pkgP]
  | otherwise =
      ["-DOWN_SESSION" | mOwnFlags m]
        -- An external interpreter, as the rules have it (see Note [Template
        -- Haskell modules] in compile_per_module.bzl).
        ++ (if isJust (mSplice m) then ["-package", "template-haskell", "-fexternal-interpreter"] else [])
        ++ (if any (inP . fst) (M.toList mods) then ["-package-db", if splicesP m then "pfinal" else "pdb", "-package", "p"] else [])
        ++ ["-iout"]
  where
    m = mods M.! i

-- * Running a history

-- | What a build left of a node: compiled (its ABI hash, its object, and
-- the usages of its imports that its interface records), failed, or not
-- compiled because what it imports failed.
data Outcome = Compiled String B.ByteString [String] | Failed String | Blocked
  deriving (Eq)

describe :: Outcome -> String
describe (Compiled abi _ us) = "compiled, ABI " ++ abi ++ (if null us then "" else ", usages " ++ intercalate "; " us)
describe (Failed err) = "failed: " ++ take 400 err
describe Blocked = "not compiled (an import failed)"

isCompiled :: Outcome -> Bool
isCompiled (Compiled _ _ _) = True
isCompiled _ = False

-- | The worker, GHC and working directory; whether the objects are compared
-- (deterministic, from GHC 9.12) or else the usages; whether a splice may
-- link past a boot file (see compiledAs).
data Config = Config {cWorker :: FilePath, cGhc :: String, cDir :: FilePath, cObjects :: Bool, cBootSplices :: Bool, cOneShot :: Bool}

-- | What a history's builds did, to see that the histories reach what they
-- are for.
data Stats = Stats {sSkipped :: Int, sRecompiled :: Int, sFailed :: Int, sBlocked :: Int, sLibChanged :: Int}

-- | For each node, the source it was last compiled from by the worker and
-- the contents then of the files its dep file lists.
type LastOk = M.Map Node (String, [(FilePath, Maybe B.ByteString)])

-- | Run the history through the worker and the clean builds. Returns the
-- first disagreement, if there is one.
runHistory :: Config -> History -> IO (Either String (), Stats)
runHistory cfg h = do
  stats <- newIORef (Stats 0 0 0 0 0)
  let dir = cDir cfg
  removePathForcibly dir
  mapM_ (createDirectoryIfMissing True . (dir </>)) ["w/src", "w" </> outDir 0, "w/psrc", "w" </> outDir pkgP, "w/dep", "w/tmp", "ref"]
  -- p's native libraries, which all the builds share (see buildC), and p's
  -- package dbs for the worker's builds. The clean builds register their
  -- own.
  let ps = [i | (i, _) <- hModules h, inP i]
  unless (null ps || not pSplices) (buildC cfg (dir </> "clib"))
  registerP cfg (dir </> "w") ps
  lastOk <- newIORef M.empty
  libSeen <- newIORef M.empty
  let go _ _ [] = pure (Right ())
      go mods n (b : rest) = do
        let mods' = foldl applyEdit mods (bEdits b)
            built = compiledAs cfg h mods'
        forM_ (nodes built) $ \node -> writeFileIfChanged (dir </> "w" </> source node) (render built node)
        (worker, skipped) <- workerBuild cfg h b built lastOk libSeen stats
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

-- | Register p's package dbs in the given directory, if p has modules, as
-- the rules make them (see haskell.bzl):
--
-- - Its early db has no library, and its import directory is the one its
--   interfaces are written to.
-- - Its final db names its library (see linkP) as one of its
--   extra-libraries. For GHC's interpreter, it also names the native
--   libraries p depends on, before p's own and each after those it depends
--   on, and the directories they are in.
registerP :: Config -> FilePath -> [Int] -> IO ()
registerP _ _ [] = pure ()
registerP cfg dir ps = do
  let common = "name: p\nversion: 0\nid: p\nkey: p\nexposed: True\nexposed-modules: " ++ unwords (map modName ps) ++ "\nimport-dirs: " ++ dir </> outDir pkgP ++ "\n"
      clib = takeDirectory dir </> "clib"
  forM_ [("pdb", common), ("pfinal", common ++ "library-dirs: " ++ dir </> "plib" ++ "\nextra-libraries: p\nextra-ghci-libraries: pcb, pc, p\ndynamic-library-dirs: " ++ dir </> "plib" ++ ", " ++ clib ++ "\n")] $ \(db, conf) -> do
    removePathForcibly (dir </> db)
    writeFile (dir </> db <.> "conf") conf
    _ <- readProcess (ghcPkgOf (cGhc cfg)) ["init", dir </> db] ""
    -- It warns that the interfaces and library are missing.
    _ <- readProcessWithExitCode (ghcPkgOf (cGhc cfg)) ["register", "--force", "--package-db", dir </> db, dir </> db <.> "conf"] ""
    pure ()

-- | p's native libraries, in the given directory: libpc.so, whose pc_value
-- p's first module calls, and libpcb.so, which libpc.so depends on. Each
-- has a soname and no RUNPATH, like the libraries buck2 links. So a
-- process finds libpcb.so for libpc.so only if it has loaded it already.
buildC :: Config -> FilePath -> IO ()
buildC cfg dir = do
  createDirectoryIfMissing True dir
  info <- readProcess (cGhc cfg) ["--info"] ""
  let cc = fromMaybe "cc" (lookup "C compiler command" (read info :: [(String, String)]))
      shared name src deps = do
        writeFile (dir </> name <.> "c") src
        callProcess cc (["-shared", "-fPIC", "-o", dir </> "lib" ++ name <.> "so", dir </> name <.> "c", "-Wl,-soname,lib" ++ name ++ ".so", "-L" ++ dir] ++ map ("-l" ++) deps)
  shared "pcb" "int pcb_value(void) { return 1; }\n" []
  shared "pc" "int pcb_value(void);\nint pc_value(void) { return 2 + pcb_value(); }\n" ["pcb"]

-- | Link p's library, libp.so, from its objects in the given directory, as
-- the rules link a library: with a soname, and against p's native library
-- (see buildC) without a RUNPATH to it. Returns the library's contents: a
-- module whose splice loads the library has it as a plain input, as with
-- the rules.
linkP :: Config -> FilePath -> [Int] -> IO B.ByteString
linkP cfg dir ps = do
  createDirectoryIfMissing True (dir </> "plib")
  let lib = dir </> "plib" </> "libp.so"
  callProcess (cGhc cfg) (["-shared", "-dynamic", "-hide-all-packages", "-package", "base", "-o", lib, "-optl-Wl,-soname,libp.so", "-L" ++ takeDirectory dir </> "clib", "-lpc"] ++ [dir </> outDir pkgP </> modName i <.> "o" | i <- ps])
  B.readFile lib

writeFileIfChanged :: FilePath -> String -> IO ()
writeFileIfChanged path s = do
  old <- (Just <$> readFile' path) `catchAny` pure Nothing
  unless (old == Just s) (writeFile path s)
  where
    readFile' p = do t <- readFile p; length t `seq` pure t

-- | The nodes in layers, each node's dependencies in earlier ones, and those
-- left in or behind a cycle.
layers :: (Node -> [Node]) -> [Node] -> ([[Node]], [Node])
layers deps = go M.empty
  where
    go _ [] = ([], [])
    go done pending =
      let ready = [n | n <- pending, all (`M.member` done) (deps n)]
       in if null ready then ([], pending) else let (rest, left) = go (M.union done (M.fromList [(n, ()) | n <- ready])) (filter (`notElem` ready) pending) in (ready : rest, left)

-- | One build through a fresh worker, each node sent as soon as those it
-- waits for are done, as buck2 sends them. Returns the outcomes, and the
-- nodes it skipped as up to date. The library that p's splices load counts
-- as a change for a module when it has changed since that module's splice
-- last loaded it.
workerBuild :: Config -> History -> Build -> M.Map Int Mod -> IORef LastOk -> IORef (M.Map Node B.ByteString) -> IORef Stats -> IO (M.Map Node Outcome, [Node])
workerBuild cfg h b mods lastOk libSeen stats = do
  let wdir = cDir cfg </> "w"
  -- Its log, of the last build, is left for a failure's inspection.
  logH <- openFile (wdir </> "worker.log") WriteMode
  let mode = if cOneShot cfg then "one-shot" else "make"
  withWorkerProcess (cWorker cfg) [] wdir ([("TMPDIR", wdir </> "tmp"), ("GHC_WORKER_VERBOSE", "1"), ("GHC_WORKER_SESSION_MODE", mode)] ++ [("GHC_WORKER_SESSIONS", "0") | bEagerDrop b]) (UseHandle logH) $ \sock -> do
      skippedRef <- newIORef []
      -- p's library, linked once all of p is compiled, by the first module
      -- whose splice loads it.
      libVar <- newMVar Nothing
      let pLib = modifyMVar libVar $ \l -> case l of
            Just c -> pure (l, c)
            Nothing -> (\c -> (Just c, c)) <$> linkP cfg wdir [k | k <- M.keys mods, inP k]
      vars <- M.fromList <$> forM (nodes mods) (\node -> (,) node <$> newEmptyMVar)
      let result node = readMVar (vars M.! node) >>= either (\(e :: SomeException) -> throwIO e) pure
      forM_ (nodes mods) $ \node -> forkIO $ do
        r <- try $ do
          deps <- mapM result (nodeDeps mods ls node)
          decide wdir sock skippedRef pLib (all isCompiled deps) node
        putMVar (vars M.! node) r
      (,) . M.fromList <$> forM (nodes mods) (\node -> (,) node <$> result node) <*> readIORef skippedRef
  where
    ls = linksOf mods
    count f = atomicModifyIORef' stats (\st -> (f st, ()))
    decide wdir sock skippedRef pLib depsOk node@(i, boot)
      | not depsOk = do
          modifyIORef' lastOk (M.delete node)
          count (\st -> st{sBlocked = sBlocked st + 1})
          pure Blocked
      | otherwise = do
          let src = render mods node
          -- p's library, for a module whose splice loads it: a plain input of
          -- its compile, whose dep file doesn't list it.
          lib <- if not boot && splicesP (mods M.! i) then (\c -> [("plib/libp.so", Just c)]) <$> pLib else pure []
          forM_ [c | (_, Just c) <- lib] $ \c -> do
            seen <- atomicModifyIORef' libSeen (\s -> (M.insert node c s, M.lookup node s))
            when (maybe False (/= c) seen) $ count (\st -> st{sLibChanged = sLibChanged st + 1})
          previous <- M.lookup node <$> readIORef lastOk
          upToDate <- case previous of
            Just (s, deps) | s == src -> and <$> mapM (\(f, c) -> (== c) <$> contents (wdir </> f)) deps
            _ -> pure False
          if upToDate
            then count (\st -> st{sSkipped = sSkipped st + 1}) >> modifyIORef' skippedRef (node :) >> current wdir node
            else do
              -- A compile of these takes a second or two: a request that
              -- takes far longer is a worker that hangs.
              answer <- timeout 120000000 (grpc sock (request node))
              (code, err) <- maybe (fail ("the worker didn't answer " ++ nodeName node ++ " in two minutes (see " ++ (wdir </> "worker.log") ++ ")")) pure answer
              when (isJust previous) $ count (\st -> st{sRecompiled = sRecompiled st + 1})
              if code /= 0
                then do
                  modifyIORef' lastOk (M.delete node)
                  count (\st -> st{sFailed = sFailed st + 1})
                  pure (Failed err)
                else do
                  deps <- lines <$> readFile (wdir </> depFile node)
                  cs <- mapM (contents . (wdir </>)) deps
                  modifyIORef' lastOk (M.insert node (src, zip deps cs ++ lib))
                  current wdir node
    contents f = (Just <$> B.readFile f) `catchAny` pure Nothing
    current wdir node@(i, _) = do
      let out ext = wdir </> outDir i </> modName i <.> (ext ++ suffix node)
      us <- if cObjects cfg then pure [] else usagesOf <$> readProcess (cGhc cfg) ["--show-iface", out "hi"] ""
      Compiled . trim <$> readFile (out "abi") <*> B.readFile (out "o") <*> pure us
    -- By package as well as name: a module of each may have the same name.
    depFile node@(i, _) = "dep" </> (if inP i then "p-" else "") ++ nodeName node <.> "dep"
    request node@(i, boot) =
      [ "--request", "--contract", contract
      , "--depfile", depFile node, "--abi", outDir i </> modName i <.> ("abi" ++ suffix node), "--module", modName i
      , "--source", source node, "--outdir", outDir i, "--hisuf", "hi", "--srcroot=" ++ srcDir i
      ] ++ ["--boot" | boot] ++ ["--link=" ++ modName k | not boot, k <- ls M.! i]
      ++ ["--hidir=p=" ++ outDir pkgP | not (inP i)]
      ++ ["--", cGhc cfg] ++ commonFlags h ++ nodeFlags mods node
      ++ ["--", "-c", source node, "-o", outDir i </> modName i <.> ("o" ++ suffix node), "-ohi", outDir i </> modName i <.> ("hi" ++ suffix node)]

-- | A clean build of the same sources, one `ghc -c` per node.
refBuild :: Config -> History -> M.Map Int Mod -> IO (M.Map Node Outcome)
refBuild cfg h mods = do
  let rdir = cDir cfg </> "ref"
  removePathForcibly rdir
  mapM_ (createDirectoryIfMissing True . (rdir </>)) ["src", outDir 0, "psrc", outDir pkgP]
  registerP cfg rdir [i | i <- M.keys mods, inP i]
  forM_ (nodes mods) $ \node -> writeFile (rdir </> source node) (render mods node)
  outcomes <- newIORef M.empty
  linked <- newIORef False
  let ls = linksOf mods
  forM_ (concat (fst (layers (nodeDeps mods ls) (nodes mods)))) $ \node@(i, boot) -> do
    done <- readIORef outcomes
    outcome <-
      if any (\d -> not (maybe False isCompiled (M.lookup d done))) (nodeDeps mods ls node)
        then pure Blocked
        else do
          already <- readIORef linked
          when (not boot && splicesP (mods M.! i) && not already) $ do
            _ <- linkP cfg rdir [k | k <- M.keys mods, inP k]
            writeIORef linked True
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

-- | The usages of imported modules in an interface's text: "import -/ M
-- hash" (the first on the "usages:" line since GHC 9.14). Before GHC 9.12,
-- when objects aren't compared, these show what a module was compiled
-- against, which its ABI hash doesn't.
usagesOf :: String -> [String]
usagesOf iface = [unwords u | l <- lines iface, u@("import" : "-/" : _) <- [dropWhile (/= "import") (words l)]]

catchAny :: forall a. IO a -> IO a -> IO a
catchAny a b = (try a :: IO (Either SomeException a)) >>= either (const b) pure

trim :: String -> String
trim = reverse . dropWhile (`elem` ("\r\n " :: String)) . reverse

main :: IO ()
main = do
  worker <- fromMaybe "ghc-worker" <$> lookupEnv "GHC_WORKER"
  ghc <- fromMaybe "ghc" <$> lookupEnv "GHC"
  version <- trim <$> readProcess ghc ["--numeric-version"] ""
  when (version /= showVersion fullCompilerVersion) $ do
    hPutStrLn stderr ("the props were built with GHC " ++ showVersion fullCompilerVersion ++ " but `" ++ ghc ++ "` is " ++ version ++ ": set GHC")
    exitFailure
  tmp <- getTemporaryDirectory
  pid <- getProcessID
  let v = versionBranch fullCompilerVersion
      cfg = Config worker ghc (tmp </> ("ghc-worker-props-" ++ show pid)) (v >= [9, 12]) (take 2 v == [9, 12]) False
      -- (In a directory of its own, as the properties run at once.)
      oneShotCfg = cfg{cOneShot = True, cDir = cDir cfg ++ "-one-shot"}
      bootCycleCfg = cfg{cDir = cDir cfg ++ "-boot-cycle"}
      bootCycle2Cfg = cfg{cDir = cDir cfg ++ "-boot-cycle-2"}
  -- The last history's directory is kept if a property fails, for a look
  -- at what it built.
  let tree = adjustOption (\(HedgehogTestLimit n) -> HedgehogTestLimit (n <|> Just 30)) . askOption $ \(HedgehogTestLimit n) ->
        -- In each session mode but the default (see Note [One-shot
        -- sessions] in the worker's Session): --make, with boot files or
        -- not; and one-shot, without (the worker refuses boot files then).
        testGroup
          "a history built through the worker agrees with clean ghc -c builds"
          [ testPropertyNamed "with --make sessions" "historyMake" (historyProp cfg (maybe 30 fromIntegral n))
          , testPropertyNamed "with one-shot sessions" "historyOneShot" (historyProp oneShotCfg (maybe 30 fromIntegral n))
          , testPropertyNamed "a boot file cycle rebuilt with -O" "bootCycle" (fixedHistory bootCycleCfg bootCycle)
          , testPropertyNamed "a second boot file cycle rebuilt with -O" "bootCycle2" (fixedHistory bootCycle2Cfg bootCycle2)
          ]
  defaultMain tree `catch` \code -> do
    when (code == ExitSuccess) (mapM_ (removePathForcibly . cDir) [cfg, oneShotCfg, bootCycleCfg, bootCycle2Cfg])
    throwIO code

-- | That the given history agrees with clean builds, through a worker of the
-- given configuration.
fixedHistory :: Config -> History -> Property
fixedHistory cfg h = withTests 1 . property $ do
  (result, _) <- liftIO (runHistory cfg h)
  either (\err -> annotate err >> failure) (const success) result

-- | M1 imports M4 through M4's boot file, and M4 imports M1; M0 imports M1
-- through M1's boot file; M5 imports M0 and M2, which imports M1. With -O,
-- after an edit to a comment of M0, M5 must compile as it did at first.
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
    plain = Mod [] [] [(0, TInt, 0)] False Nothing 0 0 False False []

-- | M1 imports M2 through M2's boot file, and its INLINE t1 uses M2; M2
-- imports M0, which imports M1 through M1's boot file; M3 imports M1. M5
-- imports M2, and after the first build M3 too, whose interface, with -O,
-- has an unfolding that mentions M2 through t1, though M3 doesn't import
-- it. After an edit to a comment of M0, M5 must compile as it did at first.
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
    plain = Mod [] [] [(0, TInt, 0)] False Nothing 0 0 False False []

-- | The property, of the given number of histories.
historyProp :: Config -> Int -> Property
historyProp cfg tests =
  -- Few shrinks: each runs a history, of a minute or more.
  withShrinks 30 . property $ do
    h <- forAll (genHistory (not (cOneShot cfg)))
    (result, st) <- liftIO (runHistory cfg h)
    -- Coverage of the package as first generated. The minimums catch a
    -- generator that stops making what the histories are for. Each is far
    -- enough below its usual share that 30 histories miss one about once in
    -- 3,000 runs. With fewer histories, we only count them.
    let mods = compiledAs cfg h (M.fromList (hModules h))
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
    -- (Fewer before GHC 9.12 and with 9.14: see compiledAs.)
    classify "a splice compiled" (any (isJust . mSplice) ms)
    unless (cOneShot cfg) $ classify "a splice in a module with a boot file" (any (\m -> mBoot m && isJust (mSplice m)) ms)
    cover' 10 "an import from p" (any (any inP . mImports) ms)
    (if pSplices then cover' 10 else classify) "a splice that runs p's code, from p's library" (any splicesP ms)
    -- Too rare (about one history in eight) for a minimum that 30
    -- histories reliably meet.
    classify "p's library changed under a module whose splice loads it" (sLibChanged st > 0)
    cover' 10 "a module of p with the name of one of the main package" (any (\i -> i >= pkgClash && i - pkgClash < M.size (M.filterWithKey (\k _ -> not (inP k)) mods)) (M.keys mods))
    cover' 10 "a value used through a re-export" (any (any (\j -> any (`elem` mImports (mods M.! j)) (mReexports (mods M.! j))) . mImports) ms)
    cover' 45 "sessions dropped as soon as idle" (any bEagerDrop (hBuilds h))
    case result of
      Right () -> success
      Left err -> annotate err >> failure
