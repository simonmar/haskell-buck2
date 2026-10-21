module TH.Gen (gen) where

import Language.Haskell.TH

gen :: Q Exp
gen = litE (integerL 42)
