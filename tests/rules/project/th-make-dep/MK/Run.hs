{-# LANGUAGE TemplateHaskell #-}
module MK.Run (run) where

import Language.Haskell.TH.Syntax (lift)
import Q.Lib (q)

run :: Int
run = $(lift q)
