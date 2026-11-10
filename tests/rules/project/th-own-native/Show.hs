module Main (main) where

import qualified A.S
import qualified B.S

main :: IO ()
main = print (A.S.s, B.S.s)
