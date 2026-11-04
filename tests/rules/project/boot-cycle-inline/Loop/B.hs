{-# LANGUAGE TemplateHaskell #-}
module Loop.B (b) where

import Control.Concurrent (threadDelay)
import Language.Haskell.TH.Syntax (runIO)
import qualified Loop.A as A

b :: Int
b = A.a + $(runIO (threadDelay 5000000) >> [| 1 |])
