{-# LANGUAGE TemplateHaskell #-}
module U.S (s) where

import L.V (v)
import Language.Haskell.TH.Syntax (lift)

s :: Int
s = $(lift v)
