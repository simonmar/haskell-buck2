module OB.A (a) where

import {-# SOURCE #-} OB.B (b)

a :: Int
a = b + 1
