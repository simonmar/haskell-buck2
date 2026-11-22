{-# LANGUAGE TemplateHaskell #-}
module Main (main) where

import Language.Haskell.TH.Syntax (lift)
import SO.Gen2 (genValue2)

main :: IO ()
main = print ($(lift genValue2) :: Int)
