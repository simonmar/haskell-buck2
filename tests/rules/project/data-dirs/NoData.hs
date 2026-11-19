{-# LANGUAGE TemplateHaskell #-}
module Main (main) where

import DD.Plain (greeting)
import Language.Haskell.TH (litE, stringL)

main :: IO ()
main = putStr $(litE (stringL greeting))
