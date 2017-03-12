{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE DataKinds #-}
{-|
Collections of different handler for use with MonadLog
-}
module Control.Monad.Log.Handler where

import Data.List.NonEmpty (NonEmpty)
import qualified Data.List.NonEmpty as NonEmpty

import Control.Lens ((&), (.~))
import Control.Retry
       (recovering, exponentialBackoff, logRetries, defaultLogMsg)
import Data.Text (Text)
import Network.Google
       (runResourceT, runGoogle, send,
        Error(TransportError, ServiceError), ServiceError(..))
import Network.Google.Logging
       (MonitoredResource, WriteLogEntriesRequestLabels, LogEntry,
        entriesWrite, writeLogEntriesRequest, wlerLabels,
        wlerEntries, leResource, leLogName)
import Network.Google.PubSub
       (PubsubMessage, projectsTopicsPublish, publishRequest, prMessages, topic, projectsTopicsCreate)
import Network.Google.Auth.Scope (HasScope', AllowScopes)
import Network.Google.Env (HasEnv)
import Control.Monad.Log (BatchingOptions, Handler, withBatchedHandler)
import Control.Monad.IO.Class (MonadIO(liftIO))
import Control.Monad.Catch
       (MonadMask, MonadCatch(catch), MonadThrow(throwM))
import Control.Monad.Base (MonadBase)
import Control.Monad.Trans.Resource (MonadBaseControl)
import Network.HTTP.Types.Status (Status(..))


-- | `withGoogleLoggingHandler` creates a new `Handler` for flash logs to
-- <https://cloud.google.com/logging/ Google Logging>
withGoogleLoggingHandler
    :: (HasScope' s '["https://www.googleapis.com/auth/cloud-platform",
                      "https://www.googleapis.com/auth/logging.admin",
                      "https://www.googleapis.com/auth/logging.write"] ~ 'True
       ,AllowScopes s
       ,HasEnv s r
       ,MonadIO io
       ,MonadMask io)
    => BatchingOptions
    -> r
    -> Maybe Text
    -> Maybe MonitoredResource
    -> Maybe WriteLogEntriesRequestLabels
    -> (Handler io LogEntry -> io a)
    -> io a
withGoogleLoggingHandler options env logname resource labels =
    withBatchedHandler options (flushToGoogleLogging env logname resource labels)


-- | method for flash log to <https://cloud.google.com/logging/ Google Logging>
flushToGoogleLogging
    :: (HasScope' s '["https://www.googleapis.com/auth/cloud-platform",
                      "https://www.googleapis.com/auth/logging.admin",
                      "https://www.googleapis.com/auth/logging.write"] ~ 'True
       ,AllowScopes s
       ,HasEnv s r)
    => r
    -> Maybe Text
    -> Maybe MonitoredResource
    -> Maybe WriteLogEntriesRequestLabels
    -> NonEmpty LogEntry
    -> IO ()
flushToGoogleLogging env logname resource labels entries =
  runResourceT
    (runGoogle
       env
       (recovering
          (exponentialBackoff 15)
          [ logRetries
              (\(TransportError _) -> return False)
              (\b e rs -> liftIO (print (defaultLogMsg b e rs)))
          , logRetries
              (\(ServiceError _) -> return False)
              (\b e rs -> liftIO (print (defaultLogMsg b e rs)))
          ]
          (\_ ->
             send
               (entriesWrite
                  ((((writeLogEntriesRequest & wlerEntries .~
                      (map
                         (\entry ->
                            ((entry & leLogName .~ logname) & leResource .~
                             resource))
                         (NonEmpty.toList entries)))) &
                    wlerLabels .~
                    labels)))) >>
        return ()))



-- | `withGooglePubSubHandler` creates a new `Handler` for flash logs to
-- <https://cloud.google.com/pubsub/ Google PubSub>
withGooglePubSubHandler
  :: ( HasScope' s '[ "https://www.googleapis.com/auth/cloud-platform", "https://www.googleapis.com/auth/pubsub"] ~ 'True
     , AllowScopes s
     , HasEnv s r
     , MonadIO io
     , MonadMask io
     , MonadBase IO io
     , MonadBaseControl IO io
     )
  => BatchingOptions -> r -> Text -> (Handler io PubsubMessage -> io a) -> io a
withGooglePubSubHandler options env topicName handler =
  runResourceT
    (runGoogle
       env
       (catch
          (send (projectsTopicsCreate topic topicName) >> return ())
          (\(ServiceError se) ->
             if statusCode ( _serviceStatus se) == 409
               then return ()
               else throwM (ServiceError se)))) >>
  withBatchedHandler options (flushToGooglePubSub env topicName) handler


-- | method for flash log to <https://cloud.google.com/pubsub/ Google PubSub>
flushToGooglePubSub
    :: (HasScope' s '["https://www.googleapis.com/auth/cloud-platform",
                      "https://www.googleapis.com/auth/pubsub"] ~ 'True
       ,AllowScopes s
       ,HasEnv s r)
    => r
    -> Text
    -> NonEmpty PubsubMessage
    -> IO ()
flushToGooglePubSub env topicName msgs =
  runResourceT
    (runGoogle
       env
       (recovering
          (exponentialBackoff 15)
          [ logRetries
              (\(TransportError _) -> return False)
              (\b e rs -> liftIO (print (defaultLogMsg b e rs)))
          , logRetries
              (\(ServiceError _) -> return False)
              (\b e rs -> liftIO (print (defaultLogMsg b e rs)))
          ]
          (\_ ->
             send
               (projectsTopicsPublish
                  (publishRequest & prMessages .~ (NonEmpty.toList msgs))
                  topicName)) >>
        return ()))
