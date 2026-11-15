{-# LANGUAGE TemplateHaskell #-}
module BT.OwnSplice (spliced) where

spliced :: Int
spliced = $([| 3 |])
