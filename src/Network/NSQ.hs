{-# LANGUAGE OverloadedStrings #-}
{-|
Module      : Network.NSQ
Description : Protocol/parser layer for the NSQ client library.
Copyright   : (c) Anja Berens, 2014
License     : Apache 2.0
Maintainer  : pharaun666@gmail.com
Stability   : experimental
Portability : unknown

This is a haskell client for the <http://nsq.io/ NSQ> message queue service.

TODO:

    * Clean up the modules

    * Start implementing a more through client

    * Write some form of tests
-}
module Network.NSQ
    ( message
    , decode
    , encode

    , MsgId
    , Topic
    , Channel

    , Message(..)
    , Command(..)

    -- TODO: probably don't want to export constructor here but want pattern matching
    , FrameType(..)
    , ErrorType(..)

    , OptionalSetting(..)
    , TLS(..)
    , Compression(..)
    , Identification(..)
    , IdentifyMetadata(..)
    , defaultIdentify

    ) where

import Prelude hiding (take)
import Control.Applicative
import Data.Int
import Data.Maybe
import Data.Monoid
import Data.Word

import qualified Data.List as DL
import qualified Data.Map.Strict as Map

import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as C8
import qualified Data.ByteString.Lazy as BL
import qualified Data.ByteString.Lazy.Builder as BL

import qualified Data.Text as T
import qualified Data.Text.Encoding as T

import Data.Attoparsec.Binary
import Data.Attoparsec.ByteString hiding (count)

import Data.Aeson ((.=))
import qualified Data.Aeson as A
import qualified Data.Aeson.Types as A


-- | Message Id, it is a 16-byte hexdecimal string encoded as ASCII
type MsgId = BS.ByteString

-- | NSQ Topic, the only allowed character in a topic is @\\.a-zA-Z0-9_-@
type Topic = T.Text

-- | NSQ Channel, the only allowed character in a channel is @\\.a-zA-Z0-9_-@
-- A channel can be marked as ephemeral by toggling the 'Bool' value to
-- true in 'Sub'
type Channel = T.Text

-- | NSQ Command
data Command = Protocol -- ^ The protocol version
             | NOP -- ^ No-op, usually used in reply to a 'Heartbeat' request from the server.
             | Identify IdentifyMetadata -- ^ Client Identification + possible features negotiation.
             | Sub Topic Channel Bool -- ^ Subscribe to a specified 'Topic'/'Channel', use 'True' if its an ephemeral channel.
             | Pub Topic BS.ByteString -- ^ Publish a message to the specified 'Topic'.
             | MPub Topic [BS.ByteString] -- ^ Publish multiple messages to a specified 'Topic'.
             | Rdy Word64 -- ^ Update @RDY@ state (ready to recieve messages). Number of message you can process at once.
             | Fin MsgId -- ^ Finish a message.
             | Req MsgId Word64 -- ^ Re-queue a message (failure to process), Timeout is in milliseconds.
             | Touch MsgId -- ^ Reset the timeout for an in-flight message.
             | Cls -- ^ Cleanly close the connection to the NSQ daemon.
             | Command BS.ByteString -- ^ Catch-all command for future expansion/custom commands.
             deriving Show

-- | Frame Type of the incoming data from the NSQ daemon.
data FrameType = FTResponse -- ^ Response to a 'Command' from the server.
               | FTError -- ^ An error in response to a 'Command'.
               | FTMessage -- ^ Messages.
               | FTUnknown Int32 -- ^ For future extension for handling new Frame Types.
               deriving Show

-- | Types of error that the server can return in response to an 'Command'
data ErrorType = Invalid
               | BadBody
               | BadTopic
               | BadChannel
               | BadMessage
               | PubFailed
               | MPubFailed
               | FinFailed
               | ReqFailed
               | TouchFailed
               deriving Show

-- | The message and replies back from the server.
data Message = OK -- ^ Everything is allright.
             | Heartbeat -- ^ Heartbeat, reply with the 'NOP' 'Command'.
             | CloseWait -- ^ Server has closed the connection.

             -- TODO: BS.ByteString -> ErrorType
             | Error BS.ByteString -- ^ The server sent back an error.

             | Message Int64 Word16 MsgId BS.ByteString -- ^ A message to be processed. The values are: Nanosecond Timestamp, number of attempts, Message Id, and the content of the message to be processed.

             | CatchAllMessage FrameType BS.ByteString -- ^ Catch-all message for future expansion. This currently includes the reply from 'Identify' if feature negotiation is set.
             deriving Show


-- Feature and Identification
data OptionalSetting = Disabled | Custom Word64
    deriving Show

data TLS = NoTLS | TLSV1
    deriving Show

data Compression = NoCompression | Snappy | Deflate Word8
    deriving Show

data Identification = Identification
    { clientId :: T.Text
    , hostname :: T.Text
    , shortId :: Maybe T.Text -- Deprecated in favor of client_id
    , longId :: Maybe T.Text -- Deprecated in favor of hostname
    , userAgent :: Maybe T.Text -- Default (client_library_name/version)
    }
    deriving Show

-- feature_negotiation - set automatically if anything is set
data IdentifyMetadata = IdentifyMetadata
    { ident :: Identification
    , tls :: Maybe TLS
    , compression :: Maybe Compression
    , heartbeatInterval :: Maybe OptionalSetting -- disabled = -1
    , outputBufferSize :: Maybe OptionalSetting -- disabled = -1
    , outputBufferTimeout :: Maybe OptionalSetting -- disabled = -1
    , sampleRate :: Maybe OptionalSetting -- disabled = 0

    -- Map of possible json value for future compat
    , custom :: Maybe (Map.Map T.Text T.Text)
    , customNegotiation :: Bool
    }
    deriving Show

defaultIdentify :: T.Text -> T.Text -> IdentifyMetadata
defaultIdentify cid host = IdentifyMetadata
    { ident = Identification cid host Nothing Nothing Nothing
    , tls = Nothing
    , compression = Nothing
    , heartbeatInterval = Nothing
    , outputBufferSize = Nothing
    , outputBufferTimeout = Nothing
    , sampleRate = Nothing
    , custom = Nothing
    , customNegotiation = False
    }

defaultUserAgent :: T.Text
defaultUserAgent = "hsnsq/0.1.0.0"


(.?=) :: A.ToJSON a => T.Text -> Maybe a -> Maybe A.Pair
_ .?= Nothing  = Nothing
name .?= Just val = Just (name, A.toJSON val)


featureNegotiation :: IdentifyMetadata -> [A.Pair]
featureNegotiation im = catMaybes
    (
        [ "tls_v1" .?= tls im -- TODO: not very good, what if there's other version of tls
        , optionalSettings "heartbeat_interval" (-1) $ heartbeatInterval im
        , optionalSettings "output_buffer_size" (-1) $ outputBufferSize im
        , optionalSettings "output_buffer_timeout" (-1) $ outputBufferTimeout im
        , optionalSettings "sample_rate" 0 $ sampleRate im
        ]
        ++
        optionalCompression (compression im)
    )

optionalSettings :: T.Text -> Int -> Maybe OptionalSetting -> Maybe A.Pair
optionalSettings _ _ Nothing                = Nothing
optionalSettings name def (Just Disabled)   = Just (name, A.toJSON def)
optionalSettings name _ (Just (Custom val)) = Just (name, A.toJSON val)

optionalCompression :: Maybe Compression -> [Maybe A.Pair]
optionalCompression Nothing              = []
optionalCompression (Just NoCompression) = Just `fmap` [ "snappy" .= False, "deflate" .= False ]
optionalCompression (Just Snappy)        = Just `fmap` [ "snappy" .= True, "deflate" .= False ]
optionalCompression (Just (Deflate l))   = Just `fmap` [ "snappy" .= False, "deflate" .= True, "deflate_level" .= l ]

customMetadata :: Maybe (Map.Map T.Text T.Text) -> [A.Pair]
customMetadata Nothing    = []
customMetadata (Just val) = Map.foldrWithKey (\k v xs -> (k .= v):xs) [] val

instance A.ToJSON TLS where
    toJSON NoTLS = A.Bool False
    toJSON TLSV1 = A.Bool True

instance A.ToJSON IdentifyMetadata where
    toJSON im@(IdentifyMetadata{ident=i}) = A.object
        (
            -- Identification section
            [ "client_id"  .= clientId i
            , "hostname"   .= hostname i
            , "short_id"   .= fromMaybe (clientId i) (shortId i)
            , "long_id"    .= fromMaybe (hostname i) (longId i)
            , "user_agent" .= fromMaybe defaultUserAgent (userAgent i)

            -- Feature Negotiation section
            , "feature_negotiation" .= (not (null $ featureNegotiation im) || customNegotiation im)
            ]
            ++
            featureNegotiation im
            ++
            customMetadata (custom im)
        )


decode :: BS.ByteString -> Maybe Message
decode str = case parseOnly message str of
    Left _ -> Nothing
    Right r -> Just r

-- TODO: this won't work for streaming the data...
--  Should provide two api, one for in memory (ie where we count up the length of the data manualy
--  And a "streaming" version in which we know the actual size before streaming (ie streaming from a file for ex)
sizedData :: BS.ByteString -> BL.Builder
sizedData dat = BL.word32BE (fromIntegral $ BS.length dat) <> BL.byteString dat


-- Body of a foldl to build up a sequence of concat sized data
concatSizedData :: (Word32, Word32, BL.Builder) -> BS.ByteString -> (Word32, Word32, BL.Builder)
concatSizedData (totalSize, count, xs) dat = (
        totalSize + 4 + fromIntegral (BS.length dat), -- Add 4 to accord for message size
        count + 1,
        xs <> sizedData dat
    )

-- Reply
encode :: Command -> BS.ByteString
encode Protocol     = "  V2"
encode NOP          = "NOP\n"
encode Cls          = "CLS\n"
encode (Identify identify) = BL.toStrict $ BL.toLazyByteString (
        BL.byteString "IDENTIFY\n" <>
        sizedData (BL.toStrict $ A.encode identify)
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



-- TODO convert "E_*" into Error
command :: BS.ByteString -> Message
command "_heartbeat_" = Heartbeat
command "OK" = OK
command "CLOSE_WAIT" = CloseWait
command x = CatchAllMessage (FTUnknown 99) x -- TODO: Better FrameType


frameType :: Int32 -> FrameType
frameType 0 = FTResponse
frameType 1 = FTError
frameType 2 = FTMessage
frameType x = FTUnknown x





-- TODO: do sanity check such as checking that the size is of a minimal
-- size, then parsing the frameType, then the remainder (fail "messg")
message :: Parser Message
message = do
    size <- fromIntegral <$> anyWord32be
    ft <- frameType <$> fromIntegral <$> anyWord32be
    frame ft (size - 4) -- Taking in accord the frameType


frame :: FrameType -> Int -> Parser Message
frame FTError    size = Error <$> take size
frame FTResponse size = command <$> take size
frame FTMessage  size = Message
    <$> (fromIntegral <$> anyWord64be)
    <*> anyWord16be
    -- 16 bytes message id
    <*> take 16
    -- Taking in accord timestamp/attempts/msgid
    <*> take (size - 26)
frame ft size = CatchAllMessage ft <$> take size
