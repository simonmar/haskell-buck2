module SO.Gen (genValue) where

-- Not inlined, so that a splice using it runs this library's code rather
-- than its unfolding.
genValue :: Int
genValue = 6
{-# NOINLINE genValue #-}
