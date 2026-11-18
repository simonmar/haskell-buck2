import Control.Concurrent (rtsSupportsBoundThreads)

main :: IO ()
main = print rtsSupportsBoundThreads
