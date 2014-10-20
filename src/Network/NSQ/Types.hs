{-|
Module      : Network.NSQ.Types
Description : Not much to see here, just the types for the library.
-}
module Network.NSQ.Types
    ( MsgId
    , Topic
    , Channel
    , LogName

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

    -- Connection config/state
    , NSQConnection(..)

    ) where

import Data.Int
import Data.Word
import Network

import qualified Data.ByteString as BS
import qualified Data.Map.Strict as Map
import qualified Data.Text as T

-- High level arch:
--  * One queue per topic/channel
--  * This queue can be feed by multiple nsqd (load balanced/nsqlookup for ex)
--  * Probably will have one set of state/config per nsqd connection and per queue/topic/channel
--  * Can probably later on provide helpers for consuming the queue


-- TODO: consider using monad-journal logger for pure code tracing
-- | Per Connection configuration such as: per nsqd state (rdy, load balance), per topic state (channel)
data NSQConnection = NSQConnection
    { server :: String
    , port :: PortNumber
    , logName :: LogName

    , identConf :: IdentifyMetadata
    }

-- | Logger Name for a connection (hslogger format)
type LogName = String

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
data ErrorType = Invalid -- ^ Something went wrong with the command (IDENTIFY, SUB, PUB, MPUB, RDY, FIN, REQ, TOUCH, CLS)
               | BadBody -- ^ Bad Body (IDENTIFY, MPUB)
               | BadTopic -- ^ Bad Topic (most likely used disallowed characters) (SUB, PUB, MPUB)
               | BadChannel -- ^ Bad channel (Like 'BadTopic' probably used an disallowed character) (SUB)
               | BadMessage -- ^ Bad Message (PUB, MPUB)
               | PubFailed -- ^ Publishing a message failed (PUB)
               | MPubFailed -- ^ Same as 'PubFailed' (MPUB)
               | FinFailed -- ^ Finish failed (Probably already finished or non-existant message-id) (FIN)
               | ReqFailed -- ^ Requeue failed (REQ)
               | TouchFailed -- ^ Touch failed (TOUCH)
               | Unknown BS.ByteString -- ^ New unknown type of error (ANY)
               deriving Show

-- | The message and replies back from the server.
data Message = OK -- ^ Everything is allright.
             | Heartbeat -- ^ Heartbeat, reply with the 'NOP' 'Command'.
             | CloseWait -- ^ Server has closed the connection.
             | Error ErrorType -- ^ The server sent back an error.

             | Message Int64 Word16 MsgId BS.ByteString -- ^ A message to be processed. The values are: Nanosecond Timestamp, number of attempts, Message Id, and the content of the message to be processed.

             | CatchAllMessage FrameType BS.ByteString -- ^ Catch-all message for future expansion. This currently includes the reply from 'Identify' if feature negotiation is set.
             deriving Show


-- | Optional settings, if 'Disabled' then this setting will be put in the
-- json as disabled specifically vs "not being listed".
data OptionalSetting = Disabled | Custom Word64
    deriving Show

-- | TLS version supported
data TLS = NoTLS | TLSV1
    deriving Show

-- | For 'Deflate' its the compression level from 0-9
data Compression = NoCompression | Snappy | Deflate Word8
    deriving Show

-- | The client identification
data Identification = Identification
    { clientId :: T.Text -- ^ An identifier of this consumer, something specific to this consumer
    , hostname :: T.Text -- ^ Hostname of the machine the client is running on
    , shortId :: Maybe T.Text -- ^ Deprecated in favor of client_id
    , longId :: Maybe T.Text -- ^ Deprecated in favor of hostname
    , userAgent :: Maybe T.Text -- ^ Default (client_library_name/version)
    }
    deriving Show

-- | Metadata for feature negotiation, if any of the values
-- are set it will be sent to the server otherwise they will be omitted.
-- If the setting is set to 'Nothing' it will not be sent to the server,
-- and if its set to 'Just' 'Disabled' it will be sent to the server as
-- disabled explicitly.
data IdentifyMetadata = IdentifyMetadata
    { ident :: Identification -- ^ Client identification
    , tls :: Maybe TLS -- ^ TLS
    , compression :: Maybe Compression -- ^ Compression
    , heartbeatInterval :: Maybe OptionalSetting -- ^ The time between each heartbeat (disabled = -1)
    , outputBufferSize :: Maybe OptionalSetting -- ^ The size of the buffer (disabled = -1)
    , outputBufferTimeout :: Maybe OptionalSetting -- ^ The timeout for the buffer (disabled = -1)
    , sampleRate :: Maybe OptionalSetting -- ^ Sampling of the message will be sent to the client (disabled = 0)
    , custom :: Maybe (Map.Map T.Text T.Text) -- ^ Map of possible key -> value for future protocol expansion
    , customNegotiation :: Bool -- ^ Set if there are any 'custom' values to send
    }
    deriving Show
