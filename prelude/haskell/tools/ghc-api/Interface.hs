{-# LANGUAGE CPP #-}
-- | Reading a module's interface, and what the rules take from it, wherever
-- each GHC version (9.6 to 9.14) keeps it.
module Interface
  ( readInterface
  , abiHash
  , usages
  , usageFile
  , directDep
  ) where

import Control.Monad.IO.Class (liftIO)

import GHC (getSession, runGhc)
import GHC.Driver.Env (hsc_NC, hsc_dflags)
import GHC.Driver.Session (targetProfile)
import GHC.Iface.Binary (CheckHiWay (..), TraceBinIFace (..), readBinIface)
import GHC.Unit.Module.Deps (Usage (..))
import GHC.Unit.Module.ModIface (ModIface, mi_usages)
#if MIN_VERSION_ghc(9,8,0)
import GHC.Data.FastString (unpackFS)
#endif
#if MIN_VERSION_ghc(9,14,0)
import GHC.Unit.Module.ModIface (mi_mod_hash)
#else
import GHC.Unit.Module.ModIface (mi_final_exts, mi_mod_hash)
#endif
import GHC.Utils.Fingerprint (Fingerprint)

-- | Read the interface file, with GHC's libdir.
readInterface :: FilePath -> FilePath -> IO ModIface
readInterface libdir path = runGhc (Just libdir) $ do
  hsc <- getSession
  liftIO (readBinIface (targetProfile (hsc_dflags hsc)) (hsc_NC hsc) IgnoreHiWay QuietBinIFace path)

-- | The interface's ABI hash and usages. From GHC 9.14 an interface may
-- record no usages (-fno-write-if-self-recomp).
abiHash :: ModIface -> Fingerprint
usages :: ModIface -> Maybe [Usage]
#if MIN_VERSION_ghc(9,14,0)
abiHash = mi_mod_hash
usages = mi_usages
#else
abiHash = mi_mod_hash . mi_final_exts
usages = Just . mi_usages
#endif

-- | The file of a usage of a file (from addDependentFile, or a library that a
-- splice loaded).
usageFile :: Usage -> Maybe FilePath
#if MIN_VERSION_ghc(9,8,0)
usageFile UsageFile{usg_file_path = p} = Just (unpackFS p)
#else
usageFile UsageFile{usg_file_path = p} = Just p
#endif
usageFile _ = Nothing

-- | An interface's direct dependency, without the import level it carries
-- since GHC 9.14.
#if MIN_VERSION_ghc(9,14,0)
directDep :: (a, b, c) -> (b, c)
directDep (_, uid, m) = (uid, m)
#else
directDep :: (b, c) -> (b, c)
directDep = id
#endif
