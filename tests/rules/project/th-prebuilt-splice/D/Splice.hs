{-# LANGUAGE TemplateHaskell #-}
module D.Splice (d) where

import A.Base (base)
import Language.Haskell.TH (integerL, litE)

d :: Int
d = $(litE (integerL 7)) + base
