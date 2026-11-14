-- | The libdir of the GHC that compiles the target, which the rules pass to
-- the tools. The tools run GHC's code in-process, which needs the libdir to
-- find GHC's settings and package database, and to read the interfaces that
-- the GHC writes.
module Libdir (takeLibdir) where

import Data.List (stripPrefix)
import System.Exit (ExitCode (..), exitWith)
import System.IO (hPutStrLn, stderr)

-- | Split the first argument, --libdir=DIR, off the arguments, or exit with
-- an error, naming the tool, if it isn't there.
takeLibdir :: String -> [String] -> IO (FilePath, [String])
takeLibdir _ (arg : rest) | Just dir <- stripPrefix "--libdir=" arg = pure (dir, rest)
takeLibdir tool _ = do
  hPutStrLn stderr (tool ++ ": the first argument must be --libdir=DIR, the libdir of the GHC that compiles the target")
  exitWith (ExitFailure 2)
