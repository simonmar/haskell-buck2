module B.C (value) where

foreign import ccall unsafe "b_value" value :: IO Int
