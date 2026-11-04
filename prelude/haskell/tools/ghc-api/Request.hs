{-# LANGUAGE CPP #-}
-- | The request the rules send for each module, the flags of the session it
-- compiles in, and the advice added to a failed compile's output.
module Request (Request (..), parseRequest, sessionFlags, withoutRts, unlinkedSplice, spliceHint, withSpliceHint) where

import Data.List (isInfixOf, stripPrefix)

import Contract (contract)

-- | One module to compile, as the rules describe it in the action's
-- arguments (see Note [The persistent worker] in compile_per_module.bzl):
--
-- > --request --contract V --depfile DEP --abi ABI --module Foo/Bar
-- >   --source Foo/Bar.hs --outdir OUT --hisuf SUF --unit UNIT [--boot]
-- >   --hidir=UNIT=DIR... --srcroot=SRCS --mkdir=DIR...
-- >   -- ghc SESSION_FLAGS... -- -c Foo/Bar.hs -o ... -ohi ...
--
-- The compile's flags come in two parts: the flags of the module's session,
-- and the module's own. The worker compiles the module in the session, and
-- of the module's own flags takes only its outputs: @-o@, @-ohi@, @-dyno@,
-- @-dynohi@, @-hiedir@ and @-stubdir@. When
-- buck2 doesn't use the worker, the compile tool (PerModuleCompile) takes
-- the same request.
data Request = Request
  { reqDepfile :: FilePath
  , reqAbi :: FilePath
  , reqModPath :: String -- Foo/Bar
  , reqSource :: FilePath
  , reqOutDir :: FilePath -- where every module's outputs are
  , reqHisuf :: String
  , reqHidirs :: [(String, FilePath)] -- the dependencies' interface (and .abi) dirs, by unit id
  , reqSrcRoots :: [FilePath] -- the tree of the target's sources, where imports are found
  , reqMkdirs :: [FilePath] -- output directories to create first
  , reqBoot :: Bool
  , reqCompiler :: String
  , reqSessionArgs :: [String] -- the flags of every module of the session
  , reqModuleArgs :: [String] -- the module's own: `ghc -c`'s source and outputs, and -hiedir and -stubdir
  }

-- | Parse the request in an action's command line, which buck2 sends whole.
-- The program and its own arguments come before the "--request" marker,
-- and are ignored.
parseRequest :: [String] -> Either String Request
parseRequest args = case drop 1 (dropWhile (/= "--request") args) of
  "--contract" : v : rest
    | v == contract -> go (Request "" "" "" "" "" "" [] [] [] False "" [] []) rest
    | otherwise -> Left ("this program takes version " ++ contract ++ " of the rules' requests, but the rules sent version " ++ v ++ ": build it from the same version of the rules")
  _ -> Left "the request names no version: build this program from the same version of the rules"
  where
    go r ("--depfile" : v : rest) = go r{reqDepfile = v} rest
    go r ("--abi" : v : rest) = go r{reqAbi = v} rest
    go r ("--module" : v : rest) = go r{reqModPath = v} rest
    go r ("--source" : v : rest) = go r{reqSource = v} rest
    go r ("--outdir" : v : rest) = go r{reqOutDir = v} rest
    go r ("--hisuf" : v : rest) = go r{reqHisuf = v} rest
    go r ("--boot" : rest) = go r{reqBoot = True} rest
    -- Ignored, since the session's flags name the module's unit too.
    go r ("--unit" : _ : rest) = go r rest
    go r ("--" : compiler : rest) =
      let (session, moduleArgs) = break (== "--") rest
       in Right r{reqCompiler = compiler, reqSessionArgs = session, reqModuleArgs = drop 1 moduleArgs}
    go r (x : rest)
      | Just v <- stripPrefix "--hidir=" x, (unit, '=' : d) <- break (== '=') v = go r{reqHidirs = reqHidirs r ++ [(unit, d)]} rest
      | Just v <- stripPrefix "--srcroot=" x = go r{reqSrcRoots = reqSrcRoots r ++ [v]} rest
      | Just v <- stripPrefix "--mkdir=" x = go r{reqMkdirs = reqMkdirs r ++ [v]} rest
      | otherwise = Left ("unexpected request argument " ++ show x)
    go _ [] = Left "the request has no compiler command"

-- | The flags of the request's session. These are the compile's flags
-- without the module's own, plus:
--
-- - @-odir@ and @-hidir@, so that outputs go to the output directory by
--   module name, which is where the rules put them anyway;
-- - the target's sources on the import path;
-- - @-fforce-recomp@, so that each request is compiled whatever GHC's
--   recompilation check would say (see Note [Compiling whenever buck2 asks]
--   in Session);
-- - flags that make object code deterministic, where GHC can (see
--   'objectDeterminism').
--
-- Options for the ghc program's runtime (@+RTS ... -RTS@) are left out,
-- since the worker's runtime is its own.
sessionFlags :: Request -> [String]
sessionFlags r =
  withoutRts (reqSessionArgs r)
    ++ ["-odir", reqOutDir r, "-hidir", reqOutDir r, "-fforce-recomp"]
    ++ objectDeterminism
    ++ ["-i" ++ d | d <- reqSrcRoots r]

-- | Flags that make object code deterministic, where GHC can (9.12 and
-- later). Otherwise GHC's uniques depend on what the session compiled
-- before, so a module's object would differ from one compile to the next,
-- and buck2 would link the library again after every edit.
objectDeterminism :: [String]
#if MIN_VERSION_ghc(9,12,0)
objectDeterminism = ["-fobject-determinism"]
#else
objectDeterminism = []
#endif

-- | GHC's flags without options for its runtime (@+RTS ... -RTS@).
withoutRts :: [String] -> [String]
withoutRts args = case break (== "+RTS") args of
  (ghc, _ : rest) -> ghc ++ withoutRts (drop 1 (dropWhile (/= "-RTS") rest))
  (ghc, []) -> ghc

-- | Add the rules' advice to the output of a compile whose splice couldn't
-- load the code it runs. A splice can only run code of a library of the
-- project whose final package db the module compiles against (see Note
-- [Template Haskell modules] in compile_per_module.bzl).
withSpliceHint :: Request -> (Int, String) -> (Int, String)
withSpliceHint r (code, out)
  | code /= 0 && unlinkedSplice `isInfixOf` out = (code, out ++ spliceHint r)
  | otherwise = (code, out)

-- | GHC's error for a splice that couldn't load the code it runs.
unlinkedSplice :: String
unlinkedSplice = "couldn't find the following symbol"

-- | The advice for a module whose splice couldn't load the code it runs.
spliceHint :: Request -> String
spliceHint r = "\n" ++ map (\c -> if c == '/' then '.' else c) (reqModPath r) ++ ": per_module: a splice ran code of a library of this project that the module doesn't compile against: list it in the target's th_build_depends, or, with explicit level imports, import the module whose code the splice runs with `import splice`\n"
