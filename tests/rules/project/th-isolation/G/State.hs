module G.State (next) where

import Data.IORef (IORef, atomicModifyIORef', newIORef)
import System.IO.Unsafe (unsafePerformIO)

counter :: IORef Int
counter = unsafePerformIO (newIORef 0)
{-# NOINLINE counter #-}

-- | The number of calls of next so far, this one included.
next :: IO Int
next = atomicModifyIORef' counter (\n -> (n + 1, n + 1))
