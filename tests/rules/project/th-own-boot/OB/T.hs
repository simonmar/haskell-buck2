{-# LANGUAGE TemplateHaskell #-}
module OB.T (t) where

import Language.Haskell.TH.Syntax (lift)
import OB.A (a)

t :: Int
t = $(lift a)
