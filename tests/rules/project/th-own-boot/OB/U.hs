{-# LANGUAGE TemplateHaskell #-}
module OB.U (u) where

import Language.Haskell.TH.Syntax (lift)
import OB.A (a)
import OB.C (c)

u :: Int
u = $(lift a) + c
