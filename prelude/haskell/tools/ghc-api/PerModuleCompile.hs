-- | Compiles one module of a target compiled per-module with `ghc -c`, then
-- writes the module's .abi file and buck2 dep file from the interface GHC
-- wrote. It takes the same request as the persistent worker, and writes the
-- same files (see Request and DepFile, and compile_per_module in
-- prelude/haskell/compile_per_module.bzl).
--
-- It reads the interface with GHC's code, using the libdir that the request
-- names. This program must be built with the same version of GHC as the
-- GHC that compiles the module, because only that version can read the
-- module's interface.
module Main (main) where

import Control.Exception (SomeException, displayException, fromException, handle, throwIO)
import Control.Monad (unless, when)
import qualified Data.ByteString as B
import System.Directory (createDirectoryIfMissing)
import System.Environment (getArgs, getEnvironment)
import System.Exit (ExitCode (..), exitWith)
import System.FilePath (takeDirectory)
import System.IO (Handle, IOMode (WriteMode), hPutStrLn, hSetBinaryMode, stderr, withBinaryFile)
import System.Process (CreateProcess (..), StdStream (..), createProcess, proc, waitForProcess)

import GHC.Utils.Panic (GhcException (..))

import DepFile (writeDepFiles)
import Interface (readInterface)
import Request

main :: IO ()
main = handle failed $ do
  r <- either (\err -> hPutStrLn stderr ("per_module_compile: " ++ err) >> exitWith (ExitFailure 2)) pure . parseRequest =<< getArgs
  mapM_ (createDirectoryIfMissing True) (reqMkdirs r)
  -- GHC's interpreter runs the module's splices in GHC's own process, with
  -- GHC's environment. So GHC gets the variables of the request's data dirs,
  -- and its library paths on LD_LIBRARY_PATH (see Note [Data files of
  -- splices] and Note [Template Haskell modules] in compile_per_module.bzl).
  env <- withRequestEnv r <$> getEnvironment
  (_, _, Just err, p) <- createProcess (proc (reqCompiler r) (reqSessionArgs r ++ reqModuleArgs r)){std_err = CreatePipe, env = Just env}
  createDirectoryIfMissing True (takeDirectory (reqDiagnostics r))
  withBinaryFile (reqDiagnostics r) WriteMode (relay err)
  code <- exitCode <$> waitForProcess p
  when (code /= 0) $ exitWith (ExitFailure code)
  case moduleArg "-ohi" r of
    Just hi -> readInterface (reqLibdir r) hi >>= writeDepFiles r
    Nothing -> hPutStrLn stderr "per_module_compile: the request names no interface file (-ohi)" >> exitWith (ExitFailure 2)

-- | Copy GHC's diagnostics to stderr as they come, and to the request's
-- diagnostics file, bytes unchanged.
relay :: Handle -> Handle -> IO ()
relay h file = hSetBinaryMode h True >> hSetBinaryMode stderr True >> go
  where
    go = do
      chunk <- B.hGetSome h 65536
      unless (B.null chunk) (B.hPut stderr chunk >> B.hPut file chunk >> go)

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
