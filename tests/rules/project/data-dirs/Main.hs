{-# LANGUAGE TemplateHaskell #-}
module Main (main) where

import DD.Paths (getDataFileName)
import Language.Haskell.TH (litE, runIO, stringL)

main :: IO ()
main = putStr $(runIO (getDataFileName "greeting.txt" >>= readFile) >>= litE . stringL)
