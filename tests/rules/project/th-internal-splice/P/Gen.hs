module P.Gen (gen) where

import Language.Haskell.TH (Exp, Q, integerL, litE)

gen :: Q Exp
gen = litE (integerL 42)
