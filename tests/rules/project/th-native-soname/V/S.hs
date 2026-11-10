{-# LANGUAGE TemplateHaskell #-}
module V.S (s) where

import Language.Haskell.TH.Syntax (lift, runIO)
import V.C (verValue)

s :: Int
s = $(runIO verValue >>= lift)
