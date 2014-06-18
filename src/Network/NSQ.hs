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

import Network.NSQ.Types
import Network.NSQ.Parser
import Network.NSQ.Identify
