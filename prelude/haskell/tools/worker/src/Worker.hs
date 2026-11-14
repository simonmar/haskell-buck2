-- | The worker's sessions. The worker keeps a GHC session for each set of
-- session flags, compiles each request in the session for its flags, and
-- decides when to drop sessions. See Note [How the worker works].
module Worker (Worker, withWorker, compileRequest, shutdown) where

import Control.Concurrent (forkIO, getNumCapabilities)
import Control.Concurrent.MVar
import Control.Exception (SomeAsyncException, SomeException, finally, fromException, mask, mask_, throwIO, try, uninterruptibleMask_)
import Control.Monad (when)
import Data.IORef
import Data.List (partition, sortOn)
import qualified Data.Map as M
import Data.Maybe (isJust)
import qualified Data.Set as Set
import Foreign.C.Types (CInt (..))
import System.Environment (lookupEnv)
import System.IO (hPutStrLn, stderr)
import System.Process (readProcess)
import Text.Read (readMaybe)

import GHC (getSession, runGhc)
import GHC.Driver.Env (hsc_NC)
import GHC.Types.Name.Cache (NameCache)
import GHC.Clock (getMonotonicTime)
import GHC.Stats (RTSStats (..), getRTSStats, getRTSStatsEnabled)
import GHC.Types.SourceError (SourceError)
import GHC.Unit.Finder.Types (FinderCache)
import Control.Monad.IO.Class (liftIO)

import Compat (sharedFileHashes)
import Request
import Session

-- | The state of the worker. It holds the worker's sessions, one for each
-- set of session flags (see Note [How the worker works]). A session is made
-- when the first request with its flags arrives. It keeps the interfaces it
-- has read until the worker drops it (see Note [Dropping the idle
-- sessions]).
data Worker = Worker
  { wCompiler :: String -- the GHC that the requests name
  , wLibdir :: FilePath
  , wSessions :: MVar (M.Map [String] Entry) -- the sessions, keyed by their session flags
  , wMaxSessions :: Int -- how many sessions to keep, counting those in use and those idle (BUCK2_GHC_WORKER_SESSIONS)
  , wCompiled :: MVar (M.Map FilePath (Set.Set Node)) -- for each target not yet finished, keyed by its output directory, the modules compiled so far
  , wVerbose :: Bool -- whether to log each compile and each session made or dropped (BUCK2_GHC_WORKER_VERBOSE)
  , wFiles :: FinderCache -- holds the file hashes that the sessions share (see Note [Hashing the libraries] in Session)
  , wNames :: NameCache -- the name cache that the sessions share (see Note [One name cache for all the sessions] in Session)
  , wShared :: Shared -- everything else that the sessions share
  , wMode :: SessionMode -- how the sessions compile (BUCK2_GHC_WORKER_SESSION_MODE)
  }

-- | A session in the worker's map, and how it is being used. The session
-- may have been made, may still be being made, or may have failed.
data Entry = Entry
  { eSession :: MVar (Either SomeException GhcSession) -- empty while the session is being made
  , eInFlight :: Int -- the number of requests using the session
  , eLastDone :: Double -- when the session's last compile finished
  , eFinished :: Bool -- whether all the modules of the session's target have been compiled
  }

-- | Start the worker for the GHC that the first request names, and run the
-- given action with it. While the action runs, GHC's signal handlers are
-- installed, so buck2's SIGTERM arrives as a 'Signal' exception.
withWorker :: Request -> (Worker -> IO a) -> IO a
withWorker first k = do
  libdir <- trim <$> readProcess (reqCompiler first) ["--print-libdir"] ""
  sessions <- newMVar M.empty
  verbose <- isJust <$> lookupEnv "BUCK2_GHC_WORKER_VERBOSE"
  maxSessions <- maybe getNumCapabilities pure . (>>= readMaybe) =<< lookupEnv "BUCK2_GHC_WORKER_SESSIONS"
  compiled <- newMVar M.empty
  files <- sharedFileHashes
  shared <- newShared
  mode <- lookupEnv "BUCK2_GHC_WORKER_SESSION_MODE" >>= \m -> case m of
    Nothing -> pure AutoSessions
    Just "auto" -> pure AutoSessions
    Just "make" -> pure MakeSessions
    Just "one-shot" -> pure OneShotSessions
    Just other -> fail ("buck2-ghc-worker: BUCK2_GHC_WORKER_SESSION_MODE is " ++ other ++ ", not auto, make or one-shot")
  -- See Note [Starting the object linker once].
  initLinker 1
  -- The session that `runGhc` makes is never used to compile anything. It
  -- is there for two things: GHC's signal handlers, which turn SIGTERM into
  -- a 'Signal' exception, and its name cache, which all the sessions share
  -- (see Note [One name cache for all the sessions] in Session). The
  -- sessions that compile are made on demand, by withSession.
  runGhc (Just libdir) $ do
    names <- hsc_NC <$> getSession
    liftIO (k (Worker (reqCompiler first) libdir sessions maxSessions compiled verbose files names shared mode))
  where
    trim = reverse . dropWhile (`elem` "\r\n") . reverse

-- | Start the runtime's object linker (see Note [Starting the object linker
-- once]). A non-zero argument makes the linker keep the CAFs of the code it
-- loads, which is what GHC's interpreter asks for.
foreign import ccall unsafe "initLinker_" initLinker :: CInt -> IO ()

-- | Remove sessions from the map. Every idle session of a finished target is
-- removed. Then, while there are still more sessions than 'wMaxSessions',
-- the least recently used of the other idle sessions is removed. It returns
-- the map that is left, and the removed sessions, which the caller must end.
-- See Note [Dropping the idle sessions].
dropIdle :: Worker -> M.Map [String] Entry -> (M.Map [String] Entry, [Entry])
dropIdle w m = (foldr M.delete m (map fst gone), map snd gone)
  where
    (finished, idle) = partition (eFinished . snd) (sortOn (eLastDone . snd) (M.toList (M.filter ((== 0) . eInFlight) m)))
    gone = finished ++ take (M.size m - length finished - wMaxSessions w) idle

-- | Record that the session has compiled a module of its target. Once every
-- module of the target has been compiled, mark all the target's sessions
-- finished, so that they are dropped when idle, and forget the modules
-- counted so far, so that the count starts again if the target is built
-- again. A target whose dependency analysis failed is never finished, since
-- there is no list of its modules to count against.
compiledIn :: Worker -> GhcSession -> Node -> IO ()
compiledIn w s n = mask_ $ do
  let target = gsOutDir s
  finished <- modifyMVar (wCompiled w) $ \m -> do
    let done = Set.insert n (M.findWithDefault Set.empty target m)
    pure $ case gsModules s of
      Just modules | modules `Set.isSubsetOf` done -> (M.delete target m, True)
      _ -> (M.insert target done m, False)
  when finished $ do
    uninterruptibleMask_ $ modifyMVar_ (wSessions w) $ traverse $ \e -> do
      made <- tryReadMVar (eSession e)
      pure $ case made of
        Just (Right s') | gsOutDir s' == target -> e{eFinished = True}
        _ -> e
    when (wVerbose w) $ hPutStrLn stderr ("buck2-ghc-worker: " ++ target ++ " finished")

-- | End the dropped sessions in a thread of their own, so that the request
-- that dropped them can be answered without waiting for the sessions'
-- external interpreters to stop. If a session can't be ended, the error is
-- logged and the session's temporary files are left behind. The second
-- argument is the number of sessions left, for the log.
endDropped :: Worker -> Int -> [Entry] -> IO ()
endDropped _ _ [] = pure ()
endDropped w left gone = do
  _ <- forkIO $ mapM_ (\e -> tryNonAsync (endEntry e) >>= either (\err -> hPutStrLn stderr ("buck2-ghc-worker: ending a session: " ++ show err)) pure) gone
  -- Don't run a major GC to reclaim the dropped sessions' memory now. Once
  -- the worker has loaded libraries for Template Haskell, every major GC
  -- checks each static closure against those libraries, which is slow, and
  -- a shared worker drops sessions all the time.
  when (wVerbose w) $ hPutStrLn stderr ("buck2-ghc-worker: " ++ show (length gone) ++ " idle sessions dropped, " ++ show left ++ " left")

-- | End the entry's session, if it was made successfully.
endEntry :: Entry -> IO ()
endEntry e = tryReadMVar (eSession e) >>= mapM_ (either (const (pure ())) endSession)

-- | End every session, before the worker exits. In verbose mode, also log
-- the worker's peak memory, its largest live heap, the time it spent
-- collecting garbage, and the CPU time of its mutator and of its
-- collections, if the RTS collects these statistics (+RTS -T).
shutdown :: Worker -> IO ()
shutdown w = do
  readMVar (wSessions w) >>= mapM_ endEntry . M.elems
  enabled <- getRTSStatsEnabled
  when (wVerbose w && enabled) $ do
    stats <- getRTSStats
    hPutStrLn stderr ("buck2-ghc-worker: peak memory " ++ show (max_mem_in_use_bytes stats `div` 2 ^ (20 :: Int)) ++ " MB, max live " ++ show (max_live_bytes stats `div` 2 ^ (20 :: Int)) ++ " MB, GC " ++ show (gc_elapsed_ns stats `div` 10 ^ (6 :: Int)) ++ " ms")
    hPutStrLn stderr ("buck2-ghc-worker: CPU mutator " ++ show (mutator_cpu_ns stats `div` 10 ^ (6 :: Int)) ++ " ms, GC " ++ show (gc_cpu_ns stats `div` 10 ^ (6 :: Int)) ++ " ms")

-- | Run an action in the session for the request's session flags, making
-- the session first if there is none yet. If the session can't be made,
-- this request fails with the reason, and so do the requests that were
-- waiting for the session. The next request with the same flags tries to
-- make it again. If the request that is making the session is cancelled
-- instead, one of the waiting requests makes it again, and the others wait
-- for that one.
withSession :: Worker -> Request -> (GhcSession -> IO a) -> IO a
withSession w r k = mask $ \restore -> do
  let flags = sessionFlags r
  -- Asynchronous exceptions are masked here, except while the session is
  -- being made and while it is used. If a request were cancelled anywhere
  -- else, it could leave its entry's session never filled in, so that the
  -- requests waiting for the session would block for ever. Or it could
  -- leave the entry's count of requests in flight too high, so that the
  -- session would never be dropped.
  (var, fresh) <- modifyMVar (wSessions w) $ \m -> case M.lookup flags m of
    Just e -> pure (M.insert flags e{eInFlight = eInFlight e + 1} m, (eSession e, False))
    Nothing -> do
      v <- newEmptyMVar
      pure (M.insert flags (Entry v 1 0 False) m, (v, True))
  -- `ours f` applies f to the entry that this request counted itself in, if
  -- that entry is still in the map. It may not be. If making the session
  -- failed, the request that was making it removed the entry, and another
  -- request may since have added a new entry for the same flags. (The waits
  -- for the lock below are uninterruptible, since the lock is only held
  -- briefly.)
  let ours f = M.update (\e -> Just (if eSession e == var then f e else e)) flags
      -- `done` counts the request out of its session, and drops idle
      -- sessions. It does both while holding the lock on the sessions. A
      -- request also holds that lock while it counts itself in, so no
      -- request can be using a session that is dropped here.
      done = do
        t <- getMonotonicTime
        (left, gone) <- uninterruptibleMask_ $ modifyMVar (wSessions w) $ \m -> do
          let (m', gone) = dropIdle w (ours (\e -> e{eInFlight = eInFlight e - 1, eLastDone = t}) m)
          pure (m', (M.size m', gone))
        endDropped w left gone
  (`finally` done) $ do
    when fresh $ do
      t0 <- getMonotonicTime
      made <- try (restore (newSession (wLibdir w) (wFiles w) (wNames w) (wShared w) (wMode w) r))
      t1 <- getMonotonicTime
      -- If making the session failed, remove its entry before the waiting
      -- requests see the failure. Then a waiting request that makes the
      -- session again, or the next request with these flags, makes a new
      -- entry rather than finding the failed one.
      case made of
        Left _ -> uninterruptibleMask_ (modifyMVar_ (wSessions w) (pure . M.filter ((/= var) . eSession)))
        Right _ -> pure ()
      putMVar var made
      when (wVerbose w) $ hPutStrLn stderr ("buck2-ghc-worker: a " ++ either (const "") (\s -> if gsOneShot s then "one-shot " else "--make ") made ++ "session for the flags of " ++ reqModPath r ++ " in " ++ show (round ((t1 - t0) * 1000) :: Int) ++ "ms")
      either (\e -> when (isAsync e) (throwIO e)) (const (pure ())) made
    made <- readMVar var
    case made of
      -- The request that was making the session was cancelled. That isn't
      -- a failure of this request, so start again, which makes the session
      -- unless another waiting request has already started to.
      Left e | isAsync e, not fresh -> restore (withSession w r k)
      _ -> either throwIO (restore . k) made
  where
    isAsync e = isJust (fromException e :: Maybe SomeAsyncException)

-- | Compile the request's module in the session for its session flags. It
-- returns the exit code for buck2, and the compile's diagnostics as text. A
-- request that names a different GHC from the worker's fails with exit code
-- 2.
compileRequest :: Worker -> Request -> IO (Int, String)
compileRequest w r
  | reqCompiler r /= wCompiler w =
      pure (2, "buck2-ghc-worker: this worker runs " ++ wCompiler w ++ ", the request names " ++ reqCompiler r ++ "\n")
  | otherwise = do
      diagnostics <- newIORef []
      t0 <- getMonotonicTime
      result <- tryNonAsync (withSession w r (\s -> compile s (\d -> modifyIORef' diagnostics (d :)) r >>= compiledIn w s))
      t1 <- getMonotonicTime
      ds <- reverse <$> readIORef diagnostics
      when (wVerbose w) $ hPutStrLn stderr ("buck2-ghc-worker: " ++ reqModPath r ++ " " ++ show (round ((t1 - t0) * 1000) :: Int) ++ "ms")
      let text = map diagText ds
      pure $ withSpliceHint r $ case result of
        Right () | not (any diagIsError ds) -> (0, unlines text)
        Right () -> (1, unlines text)
        -- compileOne throws a compile's errors as a SourceError rather than
        -- logging them. (In --make mode, GHC's driver catches and logs them
        -- after the compile.) The errors from summarising the source arrive
        -- the same way.
        Left e -> case fromException e :: Maybe SourceError of
          Just se -> (1, unlines (text ++ [show se]))
          -- Other failures, such as a splice that couldn't load the code
          -- it runs, come with no location, so they get the source's, as
          -- GHC's errors have.
          Nothing -> (1, unlines (text ++ [reqSource r ++ ": error:"] ++ map ("    " ++) (lines (dropWhile (== '\n') (show e)))))

{- Note [How the worker works]

buck2 starts the worker as a persistent worker (see Note [The persistent
worker] in compile_per_module.bzl). It sends the worker each module's
compile action as a request, which holds the action's arguments, over gRPC
on a Unix socket. The worker compiles the requests concurrently, each in
the thread that received it, and answers each one with the compile's exit
code and diagnostics. One worker serves many targets.

Terms

- Request: one module to compile (see Request). When buck2 runs the action
  without the worker, the compile tool
  (prelude/haskell/tools/ghc-api/PerModuleCompile.hs) takes the same
  request.
- Session flags: the flags of a request that are the same for all the
  modules of its target. A target that is built in several ways (static,
  shared, profiled) has a different set of session flags for each way.
- Session: a GHC session for one set of session flags. It keeps the
  interfaces it has read. The worker makes a session when the first
  request with its flags arrives, and drops it when it is no longer needed.
- Home modules: the modules of the session's target. In a --make session,
  each compile gets a home package table of its own (see Note [Each
  compile's home modules] in Session).
- Boot interface: the interface of a module's .hs-boot file. A
  {-# SOURCE #-} import of the module sees the boot interface instead of
  the module itself.

The modules

- Main: the process. It starts the worker when the first request arrives,
  and exits on buck2's SIGTERM, or when buck2 has gone away.
- Grpc and Proto: buck2's worker protocol.
- Request: a request's arguments, and the flags of its session.
- Worker: the sessions, and when to drop them (see Note [Dropping the idle
  sessions]).
- Session: compiling a request in a session (see Note [The session's
  state], and the Notes after it).
- DepFile: writing the .abi file and the dep file that the rules need as
  well as GHC's own outputs.
- Compat: the parts of the GHC API that differ between the GHC versions
  that the worker can be built with.
-}

{- Note [Starting the object linker once]

1. The problem

The runtime has one object linker per process. Each session's interpreter
starts the linker the first time it runs code, by calling initLinker_.
That function is meant to be safe to call more than once. But it records
whether it has already run in a flag that it neither locks nor sets
atomically. So if two sessions ran their first splices at the same time,
both would fill the linker's symbol table, the chains in the table's hash
buckets would form loops, and both compiles would hang. (GHC's --make never
hits this, because it has only one interpreter, which starts the linker
once.)

2. The solution

The worker starts the linker itself when the worker starts, before any
session can. When a session's interpreter calls initLinker_ later, the
flag is already set, and the call does nothing.
-}

{- Note [Dropping the idle sessions]

1. The problem

A --make session keeps every interface it has read, which can be a few
hundred MB for a large package. (A one-shot session keeps little of its
own, since the interfaces it reads go into state that all the one-shot
sessions share; see Note [One-shot sessions] in Session.) buck2 keeps the
worker until the end of the build, and one worker serves many targets (see
Note [The persistent worker] in compile_per_module.bzl). If the worker kept
every session, a clean build of a large project would use more memory than
the machine has.

So the worker has to drop sessions. But dropping a session that is still
needed costs time. The next request with its flags makes the session again,
which means analysing the target's sources and reading its imports from
disk again. And a session is often idle while it is still needed. buck2
starts each module as soon as its imports are compiled, so many targets are
part-built at once. Each of them is waiting for a slow module, either one
of its own or one of a dependency's, and there are more such targets than
compiles running at once (-j).

2. The solution

After each compile, the worker:

  - drops the idle sessions of every finished target (see 3); and
  - while it has more sessions, in use or idle, than its limit, drops the
    least recently used idle session. The limit is BUCK2_GHC_WORKER_SESSIONS,
    which the rules set from the buckconfig. If that isn't set, the limit
    is the number of capabilities.

The limit bounds the memory, as cabal's -j does by bounding the number of
ghc --make processes. Defaulting to the number of capabilities scales the
limit with the machine, as buck2's default -j does. buck2's -j bounds the
number of sessions in use, so a limit of at least -j leaves room for some
idle sessions too. A limit below -j never stops a compile from running,
since the worker only drops idle sessions, but it can make the worker drop
a session as soon as its compile is done.

3. Finished targets

Each way that a target is built in (static, shared, profiled) is compiled
separately, into an output directory of its own, though with the same unit
id. So here a target means a target built in one way, and the worker
recognises a target's sessions by their output directory. A target is
finished once the worker has compiled every module and boot interface that
GHC's analysis of the target found. The compiles count whichever of the
target's sessions they ran in, since the worker may have dropped the
target's session and made it again.

A target that is only partly built never finishes, and its sessions are
only dropped because of the limit. That happens when a single module is
requested on its own, when a build needs only some of a target's modules,
in an incremental build, and when a module fails to compile. It also
happens when GHC's analysis of the target fails (because a module's imports
don't parse, for example), since that leaves no list of modules to count
against. If a target is requested again after it has finished, its session
is simply made again. That costs time, but never compiles anything wrongly.

4. Measurements

These are the results on the bench's `project` workload (bench/Main.hs),
where all 30 targets are part-built at once, at -j8, with limits
(BUCK2_GHC_WORKER_SESSIONS) of 4, 16 and 32. The command was
`cabal bench --benchmark-options='8 3 project'`.

  limit   one-shot sessions                    --make sessions
          made     wall         peak         made     wall         peak
  4       120-124  21.8-24.7s   5.1-5.2 GB   120-122  38.0-44.6s   2.4-2.5 GB
  16      93-95    22.2-24.7s   5.2 GB       91-93    32.9-40.3s   5.1-5.5 GB
  32      30       23.1-25.2s   5.2 GB       30       22.5-23.1s   5.2 GB

So with one-shot sessions the limit matters little, and with --make
sessions it trades memory for speed.

5. The alternatives

  - Dropping sessions after a timeout doesn't bound the memory. With a
    timeout of thirty seconds, for example, the worker holds on to the
    sessions of every target finished in the last half minute, however
    many there are.
  - Dropping sessions above a memory threshold would overshoot. The RTS
    only knows the size of the live heap after a major GC, and a dropped
    session's memory only comes back at the next major GC.
  - Exiting the worker doesn't work. buck2 keeps the worker it started
    until the build is done. Once the worker has exited, buck2 fails each
    action it sends to it, rather than starting another worker.
  - Keeping just the sessions that have requests still to come isn't
    possible, because the worker can't see those requests. buck2 only sends
    an action when it runs it. The worker could guess, from the targets
    that have a module whose imports are all compiled. But when many
    targets advance in turn, all of them have such a module, and some
    sessions must be dropped all the same.

After the worker drops sessions, the memory that the process still holds
is the RTS's own. It is the allocation area, which the RTS never gives back
(hence the small default -A in the cabal file), and the part of the heap's
peak that the RTS keeps.
-}
