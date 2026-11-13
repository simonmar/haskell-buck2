{-# LANGUAGE CPP #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
-- | A gRPC server for buck2's local worker protocol, using only the packages
-- that come with GHC. It serves the unary call `/worker.Worker/Execute`
-- over HTTP/2, on the Unix socket that buck2 names in WORKER_SOCKET. See
-- Note [Just enough HTTP/2].
module Grpc (serve) where

import Control.Concurrent (ThreadId, forkIO, killThread)
import Control.Concurrent.MVar
import Control.Concurrent.STM
import Control.Exception (SomeAsyncException, SomeException, bracket, evaluate, finally, fromException, throwIO, try)
import Control.Monad (forM_, unless, void, when)
import Data.Bits (shiftL, shiftR, testBit, (.&.), (.|.))
import Data.ByteString (ByteString)
import qualified Data.ByteString as B
import qualified Data.ByteString.Builder as BB
import qualified Data.ByteString.Lazy as BL
import qualified Data.Map.Strict as M
import Data.Word (Word32, Word8)
#if !defined(darwin_HOST_OS)
import Data.Word (Word16)
#endif
import Foreign.C.Error (throwErrnoIfMinus1, throwErrnoIfMinus1Retry, throwErrnoIfMinus1_)
import Foreign.C.Types (CInt (..), CUInt (..))
import Foreign.Marshal.Alloc (allocaBytes)
import Foreign.Marshal.Array (pokeArray)
import Foreign.Marshal.Utils (copyBytes)
import Foreign.Ptr (Ptr, castPtr, nullPtr, plusPtr)
import Foreign.Storable (pokeByteOff)
import qualified GHC.Foreign as GHC
import GHC.IO.Encoding (getFileSystemEncoding)
import GHC.IO.Handle.FD (fdToHandle)
import System.IO (BufferMode (..), Handle, hClose, hFlush, hPutStrLn, hSetBinaryMode, hSetBuffering, stderr)
import System.IO.Error (isEOFError, isResourceVanishedError)
import System.Posix.IO (FdOption (CloseOnExec), setFdOption)
import System.Posix.Types (Fd (..))

import Proto

-- | Serve requests on the Unix socket at the given path. For each request,
-- the handler is given the argv of the command that buck2 asks the worker to
-- run, and returns the command's exit code and stderr. This never returns.
serve :: FilePath -> ([ByteString] -> IO (Int, ByteString)) -> IO ()
serve path handler = bracket (listenUnix path) (throwErrnoIfMinus1_ "close" . c_close) $ \sock -> do
  let loop = do
        conn <- closeOnExec =<< throwErrnoIfMinus1Retry "accept" (c_accept sock nullPtr nullPtr)
        void (forkIO (connection conn handler))
        loop
  loop

-- * The socket

foreign import ccall unsafe "socket" c_socket :: CInt -> CInt -> CInt -> IO CInt
foreign import ccall unsafe "bind" c_bind :: CInt -> Ptr () -> CUInt -> IO CInt
foreign import ccall unsafe "listen" c_listen :: CInt -> CInt -> IO CInt
-- accept blocks until a client connects, so it is a safe call, which runs
-- in an OS thread of its own.
foreign import ccall safe "accept" c_accept :: CInt -> Ptr () -> Ptr CUInt -> IO CInt
foreign import ccall unsafe "dup" c_dup :: CInt -> IO CInt
foreign import ccall unsafe "close" c_close :: CInt -> IO CInt

-- | Mark a file descriptor close-on-exec. The worker starts other programs,
-- such as the external interpreter of each session, and they shouldn't hold
-- the worker's sockets open.
closeOnExec :: CInt -> IO CInt
closeOnExec fd = setFdOption (Fd fd) CloseOnExec True >> pure fd

-- | A socket listening on the Unix socket at the given path. A Unix socket's
-- address (struct sockaddr_un) is its family and then its path, a C string
-- in the file system's encoding. On Linux the family takes 2 bytes. On
-- macOS a byte holding the address's length comes first, and then a byte of
-- family.
listenUnix :: FilePath -> IO CInt
listenUnix path = do
  sock <- closeOnExec =<< throwErrnoIfMinus1 "socket" (c_socket afUnix sockStream 0)
  enc <- getFileSystemEncoding
  allocaBytes addrSize $ \addr -> GHC.withCStringLen enc path $ \(cpath, len) -> do
    when (len >= addrSize - pathOffset) $ ioError (userError ("buck2-ghc-worker: socket path too long: " ++ path))
    pokeArray (addr `plusPtr` pathOffset) (replicate (addrSize - pathOffset) 0 :: [Word8])
#if defined(darwin_HOST_OS)
    pokeByteOff addr 0 (fromIntegral addrSize :: Word8)
    pokeByteOff addr 1 (fromIntegral afUnix :: Word8)
#else
    pokeByteOff addr 0 (fromIntegral afUnix :: Word16)
#endif
    copyBytes (addr `plusPtr` pathOffset) (castPtr cpath) len
    throwErrnoIfMinus1_ "bind" (c_bind sock addr (fromIntegral addrSize))
  throwErrnoIfMinus1_ "listen" (c_listen sock 64)
  pure sock
  where
    afUnix = 1
    sockStream = 1
    pathOffset = 2
#if defined(darwin_HOST_OS)
    addrSize = 106
#else
    addrSize = 110
#endif

-- * HTTP/2

-- | The state of one HTTP/2 connection.
data Conn = Conn
  { cOut :: Handle -- written only with cLock held
  , cLock :: MVar ()
  , cSendWindow :: TVar Int -- how much the client lets us send on the connection
  , cStreamWindows :: TVar (M.Map Word32 Int) -- how much the client lets us send on each open stream
  , cInitialWindow :: TVar Int -- a new stream's window, from the client's SETTINGS
  , cMaxFrame :: TVar Int -- the largest frame the client takes
  , cRequests :: TVar (M.Map Word32 ThreadId) -- the thread of each request that is still running
  }

-- | Serve one connection until the client closes it. Reads go through one
-- Handle and writes through another, on a duplicate of the socket, because
-- a Handle's lock is held for the whole of a blocking read. When the
-- connection ends, the requests still running on it are cancelled.
connection :: CInt -> ([ByteString] -> IO (Int, ByteString)) -> IO ()
connection fd handler = do
  inH <- fdToHandle fd
  outH <- fdToHandle =<< closeOnExec =<< throwErrnoIfMinus1 "dup" (c_dup fd)
  forM_ [inH, outH] $ \h -> hSetBinaryMode h True >> hSetBuffering h (BlockBuffering Nothing)
  conn <- Conn outH <$> newMVar () <*> newTVarIO 65535 <*> newTVarIO M.empty <*> newTVarIO 65535 <*> newTVarIO 16384 <*> newTVarIO M.empty
  r <- try $ do
    preface <- B.hGet inH 24
    unless (preface == "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n") $ ioError (userError "not an HTTP/2 connection")
    -- We send a SETTINGS frame that gives each new stream a large window,
    -- and raise the connection's window too, so that the client can send a
    -- request's body without waiting for us to return the window.
    send conn (frame 4 0 0 (BL.toStrict (BB.toLazyByteString (BB.word16BE 4 <> BB.word32BE bigWindow))) <> frame 8 0 0 (word32 (fromIntegral bigWindow - 65535)))
    readFrames inH conn handler M.empty
  -- The connection normally ends when buck2 closes it, which the reads see
  -- as the end of the input, or as an error if buck2 resets the socket.
  -- Anything else is a bug, or a client that doesn't speak HTTP/2.
  case r of
    Left (e :: SomeException)
      | Just io <- fromException e, isEOFError io || isResourceVanishedError io -> pure ()
      | otherwise -> hPutStrLn stderr ("buck2-ghc-worker: connection: " ++ show e)
    Right () -> pure ()
  readTVarIO (cRequests conn) >>= mapM_ (forkIO . killThread)
  hClose inH `finally` hClose outH
  where
    bigWindow = 2 ^ (30 :: Int) :: Word32

-- | Read frames until the connection ends. `bodies` holds the body read so
-- far of each stream whose request hasn't ended yet.
readFrames :: Handle -> Conn -> ([ByteString] -> IO (Int, ByteString)) -> M.Map Word32 ByteString -> IO ()
readFrames h conn handler bodies = do
  header <- B.hGet h 9
  unless (B.length header < 9) $ do
    let len = fromIntegral (be (B.take 3 header))
        typ = B.index header 3
        flags = B.index header 4
        sid = fromIntegral (be (B.drop 5 header)) .&. 0x7fffffff
        endStream = testBit flags 0
    payload <- B.hGet h len
    case typ of
      -- DATA: a piece of a request's body. Give the client back the window
      -- it used at once, and run the request when its body is complete.
      0 -> do
        when (len > 0) $ send conn (frame 8 0 0 (word32 len) <> frame 8 0 sid (word32 len))
        let body = M.findWithDefault B.empty sid bodies <> unpad flags payload
        if endStream
          then request conn handler sid body >> readFrames h conn handler (M.delete sid bodies)
          else readFrames h conn handler (M.insert sid body bodies)
      -- HEADERS: a new request. The worker only serves one method, so the
      -- headers aren't decoded (see Note [Just enough HTTP/2]).
      1 -> do
        atomically $ readTVar (cInitialWindow conn) >>= \w -> modifyTVar' (cStreamWindows conn) (M.insert sid w)
        readFrames h conn handler (M.insert sid B.empty bodies)
      -- RST_STREAM: the client gave up on a request, so cancel it. The
      -- request's thread is killed from a thread of its own, since
      -- killThread waits until the exception is delivered.
      3 -> do
        running <- atomically $ do
          modifyTVar' (cStreamWindows conn) (M.delete sid)
          M.lookup sid <$> readTVar (cRequests conn)
        mapM_ (forkIO . killThread) running
        readFrames h conn handler (M.delete sid bodies)
      -- SETTINGS: acknowledge them, and note the ones that limit what we send.
      4 | not (testBit flags 0) -> do
            forM_ (chunks 6 payload) $ \s -> case be (B.take 2 s) of
              4 -> atomically $ do
                let new = fromIntegral (be (B.drop 2 s))
                old <- readTVar (cInitialWindow conn)
                writeTVar (cInitialWindow conn) new
                modifyTVar' (cStreamWindows conn) (M.map (+ (new - old)))
              5 -> atomically $ writeTVar (cMaxFrame conn) (fromIntegral (be (B.drop 2 s)))
              _ -> pure ()
            send conn (frame 4 1 0 B.empty)
            readFrames h conn handler bodies
      -- PING: answer it.
      6 | not (testBit flags 0) -> send conn (frame 6 1 0 payload) >> readFrames h conn handler bodies
      -- GOAWAY: the client is done.
      7 -> pure ()
      -- WINDOW_UPDATE: the client lets us send more.
      8 -> do
        let inc = fromIntegral (be payload .&. 0x7fffffff)
        atomically $
          if sid == 0
            then modifyTVar' (cSendWindow conn) (+ inc)
            else modifyTVar' (cStreamWindows conn) (M.adjust (+ inc) sid)
        readFrames h conn handler bodies
      -- Anything else needs nothing from us: PRIORITY, the CONTINUATION of
      -- headers that we don't read, and acknowledgements.
      _ -> readFrames h conn handler bodies
  where
    unpad flags p
      | testBit flags 3, Just (n, rest) <- B.uncons p = B.take (B.length rest - fromIntegral n) rest
      | otherwise = p

-- | Run a request in a thread of its own, and send its response: headers,
-- the gRPC message, and trailers with the call's status. The status is
-- always OK, since a failed compile is reported by the exit code in the
-- response, not as a gRPC error.
--
-- If the handler throws an exception, which is a bug in the worker, the
-- exception goes to stderr and the stream is reset, so that buck2 reports
-- the action as failed. The response is evaluated fully before any of it is
-- sent, so that an exception hidden in it is caught here too. If the
-- request is cancelled, or the connection closes before the response is
-- ready, nothing is sent.
request :: Conn -> ([ByteString] -> IO (Int, ByteString)) -> Word32 -> ByteString -> IO ()
request conn handler sid body = do
  -- The thread waits until it is in cRequests, so that it can't finish
  -- before it is added, and a later RST_STREAM always finds it.
  registered <- newEmptyMVar
  tid <- forkIO $ (readMVar registered >> respond) `finally` atomically (do
    modifyTVar' (cStreamWindows conn) (M.delete sid)
    modifyTVar' (cRequests conn) (M.delete sid))
  atomically (modifyTVar' (cRequests conn) (M.insert sid tid))
  putMVar registered ()
  where
    respond = do
      r <- trySync $ do
        (code, err) <- handler (ecArgv (decodeExecuteCommand (message body)))
        let msg = encodeExecuteResponse code err
        evaluate (BL.toStrict (BB.toLazyByteString (BB.word8 0 <> BB.word32BE (fromIntegral (B.length msg)) <> BB.byteString msg)))
      void . trySync $ case r of
        Left e -> do
          hPutStrLn stderr ("buck2-ghc-worker: " ++ show e)
          send conn (frame 3 0 sid (word32 2))
        Right grpcMessage -> do
          send conn (frame 1 4 sid responseHeaders)
          open <- sendData conn sid grpcMessage
          when open $ send conn (frame 1 5 sid trailers)
    -- The body of a unary call holds one message, after gRPC's prefix: a
    -- byte saying whether it's compressed, and its length in 4 bytes.
    message bs = B.take (fromIntegral (be (B.take 4 (B.drop 1 bs)))) (B.drop 5 bs)
    -- Catch the exceptions that the request's own code throws, but not the
    -- one that cancels the request.
    trySync :: IO a -> IO (Either SomeException a)
    trySync act = try act >>= \case
      Left e | Just (_ :: SomeAsyncException) <- fromException e -> throwIO e
      other -> pure other

-- | Send a response's message as DATA frames, each no larger than the
-- client allows or than its windows have room for. It returns False if the
-- client reset the stream before the message was all sent.
sendData :: Conn -> Word32 -> ByteString -> IO Bool
sendData conn sid bs
  | B.null bs = pure True
  | otherwise = do
      n <- atomically $ do
        stream <- M.lookup sid <$> readTVar (cStreamWindows conn)
        case stream of
          Nothing -> pure 0
          Just sw -> do
            conw <- readTVar (cSendWindow conn)
            maxFrame <- readTVar (cMaxFrame conn)
            let n = minimum [conw, sw, maxFrame, B.length bs]
            check (n > 0)
            writeTVar (cSendWindow conn) (conw - n)
            modifyTVar' (cStreamWindows conn) (M.adjust (subtract n) sid)
            pure n
      if n == 0
        then pure False
        else send conn (frame 0 0 sid (B.take n bs)) >> sendData conn sid (B.drop n bs)

-- | The response's headers, ":status: 200" and "content-type:
-- application/grpc", and its trailers, "grpc-status: 0", in HPACK.
-- ":status: 200" is an entry of HPACK's static table. The others are
-- literals that the client isn't asked to add to its table (see Note [Just
-- enough HTTP/2]).
responseHeaders, trailers :: ByteString
responseHeaders = B.pack [0x88, 0x0f, 0x10, 16] <> "application/grpc"
trailers = B.pack [0x00, 11] <> "grpc-status" <> B.pack [1] <> "0"

-- | Write some frames, whole, and flush them.
send :: Conn -> BB.Builder -> IO ()
send conn b = withMVar (cLock conn) $ \_ -> BB.hPutBuilder (cOut conn) b >> hFlush (cOut conn)

-- | A frame: its 9-byte header (length, type, flags and stream), then its
-- payload.
frame :: Word8 -> Word8 -> Word32 -> ByteString -> BB.Builder
frame typ flags sid payload =
  BB.word8 (fromIntegral (len `shiftR` 16)) <> BB.word16BE (fromIntegral len) <> BB.word8 typ <> BB.word8 flags <> BB.word32BE sid <> BB.byteString payload
  where
    len = B.length payload

word32 :: Int -> ByteString
word32 = BL.toStrict . BB.toLazyByteString . BB.word32BE . fromIntegral

-- | A big-endian number.
be :: ByteString -> Word32
be = B.foldl' (\a b -> (a `shiftL` 8) .|. fromIntegral b) 0

chunks :: Int -> ByteString -> [ByteString]
chunks n bs = if B.length bs < n then [] else B.take n bs : chunks n (B.drop n bs)

{- Note [Just enough HTTP/2]

buck2 talks to its local workers with gRPC, over HTTP/2 on a Unix socket.
This module implements only as much of HTTP/2 (RFC 9113) as a server of one
unary method needs, so that the worker depends on no package beyond those
that come with GHC.

- Headers aren't read. A request's HEADERS frame, and any CONTINUATION
  frames, only say which method is called. The worker serves only Execute,
  so it takes every request to be one. HPACK, the headers' compression,
  keeps a table on each side that each header block may change. Since this
  server never decodes a block, it needn't keep the client's table. Its own
  blocks use HPACK's static table and literals that it doesn't ask the
  client to add to the client's table, so neither side's table changes.
- Flow control: the server gives each new stream and the connection a large
  window, and gives the client back the window that a request's body used
  as soon as it arrives, so the client doesn't wait to send. When the server
  sends a response, it waits for the client's windows (sendData).
- The server handles only the frames that a unary call needs: one HEADERS
  and some DATA in, then HEADERS, DATA and trailers out. It cancels a
  request when the client resets its stream or closes the connection.
  PRIORITY is ignored, and the server never pushes.
-}
