module Network.NSQ
    ( message
    , decode
    , encode

    , Message(..)
    ) where

import Data.Char
import Data.Word
import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as C8

import Control.Monad
import Control.Applicative
import Data.Attoparsec.ByteString

-- Data of a NSQ message
data Message = Identifier
             | Error BS.ByteString
             | Message BS.ByteString

decode :: BS.ByteString -> Maybe Message
decode str = case parseOnly message str of
    Left _ -> Nothing
    Right r -> Just r

encode :: Message -> BS.ByteString
encode (Identifier) = C8.pack "  V2" -- Handshake
encode (Message _)  = undefined

message :: Parser Message
message = undefined
