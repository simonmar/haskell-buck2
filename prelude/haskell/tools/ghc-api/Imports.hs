{-# LANGUAGE CPP #-}
-- | A module summary's imports, wherever each GHC version (9.6 to 9.14)
-- keeps them.
module Imports (importName, importLocated, srcImportName, spliceImport) where

import GHC (GenLocated (..), Located, ModuleName, PkgQual)
#if MIN_VERSION_ghc(9,14,0)
import GHC.Types.Basic (ImportLevel (..))
#endif

-- importName: a summary's import, with the package it names, if any.
-- srcImportName: a {-# SOURCE #-} import. Both without the import level
-- that they carry since GHC 9.14.
--
-- importLocated: an import's module, where the import is.
--
-- spliceImport: whether an import is at the splice level (`import splice`,
-- from GHC 9.14).
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
