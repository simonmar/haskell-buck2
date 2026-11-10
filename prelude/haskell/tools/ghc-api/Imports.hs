{-# LANGUAGE CPP #-}
-- | A module summary's imports, wherever each GHC version (9.6 to 9.14)
-- keeps them.
module Imports (importName, importLocated, srcImportName) where

import GHC (GenLocated (..), Located, ModuleName, PkgQual)

-- importName: a summary's import, with the package it names, if any.
-- srcImportName: a {-# SOURCE #-} import. Both without the import level
-- that they carry since GHC 9.14. importLocated: an import's module, where
-- the import is.
#if MIN_VERSION_ghc(9,14,0)
importName :: (a, PkgQual, Located ModuleName) -> (ModuleName, PkgQual)
importName (_, pkg, L _ mn) = (mn, pkg)
importLocated :: (a, PkgQual, Located ModuleName) -> Located ModuleName
importLocated (_, _, lmn) = lmn
srcImportName :: Located ModuleName -> ModuleName
srcImportName (L _ mn) = mn
#else
importName :: (PkgQual, Located ModuleName) -> (ModuleName, PkgQual)
importName (pkg, L _ mn) = (mn, pkg)
importLocated :: (PkgQual, Located ModuleName) -> Located ModuleName
importLocated (_, lmn) = lmn
srcImportName :: (a, Located ModuleName) -> ModuleName
srcImportName (_, L _ mn) = mn
#endif
