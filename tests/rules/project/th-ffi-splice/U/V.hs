{-# LANGUAGE TemplateHaskell #-}
module U.V (v) where

import FFI.C (clValue)
import Language.Haskell.TH.Syntax (lift, runIO)

v :: Int
v = $(runIO clValue >>= lift)
