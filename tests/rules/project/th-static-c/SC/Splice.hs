{-# LANGUAGE TemplateHaskell #-}
module SC.Splice (one) where

import Language.Haskell.TH (integerL, litE)

one :: Int
one = $(litE (integerL 1))
