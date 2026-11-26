module Example (example) where

import Example.Hidden (hidden)
import Internal (internal)

example :: Int
example = hidden + internal
