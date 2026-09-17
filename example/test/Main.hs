module Main (main) where

import Example.Lib (addPoints, greet, greetFirst)
import System.Exit (exitFailure, exitSuccess)

main :: IO ()
main = do
  let greeting = greet "World"
  total <- addPoints 3 4
  let firstOf = greetFirst ["Alice", "Bob"]
      firstOfEmpty = greetFirst []
      failures =
        [ msg
        | (ok, msg) <-
            [ (greeting == "Hello, World!", "greet: got " ++ show greeting)
            , (total == 7, "addPoints: got " ++ show total)
            , (firstOf == "Hello, Alice!", "greetFirst: got " ++ show firstOf)
            , (firstOfEmpty == "Hello, stranger!", "greetFirst (empty): got " ++ show firstOfEmpty)
            ]
        , not ok
        ]
  if null failures
    then exitSuccess
    else do
      mapM_ putStrLn failures
      exitFailure
