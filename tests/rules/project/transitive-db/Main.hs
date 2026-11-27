module Main (main) where
import TD.Mid (mid)
import TD.UsesBase (usesBase)
main :: IO ()
main = print (mid + usesBase)
