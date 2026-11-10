module DD.Paths (getDataFileName) where

import System.Environment (getEnv)

getDataFileName :: FilePath -> IO FilePath
getDataFileName name = (++ ("/" ++ name)) <$> getEnv "data_dirs_datadir"
