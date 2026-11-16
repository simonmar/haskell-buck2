{-# LANGUAGE TemplateHaskell #-}
module BT.UnusedSplice (spliced) where

import Language.Haskell.TH.Syntax (lift)

spliced :: Int
spliced = $(lift (6 :: Int))
