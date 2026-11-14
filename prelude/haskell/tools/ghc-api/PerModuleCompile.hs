{-# LANGUAGE CPP #-}
-- | Compiles one module of a target compiled per-module with `ghc -c`, then
-- writes the module's .abi file and buck2 dep file from the interface GHC
-- wrote. It takes the same request as the persistent worker, and writes the
-- same files (see Request and DepFile, and compile_per_module in
-- prelude/haskell/compile_per_module.bzl).
--
-- GHC_LIBDIR is the libdir of the GHC this program is built with, which has
-- to be the GHC that compiles the modules: only that GHC can read their
-- interfaces.
module Main (main) where

import Control.Exception (SomeException, displayException, fromException, handle, throwIO)
import Control.Monad (when)
import qualified Data.ByteString as B
import qualified Data.ByteString.Char8 as B8
import System.Directory (createDirectoryIfMissing)
import System.Environment (getArgs, getEnvironment)
import System.Exit (ExitCode (..), exitWith)
import System.IO (Handle, hPutStr, hPutStrLn, hSetBinaryMode, stderr)
import System.Process (CreateProcess (..), StdStream (..), createProcess, proc, waitForProcess)

import GHC.Utils.Panic (GhcException (..))

import DepFile (writeDepFiles)
import Interface (readInterface)
import Request

main :: IO ()
main = handle failed $ do
  r <- either (\err -> hPutStrLn stderr ("per_module_compile: " ++ err) >> exitWith (ExitFailure 2)) pure . parseRequest =<< getArgs
  mapM_ (createDirectoryIfMissing True) (reqMkdirs r)
  -- With -fforce-recomp: buck2 decides when the module compiles, not GHC
  -- (see Note [Early cut-off by dep files] in compile_per_module.bzl).
  -- GHC's interpreter runs the module's splices with GHC's environment, so
  -- GHC gets the variables of the request's data dirs (see Note [Data files
  -- of splices] in compile_per_module.bzl).
  env <- withDataDirs r <$> getEnvironment
  (_, _, Just err, p) <- createProcess (proc (reqCompiler r) (reqSessionArgs r ++ ["-fforce-recomp"] ++ reqModuleArgs r)){std_err = CreatePipe, env = Just env}
  out <- relay err
  code <- exitCode <$> waitForProcess p
  when (code /= 0) $ do
    mapM_ (hPutStr stderr) (spliceHint r (B8.unpack out))
    exitWith (ExitFailure code)
  case dropWhile (/= "-ohi") (reqModuleArgs r) of
    _ : hi : _ -> readInterface GHC_LIBDIR hi >>= writeDepFiles r
    _ -> hPutStrLn stderr "per_module_compile: the request names no interface file (-ohi)" >> exitWith (ExitFailure 2)

-- | Copy GHC's diagnostics to stderr as they come, bytes unchanged, and
-- return them.
relay :: Handle -> IO B.ByteString
relay h = hSetBinaryMode h True >> hSetBinaryMode stderr True >> go []
  where
    go chunks = do
      chunk <- B.hGetSome h 65536
      if B.null chunk
        then pure (B.concat (reverse chunks))
        else B.hPut stderr chunk >> go (chunk : chunks)

-- | Fail with what went wrong, such as an interface that recorded no usages
-- (see DepFile), rather than with an uncaught exception.
failed :: SomeException -> IO ()
failed e = case fromException e of
  Just exit -> throwIO (exit :: ExitCode)
  Nothing -> do
    hPutStrLn stderr ("per_module_compile: " ++ case fromException e of
      Just (ProgramError m) -> m
      _ -> displayException e)
    exitWith (ExitFailure 1)

-- | A process's exit code, as a shell gives it: 128 plus the signal's number
-- for a process killed by a signal.
exitCode :: ExitCode -> Int
exitCode ExitSuccess = 0
exitCode (ExitFailure n) = if n < 0 then 128 - n else n
