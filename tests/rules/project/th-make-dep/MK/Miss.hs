{-# LANGUAGE TemplateHaskell #-}
module MK.Miss (miss) where

import Language.Haskell.TH.Syntax (lift)
import Q.Lib (q)

miss :: Int
miss = $(lift q)
