module E.Own (own) where

import Language.Haskell.TH (Exp, Q)
import TH.Gen (gen)

own :: Q Exp
own = gen
