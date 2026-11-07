{-# LANGUAGE ExplicitLevelImports, TemplateHaskell #-}
module E.UseOwn (e4) where

import splice E.Own (own)

e4 :: Int
e4 = $(own)
