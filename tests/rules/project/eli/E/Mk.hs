{-# LANGUAGE ExplicitLevelImports, TemplateHaskell #-}
module E.Mk (e3) where

import splice Language.Haskell.TH.Syntax (lift)
import splice Q.Lib (q)

e3 :: Int
e3 = $(lift q)
