{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
-- | A gRPC server for buck2's local worker protocol: the unary
-- `/worker.Worker/Execute` call over HTTP/2 on the Unix socket buck2 names in
-- WORKER_SOCKET. gRPC framing is a 1-byte compression flag and a 4-byte
-- big-endian length before each message, and the status goes in the HTTP/2
-- trailers.
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

-- | Serve requests on the socket. The handler gets the command's argv, and
-- returns the exit code and stderr. Never returns.
serve :: FilePath -> ([ByteString] -> IO (Int, ByteString)) -> IO ()
serve path handler = withSocketsDo $ bracket open close $ \sock -> do
  listen sock 64
  forever $ do
    (conn, _) <- accept sock
    -- http2's timeout manager (30 seconds by default) kills a connection
    -- that receives nothing for that long, and a request's handler that
    -- neither reads nor writes for that long. But buck2 keeps one
    -- connection for the whole build, which is quiet while it runs other
    -- actions, and a handler writes nothing while it compiles. So we set a
    -- day, which in effect is no timeout.
    conf <- allocSimpleConfig' conn 32768 (24 * 3600 * 1000000)
    -- A connection ends when buck2 closes it, which `run` reports as an
    -- exception.
    void $ forkIO ((run defaultServerConfig conf server `catch` \(_ :: SomeException) -> pure ()) `finally` (freeSimpleConfig conf >> close conn))
  where
    open = do
      s <- socket AF_UNIX Stream defaultProtocol
      bind s (SockAddrUnix path)
      pure s
    -- An exception here is a bug. It would only reset the stream, and buck2
    -- would just report "see worker logs", so we log it. An asynchronous
    -- exception isn't a bug: the server kills the handler when the
    -- connection closes, which a client may do as soon as it has the
    -- response.
    server req aux respond = serve' req aux respond `catch` \e -> do
      case fromException e of
        Just (_ :: SomeAsyncException) -> pure ()
        Nothing -> hPutStrLn stderr ("ghc-worker: " ++ show (e :: SomeException))
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
    -- Called per body chunk, then once more at the end.
    trailers (Just _) = pure (NextTrailersMaker trailers)
    trailers Nothing = pure (Trailers [("grpc-status", "0")])
    readAll req = go []
      where
        go acc = do
          chunk <- getRequestBodyChunk req
          if B.null chunk then pure (B.concat (reverse acc)) else go (chunk : acc)
    -- The first (and only) message of the body.
    message bs
      | B.length bs < 5 = B.empty
      | otherwise =
          let len = foldl (\a b -> (a `shiftL` 8) .|. fromIntegral b) (0 :: Int) (B.unpack (B.take 4 (B.drop 1 bs)))
           in B.take len (B.drop 5 bs)
