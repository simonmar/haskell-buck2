module FFI.W (wValue) where

import FFI.C (clValue)

wValue :: IO Int
wValue = clValue
