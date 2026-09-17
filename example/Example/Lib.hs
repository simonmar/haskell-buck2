{-# LANGUAGE TemplateHaskell #-}

module Example.Lib (greet, addPoints, greetFirst) where

import Example.Point (Point(..), addPoint)
import Example.TH (makeGreeter)
import Safe (headMay)

$(makeGreeter "greet")

addPoints :: Int -> Int -> IO Int
addPoints x y = addPoint (Point (fromIntegral x) (fromIntegral y))

-- | Uses the `safe` package (not a GHC boot library) so that
-- gen-haskell-prebuilt.py has at least one real cabal-store package to
-- resolve, rather than only GHC-bundled ones.
greetFirst :: [String] -> String
greetFirst names = case headMay names of
  Just n -> greet n
  Nothing -> "Hello, stranger!"
