{-# LANGUAGE TemplateHaskell #-}
module Main (main) where

import Language.Haskell.TH (litE, runIO, stringL)
import Paths_own (getDataFileName)

main :: IO ()
main = putStr $(runIO (getDataFileName "greeting.txt" >>= readFile) >>= litE . stringL)
