module Main (main) where

import System.Exit (exitFailure)
import System.Process (readProcess)

main :: IO ()
main = do
  out <- readProcess "tool" [] ""
  if out == "tool output\n" then putStrLn "ok" else putStrLn ("tool printed " ++ show out) >> exitFailure
