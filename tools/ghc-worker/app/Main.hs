{-# LANGUAGE ScopedTypeVariables #-}
-- | buck2 persistent worker for per-module Haskell compilation. See Note
-- [How the worker works] in Worker.
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
  -- Write each line whole. Unbuffered, a line is written a character at a
  -- time, and the lines of concurrent compiles interleave.
  hSetBuffering stderr LineBuffering
  socket <- lookupEnv "WORKER_SOCKET"
  case socket of
    Nothing -> do
      hPutStrLn stderr "ghc-worker: runs as a buck2 persistent worker, with WORKER_SOCKET set; without one, the rules compile with their compile tool (prelude/haskell/tools/ghc-api)"
      exitWith (ExitFailure 2)
    Just path -> persistent path

-- The worker starts when the first request arrives, since it needs the
-- request's compiler. Then each request is compiled by the thread that
-- received it. If the worker can't start, every request fails, saying why.
persistent :: FilePath -> IO ()
persistent path = do
  -- buck2 ends its workers with SIGTERM when the build is done. But if the
  -- daemon is killed during the build, the worker lives on, holding its
  -- sessions, with nothing to send it requests. So we also end when the
  -- process that started us (buck2's forkserver) does.
  --
  -- Either way, `end` ends the sessions first, which removes their
  -- temporary files, and then exits even if that throws or hangs (hence the
  -- try and the timeout). It may run in the thread that checks the parent,
  -- where an exception would end only that thread, not the process.
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
        Left err -> pure (2, B8.pack ("ghc-worker: " ++ err ++ "\n"))
        Right req -> do
          _ <- tryPutMVar first req
          w <- readMVar worker
          case w of
            Left err -> pure (2, B8.pack (err ++ "\n"))
            Right wk -> (\(code, err) -> (code, B8.pack err)) <$> compileRequest wk req
  void . forkIO $ serve path handle `catch` \(e :: SomeException) -> do
    hPutStrLn stderr ("ghc-worker: " ++ displayException e)
    exitImmediately (ExitFailure 1)
  req <- takeMVar first
  -- The SIGTERM (see above) comes as an exception, from the GHC session's
  -- own signal handler.
  started <- try $ withWorker req (\w -> putMVar worker (Right w) >> forever (threadDelay maxBound)) `catch` \e -> case e of
    Signal _ -> end
    _ -> throwIO e
  case started of
    Right () -> pure ()
    Left (e :: SomeException) -> do
      let err = displayException e
      hPutStrLn stderr err
      -- An exception before the worker started makes every request fail,
      -- saying why. An exception after it started (an interrupt, say) ends
      -- the worker.
      failed <- tryPutMVar worker (Left err)
      if failed then forever (threadDelay maxBound) else end
