module TF.M (m) where

import A.Base (base)
import Language.Haskell.TH.Syntax (lift)

m :: Int
m = $(lift base)
