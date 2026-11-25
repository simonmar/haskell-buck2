module SO.Gen2 (genValue2) where

import SO.Gen (genValue)

-- Not inlined, so that a splice using it runs this library's code rather
-- than its unfolding.
genValue2 :: Int
genValue2 = genValue + 1
{-# NOINLINE genValue2 #-}
