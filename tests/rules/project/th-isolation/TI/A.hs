{-# LANGUAGE TemplateHaskell #-}
module TI.A (a) where

import G.State (next)
import Language.Haskell.TH.Syntax (lift, runIO)

a :: Int
a = $(runIO next >>= lift)
