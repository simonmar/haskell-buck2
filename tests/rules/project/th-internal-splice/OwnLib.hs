{-# LANGUAGE TemplateHaskell #-}
module Main (main) where

import P.LibGen (libGen)

main :: IO ()
main = print ($(libGen) :: Int)
