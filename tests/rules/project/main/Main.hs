module Main (main) where

import B.M (m)
import Main.Util (twice)

main :: IO ()
main = print (twice m)
