-- | Encoding and decoding of the protobuf messages of buck2's worker
-- protocol (worker.proto), written by hand. The worker only uses two small
-- messages, ExecuteCommand and ExecuteResponse, which aren't worth a
-- dependency on a protobuf library.
--
-- In protobuf's wire format, each field starts with a varint key, which is
-- the field number shifted left by 3 bits, with the wire type in the low 3
-- bits. The field's value follows. For wire type 0 the value is a varint,
-- and for wire type 2 it is a varint length followed by that many bytes.
module Proto (ExecuteCommand (..), decodeExecuteCommand, encodeExecuteResponse, encodeExecuteCommand, decodeExecuteResponse) where

import Data.Bits (shiftL, shiftR, (.&.), (.|.))
import Data.ByteString (ByteString)
import qualified Data.ByteString as B
import qualified Data.ByteString.Builder as BB
import qualified Data.ByteString.Lazy as BL
import Data.Word (Word64, Word8)

-- | The part of an ExecuteCommand message that the worker uses: the
-- command's arguments (field 1). The command's environment (field 2) is
-- ignored, since the rules don't give these actions an environment of their
-- own.
newtype ExecuteCommand = ExecuteCommand {ecArgv :: [ByteString]}

-- Split a message into its fields, each with its field number and value. A
-- varint value is in 'Left', and a length-delimited value in 'Right'.
-- Fixed-size values (wire types 1 and 5) are skipped, and decoding stops at
-- any other wire type.
fields :: ByteString -> [(Word64, Either Word64 ByteString)]
fields bs
  | B.null bs = []
  | otherwise =
      let (key, rest) = varint bs
          num = key `shiftR` 3
       in case key .&. 7 of
            0 -> let (v, rest') = varint rest in (num, Left v) : fields rest'
            2 ->
              let (len, rest') = varint rest
                  (payload, rest'') = B.splitAt (fromIntegral len) rest'
               in (num, Right payload) : fields rest''
            1 -> fields (B.drop 8 rest)
            5 -> fields (B.drop 4 rest)
            _ -> []

varint :: ByteString -> (Word64, ByteString)
varint = go 0 0
  where
    go acc shift bs = case B.uncons bs of
      Nothing -> (acc, B.empty)
      Just (b, rest) ->
        let acc' = acc .|. (fromIntegral (b .&. 0x7f) `shiftL` shift)
         in if b .&. 0x80 == 0 then (acc', rest) else go acc' (shift + 7) rest

decodeExecuteCommand :: ByteString -> ExecuteCommand
decodeExecuteCommand bs = ExecuteCommand [a | (1, Right a) <- fields bs]

-- Encode an ExecuteResponse with the given exit code (field 1, a varint) and
-- stderr (field 2, a byte string). The keys 8 and 18 are those two field
-- numbers combined with their wire types.
encodeExecuteResponse :: Int -> ByteString -> ByteString
encodeExecuteResponse code err =
  BL.toStrict . BB.toLazyByteString $
    putVarint 8 <> putVarint (fromIntegral code)
      <> putVarint 18 <> putVarint (fromIntegral (B.length err)) <> BB.byteString err

putVarint :: Word64 -> BB.Builder
putVarint n
  | n < 0x80 = BB.word8 (fromIntegral n)
  | otherwise = BB.word8 (fromIntegral (n .&. 0x7f) .|. 0x80 :: Word8) <> putVarint (n `shiftR` 7)

-- | Encode an ExecuteCommand with the given argv. This and
-- 'decodeExecuteResponse' are the client's side of the protocol, for
-- programs that talk to the worker, such as its test suites.
encodeExecuteCommand :: [ByteString] -> ByteString
encodeExecuteCommand argv =
  BL.toStrict . BB.toLazyByteString . mconcat $
    [putVarint 10 <> putVarint (fromIntegral (B.length a)) <> BB.byteString a | a <- argv]

-- | Decode the exit code and stderr of an ExecuteResponse. A missing field
-- reads as protobuf's default, which is 0 or empty.
decodeExecuteResponse :: ByteString -> (Int, ByteString)
decodeExecuteResponse bs = (fromIntegral code, B.concat (take 1 [e | (2, Right e) <- fs]))
  where
    fs = fields bs
    code = case [c | (1, Left c) <- fs] of
      c : _ -> c
      [] -> 0
