{-# LANGUAGE TemplateHaskell #-}
module MK.Lit (lit) where

import Language.Haskell.TH.Syntax (lift)
import Q.Lib (q)

lit :: Int
lit = q + $(lift (1 :: Int))
