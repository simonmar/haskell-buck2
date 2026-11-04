{-# LANGUAGE TemplateHaskell #-}
module Main (main) where

import P.Gen (gen)

main :: IO ()
main = print ($(gen) :: Int)
