{-# LANGUAGE ExplicitLevelImports, TemplateHaskell #-}
module E.Gen (e1) where

import A.Base (base)
import splice TH.Gen (gen)

e1 :: Int
e1 = $(gen) + base
