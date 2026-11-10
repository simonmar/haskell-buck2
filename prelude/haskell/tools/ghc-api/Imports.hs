{-# LANGUAGE CPP #-}
-- | A module summary's imports, wherever each GHC version (9.6 to 9.14)
-- keeps them.
module Imports (importName, importLocated, srcImportName) where

import GHC (GenLocated (..), Located, ModuleName, PkgQual)

-- Accessors for the imports of a module summary. GHC 9.14 added an import
-- level to each import, which these ignore.
--
-- * importName: an import's module name, and the package it names (with
--   PackageImports), if any.
-- * importLocated: an import's module name, with its source location.
-- * srcImportName: the module name of a {-# SOURCE #-} import.
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
