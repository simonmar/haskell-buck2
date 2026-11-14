{-# LANGUAGE TemplateHaskell #-}
module D.UseOwn (m) where

import D.Own (len)
import Language.Haskell.TH.Syntax (lift)

m :: Int
m = $(lift len)
