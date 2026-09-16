{-# LANGUAGE TemplateHaskell #-}

-- | A tiny Template Haskell splice, so the test project exercises TH
-- (both the compile-time splice itself, and the dynamic-linking-of-
-- dependencies-into-GHC machinery that requires).
module Example.TH (makeGreeter) where

import Language.Haskell.TH

-- | @$(makeGreeter "greet")@ generates:
--
-- > greet :: String -> String
-- > greet n = "Hello, " ++ n ++ "!"
makeGreeter :: String -> Q [Dec]
makeGreeter fnName = do
  let name = mkName fnName
  n <- newName "n"
  pure
    [ SigD name (AppT (AppT ArrowT (ConT ''String)) (ConT ''String))
    , FunD name
        [ Clause [VarP n]
            (NormalB
              (AppE (AppE (VarE '(++))
                          (AppE (AppE (VarE '(++)) (LitE (StringL "Hello, ")))
                                (VarE n)))
                    (LitE (StringL "!"))))
            []
        ]
    ]
