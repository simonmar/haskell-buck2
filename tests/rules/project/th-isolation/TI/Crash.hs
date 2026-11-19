{-# LANGUAGE TemplateHaskell #-}
module TI.Crash (crashed) where

import Control.Concurrent (threadDelay)
import K.Crash (crash)
import Language.Haskell.TH.Syntax (lift, runIO)

crashed :: ()
crashed = $(runIO (threadDelay 1000000 >> crash) >> lift ())
