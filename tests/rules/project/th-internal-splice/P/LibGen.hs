module P.LibGen (libGen) where

import A.Mid (mid)
import Language.Haskell.TH (Exp, Q, integerL, litE)

libGen :: Q Exp
libGen = litE (integerL (fromIntegral mid))
