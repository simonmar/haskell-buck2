module FFI.C (clValue) where

foreign import ccall unsafe "cl_value" clValue :: IO Int
