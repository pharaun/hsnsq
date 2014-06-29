{-# LANGUAGE OverloadedStrings #-}
import Data.List
import Data.Maybe
import System.IO

import qualified Data.ByteString as BS
import qualified Pipes.Network.TCP as PNT
import qualified Pipes.Attoparsec as PA
import qualified Pipes.Prelude as PP
import Pipes
import Control.Applicative

import Network.NSQ.Types
import Network.NSQ.Connection

import System.IO (stderr)
import System.Log.Logger (rootLoggerName, setHandlers, updateGlobalLogger, Priority(DEBUG), setLevel)
import System.Log.Handler.Simple (streamHandler, GenericHandler)
import System.Log.Handler (setFormatter)
import System.Log.Formatter


withFormatter :: GenericHandler Handle -> GenericHandler Handle
withFormatter handler = setFormatter handler formatter
    where formatter = simpleLogFormatter "[$time $loggername $prio] $msg"

main = do
    stream <- withFormatter <$> streamHandler stderr DEBUG
    let log = rootLoggerName

    updateGlobalLogger log (setLevel DEBUG)
    updateGlobalLogger log (setHandlers [stream])

    -- Connect
    establish testConfig


testConfig :: ConnectionConfig
testConfig = ConnectionConfig "66.175.216.197" 4150 "NSQ.GameLost" -- TODO: standardize on some sort of logger hierchary (nsq server/topic?)






--
-- State:
--  * Per nsqd (connection) state (rdy, load balance, etc)
--  * Per topic state (channel related info and which nsqd connection)
--  * Global? state (do we have any atm? maybe configuration?)
--


--
-- High level arch:
--  * One queue per topic/channel
--  * This queue can be feed by multiple nsqd (load balanced/nsqlookup for ex)
--  * Probably will have one set of state/config per nsqd connection and per queue/topic/channel
--  * Can probably later on provide helpers for consuming the queue
--
-- Detail:
--  * Support connecting to a particular nsqd and doing the needful to
--  establish identification and so forth
--  * Auto-handle heartbeat and all related stuff
--  * A higher layer will handle the message reading/balancing between multiplex nsqd connection for a particular topic/channel
--
-- Note:
--  * One sub (topic/channel) per nsqd connection max, any more will get an E_INVALID
--  * Seems to be able to publish to any topic/channel without limitation
--
