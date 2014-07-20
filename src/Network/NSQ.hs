{-|
Module      : Network.NSQ
Description : Protocol/parser layer for the NSQ client library.
Copyright   : (c) Paul Berens, 2014
License     : Apache 2.0
Maintainer  : berens.paul@gmail.com
Stability   : experimental
Portability : unknown

This is a haskell client for the <http://nsq.io/ NSQ> message queue service.

TODO:

    * Start implementing a more through client

    * Write some form of tests

    * More through docs, the initial docs sucks.
-}
module Network.NSQ
    ( MsgId
    , Topic
    , Channel

    , Message(..)
    , Command(..)

    , FrameType(..)
    , ErrorType(..)

    , OptionalSetting(..)
    , TLS(..)
    , Compression(..)
    , Identification(..)
    , IdentifyMetadata(..)

    , NSQConnection(..)

    -- Parser
    , message
    , decode
    , encode

    -- Identify
    , defaultIdentify
    , defaultUserAgent
    , encodeMetadata

    -- Connection
    , defaultConfig
    , establish
    ) where

import Network.NSQ.Types
import Network.NSQ.Parser
import Network.NSQ.Identify
import Network.NSQ.Connection
