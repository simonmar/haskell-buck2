{-# LANGUAGE ScopedTypeVariables #-}
-- | A buck2 persistent worker that compiles the modules of Haskell targets
-- that are compiled per-module. See Note [How the worker works] in Worker.
module Main (main) where

import Control.Concurrent (forkIO, threadDelay)
import Control.Concurrent.MVar
import Control.Exception (SomeException, catch, displayException, throwIO, try)
import System.Timeout (timeout)
import Control.Monad (forever, void, when)
import qualified Data.ByteString.Char8 as B8
import System.Environment (lookupEnv)
import System.Exit (ExitCode (..), exitWith)
import System.IO (BufferMode (..), hPutStrLn, hSetBuffering, stderr)
import System.Posix.Process (exitImmediately, getParentProcessID)

import GHC.Utils.Panic (GhcException (..))
import Grpc (serve)
import Request (parseRequest)
import Worker

main :: IO ()
main = do
  -- Write each line of stderr whole. stderr is unbuffered by default, which
  -- writes a line a character at a time, so the lines that concurrent
  -- compiles log would be interleaved.
  hSetBuffering stderr LineBuffering
  socket <- lookupEnv "WORKER_SOCKET"
  case socket of
    Nothing -> do
      hPutStrLn stderr "buck2-ghc-worker: runs as a buck2 persistent worker, with WORKER_SOCKET set; without one, the rules compile with their compile tool (prelude/haskell/tools/ghc-api)"
      exitWith (ExitFailure 2)
    Just path -> persistent path

-- Serve requests on the socket at the given path. The worker (see Worker) is
-- only started when the first request arrives, because it needs to know
-- which GHC the request names. After that, each request is compiled by the
-- thread that received it. If the worker can't be started, every request
-- fails with the reason.
persistent :: FilePath -> IO ()
persistent path = do
  -- buck2 sends its workers SIGTERM when the build is done. But if the
  -- buck2 daemon is killed during the build, the worker would live on,
  -- holding its sessions' memory, with nothing left to send it requests. So
  -- the worker also exits when the process that started it (buck2's
  -- forkserver) exits, which it notices because its parent process ID
  -- changes.
  --
  -- Either way, `end` shuts the sessions down first, which removes their
  -- temporary files, and then exits. It exits even if the shutdown throws
  -- an exception or hangs, hence the `try` and the `timeout`. It exits with
  -- exitImmediately rather than exitWith, because it may run in the thread
  -- that watches the parent, where exitWith's exception would only end that
  -- thread, not the process.
  worker <- newEmptyMVar
  let end = do
        _ <- timeout 5000000 (try (tryReadMVar worker >>= mapM_ (either (const (pure ())) shutdown)) :: IO (Either SomeException ()))
        exitImmediately ExitSuccess
  parent <- getParentProcessID
  void . forkIO . forever $ do
    threadDelay 1000000
    p <- getParentProcessID
    when (p /= parent) end
  first <- newEmptyMVar
  let handle argv = case parseRequest (map B8.unpack argv) of
        Left err -> pure (2, B8.pack ("buck2-ghc-worker: " ++ err ++ "\n"))
        Right req -> do
          _ <- tryPutMVar first req
          w <- readMVar worker
          case w of
            Left err -> pure (2, B8.pack (err ++ "\n"))
            Right wk -> (\(code, err) -> (code, B8.pack err)) <$> compileRequest wk req
  void . forkIO $ serve path handle `catch` \(e :: SomeException) -> do
    hPutStrLn stderr ("buck2-ghc-worker: " ++ displayException e)
    exitImmediately (ExitFailure 1)
  req <- takeMVar first
  -- GHC's signal handlers, which withWorker installs, turn buck2's SIGTERM
  -- (see above) into a 'Signal' exception in this thread.
  started <- try $ withWorker req (\w -> putMVar worker (Right w) >> forever (threadDelay maxBound)) `catch` \e -> case e of
    Signal _ -> end
    _ -> throwIO e
  case started of
    Right () -> pure ()
    Left (e :: SomeException) -> do
      let err = displayException e
      hPutStrLn stderr err
      -- If the worker never started, `worker` is still empty. Filling it
      -- with the error makes every request fail with that error, and the
      -- process stays up until buck2 ends it. If the worker had started,
      -- the exception (an interrupt, for example) ends the process.
      failed <- tryPutMVar worker (Left err)
      if failed then forever (threadDelay maxBound) else end
