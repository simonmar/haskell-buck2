{-# LANGUAGE TemplateHaskell #-}
module P.Use (use) where

import P.Gen (gen)

use :: Int
use = $(gen)
