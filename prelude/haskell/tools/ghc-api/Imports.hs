{-# LANGUAGE CPP #-}
-- | A module summary's imports, wherever each GHC version (9.6 to 9.14)
-- keeps them.
module Imports (importName, importLocated, srcImportName, spliceImport) where

import GHC (GenLocated (..), Located, ModuleName, PkgQual)
#if MIN_VERSION_ghc(9,14,0)
import GHC.Types.Basic (ImportLevel (..))
#endif

-- Accessors for the imports of a module summary. GHC 9.14 added an import
-- level to each import, which all but spliceImport ignore.
--
-- * importName: an import's module name, and the package it names (with
--   PackageImports), if any.
-- * importLocated: an import's module name, with its source location.
-- * srcImportName: the module name of a {-# SOURCE #-} import.
-- * spliceImport: whether an import is at the splice level (`import
--   splice`).
#if MIN_VERSION_ghc(9,14,0)
importName :: (ImportLevel, PkgQual, Located ModuleName) -> (ModuleName, PkgQual)
importName (_, pkg, L _ mn) = (mn, pkg)
importLocated :: (ImportLevel, PkgQual, Located ModuleName) -> Located ModuleName
importLocated (_, _, lmn) = lmn
srcImportName :: Located ModuleName -> ModuleName
srcImportName (L _ mn) = mn
spliceImport :: (ImportLevel, PkgQual, Located ModuleName) -> Bool
spliceImport (level, _, _) = level == SpliceLevel
#else
importName :: (PkgQual, Located ModuleName) -> (ModuleName, PkgQual)
importName (pkg, L _ mn) = (mn, pkg)
importLocated :: (PkgQual, Located ModuleName) -> Located ModuleName
importLocated (_, lmn) = lmn
srcImportName :: (a, Located ModuleName) -> ModuleName
srcImportName (_, L _ mn) = mn
spliceImport :: (PkgQual, Located ModuleName) -> Bool
spliceImport _ = False
#endif
