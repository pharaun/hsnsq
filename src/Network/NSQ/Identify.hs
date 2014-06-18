{-# LANGUAGE OverloadedStrings #-}
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

encodeMetadata :: IdentifyMetadata -> BL.ByteString
encodeMetadata = A.encode
