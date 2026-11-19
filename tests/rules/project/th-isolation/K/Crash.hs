module K.Crash (crash) where

foreign import ccall "stdlib.h abort" c_abort :: IO ()

-- | Abort the process.
crash :: IO ()
crash = c_abort
