{-# LANGUAGE ExplicitLevelImports, TemplateHaskell #-}
module E.Own (own) where

import splice E.OwnGen (gen)

own :: Integer
own = $(gen)
