{-# LANGUAGE CPP #-}
module L.V (v) where

v :: Int
#ifdef EXEC
v = 4
#else
v = 3
#endif
