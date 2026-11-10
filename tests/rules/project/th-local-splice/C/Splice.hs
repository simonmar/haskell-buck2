{-# LANGUAGE TemplateHaskell #-}
module C.Splice (splice) where

import A.Base (base)
import TH.Gen (gen)

splice :: Int
splice = $(gen) + base
