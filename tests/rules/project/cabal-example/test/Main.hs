module Main (main) where

import Example (example)
import System.Exit (exitFailure)
import Control.Monad (unless)

main :: IO ()
main = unless (example == 3) exitFailure
