-- | What the compile tool and the worker write for the rules besides GHC's
-- outputs.
module DepFile (writeDepFiles) where

import Control.Monad (filterM, forM, unless)
import Data.List (isPrefixOf)
import qualified Data.Set as Set
import System.Directory (canonicalizePath, doesFileExist, getCurrentDirectory)
import System.FilePath (makeRelative, takeFileName, (<.>), (</>))

import GHC (moduleName, moduleNameString, moduleUnit)
import GHC.Unit.Module.Deps (Usage (..), dep_direct_mods)
import GHC.Unit.Module.ModIface (ModIface, mi_deps)
import GHC.Unit.Types (GenWithIsBoot (..), IsBootInterface (..), unitString)
import GHC.Utils.Fingerprint (Fingerprint)
import GHC.Utils.Panic (GhcException (ProgramError), throwGhcExceptionIO)

import Interface (abiHash, directDep, usageFile, usages)
import Request

-- | Write a compiled module's ABI file and dep file, from its interface. The
-- ABI file has the interface's ABI hash. The dep file lists the usages GHC
-- recorded for its own recompilation check: the imported modules, as their
-- .abi files, and the files a splice loaded. See Note [Early cut-off by dep
-- files] in compile_per_module.bzl.
writeDepFiles :: Request -> ModIface -> IO ()
writeDepFiles r iface = do
  -- A splice can't run code of the target's own modules (see Note [Template
  -- Haskell modules] in compile_per_module.bzl). But GHC still finds them,
  -- in the session or as objects in the output directory, so we fail the
  -- compile if a splice loaded one.
  outDir <- canonicalizePath (reqOutDir r)
  -- Without usages, the dep file would say the module read nothing, and it
  -- would never compile again.
  us <- maybe (throwGhcExceptionIO (ProgramError (modName ++ ": its interface records no usages, so its dep file can't say what it read: don't compile it with -fno-write-if-self-recomp"))) pure (usages iface)
  own <- fmap concat . forM us $ \u -> case u of
    UsageHomeModuleInterface{usg_mod_name = m} -> pure [moduleNameString m]
    _ | Just path <- usageFile u -> do
      ok <- doesFileExist path
      c <- if ok then canonicalizePath path else pure path
      pure [takeFileName path | (outDir ++ "/") `isPrefixOf` c]
    _ -> pure []
  unless (null own) $
    throwGhcExceptionIO (ProgramError (modName ++ ": a splice ran code of this target's own modules (" ++ unwords own ++ "), which per_module doesn't support: build the target with per_module = False"))
  writeFile (reqAbi r) (show (abiHash iface :: Fingerprint) ++ "\n")
  cwd <- getCurrentDirectory
  -- A module that is only imported {-# SOURCE #-} is listed as its boot
  -- file's .abi-boot.
  let direct = [(gwib_mod d, gwib_isBoot d) | (_, d) <- map directDep (Set.toList (dep_direct_mods (mi_deps iface)))]
      ext m = if (m, IsBoot) `elem` direct && (m, NotBoot) `notElem` direct then "abi-boot" else "abi"
  entries <- fmap concat . forM us $ \u -> case u of
    UsageHomeModule{usg_mod_name = m} -> existing [reqOutDir r </> modFile m <.> ext m]
    UsageHomeModuleInterface{usg_mod_name = m} -> existing [reqOutDir r </> modFile m <.> "abi"]
    -- Looked up by its unit as well as its name, since a module of another
    -- unit may have the same name.
    UsagePackageModule{usg_mod = m} -> firstExisting (concat [[d </> modFile (moduleName m) <.> "abi", d </> modFile (moduleName m) <.> reqHisuf r] | (unit, d) <- reqHidirs r, unit == unitString (moduleUnit m)])
    _ | Just path <- usageFile u -> do
      -- Files outside the project (the libraries of GHC's own package db)
      -- aren't inputs of the action.
      ok <- doesFileExist path
      if ok then (\c -> [c | isUnder cwd c]) <$> canonicalizePath path else pure []
    _ -> pure []
  self <- if reqBoot r then pure [] else existing [reqOutDir r </> reqModPath r <.> "abi-boot"]
  rel <- mapM (fmap (makeRelative cwd) . canonicalizePath) (entries ++ self)
  writeFile (reqDepfile r) (unlines rel)
  where
    modName = map (\c -> if c == '/' then '.' else c) (reqModPath r)
    modFile = map (\c -> if c == '.' then '/' else c) . moduleNameString
    existing = filterM doesFileExist
    firstExisting = fmap (take 1) . existing
    isUnder cwd p = (cwd ++ "/") `isPrefixOf` p
