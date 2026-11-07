{-# LANGUAGE Safe #-}
-- A Safe module, each of whose imports GHC records as "import safe" in its
-- interface.
module B.Safe (safe) where

import A.Mid

safe :: Int
safe = mid
