-- | Writing the files that the compile tool and the worker produce besides
-- GHC's own outputs: a module's .abi file, and its buck2 dep file.
module DepFile (writeDepFiles) where

import Control.Monad (filterM, forM, unless)
import Data.List (isPrefixOf)
import qualified Data.Set as Set
import System.Directory (canonicalizePath, doesFileExist, getCurrentDirectory)
import System.FilePath (dropExtension, makeRelative, takeDirectory, takeFileName, (<.>), (</>))

import GHC (moduleName, moduleNameString, moduleUnit)
import GHC.Unit.Module.Deps (Usage (..), dep_direct_mods)
import GHC.Unit.Module.ModIface (ModIface, mi_deps)
import GHC.Unit.Types (GenWithIsBoot (..), IsBootInterface (..), unitString)
import GHC.Utils.Fingerprint (Fingerprint)
import GHC.Utils.Panic (GhcException (ProgramError), throwGhcExceptionIO)

import Interface (abiHash, directDep, usageFile, usageLoadedModule, usages)
import Request

-- | Write a compiled module's ABI file and dep file, from its interface. The
-- ABI file has the interface's ABI hash. The dep file lists the usages GHC
-- recorded for its own recompilation check: the imported modules, as their
-- .abi files, and the files a splice loaded. See Note [Early cut-off by dep
-- files] in compile_per_module.bzl.
writeDepFiles :: Request -> ModIface -> IO ()
writeDepFiles r iface = do
  writeFile (reqAbi r) (show (abiHash iface :: Fingerprint) ++ "\n")
  cwd <- getCurrentDirectory
  -- A module that is only imported {-# SOURCE #-} is listed as its boot
  -- file's .abi-boot.
  let direct = [(gwib_mod d, gwib_isBoot d) | (_, d) <- map directDep (Set.toList (dep_direct_mods (mi_deps iface)))]
      ext m = if (m, IsBoot) `elem` direct && (m, NotBoot) `notElem` direct then "abi-boot" else "abi"
  -- Without usages, the dep file would say the module read nothing, and it
  -- would never compile again.
  us <- maybe (throwGhcExceptionIO (ProgramError (modName ++ ": its interface records no usages, so its dep file can't say what it read: don't compile it with -fno-write-if-self-recomp"))) pure (usages iface)
  -- A splice can only run code of the modules that the compile waits for,
  -- whose objects are its inputs (see Note [Template Haskell modules] in
  -- compile_per_module.bzl). It doesn't wait for a module that an import
  -- cycle among Template Haskell modules kept out. GHC may still have found
  -- such a module's object in the output directory, left by an earlier
  -- build, so we fail the compile if a splice loaded one.
  outDir <- canonicalizePath (reqOutDir r)
  loaded <- fmap concat . forM us $ \u -> case usageFile u of
    Just path -> do
      ok <- doesFileExist path
      -- Only the directory is canonicalized. A profiled compile's .dyn_o
      -- files are links to the non-profiled compile's objects, so following
      -- the link would take the path out of the output directory.
      c <- if ok then (</> takeFileName path) <$> canonicalizePath (takeDirectory path) else pure path
      pure [map (\ch -> if ch == '/' then '.' else ch) (dropExtension (makeRelative outDir c)) | (outDir ++ "/") `isPrefixOf` c]
    Nothing -> pure []
  let reached = [m | m <- loaded, m `notElem` reqClosure r]
  unless (null reached) $
    throwGhcExceptionIO (ProgramError (modName ++ ": a splice ran code of " ++ unwords reached ++ ", which " ++ modName ++ "'s compile doesn't wait for, because of an import cycle among the target's Template Haskell modules"))
  entries <- fmap concat . forM us $ \u -> case u of
    UsageHomeModule{usg_mod_name = m} -> existing [reqOutDir r </> modFile m <.> ext m]
    _ | Just m <- usageLoadedModule u -> existing [reqOutDir r </> modFile m <.> "abi"]
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
