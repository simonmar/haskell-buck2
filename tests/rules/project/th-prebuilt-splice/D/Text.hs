{-# LANGUAGE TemplateHaskell #-}
module D.Text (n) where

import qualified Data.Text as Text
import Language.Haskell.TH.Syntax (lift)

n :: Int
n = $(lift (Text.length (Text.toUpper (Text.pack "abc"))))
