{-# LANGUAGE TemplateHaskell, ExplicitLevelImports, ImplicitStagePersistence #-}
module P.Persist (p) where

import TH.Gen (gen)

p :: Int
p = $(gen)
