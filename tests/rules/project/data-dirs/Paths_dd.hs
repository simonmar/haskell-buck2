module Paths_dd (getDataFileName) where

import System.Environment (getEnv)

getDataFileName :: FilePath -> IO FilePath
getDataFileName name = (++ ("/" ++ name)) <$> getEnv "dd_datadir"
