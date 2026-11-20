module SC.Lib (csValue) where

foreign import ccall "cs_value" csValue :: Int
