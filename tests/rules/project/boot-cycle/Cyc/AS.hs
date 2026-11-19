{-# LANGUAGE TemplateHaskell #-}
module Cyc.AS (s) where

import Cyc.A (A (..))
import Language.Haskell.TH.Syntax (lift)

s :: (A, Int)
s = (A, $(lift (1 :: Int)))
