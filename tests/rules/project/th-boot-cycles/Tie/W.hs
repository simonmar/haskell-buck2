module Tie.W (w) where
import Tie.I (i)
w :: Int
w = 5
{-# NOINLINE w #-}
w2 :: Int
w2 = i
