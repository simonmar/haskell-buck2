module Tie.V (v) where
import {-# SOURCE #-} Tie.W (w)
v :: Int
v = w + 100
{-# NOINLINE v #-}
