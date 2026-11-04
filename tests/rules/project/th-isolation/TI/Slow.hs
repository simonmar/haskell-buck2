{-# LANGUAGE TemplateHaskell #-}
module TI.Slow (slow) where

import Control.Concurrent (threadDelay)
import Language.Haskell.TH.Syntax (lift, runIO)

slow :: ()
slow = $(runIO (threadDelay 5000000) >> lift ())
