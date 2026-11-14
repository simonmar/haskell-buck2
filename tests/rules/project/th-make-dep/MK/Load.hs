{-# LANGUAGE TemplateHaskell #-}
module MK.Load (load) where

import Language.Haskell.TH.Syntax (lift)
import Q.Lib (q)

load :: Int
load = $(lift q)
