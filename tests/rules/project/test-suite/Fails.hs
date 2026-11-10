module Main (main) where

import System.Exit (exitFailure)

main :: IO ()
main = putStrLn "this test only runs when it is asked for" >> exitFailure
