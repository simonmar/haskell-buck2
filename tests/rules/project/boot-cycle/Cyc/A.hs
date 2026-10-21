module Cyc.A (A (..)) where

import {-# SOURCE #-} Cyc.B (B)

data A = A | AB B
