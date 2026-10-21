module TF.M (m) where

import Language.Haskell.TH.Syntax (lift)

m :: Int
m = $(lift (length "toolchain"))
