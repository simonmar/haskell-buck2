{-# LANGUAGE Trustworthy #-}
-- (Trustworthy: so that B.Safe, a Safe module, can import it.)
module A.Mid (mid) where

import A.Base

mid :: Int
mid = base + 1
