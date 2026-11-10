{-# LANGUAGE TypeFamilies #-}
module I.Fam () where

import I.T (F)

type instance F Int = Bool
