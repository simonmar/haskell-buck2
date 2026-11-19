{-# LANGUAGE TemplateHaskell #-}
module MK.MissAfter (missAfter) where

import Language.Haskell.TH.Syntax (lift)
import MK.Load (load)
import Q.Lib (q)

missAfter :: Int
missAfter = load + $(lift q)
