{-# LANGUAGE TemplateHaskell #-}

module Example.Lib (greet, addPoints) where

import Example.Point (Point(..), addPoint)
import Example.TH (makeGreeter)

$(makeGreeter "greet")

addPoints :: Int -> Int -> IO Int
addPoints x y = addPoint (Point (fromIntegral x) (fromIntegral y))
