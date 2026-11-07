{-# LANGUAGE OverloadedStrings #-}
-- | A client of the worker, as buck2 is one, for the test suite and the
-- benchmarks.
module Client (ghcPkgOf, grpc, poll, startWorkerProcess, withWorkerProcess) where

import Control.Concurrent (threadDelay)
import Control.Exception (bracket, finally)
import Control.Monad (unless)
import Data.ByteString (ByteString)
import qualified Data.ByteString as B
import qualified Data.ByteString.Builder as BB
import qualified Data.ByteString.Char8 as B8
import qualified Network.HTTP.Types as H
import qualified Network.HTTP2.Client as H2
import Network.Socket
import Data.List (isPrefixOf)
import System.Directory (doesFileExist, removePathForcibly)
import System.Environment (getEnvironment)
import System.FilePath (takeDirectory, takeFileName, (</>))
import System.Process (CreateProcess (..), ProcessHandle, StdStream, createProcess, proc, terminateProcess, waitForProcess)

import Proto

-- | Send a request with the given arguments, as a call of
-- /worker.Worker/Execute on the worker's socket, and return its exit code
-- and stderr. Each request gets a connection of its own, unlike buck2's, but
-- the server treats connections alike.
grpc :: FilePath -> [String] -> IO (Int, String)
grpc path args = do
  sock <- socket AF_UNIX Stream defaultProtocol
  connect sock (SockAddrUnix path)
  -- A connection timeout far longer than a compile (http2's default is 30
  -- seconds), since the callers bound compiles themselves.
  conf <- H2.allocSimpleConfig' sock 4096 600000000
  (code, err) <- H2.run H2.defaultClientConfig conf client `finally` (H2.freeSimpleConfig conf >> close sock)
  pure (code, B8.unpack err)
  where
    payload = encodeExecuteCommand (map B8.pack args)
    frame = BB.word8 0 <> BB.word32BE (fromIntegral (B.length payload)) <> BB.byteString payload
    client :: H2.Client (Int, ByteString)
    client sendRequest _ = sendRequest (H2.requestBuilder H.methodPost "/worker.Worker/Execute" [("content-type", "application/grpc"), ("te", "trailers")] frame) $ \rsp -> do
      body <- readAll rsp []
      pure (decodeExecuteResponse (B.drop 5 body))
    readAll rsp acc = do
      chunk <- H2.getResponseBodyChunk rsp
      if B.null chunk then pure (B.concat (reverse acc)) else readAll rsp (chunk : acc)

-- | Start a worker as buck2 starts it, with the given arguments (RTS
-- options, say), in the given directory, with the given environment
-- settings and stderr. Once the worker has opened its socket, w.sock in
-- that directory, returns the process and the socket's path.
startWorkerProcess :: FilePath -> [String] -> FilePath -> [(String, String)] -> StdStream -> IO (ProcessHandle, FilePath)
startWorkerProcess worker args dir settings0 err = do
  let sock = dir </> "w.sock"
      settings = ("WORKER_SOCKET", sock) : settings0
  removePathForcibly sock
  environment <- getEnvironment
  (_, _, _, ph) <- createProcess (proc worker args){cwd = Just dir, env = Just (settings ++ filter ((`notElem` map fst settings) . fst) environment), std_err = err}
  ok <- poll 100 (doesFileExist sock)
  unless ok $ terminateProcess ph >> fail "the worker opened no socket"
  pure (ph, sock)

-- | Run the body with a worker started as startWorkerProcess starts it,
-- passing it the worker's socket. The worker is ended with SIGTERM, as
-- buck2 ends it, whatever the body did.
withWorkerProcess :: FilePath -> [String] -> FilePath -> [(String, String)] -> StdStream -> (FilePath -> IO a) -> IO a
withWorkerProcess worker args dir settings err k =
  bracket
    (startWorkerProcess worker args dir settings err)
    (\(ph, _) -> terminateProcess ph >> waitForProcess ph)
    (k . snd)

-- | Whether the condition holds within the given number of tenths of a
-- second. This is for waiting on another process, which the caller can only
-- watch.
poll :: Int -> IO Bool -> IO Bool
poll n cond = do
  ok <- cond
  if ok then pure True else if n <= 0 then pure False else threadDelay 100000 >> poll (n - 1) cond

-- | The ghc-pkg beside a GHC: ghc-9.12.4's is ghc-pkg-9.12.4. A bare name
-- stays one, to be found on $PATH.
ghcPkgOf :: String -> String
ghcPkgOf ghc = if '/' `elem` ghc then takeDirectory ghc </> name else name
  where
    name = rename (takeFileName ghc)
    rename s
      | "ghc" `isPrefixOf` s = "ghc-pkg" ++ drop 3 s
      | c : rest <- s = c : rename rest
      | otherwise = "ghc-pkg"
