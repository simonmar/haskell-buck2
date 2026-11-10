module I.High (fam) where

import I.Mid ()
import I.T (F, T (..))

instance Show T where
  show T = "T"

fam :: F Int
fam = True
