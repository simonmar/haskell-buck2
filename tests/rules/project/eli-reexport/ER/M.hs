{-# LANGUAGE ExplicitLevelImports, TemplateHaskell #-}
module ER.M (m) where

import splice A.Base (base)
import splice Language.Haskell.TH.Syntax (lift)

m :: Int
m = $(lift base)
