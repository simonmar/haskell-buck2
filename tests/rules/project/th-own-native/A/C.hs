module A.C (value) where

foreign import ccall unsafe "a_value" value :: IO Int
