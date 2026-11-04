{-# LANGUAGE TemplateHaskell #-}
module MK.Bad (bad) where

import Language.Haskell.TH.Syntax (lift)

bad :: Int
bad = $(lift (1 :: Int))
