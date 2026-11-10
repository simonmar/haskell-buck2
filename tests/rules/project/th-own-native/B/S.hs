{-# LANGUAGE TemplateHaskell #-}
module B.S (s) where

import B.C (value)
import Language.Haskell.TH.Syntax (lift, runIO)

s :: Int
s = $(runIO value >>= lift)
