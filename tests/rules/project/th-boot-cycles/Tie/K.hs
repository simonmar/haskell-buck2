{-# LANGUAGE TemplateHaskell #-}
module Tie.K (k) where

import Language.Haskell.TH.Syntax (lift)
import Tie.B (b)

k :: Int
k = b + $(lift (1 :: Int))
