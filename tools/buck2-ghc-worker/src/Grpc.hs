{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
-- | A gRPC server for buck2's local worker protocol. It serves the unary
-- call `/worker.Worker/Execute` over HTTP/2, on the Unix socket that buck2
-- names in WORKER_SOCKET. gRPC puts a 1-byte compression flag and a 4-byte
-- big-endian length before each message, and sends the call's status in the
-- HTTP/2 trailers.
module Grpc (serve) where

import Control.Concurrent (forkIO)
import Control.Exception (SomeAsyncException, SomeException, bracket, catch, finally, fromException, throwIO)
import Control.Monad (forever, void)
import Data.Bits (shiftL, (.|.))
import Data.ByteString (ByteString)
import qualified Data.ByteString as B
import qualified Data.ByteString.Builder as BB
import qualified Network.HTTP.Types as H
import Network.HTTP2.Server
import Network.Socket
import Proto
import System.IO (hPutStrLn, stderr)

-- | Serve requests on the Unix socket at the given path. For each request,
-- the handler is given the argv of the command that buck2 asks the worker to
-- run, and returns the command's exit code and stderr. This never returns.
serve :: FilePath -> ([ByteString] -> IO (Int, ByteString)) -> IO ()
serve path handler = withSocketsDo $ bracket open close $ \sock -> do
  listen sock 64
  forever $ do
    (conn, _) <- accept sock
    -- By default, http2's timeout manager kills a connection that receives
    -- nothing for 30 seconds, and a request's handler that neither reads
    -- nor writes for that long. Neither is a sign of trouble here. buck2
    -- keeps one connection open for the whole build, and it is quiet while
    -- buck2 runs other actions. A handler writes nothing while it compiles,
    -- which can take longer than that. So we set the timeout to a day,
    -- which in effect turns it off.
    conf <- allocSimpleConfig' conn 32768 (24 * 3600 * 1000000)
    -- When buck2 closes the connection, `run` throws an exception. That is
    -- the normal way for a connection to end, so the exception is ignored.
    void $ forkIO ((run defaultServerConfig conf server `catch` \(_ :: SomeException) -> pure ()) `finally` (freeSimpleConfig conf >> close conn))
  where
    open = do
      s <- socket AF_UNIX Stream defaultProtocol
      bind s (SockAddrUnix path)
      pure s
    -- A synchronous exception from a handler is a bug in the worker. The
    -- http2 library would only reset the stream, and buck2 would only say
    -- "see worker logs", so we write the exception to stderr before
    -- rethrowing it. An asynchronous exception isn't a bug. The server
    -- kills the handler when the connection closes, and a client may close
    -- it as soon as it has the response.
    server req aux respond = serve' req aux respond `catch` \e -> do
      case fromException e of
        Just (_ :: SomeAsyncException) -> pure ()
        Nothing -> hPutStrLn stderr ("buck2-ghc-worker: " ++ show (e :: SomeException))
      throwIO e
    serve' req _aux respond = do
      body <- readAll req
      case requestPath req of
        Just "/worker.Worker/Execute" -> do
          let cmd = decodeExecuteCommand (message body)
          (code, err) <- handler (ecArgv cmd)
          let payload = encodeExecuteResponse code err
              frame = BB.word8 0 <> BB.word32BE (fromIntegral (B.length payload)) <> BB.byteString payload
              rsp = responseBuilder H.status200 [("content-type", "application/grpc")] frame
          respond (setResponseTrailersMaker rsp trailers) []
        _ -> respond (responseNoBody H.status404 []) []
    -- http2 calls the trailers maker with each chunk of the response body,
    -- and then with Nothing, when it wants the trailers. The gRPC status is
    -- always OK (0): a failed compile is reported by the exit code in the
    -- response, not as a gRPC error.
    trailers (Just _) = pure (NextTrailersMaker trailers)
    trailers Nothing = pure (Trailers [("grpc-status", "0")])
    readAll req = go []
      where
        go acc = do
          chunk <- getRequestBodyChunk req
          if B.null chunk then pure (B.concat (reverse acc)) else go (chunk : acc)
    -- The message in a request's body. The body of a unary call holds
    -- exactly one message, after the 5-byte gRPC prefix. A body too short
    -- to have the prefix gives an empty message.
    message bs
      | B.length bs < 5 = B.empty
      | otherwise =
          let len = foldl (\a b -> (a `shiftL` 8) .|. fromIntegral b) (0 :: Int) (B.unpack (B.take 4 (B.drop 1 bs)))
           in B.take len (B.drop 5 bs)
