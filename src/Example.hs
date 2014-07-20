{-# LANGUAGE OverloadedStrings #-}
import Network.NSQ.Types
import Network.NSQ.Connection

import Control.Concurrent.STM
import Control.Monad
import Control.Concurrent.Async
import Control.Applicative

-- Logger
import System.IO (stderr, Handle)
import System.Log.Logger (rootLoggerName, setHandlers, updateGlobalLogger, Priority(DEBUG), setLevel, infoM)
import System.Log.Handler.Simple (streamHandler, GenericHandler)
import System.Log.Handler (setFormatter)
import System.Log.Formatter


main = do
    -- Logger stuff
    stream <- withFormatter <$> streamHandler stderr DEBUG
    let loggerName = rootLoggerName

    updateGlobalLogger loggerName (setLevel DEBUG)
    updateGlobalLogger loggerName (setHandlers [stream])

    -- Create a channel to pump data into
    conf <- defaultConfig "66.175.216.197"
    topicQueue <- newTQueueIO
    replyQueue <- newTQueueIO

    -- Connect
    race_
        (establish conf topicQueue replyQueue)
        (consumeMessages topicQueue replyQueue)


consumeMessages :: TQueue Message -> TQueue Command -> IO ()
consumeMessages q r = forever $ do
    msg <- atomically (do
        m <- readTQueue q
        -- Process data here

        -- TODO: Unsafe, assumes it only get Messages (true as of current implementation, but still unsafe)
        writeTQueue r $ Fin $ mId m
        return m)
    infoM "Client.Consume" (show msg)

    where
        mId (Message _ _ mesgId _) = mesgId


withFormatter :: GenericHandler Handle -> GenericHandler Handle
withFormatter handler = setFormatter handler formatter
    where formatter = simpleLogFormatter "[$time $loggername $prio] $msg"
