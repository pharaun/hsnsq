{-# LANGUAGE OverloadedStrings #-}
module Network.NSQ.Connection
    ( establish

    ) where

import Control.Monad.Reader
import Control.Monad.Trans.State.Strict
import Data.List
import Data.Maybe
import Network
import Prelude hiding (log)
import System.IO
import System.Time

import qualified Data.ByteString as BS
import qualified Data.ByteString.Char8 as C8

import qualified Pipes.Network.TCP as PNT
import qualified Pipes.Attoparsec as PA
import qualified Pipes.Prelude as PP
import Pipes

import Control.Applicative
import Control.Concurrent.Async
import Control.Concurrent.STM
import Control.Concurrent.STM.TQueue

import System.Log.Logger (debugM, errorM)

import qualified Network.NSQ as NSQ
import Network.NSQ.Types

--
-- Establish a session with this server
--
-- Detail:
--  * Support connecting to a particular nsqd and doing the needful to establish identification and so forth
--  * Auto-handle heartbeat and all related stuff
--  * A higher layer will handle the message reading/balancing between multiplex nsqd connection for a particular topic/channel
--
establish :: ConnectionConfig -> IO ()
establish sc = PNT.withSocketsDo $
    -- Establish stocket
    PNT.connect (server sc) (show $ port sc) (\(sock, _) -> do

        -- TODO: maybe consider PNT.fromSocketN so that we can adjust fetch size if needed downstream
        let send = (log "send" $ logName sc) >-> PNT.toSocket sock
        race_
            (handleNSQ (PNT.fromSocket sock 8192 >-> (log "recv" $ logName sc)) send (ConnectionState sc))
            (runEffect $ handleReply (replyQueue sc) >-> showCommand >-> send)

        return ()
    )

--
-- The NSQ handler and protocol
--
handleNSQ :: (Monad m, MonadIO m) => Producer BS.ByteString m () -> Consumer BS.ByteString m () -> ConnectionState -> m ()
handleNSQ recv send ss = do
    -- Initial connection
    runEffect $ handshake ss >-> showCommand >-> send

    -- Regular nsq streaming
    runEffect $ (nsqParserErrorLogging (logName $ config ss) recv) >-> (command ss) >-> showCommand >-> send

    return ()

--
-- NSQ Reply handler
--
-- TODO: extend this to handle the rest of the interaction maybe? Or should
-- only be for external commands, that way we can have priority (internal
-- commands like nop gets priority over client commands?)
--
handleReply :: (Monad m, MonadIO m) => TQueue Command -> Producer NSQ.Command m ()
handleReply queue = forever $ do
    cmd <- liftIO $ atomically $ readTQueue queue
    yield cmd

--
-- Parses incoming nsq messages and emits any errors to a log and keep going
--
nsqParserErrorLogging :: MonadIO m => LogName -> Producer BS.ByteString m () -> Producer NSQ.Message m ()
nsqParserErrorLogging l producer = do
    (result, rest) <- lift $ runStateT (PA.parse NSQ.message) producer

    case result of
        Nothing -> liftIO $ errorM l "Pipe is exhausted for nsq parser\n"
        Just y  -> do
            case y of
                Right x -> (liftIO $ debugM l ("msg: " ++ show x)) >> yield x
                Left x  -> liftIO $ errorM l (show x)
            nsqParserErrorLogging l rest

--
-- Format outbound NSQ Commands
--
showCommand :: Monad m => Pipe NSQ.Command BS.ByteString m ()
showCommand = PP.map encode
    where
        encode = NSQ.encode

--
-- Handshake for the initial connection to the network
--
handshake :: Monad m => ConnectionState -> Producer NSQ.Command m ()
handshake ss = do

    yield $ NSQ.Protocol
    yield $ NSQ.Identify $ (NSQ.defaultIdentify "pharaun-ASDF" "netheril.elder.lan."){NSQ.heartbeatInterval = Just $ NSQ.Custom 1000}

    -- sub to a channel
    yield $ NSQ.Sub "glc-gamestate" "netheril.elder.lan." False

    -- Publish
    yield $ NSQ.Pub "glc-gamestate" "{}"

    yield $ NSQ.MPub "glc-gamestate" ["{}", "{}", "{}"]

    -- Open floodgate for 1 msg at a time
    yield $ NSQ.Rdy 1

    return ()

--
-- Log anything that passes through this stream to a logfile
--
log :: MonadIO m => String -> LogName -> Pipe BS.ByteString BS.ByteString m r
log w l = forever $ do
    x <- await
    liftIO $ debugM l (w ++ ": " ++ show x) -- TODO: need a better way to log raw protocol messages
    yield x

--
-- Do something with the inbound message
--
command :: (Monad m, MonadIO m) => ConnectionState -> Pipe NSQ.Message NSQ.Command m ()
command ss = forever $ do
    msg <- await

    case msg of
        NSQ.Heartbeat         -> yield $ NSQ.NOP
        NSQ.Message _ _ mId _ -> do
            liftIO $ atomically $ writeTQueue (topicQueue $ config ss) msg
            --yield $ NSQ.Rdy 1

        otherwise             -> return ()

--             | Fin MsgId
--             | Req MsgId Word64 -- msgid, timeout
--             | Touch MsgId
--             | Cls
