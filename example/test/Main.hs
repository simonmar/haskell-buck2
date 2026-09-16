module Main (main) where

import Example.Lib (addPoints, greet)
import System.Exit (exitFailure, exitSuccess)

main :: IO ()
main = do
  let greeting = greet "World"
  total <- addPoints 3 4
  let failures =
        [ msg
        | (ok, msg) <-
            [ (greeting == "Hello, World!", "greet: got " ++ show greeting)
            , (total == 7, "addPoints: got " ++ show total)
            ]
        , not ok
        ]
  if null failures
    then exitSuccess
    else do
      mapM_ putStrLn failures
      exitFailure
