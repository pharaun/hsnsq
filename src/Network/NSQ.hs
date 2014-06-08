{-# LANGUAGE OverloadedStrings #-}
module Network.NSQ
    ( message
    , decode
    , encode

    , Message(..)
    , Command(..)
    ) where

import Prelude hiding (take)
import Data.Char
import Data.Word
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as C8

import Control.Monad
import Control.Applicative
import Data.Attoparsec.ByteString
import Data.Attoparsec.Binary

-- NSQ Command
data Command = Protocol
             | NOP

             -- Catch-all command to server
             | Command BS.ByteString
             deriving Show


-- NSQ Message from server
data Message = Heartbeat

             -- Catch-all (reply from server)
             | Message BS.ByteString
             deriving Show


decode :: BS.ByteString -> Maybe Message
decode str = case parseOnly message str of
    Left _ -> Nothing
    Right r -> Just r


-- Reply
encode :: Command -> BS.ByteString
encode Protocol    = "  V2"
encode NOP         = "NOP\n"
encode (Command m) = m



command :: BS.ByteString -> Message
command "_heartbeat_" = Heartbeat
command x = Message x


message :: Parser Message
message = do
    size <- anyWord32be
    frameType <- anyWord32be
    mesg <- take $ (fromIntegral size) - 4 -- This is -4 because size refers to the rest of the message, not the message itself.

    return $ command mesg
