module V.C (verValue) where

foreign import ccall unsafe "ver_value" verValue :: IO Int
