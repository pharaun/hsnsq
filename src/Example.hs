{-# LANGUAGE OverloadedStrings #-}
import Network.NSQ.Types
import Network.NSQ.Connection

import Control.Applicative
import Control.Concurrent.Async
import Control.Concurrent.STM
import Control.Concurrent.STM.TVar
import Control.Monad

-- Logger
import System.IO (stderr, Handle)
import System.Log.Logger (rootLoggerName, setHandlers, updateGlobalLogger, Priority(DEBUG, EMERGENCY), setLevel, infoM)
import System.Log.Handler.Simple (streamHandler, GenericHandler)
import System.Log.Handler (setFormatter)
import System.Log.Formatter

-- Benchmark generation
import Options.Applicative
import Network


main :: IO ()
main = do
    settings <- execParser opts

    -- Logger stuff
    stream <- withFormatter <$> streamHandler stderr DEBUG
    let loggerName = rootLoggerName

    updateGlobalLogger loggerName (setLevel EMERGENCY)
    updateGlobalLogger loggerName (setHandlers [stream])

    -- Reader thread to die
    die <- newTVarIO False

    -- Start up the producer to spam messages
    producer <- async (prod settings die)
    consumer <- async (cons settings die)
    waitBoth producer consumer
    return ()

  where
      opts = info (helper <*> config)
            (  fullDesc
            <> progDesc "Execute a benchmark against nsq at a given settings"
            <> header "nsq-example - An benchmark example using the hsnsq library" )

prod :: Config -> TVar Bool -> IO ()
prod s d = do
    -- Create a channel to pump data into
    conf <- defaultConfig $ sHostname s
    let conf' = conf{ port = sPort s }

    -- Queue
    topicQueue <- newTQueueIO
    replyQueue <- newTQueueIO

    -- TODO: ahead of time generate some bulk message and strictify it for
    -- consumption

    -- Connect and start producing stuff
    race_
        (establish conf' topicQueue replyQueue)
        (generateMessages s d topicQueue replyQueue)

cons :: Config -> TVar Bool -> IO ()
cons s d = do
    -- Create a channel to pump data into
    conf <- defaultConfig $ sHostname s
    let conf' = conf{ port = sPort s }

    -- Queue
    topicQueue <- newTQueueIO
    replyQueue <- newTQueueIO

    -- Inject the channel + rdy
    atomically $ do
        writeTQueue replyQueue $ Sub "benchmark" "anauria" True
        writeTQueue replyQueue $ Rdy (fromInteger $ sRdyNum s)

    -- Connect
    race_
        (establish conf' topicQueue replyQueue)
        (consumeMessages s d topicQueue replyQueue)

--data Config = Config
--    { hostname :: String
--    , port :: PortNumber
--    , count :: Integer
--    , rate :: Integer
--    , size :: Integer
--    , rdyNum :: Integer
--    }
consumeMessages :: Config -> TVar Bool -> TQueue Message -> TQueue Command -> IO ()
consumeMessages s d q r = forever $ do
    msg <- atomically (do
        m <- readTQueue q
        -- Process data here

        -- TODO: Unsafe, assumes it only get Messages (true as of current implementation, but still unsafe)
        writeTQueue r $ Fin $ mId m
        writeTQueue r $ Rdy 1
        return m)
    infoM "Client.Consume" (show msg)

    where
        mId (Message _ _ mesgId _) = mesgId

--data Config = Config
--    { hostname :: String
--    , port :: PortNumber
--    , count :: Integer
--    , rate :: Integer
--    , size :: Integer
--    , rdyNum :: Integer
--    }
generateMessages :: Config -> TVar Bool -> TQueue Message -> TQueue Command -> IO ()
generateMessages s d q r = undefined



withFormatter :: GenericHandler Handle -> GenericHandler Handle
withFormatter handler = setFormatter handler formatter
    where formatter = simpleLogFormatter "[$time $loggername $prio] $msg"

--
--1) hostname/ip to connect to for nsq
--2) port to connect to for nsq
--3) count of messages to send
--4) send-rate in msg/sec
--5) message size in kilobytes (min of 1-4kb)
--6) RDY size (we are doing 1 for now but should be able to bump this up)
--
data Config = Config
    { sHostname :: String
    , sPort :: PortNumber
    , sCount :: Integer
    , sRate :: Integer
    , sSize :: Integer
    , sRdyNum :: Integer
    }

config :: Parser Config
config = Config
    <$> option str
        (  long "hostname"
        <> short 'h'
        <> value "66.175.216.197"
        <> showDefaultWith id
        <> help "Hostname for nsq instance" )
    <*> (fromInteger <$> option auto
        (  long "port"
        <> short 'p'
        <> value 4150
        <> showDefaultWith show
        <> help "Port for nsq instance" ))
    <*> option auto
        (  long "count"
        <> short 'c'
        <> value 200
        <> showDefaultWith show
        <> help "Number of message to send before quitting" )
    <*> option auto
        (  long "rate"
        <> short 'r'
        <> value 20
        <> showDefaultWith show
        <> help "Rate of sending messages x/sec" )
    <*> option auto
        (  long "size"
        <> short 's'
        <> value 4
        <> showDefaultWith show
        <> help "Size of messages in kilobytes" )
    <*> option auto
        (  long "rdy"
        <> short 'y'
        <> value 1
        <> showDefaultWith show
        <> help "Number of rdy message to have in flight" )
