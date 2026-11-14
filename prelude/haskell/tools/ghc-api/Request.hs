{-# LANGUAGE CPP #-}
-- | The request that the rules send to compile each module, the flags of
-- the GHC session that compiles it, and the advice that is added to a
-- failed compile's output.
module Request (Request (..), parseRequest, sessionFlags, withDataDirs, withoutRts, spliceHint, withSpliceHint) where

import Data.Char (isDigit, isSpace)
import Data.List (intercalate, isPrefixOf, stripPrefix, tails)
import Data.Maybe (fromMaybe, listToMaybe, mapMaybe)

import Contract (contract)

-- | The request to compile one module, which the rules send as the
-- action's arguments (see Note [The persistent worker] in
-- compile_per_module.bzl):
--
-- > --request --contract V --depfile DEP --abi ABI --module Foo/Bar
-- >   --source Foo/Bar.hs --outdir OUT --hisuf SUF [--boot]
-- >   [--hidir=UNIT=DIR]... [--srcroot=SRCS]... [--mkdir=DIR]...
-- >   [--data-dir=VAR=DIR]...
-- >   -- ghc SESSION_FLAGS... -- -c Foo/Bar.hs -o ... -ohi ...
--
-- The flags come in two parts: the session flags, which are the same for
-- every module of the target, and the module's own. The worker compiles the
-- module in the session, and takes only the outputs from the module's flags:
-- @-o@, @-ohi@, @-dyno@, @-dynohi@, @-hiedir@ and @-stubdir@. When buck2
-- doesn't use the worker, the compile tool (PerModuleCompile) takes the same
-- request.
data Request = Request
  { reqDepfile :: FilePath
  , reqAbi :: FilePath
  , reqModPath :: String -- Foo/Bar
  , reqSource :: FilePath
  , reqOutDir :: FilePath -- where every module's outputs are
  , reqHisuf :: String
  , reqHidirs :: [(String, FilePath)] -- the dependencies' interface (and .abi) dirs, by unit id
  , reqSrcRoots :: [FilePath] -- trees of the target's sources, which go on the session's import path
  , reqMkdirs :: [FilePath] -- output directories to create first
  , reqDataDirs :: [(String, FilePath)] -- the variables for the module's splices, with the data dirs they name (see Note [Data files of splices] in compile_per_module.bzl)
  , reqBoot :: Bool -- whether the module is a boot file
  , reqCompiler :: String
  , reqSessionArgs :: [String] -- the session flags, which are the same for every module of the target
  , reqModuleArgs :: [String] -- the module flags: `ghc -c`'s source and output files, -hiedir and -stubdir
  }

-- | Parse the request from an action's command line. buck2 sends the whole
-- command line, so it starts with the program and the program's own
-- arguments. Those end at the "--request" marker, and are ignored.
parseRequest :: [String] -> Either String Request
parseRequest args = case drop 1 (dropWhile (/= "--request") args) of
  "--contract" : v : rest
    | v == contract -> go (Request "" "" "" "" "" "" [] [] [] [] False "" [] []) rest
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
    go r ("--" : compiler : rest) =
      let (session, moduleArgs) = break (== "--") rest
       in Right r{reqCompiler = compiler, reqSessionArgs = session, reqModuleArgs = drop 1 moduleArgs}
    go r (x : rest)
      | Just v <- stripPrefix "--hidir=" x, (unit, '=' : d) <- break (== '=') v = go r{reqHidirs = reqHidirs r ++ [(unit, d)]} rest
      | Just v <- stripPrefix "--srcroot=" x = go r{reqSrcRoots = reqSrcRoots r ++ [v]} rest
      | Just v <- stripPrefix "--mkdir=" x = go r{reqMkdirs = reqMkdirs r ++ [v]} rest
      | Just v <- stripPrefix "--data-dir=" x, (var, '=' : d) <- break (== '=') v = go r{reqDataDirs = reqDataDirs r ++ [(var, d)]} rest
      | otherwise = Left ("unexpected request argument " ++ show x)
    go _ [] = Left "the request has no compiler command"

-- | The flags of the session that compiles the request's module. They are
-- the request's session flags, without any options for the ghc program's
-- runtime (@+RTS ... -RTS@), because the worker has its own runtime. To
-- those, this adds:
--
-- - @-odir@ and @-hidir@, so that GHC writes each output into the output
--   directory, at a path made from the module's name. That is where the
--   rules expect the outputs.
-- - The trees of the target's sources, on the import path.
-- - @-fforce-recomp@, so that GHC compiles the module whenever the worker
--   asks, whatever GHC's recompilation check would say (see Note
--   [Compiling whenever buck2 asks] in tools/buck2-ghc-worker/src/Session.hs).
-- - Flags that make object code deterministic, where GHC supports them
--   (see 'objectDeterminism').
sessionFlags :: Request -> [String]
sessionFlags r =
  withoutRts (reqSessionArgs r)
    ++ ["-odir", reqOutDir r, "-hidir", reqOutDir r, "-fforce-recomp"]
    ++ objectDeterminism
    ++ ["-i" ++ d | d <- reqSrcRoots r]

-- | Flags that make object code deterministic, which GHC supports from
-- 9.12. Without them, the uniques in a module's object depend on what the
-- session compiled before. The object would then differ from one compile
-- to the next, and buck2 would link the library again after every edit.
objectDeterminism :: [String]
#if MIN_VERSION_ghc(9,12,0)
objectDeterminism = ["-fobject-determinism"]
#else
objectDeterminism = []
#endif

-- | Add the variables of the request's data dirs to an environment,
-- replacing any variables of the same names.
withDataDirs :: Request -> [(String, String)] -> [(String, String)]
withDataDirs r env = reqDataDirs r ++ [(k, v) | (k, v) <- env, k `notElem` map fst (reqDataDirs r)]

-- | GHC's flags without options for its runtime (@+RTS ... -RTS@).
withoutRts :: [String] -> [String]
withoutRts args = case break (== "+RTS") args of
  (ghc, _ : rest) -> ghc ++ withoutRts (drop 1 (dropWhile (/= "-RTS") rest))
  (ghc, []) -> ghc

-- | Add the rules' advice to the output of a compile whose splice couldn't
-- load the code it runs. A splice can only run code from a library of the
-- project if the module compiles against that library's final package db
-- (see Note [Template Haskell modules] in compile_per_module.bzl).
withSpliceHint :: Request -> (Int, String) -> (Int, String)
withSpliceHint r (code, out)
  | code /= 0 = (code, out ++ fromMaybe "" (spliceHint r out))
  | otherwise = (code, out)

-- | The advice for a module whose compile failed with the given output, if
-- the output says that a splice couldn't load the code it runs. The advice
-- names the package of the missing symbol, if the output gives the symbol
-- z-encoded: its prefix up to the first underscore is the unit id of the
-- package, such as @textzm2zi1zi2zmAbC_DataziText_pack_closure@ for
-- text-2.1.2-AbC.
--
-- GHC's error gives the symbol so up to GHC 9.12. From 9.14 it gives only
-- the name (@closure:pack@). On macOS, a splice that loads a module of its
-- own target fails in the external interpreter alone, with no error from
-- GHC. In both cases only the interpreter's own messages have the symbol.
-- Those messages aren't in the output of a compile in the persistent
-- worker, so there the advice can't name the package.
spliceHint :: Request -> String -> Maybe String
spliceHint r out
  | null ghcErrors && null lookupFailures = Nothing
  | otherwise = Just ("\n" ++ reqSource r ++ ": error: per_module: a splice couldn't load code from " ++ maybe "a package" ("the package " ++) (listToMaybe (mapMaybe package (interpreterSymbols ++ lookupFailures ++ concatMap ghcSymbol ghcErrors))) ++ advice)
  where
    unlinkedSplice = "couldn't find the following symbol"
    ghcErrors = take 1 [rest | rest <- tails out, unlinkedSplice `isPrefixOf` rest]
    -- The line after GHC's message is the symbol, or, for the library that
    -- GHC loaded the target's own modules from, "<library>: undefined
    -- symbol: <symbol>". Either way the symbol is the line's last word.
    ghcSymbol rest = take 1 (reverse (words (takeWhile (/= '\n') (dropWhile isSpace (dropWhile (== ':') (drop (length unlinkedSplice) rest))))))
    interpreterSymbols = [takeWhile (/= '\'') symbol | line <- tails out, Just symbol <- [stripPrefix "Could not load '" line]]
    -- The interpreter's message for each symbol it couldn't find. The symbol
    -- may be a C function's (_cl_value, say), which names no package.
    lookupFailures = [takeWhile (not . isSpace) symbol | line <- tails out, Just symbol <- [stripPrefix "Failed to lookup symbol: " line]]
    -- macOS's symbols have an underscore in front of the name GHC gave them.
    package symbol
      | '_' `elem` name = packageName (zDecode (takeWhile (/= '_') name))
      | otherwise = Nothing
      where
        name = fromMaybe symbol (stripPrefix "_" symbol)
    advice = ": list the package in the target's template_haskell_depends\n"

-- | The package name of a unit id such as text-2.1.2-AbC: the components
-- before the version. Nothing if it has no version, as the prefix of a C
-- symbol hasn't.
packageName :: String -> Maybe String
packageName unit = case break startsWithDigit (splitOn '-' unit) of
  (name@(_ : _), _ : _) -> Just (intercalate "-" name)
  _ -> Nothing
  where
    startsWithDigit (c : _) = isDigit c
    startsWithDigit [] = False
    splitOn d xs = case break (== d) xs of
      (a, _ : b) -> a : splitOn d b
      (a, []) -> [a]

-- | Decode GHC's z-encoding of a name, for the characters a unit id has.
zDecode :: String -> String
zDecode ('z' : c : rest) | Just d <- lookup c [('m', '-'), ('i', '.'), ('u', '_'), ('z', 'z')] = d : zDecode rest
zDecode ('Z' : 'Z' : rest) = 'Z' : zDecode rest
zDecode (c : rest) = c : zDecode rest
zDecode [] = []
