-- | Marshalling for the @ShimPoint@ C struct (declared in
-- @cbits/shim.h@), and the FFI import of the C++ function that operates
-- on it. Exercises hsc2hs (struct layout via @#{peek}@/@#{poke}@) and
-- FFI-to-C++ (the actual implementation, in @cbits/shim.cpp@, is C++,
-- exposed via an @extern \"C\"@ wrapper).
module Example.Point (Point(..), addPoint) where

#include "shim.h"

import Data.Int (Int32)
import Foreign
import Foreign.C.Types

data Point = Point
  { pointX :: !Int32
  , pointY :: !Int32
  } deriving (Eq, Show)

instance Storable Point where
  sizeOf _ = #{size ShimPoint}
  alignment _ = #{alignment ShimPoint}
  peek ptr =
    Point
      <$> (#{peek ShimPoint, x} ptr)
      <*> (#{peek ShimPoint, y} ptr)
  poke ptr (Point x y) = do
    #{poke ShimPoint, x} ptr x
    #{poke ShimPoint, y} ptr y

foreign import ccall unsafe "shim_add_point"
  c_shim_add_point :: Ptr Point -> IO CInt

addPoint :: Point -> IO Int
addPoint p = with p $ \ptr -> fromIntegral <$> c_shim_add_point ptr
