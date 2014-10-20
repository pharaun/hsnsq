{-# LANGUAGE OverloadedStrings #-}
{-|
Module      : Network.NSQ.Identify
Description : The metadata component for formatting and parsing the metadata sent to nsqd as part of the feature negotiation done upon connection establish.
-}
module Network.NSQ.Identify
    ( defaultIdentify
    , defaultUserAgent
    , encodeMetadata

    ) where

import Prelude hiding (take)
import Data.Maybe

import qualified Data.Map.Strict as Map

import qualified Data.ByteString.Lazy as BL

import qualified Data.Text as T

import Data.Aeson ((.=))
import qualified Data.Aeson as A
import qualified Data.Aeson.Types as A

import Network.NSQ.Types

-- | Build a default 'IdentifyMetadata' that makes sense which is
-- basically just setting the client 'Identification' and leaving
-- the rest of the settings up to the server to determine.
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

-- | The default user agent to send, for identifying what client library is
-- connecting to the nsqd.
defaultUserAgent :: T.Text
defaultUserAgent = "hsnsq/0.1.2.0" -- TODO: find out how to identify this in the build step

-- | Generate a collection of Aeson pairs to insert into the json
-- that is being sent to the server as part of the metadata negotiation.
featureNegotiation :: IdentifyMetadata -> [A.Pair]
featureNegotiation im = catMaybes
    (
        tlsSettings (tls im)
        ++
        [ optionalSettings "heartbeat_interval" (-1) $ heartbeatInterval im
        , optionalSettings "output_buffer_size" (-1) $ outputBufferSize im
        , optionalSettings "output_buffer_timeout" (-1) $ outputBufferTimeout im
        , optionalSettings "sample_rate" 0 $ sampleRate im
        ]
        ++
        optionalCompression (compression im)
    )

-- | Take an optional setting and render an Aeson pair.
optionalSettings :: T.Text -> Int -> Maybe OptionalSetting -> Maybe A.Pair
optionalSettings _ _ Nothing                = Nothing
optionalSettings name def (Just Disabled)   = Just (name, A.toJSON def)
optionalSettings name _ (Just (Custom val)) = Just (name, A.toJSON val)

-- | Render the Aeson pairs for optional compression
optionalCompression :: Maybe Compression -> [Maybe A.Pair]
optionalCompression Nothing              = []
optionalCompression (Just NoCompression) = Just `fmap` [ "snappy" .= False, "deflate" .= False ]
optionalCompression (Just Snappy)        = Just `fmap` [ "snappy" .= True, "deflate" .= False ]
optionalCompression (Just (Deflate l))   = Just `fmap` [ "snappy" .= False, "deflate" .= True, "deflate_level" .= l ]

-- | Take the custom settings out of the custom map and render Aeson pairs
customMetadata :: Maybe (Map.Map T.Text T.Text) -> [A.Pair]
customMetadata Nothing    = []
customMetadata (Just val) = Map.foldrWithKey (\k v xs -> (k .= v):xs) [] val

-- | Tls settings
tlsSettings :: Maybe TLS -> [Maybe A.Pair]
tlsSettings Nothing      = []
tlsSettings (Just NoTLS) = [Just $ "tls_v1" .= False]
tlsSettings (Just TLSV1) = [Just $ "tls_v1" .= True]

-- TODO: This is an Orphan instance because the type is in types.hs, need to fix this
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

-- | Encode the metadata from 'IdentifyMetadata' into a 'ByteString' for
-- feeding the 'Identify' 'Command' for sending the metadata to the nsq
-- daemon as part of the feature negotiation.
encodeMetadata :: IdentifyMetadata -> BL.ByteString
encodeMetadata = A.encode
