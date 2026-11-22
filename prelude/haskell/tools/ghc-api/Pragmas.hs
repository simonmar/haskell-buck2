{-# LANGUAGE CPP #-}
-- | The flags that a module's OPTIONS_GHC and LANGUAGE pragmas give.
module Pragmas (optionsPragmas) where

import GHC (DynFlags, Located)
import GHC.Data.StringBuffer (StringBuffer)
import GHC.Driver.Config.Parser (initParserOpts)
import GHC.Parser.Header (getOptions)
#if MIN_VERSION_ghc(9,14,0)
import GHC.Driver.Config.Parser (supportedLanguagePragmas)
#endif
#if MIN_VERSION_ghc(10,0,0)
import GHC.Types.SourceError (initSourceErrorContext)
#endif

-- | Read the flags that the OPTIONS_GHC and LANGUAGE pragmas at the head of
-- a module's source give, parsing the source with the given flags. The file
-- name is only used in GHC's messages. (From GHC 9.14, the parser also needs
-- the list of supported extensions, and from GHC 10.0 the context in which
-- to report errors.)
optionsPragmas :: DynFlags -> StringBuffer -> FilePath -> [Located String]
#if MIN_VERSION_ghc(10,0,0)
optionsPragmas dflags buf file = snd (getOptions (initParserOpts dflags) (initSourceErrorContext dflags) (supportedLanguagePragmas dflags) buf file)
#elif MIN_VERSION_ghc(9,14,0)
optionsPragmas dflags buf file = snd (getOptions (initParserOpts dflags) (supportedLanguagePragmas dflags) buf file)
#else
optionsPragmas dflags buf file = snd (getOptions (initParserOpts dflags) buf file)
#endif
