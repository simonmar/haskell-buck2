{-# LANGUAGE TemplateHaskell #-}
module Main (main) where

import L.V (v)
import Language.Haskell.TH.Syntax (lift)
import System.Environment (getArgs)

main :: IO ()
main = do
  [out] <- getArgs
  writeFile out (show ($(lift v) :: Int))
