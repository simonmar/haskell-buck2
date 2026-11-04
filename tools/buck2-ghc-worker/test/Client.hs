{-# LANGUAGE OverloadedStrings #-}
-- | A client that talks to the worker the way buck2 does, for the test suite
-- and the benchmarks.
module Client (ghcPkgOf, grpc, poll, startWorkerProcess, withWorkerProcess) where

import Control.Concurrent (threadDelay)
import Control.Exception (IOException, bracket, finally, try)
import Control.Monad (unless)
import Data.ByteString (ByteString)
import qualified Data.ByteString as B
import qualified Data.ByteString.Builder as BB
import qualified Data.ByteString.Char8 as B8
import qualified Network.HTTP.Types as H
import qualified Network.HTTP2.Client as H2
import Network.Socket
import Data.List (isPrefixOf)
import System.Directory (removePathForcibly)
import System.Environment (getEnvironment)
import System.FilePath (takeDirectory, takeFileName, (</>))
import System.Process (CreateProcess (..), ProcessHandle, StdStream, createProcess, proc, terminateProcess, waitForProcess)

import Proto

-- | Send a request with the given arguments to the worker listening on the
-- socket, as a gRPC call of /worker.Worker/Execute, and return the exit code
-- and stderr that the worker answers with. Unlike buck2, which sends many
-- requests over one connection, this opens a new connection for each
-- request. The worker handles both the same way.
grpc :: FilePath -> [String] -> IO (Int, String)
grpc path args = do
  sock <- socket AF_UNIX Stream defaultProtocol
  connect sock (SockAddrUnix path)
  -- Allow the connection to stay quiet for far longer than any compile
  -- takes, instead of http2's default of 30 seconds. The callers put their
  -- own time limits on compiles.
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

-- | Start a worker the way buck2 starts it. The worker runs in the given
-- directory, with the given arguments (RTS options, for example), the given
-- environment variables added to this process's environment, and the given
-- stderr. Its socket is w.sock in that directory. Once the worker accepts
-- connections on the socket, this returns the worker's process and the
-- socket's path.
startWorkerProcess :: FilePath -> [String] -> FilePath -> [(String, String)] -> StdStream -> IO (ProcessHandle, FilePath)
startWorkerProcess worker args dir settings0 err = do
  let sock = dir </> "w.sock"
      settings = ("WORKER_SOCKET", sock) : settings0
  removePathForcibly sock
  environment <- getEnvironment
  (_, _, _, ph) <- createProcess (proc worker args){cwd = Just dir, env = Just (settings ++ filter ((`notElem` map fst settings) . fst) environment), std_err = err}
  -- The socket's file appears when the worker binds it, a moment before the
  -- worker starts listening, so the first connections may be refused. So we
  -- retry until one succeeds, as buck2 does.
  ok <- poll 100 (accepts sock)
  unless ok $ terminateProcess ph >> fail "the worker opened no socket"
  pure (ph, sock)

-- | Whether a connection to the socket succeeds.
accepts :: FilePath -> IO Bool
accepts path = bracket (socket AF_UNIX Stream defaultProtocol) close $ \sock ->
  either (\(_ :: IOException) -> False) (const True) <$> try (connect sock (SockAddrUnix path))

-- | Start a worker with startWorkerProcess, and run the body with the
-- worker's socket. Afterwards, whether or not the body succeeded, end the
-- worker with SIGTERM, as buck2 does.
withWorkerProcess :: FilePath -> [String] -> FilePath -> [(String, String)] -> StdStream -> (FilePath -> IO a) -> IO a
withWorkerProcess worker args dir settings err k =
  bracket
    (startWorkerProcess worker args dir settings err)
    (\(ph, _) -> terminateProcess ph >> waitForProcess ph)
    (k . snd)

-- | Check the condition every tenth of a second, up to the given number of
-- times, and return whether it ever held. This is for waiting on another
-- process, whose progress the caller can only observe from outside.
poll :: Int -> IO Bool -> IO Bool
poll n cond = do
  ok <- cond
  if ok then pure True else if n <= 0 then pure False else threadDelay 100000 >> poll (n - 1) cond

-- | The ghc-pkg that comes with the given GHC, in the same directory. For
-- example, the ghc-pkg of /opt/bin/ghc-9.12.4 is /opt/bin/ghc-pkg-9.12.4. If
-- the GHC is a bare name with no directory, so is the result, to be looked
-- up on $PATH.
ghcPkgOf :: String -> String
ghcPkgOf ghc = if '/' `elem` ghc then takeDirectory ghc </> name else name
  where
    name = rename (takeFileName ghc)
    rename s
      | "ghc" `isPrefixOf` s = "ghc-pkg" ++ drop 3 s
      | c : rest <- s = c : rename rest
      | otherwise = "ghc-pkg"
