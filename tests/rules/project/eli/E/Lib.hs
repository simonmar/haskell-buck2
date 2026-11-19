{-# LANGUAGE ExplicitLevelImports, TemplateHaskell #-}
module E.Lib (e2) where

import A.Base (base)
import splice Language.Haskell.TH (integerL, litE)

e2 :: Int
e2 = $(litE (integerL 1)) + base
