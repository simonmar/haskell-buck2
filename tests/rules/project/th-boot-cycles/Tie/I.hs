{-# LANGUAGE TemplateHaskell #-}
module Tie.I (i) where

import Language.Haskell.TH.Syntax (lift)
import Tie.A (a)

i :: Int
i = a + $(lift (1 :: Int))
