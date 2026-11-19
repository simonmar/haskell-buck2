module E.OwnGen (gen) where

import Language.Haskell.TH

gen :: Q Exp
gen = litE (integerL 1)
