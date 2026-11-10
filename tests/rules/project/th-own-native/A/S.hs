{-# LANGUAGE TemplateHaskell #-}
module A.S (s) where

import A.C (value)
import Language.Haskell.TH.Syntax (lift, runIO)

s :: Int
s = $(runIO value >>= lift)
