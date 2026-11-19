{-# LANGUAGE TemplateHaskell #-}
module TI.B (b) where

import G.State (next)
import Language.Haskell.TH.Syntax (lift, runIO)

b :: Int
b = $(runIO next >>= lift)
