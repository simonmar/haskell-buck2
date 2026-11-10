-- | What the rules give the per-module compile tool for each module (see
-- compile_per_module in compile_per_module.bzl):
--
-- > --depfile DEP --abi ABI --module Foo/Bar --outdir OUT --hisuf SUF
-- >   [--hidir=UNIT=DIR]... [--mkdir=DIR]...
-- >   -- ghc SESSION_FLAGS... -- MODULE_FLAGS...
--
-- The tool runs GHC with the session flags followed by the module flags. The
-- session flags are the same for every module of the target, including the
-- package dbs. The module flags are the module's own source and output
-- files.
module Request (Request (..), parseRequest, withoutRts, unlinkedSplice, spliceHint) where

import Data.List (stripPrefix)
import System.FilePath ((<.>), (</>))

data Request = Request
  { reqDepfile :: FilePath
  , reqAbi :: FilePath
  , reqModPath :: String -- Foo/Bar
  , reqOutDir :: FilePath -- where every module's outputs are
  , reqHisuf :: String
  , reqHidirs :: [(String, FilePath)] -- the dependencies' interface (and .abi) dirs, by unit id
  , reqMkdirs :: [FilePath] -- output directories to create first
  , reqBoot :: Bool -- whether the module is a boot file
  , reqCompiler :: String
  , reqSessionArgs :: [String] -- the flags of every module of the target
  , reqModuleArgs :: [String] -- the module's own: `ghc -c`'s source and outputs
  }

parseRequest :: [String] -> Either String Request
parseRequest = go (Request "" "" "" "" "" [] [] False "" [] [])
  where
    go r ("--depfile" : v : rest) = go r{reqDepfile = v} rest
    go r ("--abi" : v : rest) = go r{reqAbi = v} rest
    go r ("--module" : v : rest) = go r{reqModPath = v} rest
    go r ("--outdir" : v : rest) = go r{reqOutDir = v} rest
    go r ("--hisuf" : v : rest) = go r{reqHisuf = v} rest
    go r ("--" : compiler : rest) =
      let (session, moduleArgs) = break (== "--") rest
       in Right r{reqCompiler = compiler, reqSessionArgs = session, reqModuleArgs = drop 1 moduleArgs, reqBoot = reqAbi r == reqOutDir r </> reqModPath r <.> "abi-boot"}
    go r (x : rest)
      | Just v <- stripPrefix "--hidir=" x, (unit, '=' : d) <- break (== '=') v = go r{reqHidirs = reqHidirs r ++ [(unit, d)]} rest
      | Just v <- stripPrefix "--mkdir=" x = go r{reqMkdirs = reqMkdirs r ++ [v]} rest
      | otherwise = Left ("unexpected argument " ++ show x)
    go _ [] = Left "no compiler command"

-- | GHC's error for a splice that couldn't load the code it runs.
unlinkedSplice :: String
unlinkedSplice = "couldn't find the following symbol"

-- | The advice for a module whose splice couldn't load the code it runs. A
-- splice can only run code of prebuilt packages (see Note [Template Haskell
-- modules] in compile_per_module.bzl).
spliceHint :: Request -> String
spliceHint r = "\n" ++ map (\c -> if c == '/' then '.' else c) (reqModPath r) ++ ": per_module: a splice can run only the code of prebuilt packages, not of this project's other libraries: build the target with per_module = False\n"

-- | GHC's flags without options for its runtime (@+RTS ... -RTS@).
withoutRts :: [String] -> [String]
withoutRts args = case break (== "+RTS") args of
  (ghc, _ : rest) -> ghc ++ withoutRts (drop 1 (dropWhile (/= "-RTS") rest))
  (ghc, []) -> ghc
