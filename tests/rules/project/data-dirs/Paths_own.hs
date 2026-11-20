module Paths_own (getDataFileName) where

import System.Environment (getEnv)

getDataFileName :: FilePath -> IO FilePath
getDataFileName name = (++ ("/" ++ name)) <$> getEnv "own_datadir"
