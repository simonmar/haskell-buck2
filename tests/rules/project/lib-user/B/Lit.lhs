A literate module, with an instance its importer uses.

> module B.Lit (L (..), lit) where

> data L = L

> instance Show L where
>   show _ = "L"

> lit :: Int
> lit = 1
