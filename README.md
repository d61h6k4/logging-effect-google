# logging-effect-google
> logging-effect handlers for google-logging and google-pubsub

Handlers for [logging-effect](https://hackage.haskell.org/package/logging-effect) which can fetch logs to [Google Logging](https://cloud.google.com/logging/) and to [Google PubSub](https://cloud.google.com/pubsub).

## Installation

This package is not in hackage yet. So for install it add to `stack.yaml`
in `packages` next:
```
- location:
  git: https://github.com/d61h6k4/logging-effect-google.git
  commit: <insert commit here>
```
and add `logging-effect-google` to your `cabal` file.

## Usage example

Here example how I use it with [wai](https://hackage.haskell.org/package/wai) server on GCP. Additionally here used [wai-logging-effect-google](https://github.com/d61h6k4/wai-logging-effect-google.git). Here google logging handler used to store logs from wai and google pubsub handler to store events from clients.

```haskell
events
    :: Handler IO PubsubMessage -> Request -> IO Response
events pubsub request =
    case checkAuth request of
        Left err -> return err
        Right token -> do
            reqbody <- liftIO $ requestBody request
            case (checkMethod request >> extractCheckSum request >>=
                  checkIntegrity (calculateMD5 reqbody)) of
                Left response -> return response
                Right response ->
                    case decodeMessage reqbody :: Either String EventLogs of
                        Left err ->
                            return
                                (responseLBS
                                     status400
                                     [("Content-Type", "plain/text")]
                                     (BSLC8.pack err))
                        Right msg' ->
                            mapM_
                                (\entity ->
                                      (pubsub
                                           (pubsubMessage & pmData .~
                                            Just (encodeMessage entity))))
                                (localiso token msg') >>
                            return response

app :: Handler IO PubsubMessage -> Application
app pubsub request respond =
    case rawPathInfo request of
        "/events" ->
            events pubsub request >>= respond

main :: IO ()
main = do
    lgr <- newLogger Debug stdout
    env <- newEnv <&> (envScopes .~ ( loggingWriteScope ! pubSubScope)) . (envLogger .~ lgr)
    withGooglePubSubHandler
        (defaultBatchingOptions
         { flushMaxDelay = 3 * 1000000
         , flushMaxQueueSize = 128
         })
        env
        ("pubsub_topic_name") $
        \pubsub ->
             withGoogleLoggingHandler
                 (defaultBatchingOptions
                  { flushMaxDelay = 10 * 1000000
                  , flushMaxQueueSize = 128
                  })
                 env
                 (Just
                      ("projects/" <> ("test_project_id") <>
                       ("/logs/negotians")))
                 (Just
                      ((monitoredResource & mrLabels .~
                        (Just
                             (monitoredResourceLabels
                                  (HashMap.fromList
                                       ([ ( "instanceId"
                                          , ("0000"))
                                        , ("zone", ("eu-west1-c"))]))))) &
                       mrType .~
                       (Just "gce_instance")))
                 Nothing $
             \wailogger ->
                  run 3000 $ loggerMiddleware wailogger $ gzip def $
                  app pubsub
```

## Development setup

Fork it.

## Release History

## Meta

Distributed under BSD license. See ``LICENSE`` for more information.
