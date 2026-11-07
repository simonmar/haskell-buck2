module C.Ann (ann) where

import A.Base (base)

{-# ANN ann "an annotation" #-}
ann :: Int
ann = base
