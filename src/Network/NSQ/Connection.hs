{-# LANGUAGE OverloadedStrings #-}
module Network.NSQ.Connection
    ( defaultConfig
    , establish

    ) where

import Control.Monad.Reader
import Control.Monad.Trans.State.Strict
import Data.List
import Data.Maybe
import Network
import Prelude hiding (log)
import System.IO
import System.Time
import Network.HostName

import qualified Data.Text as T
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
-- Default Config
--
-- TODO: standardize on some sort of logger hierchary (nsq server/topic?)
-- NSQ.[subsystem].[topic].[connection] - message
-- NSQ.[subsystem].[custom] ....
--
defaultConfig :: String -> IO NSQConnection
defaultConfig server = do
    hostname <- T.pack <$> getHostName
    let clientId = T.takeWhile (/= '.') hostname
    let ident = NSQ.defaultIdentify clientId hostname

    return $ NSQConnection server 4150 "NSQ.Connection." ident

--
-- Establish a session with this server
--
-- Detail:
--  * Support connecting to a particular nsqd and doing the needful to establish identification and so forth
--  * Auto-handle heartbeat and all related stuff
--  * A higher layer will handle the message reading/balancing between multiplex nsqd connection for a particular topic/channel
--
establish :: NSQConnection -> TQueue Message -> TQueue Command -> IO ()
establish conn topicQueue reply = PNT.withSocketsDo $
    -- Establish stocket
    PNT.connect (server conn) (show $ port conn) (\(sock, _) -> do

        -- TODO: maybe consider PNT.fromSocketN so that we can adjust fetch size if needed downstream
        let send = (log "send" $ logName conn) >-> PNT.toSocket sock
        let recv = PNT.fromSocket sock 8192 >-> (log "recv" $ logName conn)
        race_
            (handleNSQ conn recv send topicQueue)
            (runEffect $ handleReply reply >-> showCommand >-> send) -- Handles user replies
    )

--
-- NSQ Reply handler
--
handleReply :: (Monad m, MonadIO m) => TQueue Command -> Producer NSQ.Command m ()
handleReply queue = forever $ do
    cmd <- liftIO $ atomically $ readTQueue queue
    yield cmd

--
-- The NSQ handler and protocol
--
handleNSQ :: (Monad m, MonadIO m) => NSQConnection -> Producer BS.ByteString m () -> Consumer BS.ByteString m () -> TQueue Message -> m ()
handleNSQ sc recv send topicQueue = do
    -- Initial handshake to kick off the handshake
    runEffect $ (initialHandshake $ identConf sc) >-> showCommand >-> send

    -- Rest of the handshake process (parsing and dealing with identification)
    runEffect $ (nsqParserErrorLogging (logName sc) recv) >-> identReply sc

    -- Setup the topic/channel/rdy
    runEffect $ setupTopic >-> showCommand >-> send

    -- Regular nsq streaming
    runEffect $ (nsqParserErrorLogging (logName sc) recv) >-> (command topicQueue) >-> showCommand >-> send

    return ()

    where
        -- Initial Handshake
        initialHandshake im = do
            yield $ NSQ.Protocol
            yield $ NSQ.Identify im
            return ()

        -- TODO; replace it with actual logic
        setupTopic = do
            yield $ NSQ.Sub "glc-gamestate" "netheril.elder.lan." False
            yield $ NSQ.Rdy 1
            return ()

        -- Process the ident reply
        identReply sc = do
            ident <- await

            -- TODO: do stuff with it
            liftIO $ debugM (logName sc) ("IDENT: " ++ show ident)

            return ()

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
showCommand = PP.map NSQ.encode

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
command :: (Monad m, MonadIO m) => TQueue Message -> Pipe NSQ.Message NSQ.Command m ()
command topicQueue = forever $ do
    msg <- await

    case msg of
        NSQ.Heartbeat         -> yield $ NSQ.NOP
        NSQ.Message _ _ mId _ -> do
            liftIO $ atomically $ writeTQueue topicQueue msg

        otherwise             -> return ()
