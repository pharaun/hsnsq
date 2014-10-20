{-# LANGUAGE OverloadedStrings #-}
{-|
Module      : Network.NSQ.Parser
Description : Protocol Parser layer for the NSQ client library.
-}
module Network.NSQ.Parser
    ( message
    , decode
    , encode
    ) where

import Data.Word
import Data.Monoid
import Control.Applicative
import Data.Attoparsec.Binary
import Data.Attoparsec.ByteString hiding (count)
import Data.Int
import Prelude hiding (take)

import qualified Data.List as DL

import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as C8
import qualified Data.ByteString.Lazy as BL
import qualified Data.ByteString.Lazy.Builder as BL

import qualified Data.Text.Encoding as T

import Network.NSQ.Types
import Network.NSQ.Identify


-- | Decode the 'ByteString' to an 'Message'
decode :: BS.ByteString -> Maybe Message
decode str = case parseOnly message str of
    Left _ -> Nothing
    Right r -> Just r


-- | Convert various nsq messages into useful 'Message' types
command :: BS.ByteString -> Message
command "_heartbeat_"   = Heartbeat
command "OK"            = OK
command "CLOSE_WAIT"    = CloseWait
command x               = CatchAllMessage (FTUnknown 99) x -- TODO: Better FrameType

-- | Convert various Error strings to 'ErrorType'
errorCasting :: BS.ByteString -> ErrorType
errorCasting "E_INVALID"         = Invalid
errorCasting "E_BAD_BODY"        = BadBody
errorCasting "E_BAD_TOPIC"       = BadTopic
errorCasting "E_BAD_MESSAGE"     = BadMessage
errorCasting "E_PUB_FAILED"      = PubFailed
errorCasting "E_MPUB_FAILED"     = MPubFailed
errorCasting "E_FIN_FAILED"      = FinFailed
errorCasting "E_REQ_FAILED"      = ReqFailed
errorCasting "E_TOUCH_FAILED"    = TouchFailed
errorCasting x                   = Unknown x

-- | Frame types into 'FrameType'
frameType :: Int32 -> FrameType
frameType 0 = FTResponse
frameType 1 = FTError
frameType 2 = FTMessage
frameType x = FTUnknown x

-- TODO: do sanity check such as checking that the size is of a minimal
-- size, then parsing the frameType, then the remainder (fail "messg")
-- | Parse the low level message frames into a 'Message' type.
message :: Parser Message
message = do
    size <- fromIntegral <$> anyWord32be
    ft <- frameType <$> fromIntegral <$> anyWord32be
    frame ft (size - 4) -- Taking in accord the frameType

-- | Parse in the frame (remaining portion) of the message in accordance of
-- the 'Frametype'
frame :: FrameType -> Int -> Parser Message
frame FTError    size = Error <$> (errorCasting `fmap` take size)
frame FTResponse size = command <$> take size
frame FTMessage  size = Message
    <$> (fromIntegral <$> anyWord64be)
    <*> anyWord16be
    -- 16 bytes message id
    <*> take 16
    -- Taking in accord timestamp/attempts/msgid
    <*> take (size - 26)
frame ft size = CatchAllMessage ft <$> take size


-- TODO: this won't work for streaming the data...
--  Should provide two api, one for in memory (ie where we count up the length of the data manualy
--  And a "streaming" version in which we know the actual size before streaming (ie streaming from a file for ex)
-- | Primitive version for encoding the size of the data into the frame
-- content then encoding the remaining.
sizedData :: BS.ByteString -> BL.Builder
sizedData dat = BL.word32BE (fromIntegral $ BS.length dat) <> BL.byteString dat

-- Body of a foldl to build up a sequence of concat sized data
concatSizedData :: (Word32, Word32, BL.Builder) -> BS.ByteString -> (Word32, Word32, BL.Builder)
concatSizedData (totalSize, count, xs) dat = (
        totalSize + 4 + fromIntegral (BS.length dat), -- Add 4 to accord for message size
        count + 1,
        xs <> sizedData dat
    )

-- | Encode a 'Command' into raw 'ByteString' to send to the network to the
-- nsqd daemon. There are a few gotchas here; You can only have one 'Sub'
-- (topic/channel) per nsqld connection, any other will yield 'Invalid'.
-- Also you can publish to any number of topic without limitation.
encode :: Command -> BS.ByteString
encode Protocol     = "  V2"
encode NOP          = "NOP\n"
encode Cls          = "CLS\n"
encode (Identify identify) = BL.toStrict $ BL.toLazyByteString (
        BL.byteString "IDENTIFY\n" <>
        sizedData (BL.toStrict $ encodeMetadata identify)
    )
encode (Sub topic channel ephemeral) = BL.toStrict $ BL.toLazyByteString (
        BL.byteString "SUB " <>
        BL.byteString (T.encodeUtf8 topic) <>
        BL.byteString " " <>
        BL.byteString (T.encodeUtf8 channel) <>
        BL.byteString (if ephemeral then "#ephemeral" else "") <>
        BL.byteString "\n"
    )
encode (Pub topic dat) = BL.toStrict $ BL.toLazyByteString (
        BL.byteString "PUB " <>
        BL.byteString (T.encodeUtf8 topic) <>
        BL.byteString "\n" <>
        sizedData dat
    )
encode (MPub topic dx) = BL.toStrict $ BL.toLazyByteString (
        BL.byteString "MPUB " <>
        BL.byteString (T.encodeUtf8 topic) <>
        BL.byteString "\n" <>
        BL.word32BE (totalSize + 4) <> -- Accord for message count
        BL.word32BE totalCount <>
        content
    )
    where
        (totalSize, totalCount, content) = DL.foldl' concatSizedData (0, 0, mempty) dx

encode (Rdy count) = BL.toStrict $ BL.toLazyByteString (
        BL.byteString "RDY " <>
        BL.byteString (C8.pack $ show count) <>
        BL.byteString "\n"
    )
encode (Fin msg_id) = BL.toStrict $ BL.toLazyByteString (
        BL.byteString "FIN " <>
        BL.byteString msg_id <>
        BL.byteString "\n"
    )
encode (Touch msg_id) = BL.toStrict $ BL.toLazyByteString (
        BL.byteString "TOUCH " <>
        BL.byteString msg_id <>
        BL.byteString "\n"
    )
encode (Req msg_id timeout) = BL.toStrict $ BL.toLazyByteString (
        BL.byteString "REQ " <>
        BL.byteString msg_id <>
        BL.byteString " " <>
        BL.byteString (C8.pack $ show timeout) <>
        BL.byteString "\n"
    )
encode (Command m)  = m
