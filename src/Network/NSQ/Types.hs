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
import System.IO

import qualified Data.ByteString as BS
import qualified Data.Map.Strict as Map
import qualified Data.Text as T
import Control.Concurrent.STM.TQueue (TQueue)

-- High level arch:
--  * One queue per topic/channel
--  * This queue can be feed by multiple nsqd (load balanced/nsqlookup for ex)
--  * Probably will have one set of state/config per nsqd connection and per queue/topic/channel
--  * Can probably later on provide helpers for consuming the queue


-- | Per Connection configuration
--  * Per nsqd (connection) state (rdy, load balance, etc)
--  * Per topic state (channel related info and which nsqd connection)
--  * Global? state (do we have any atm? maybe configuration?)
-- TODO: consider using monad-journal logger for pure code tracing
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
