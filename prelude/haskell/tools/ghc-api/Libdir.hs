{-# LANGUAGE CPP #-}
-- | The libdir of the GHC that compiles the target. The tools need it to run
-- GHC's code in-process, for example to read the package databases and the
-- interfaces that the GHC writes.
module Libdir (takeLibdir) where

import Data.List (stripPrefix)
#ifndef GHC_LIBDIR
import System.Exit (ExitCode (..), exitWith)
import System.IO (hPutStrLn, stderr)
#endif

-- | Splits an optional first argument --libdir=DIR off the arguments. The
-- tool must be built with the same version of GHC as the GHC that compiles
-- the target, because only that version can read the GHC's files.
--
-- Without --libdir, the libdir is that of the GHC that built the tool,
-- which haskell_ghc_api_tool passes as the CPP macro GHC_LIBDIR. A tool
-- built for a GHC other than the one that builds it, such as a tool that
-- links the GHC library of a GHC built from source, has no GHC_LIBDIR and
-- is always given --libdir.
takeLibdir :: String -> [String] -> IO (FilePath, [String])
takeLibdir _ (arg : rest) | Just dir <- stripPrefix "--libdir=" arg = pure (dir, rest)
#ifdef GHC_LIBDIR
takeLibdir _ args = pure (GHC_LIBDIR, args)
#else
takeLibdir tool _ = do
  hPutStrLn stderr (tool ++ ": the first argument must be --libdir=DIR, because this program wasn't built with a GHC_LIBDIR")
  exitWith (ExitFailure 2)
#endif
