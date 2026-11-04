module Loop.A (a, inlined) where

import {-# SOURCE #-} qualified Loop.B as B

a :: Int
a = 1

inlined :: Int
inlined = a + B.b
{-# INLINE inlined #-}
