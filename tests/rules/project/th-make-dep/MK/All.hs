{-# LANGUAGE TemplateHaskell #-}
module MK.All (all') where

import Language.Haskell.TH.Syntax (lift)
import Q.Lib (q)

all' :: Int
all' = $(lift q)
