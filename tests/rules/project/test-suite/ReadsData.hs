module Main (main) where

import System.Environment (getEnv)
import System.Exit (exitFailure)

main :: IO ()
main = do
  dir <- getEnv "test_suite_datadir"
  greeting <- readFile (dir ++ "/greeting.txt")
  putStr greeting
  if greeting == "hello\n" then pure () else exitFailure
