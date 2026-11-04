{-# LANGUAGE TemplateHaskell #-}
module U.W (w) where

import FFI.W (wValue)
import Language.Haskell.TH.Syntax (lift, runIO)

w :: Int
w = $(runIO wValue >>= lift)
