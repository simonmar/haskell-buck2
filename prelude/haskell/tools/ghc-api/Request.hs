-- | The request that the rules send to compile each module, and the flags
-- of the GHC session that compiles it.
module Request (Request (..), parseRequest, moduleArg, sessionFlags, withRequestEnv, withoutRts) where

import Data.List (intercalate, isPrefixOf, stripPrefix)

import Contract (contract)

-- | The request to compile one module, which the rules send as the
-- action's arguments (see Note [The persistent worker] in
-- compile_per_module.bzl):
--
-- > --request --contract V --libdir LIBDIR --depfile DEP --abi ABI
-- >   --module Foo/Bar --source Foo/Bar.hs --outdir OUT --hisuf SUF [--boot]
-- >   [--hidir=UNIT=DIR]... [--srcroot=SRCS]... [--mkdir=DIR]...
-- >   [--data-dir=VAR=DIR]... [--library-path=DIR]... [--loadable=MODULE]...
-- >   -- ghc SESSION_FLAGS... -- -c Foo/Bar.hs -o ... -ohi ...
--
-- The flags come in two parts: the session flags, which are the same for
-- every module of the target, and the module's own. The worker compiles the
-- module in the session, and takes only the outputs from the module's flags:
-- @-o@, @-ohi@, @-dyno@, @-dynohi@, @-hiedir@ and @-stubdir@. When buck2
-- doesn't use the worker, the compile tool (PerModuleCompile) takes the same
-- request.
--
-- LIBDIR is the libdir of the GHC that compiles the module. The worker and
-- the compile tool run GHC's code in-process, and that code reads GHC's
-- settings and package database from the libdir.
data Request = Request
  { reqLibdir :: FilePath
  , reqDepfile :: FilePath
  , reqAbi :: FilePath
  , reqDiagnostics :: FilePath -- where to write the compile's messages, such as warnings
  , reqModPath :: String -- Foo/Bar
  , reqSource :: FilePath
  , reqOutDir :: FilePath -- where every module's outputs are
  , reqHisuf :: String
  , reqHidirs :: [(String, FilePath)] -- the dependencies' interface (and .abi) dirs, by unit id
  , reqSrcRoots :: [FilePath] -- trees of the target's sources, which go on the session's import path
  , reqMkdirs :: [FilePath] -- output directories to create first
  , reqDataDirs :: [(String, FilePath)] -- the variables for the module's splices, with the data dirs they name (see Note [Data files of splices] in compile_per_module.bzl)
  , reqLibraryPaths :: [FilePath] -- the directories of the native libraries that the module's splices may load, for LD_LIBRARY_PATH (see Note [Template Haskell modules] in compile_per_module.bzl)
  , reqBoot :: Bool -- whether the module is a boot file
  , reqLoadable :: [String] -- for a module that runs Template Haskell, the target's modules whose objects the compile has, so that its splices may load them (see Note [Template Haskell modules] in compile_per_module.bzl)
  , reqCompiler :: String
  , reqSessionArgs :: [String] -- the session flags, which are the same for every module of the target
  , reqModuleArgs :: [String] -- the module flags: `ghc -c`'s source and output files, -hiedir and -stubdir
  }

-- | The value that the request's module flags give `flag`, such as the
-- interface file that @-ohi@ names.
moduleArg :: String -> Request -> Maybe FilePath
moduleArg flag r = case dropWhile (/= flag) (reqModuleArgs r) of
  _ : v : _ -> Just v
  _ -> Nothing

-- | Parse the request from an action's command line. buck2 sends the whole
-- command line, so it starts with the program and the program's own
-- arguments. Those end at the "--request" marker, and are ignored.
parseRequest :: [String] -> Either String Request
parseRequest args = case drop 1 (dropWhile (/= "--request") args) of
  "--contract" : v : rest
    | v == contract -> go (Request "" "" "" "" "" "" "" "" [] [] [] [] [] False [] "" [] []) rest
    | otherwise -> Left ("this program takes version " ++ contract ++ " of the rules' requests, but the rules sent version " ++ v ++ ": build it from the same version of the rules")
  _ -> Left "the request names no version: build this program from the same version of the rules"
  where
    go r ("--libdir" : v : rest) = go r{reqLibdir = v} rest
    go r ("--depfile" : v : rest) = go r{reqDepfile = v} rest
    go r ("--abi" : v : rest) = go r{reqAbi = v} rest
    go r ("--diagnostics" : v : rest) = go r{reqDiagnostics = v} rest
    go r ("--module" : v : rest) = go r{reqModPath = v} rest
    go r ("--source" : v : rest) = go r{reqSource = v} rest
    go r ("--outdir" : v : rest) = go r{reqOutDir = v} rest
    go r ("--hisuf" : v : rest) = go r{reqHisuf = v} rest
    go r ("--boot" : rest) = go r{reqBoot = True} rest
    go r ("--" : compiler : rest)
      | null (reqLibdir r) = Left "the request names no libdir (--libdir)"
      | null (reqDiagnostics r) = Left "the request names no diagnostics file (--diagnostics)"
      | otherwise =
          let (session, moduleArgs) = break (== "--") rest
           in Right r{reqCompiler = compiler, reqSessionArgs = session, reqModuleArgs = drop 1 moduleArgs}
    go r (x : rest)
      | Just v <- stripPrefix "--hidir=" x, (unit, '=' : d) <- break (== '=') v = go r{reqHidirs = reqHidirs r ++ [(unit, d)]} rest
      | Just v <- stripPrefix "--srcroot=" x = go r{reqSrcRoots = reqSrcRoots r ++ [v]} rest
      | Just v <- stripPrefix "--mkdir=" x = go r{reqMkdirs = reqMkdirs r ++ [v]} rest
      | Just v <- stripPrefix "--loadable=" x = go r{reqLoadable = reqLoadable r ++ [v]} rest
      | Just v <- stripPrefix "--data-dir=" x, (var, '=' : d) <- break (== '=') v = go r{reqDataDirs = reqDataDirs r ++ [(var, d)]} rest
      | Just d <- stripPrefix "--library-path=" x = go r{reqLibraryPaths = reqLibraryPaths r ++ [d]} rest
      | otherwise = Left ("unexpected request argument " ++ show x)
    go _ [] = Left "the request has no compiler command"

-- | The flags of the session that compiles the request's module. They are
-- the request's session flags, without two kinds of flag that only the ghc
-- program takes:
--
-- - options for the ghc program's runtime (@+RTS ... -RTS@), because the
--   worker has its own runtime;
-- - @-B@, which tells the ghc program its libdir. A toolchain whose GHC is
--   built from source passes it as part of the compiler command. The worker
--   takes the libdir from the request instead (@--libdir@).
--
-- To those, this adds:
--
-- - @-odir@ and @-hidir@, so that GHC writes each output into the output
--   directory, at a path made from the module's name. That is where the
--   rules expect the outputs.
-- - The trees of the target's sources, on the import path.
--
-- Every other flag comes from the rules, so that the worker compiles with
-- the same flags as the compile tool's @ghc -c@.
sessionFlags :: Request -> [String]
sessionFlags r =
  filter (not . ("-B" `isPrefixOf`)) (withoutRts (reqSessionArgs r))
    ++ ["-odir", reqOutDir r, "-hidir", reqOutDir r]
    ++ ["-i" ++ d | d <- reqSrcRoots r]

-- | Add the variables of the request's data dirs to an environment, in place
-- of any variables with the same names, and put the request's library paths
-- at the front of its LD_LIBRARY_PATH. The request's splices need both.
withRequestEnv :: Request -> [(String, String)] -> [(String, String)]
withRequestEnv r env = vars ++ [(k, v) | (k, v) <- env, k `notElem` map fst vars]
  where
    vars = reqDataDirs r ++ [("LD_LIBRARY_PATH", intercalate ":" (reqLibraryPaths r ++ maybe [] pure (lookup "LD_LIBRARY_PATH" env))) | not (null (reqLibraryPaths r))]

-- | GHC's flags without options for its runtime (@+RTS ... -RTS@).
withoutRts :: [String] -> [String]
withoutRts args = case break (== "+RTS") args of
  (ghc, _ : rest) -> ghc ++ withoutRts (drop 1 (dropWhile (/= "-RTS") rest))
  (ghc, []) -> ghc
