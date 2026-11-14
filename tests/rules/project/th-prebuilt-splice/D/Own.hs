module D.Own (len) where

import qualified Data.Text as Text

len :: Int
len = Text.length (Text.pack "abcd")
