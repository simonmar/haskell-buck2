{-# LANGUAGE CPP #-}
-- | A module summary's imports, wherever each GHC version (9.6 to 10.1)
-- keeps them.
module Imports (Import, ordinaryImports, textualImports, sourceImports, importName, importLocated, findImport, findModuleByName) where

import GHC (GenLocated (..), Located, ModSummary, ModuleName, PkgQual (..))
import GHC.Driver.Env (HscEnv)
import GHC.Unit.Finder (FindResult, findImportedModule)
import GHC.Unit.Module.ModSummary (ModSummary (ms_textual_imps), ms_imps, ms_srcimps)
#if MIN_VERSION_ghc(10,1,0)
import GHC.Unit.Finder (resolveImport)
import GHC.Types.UnresolvedImport (UnresolvedImport (..))
import GHC.Unit.Types (IsBootInterface (..), ModuleLookupScope (..))
#endif
#if !MIN_VERSION_ghc(10,1,0) && MIN_VERSION_ghc(9,14,0)
import GHC.Types.Basic (ImportLevel)
#endif

-- | An import of a module summary. GHC 9.14 added an import level to each
-- import, which these functions ignore.
#if MIN_VERSION_ghc(10,1,0)
type Import = UnresolvedImport PkgQual
#elif MIN_VERSION_ghc(9,14,0)
type Import = (ImportLevel, PkgQual, Located ModuleName)
#else
type Import = (PkgQual, Located ModuleName)
#endif

-- | The module's imports that aren't {-# SOURCE #-} imports, including
-- those of its plugins.
ordinaryImports :: ModSummary -> [Import]

-- | The module's own imports that aren't {-# SOURCE #-} imports, without
-- those of its plugins.
textualImports :: ModSummary -> [Import]

-- | The module names of the module's {-# SOURCE #-} imports.
sourceImports :: ModSummary -> [ModuleName]

-- | An import's module name, and the package that it names (with
-- PackageImports), if any.
importName :: Import -> (ModuleName, PkgQual)

-- | An import's module name, with its source location.
importLocated :: Import -> Located ModuleName

-- | Find the module that an import names, as GHC does when it compiles the
-- module. Since GHC 10.1, the lookup depends on where the import comes
-- from: GHC's implicit import of GHC.Essentials may name a hidden module,
-- for example.
findImport :: HscEnv -> Import -> IO FindResult

-- | Find a module by its name alone, as a user's import that names no
-- package would.
findModuleByName :: HscEnv -> ModuleName -> IO FindResult

#if MIN_VERSION_ghc(10,1,0)
-- Since GHC 10.1, ms_imps has the {-# SOURCE #-} imports too.
ordinaryImports = filter ((== NotBoot) . ui_boot) . ms_imps
textualImports = filter ((== NotBoot) . ui_boot) . ms_textual_imps
sourceImports ms = [mn | UnresolvedImport{ui_mod_name = L _ mn} <- ms_srcimps ms]
importName i = let L _ mn = ui_mod_name i in (mn, ui_pkg_qual i)
importLocated = ui_mod_name
findImport = resolveImport
findModuleByName hsc mn = findImportedModule hsc LookupUser mn NoPkgQual
#elif MIN_VERSION_ghc(9,14,0)
ordinaryImports = ms_imps
textualImports = ms_textual_imps
sourceImports ms = [mn | L _ mn <- ms_srcimps ms]
importName (_, pkg, L _ mn) = (mn, pkg)
importLocated (_, _, lmn) = lmn
#else
ordinaryImports = ms_imps
textualImports = ms_textual_imps
sourceImports ms = [mn | (_, L _ mn) <- ms_srcimps ms]
importName (pkg, L _ mn) = (mn, pkg)
importLocated (_, lmn) = lmn
#endif

#if !MIN_VERSION_ghc(10,1,0)
findImport hsc i = let (mn, pkg) = importName i in findImportedModule hsc mn pkg
findModuleByName hsc mn = findImportedModule hsc mn NoPkgQual
#endif
