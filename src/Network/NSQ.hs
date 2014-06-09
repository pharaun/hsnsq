{-# LANGUAGE OverloadedStrings #-}
module Network.NSQ
    ( message
    , decode
    , encode

    , Message(..)
    , Command(..)

    , OptionalSetting(..)
    , TLS(..)
    , Compression(..)
    , Identification(..)
    , IdentifyMetadata(..)
    , defaultIdentify

    ) where

import Data.Monoid
import Data.Char
import Data.Maybe
import Data.Word
import qualified Data.List as DL
import Prelude hiding (take)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as C8
import qualified Data.ByteString.Lazy as BL
import qualified Data.ByteString.Lazy.Builder as BL
import qualified Data.Map.Strict as Map
import qualified Data.Text as T
import qualified Data.Text.Encoding as T

import Control.Applicative
import Control.Monad
import Data.Attoparsec.Binary
import Data.Attoparsec.ByteString

import Data.Aeson ((.=))
import qualified Data.Aeson as A
import qualified Data.Aeson.Types as A

import Debug.Trace

-- NSQ Command
data Command = Protocol
             | NOP
             | Identify IdentifyMetadata
             | Sub T.Text T.Text Bool -- Topic, Channel, Ephemeral
             | Pub T.Text BS.ByteString -- Topic, data
             | MPub T.Text [BS.ByteString] -- Topic, multi-data

             -- Catch-all command to server
             | Command BS.ByteString
             deriving Show


-- NSQ Message from server
data Message = Heartbeat
             | OK

             -- Catch-all (reply from server) (This currently include the reply from identification)
             | Message BS.ByteString
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
name .?= Nothing  = Nothing
name .?= Just val = Just (name, A.toJSON val)


featureNegotiation :: IdentifyMetadata -> [A.Pair]
featureNegotiation im = catMaybes
    (
        [ "tls_v1" .?= (tls im) -- TODO: not very good, what if there's other version of tls
        , (optionalSettings "heartbeat_interval" (-1) $ heartbeatInterval im)
        , (optionalSettings "output_buffer_size" (-1) $ outputBufferSize im)
        , (optionalSettings "output_buffer_timeout" (-1) $ outputBufferTimeout im)
        , (optionalSettings "sample_rate" 0 $ sampleRate im)
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
    toJSON im@(IdentifyMetadata{ident=ident}) = A.object
        (
            -- Identification section
            [ "client_id"  .= (clientId ident)
            , "hostname"   .= (hostname ident)
            , "short_id"   .= (fromMaybe (clientId ident) (shortId ident))
            , "long_id"    .= (fromMaybe (hostname ident) (longId ident))
            , "user_agent" .= (fromMaybe defaultUserAgent (userAgent ident))

            -- Feature Negotiation section
            , "feature_negotiation" .= ((not $ null $ featureNegotiation im) || (customNegotiation im))
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
sizedData dat = (BL.word32BE $ fromIntegral $ BS.length $ dat) <> (BL.byteString dat)


-- Body of a foldl to build up a sequence of concat sized data
concatSizedData :: (Word32, Word32, BL.Builder) -> BS.ByteString -> (Word32, Word32, BL.Builder)
concatSizedData (totalSize, count, xs) dat = (
        (totalSize + 4 + (fromIntegral $ BS.length dat)), -- Add 4 to accord for message size
        (count + 1),
        (xs <> sizedData dat)
    )

-- Reply
encode :: Command -> BS.ByteString
encode Protocol     = "  V2"
encode NOP          = "NOP\n"
encode (Identify ident) = BL.toStrict $ BL.toLazyByteString (
        (BL.byteString "IDENTIFY\n") <>
        (sizedData $ BL.toStrict $ A.encode ident)
    )
encode (Sub topic channel ephemeral) = T.encodeUtf8 $ T.concat [ "SUB ", topic, " ", channel, if ephemeral then "#ephemeral" else "", "\n"]
encode (Pub topic dat) = BL.toStrict $ BL.toLazyByteString (
        (BL.byteString "PUB ") <>
        (BL.byteString $ T.encodeUtf8 topic) <>
        (BL.byteString "\n") <>
        (sizedData dat)
    )
encode (MPub topic dx) = BL.toStrict $ BL.toLazyByteString (
        (BL.byteString "MPUB ") <>
        (BL.byteString $ T.encodeUtf8 topic) <>
        (BL.byteString "\n") <>
        (BL.word32BE $ totalSize + 4) <> -- Accord for message count
        (BL.word32BE $ totalCount) <>
        content
    )
    where
        (totalSize, totalCount, content) = DL.foldl' concatSizedData (0, 0, mempty) dx

encode (Command m)  = m



-- TODO convert "E_*" into Error
command :: BS.ByteString -> Message
command "_heartbeat_" = Heartbeat
command "OK" = OK
command x = Message x


message :: Parser Message
message = do
    size <- anyWord32be
    frameType <- anyWord32be
    mesg <- take $ (fromIntegral size) - 4 -- This is -4 because size refers to the rest of the message, not the message itself.

    return $ traceShow size $ traceShow frameType $ command mesg
