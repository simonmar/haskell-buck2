{-# LANGUAGE TemplateHaskell #-}
module Tie.AZ (z) where

import Language.Haskell.TH.Syntax (lift)
import Tie.V (v)

z :: Int
z = v + $(lift (1 :: Int))
