{-# LANGUAGE DataKinds, OverloadedStrings, TypeOperators #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE LambdaCase, TupleSections, RecordWildCards #-}
module Main where

import qualified Codec.Serialise as CBOR
import Control.Concurrent
import Control.Concurrent.STM
import Control.Monad
import Control.Monad.Catch (MonadCatch, MonadMask, MonadThrow)
import Control.Monad.Except
import Data.Aeson
import Data.Foldable
import Data.List
import Data.Maybe
import Data.Time
import Network.CircleCI.Build
import Network.HTTP.Client (Manager)
import Network.HTTP.Client.TLS (newTlsManager)
import Network.Wai.Handler.Warp
import Servant
import Servant.Client
import System.Directory
import System.Environment
import System.Exit
import System.IO
import System.IO.Temp
import System.Process
import Web.FormUrlEncoded

import qualified Data.ConfigManager   as Conf
import qualified Data.ByteString.Lazy as LBS
import qualified Data.HashMap.Strict  as HashMap
import qualified Data.Text            as T

main :: IO ()
main = do
  args <- getArgs
  (cfg, ongoingJobs) <- getConfig $ case args of
    [] -> error "Please specify a config file"
    (cfgPath:_) -> cfgPath
  hSetBuffering stderr NoBuffering
  l ["Loaded " ++ show (length ongoingJobs) ++ " existing jobs."]

  queue <- newTVarIO ongoingJobs

  _ <- forkIO (builder cfg queue)

  run (httpPort cfg) . serve api $
    hoistServer api runApp (server cfg queue)

-- * Types

type Remote    = String
type Ref       = String
type PHID      = T.Text

data Task = Task
  { taskRef  :: Ref
  , taskPHID :: PHID
  , taskNum  :: BuildNumber
  , taskInfo :: Maybe BuildInfo
  } deriving (Eq, Show)

-- We drop the 'taskInfo' bit when encoding/decoding
-- 'Task's.
instance CBOR.Serialise Task where
  encode Task{..} = CBOR.encode (taskRef, taskPHID, n)
    where BuildNumber n = taskNum
  decode = (\(ref, phid, num) -> Task ref phid (BuildNumber num) Nothing)
       <$> CBOR.decode

instance CBOR.Serialise a => CBOR.Serialise (Q a) where
  encode = CBOR.encode . toList
  decode = (\xs -> Q xs []) <$> CBOR.decode

writeStateFile :: FilePath -> Q Task -> IO ()
writeStateFile fp = LBS.writeFile fp . CBOR.serialise

readStateFile :: FilePath -> IO (Q Task)
readStateFile fp = CBOR.deserialise <$> LBS.readFile fp

type WorkQueue = TVar (Q Task)

data Q a = Q [a] [a]
  deriving (Eq, Show)

emptyQ :: Q a
emptyQ = Q [] []

instance Functor Q where
  fmap f (Q xs ys) = Q (fmap f xs) (fmap f ys)

instance Foldable Q where
  foldMap f (Q xs ys) = foldMap f xs <> foldMap f (reverse ys)

instance Traversable Q where
  traverse f (Q xs ys) = Q <$> traverse f xs <*> traverse f (reverse ys)

pushQ :: a -> Q a -> Q a
pushQ x (Q [] ys) = Q (reverse ys) [x]
pushQ x (Q xs ys) = Q xs           (x:ys)

catMaybesQ :: Q (Maybe a) -> Q a
catMaybesQ (Q xs ys) = Q (catMaybes xs) (catMaybes ys)

pushTask :: MonadIO m => Task -> WorkQueue -> m ()
pushTask t q = liftIO . atomically $ modifyTVar q (pushQ t)

collectTasks :: MonadIO m => WorkQueue -> m (Q Task)
collectTasks = liftIO . atomically . readTVar

setTasks :: MonadIO m => WorkQueue -> Q Task -> m ()
setTasks queue tasks = liftIO $ atomically (writeTVar queue tasks)

newtype App a = App { unApp :: ExceptT AppError IO a }
  deriving ( Functor, Applicative, Monad
           , MonadIO, MonadError AppError, MonadCatch, MonadMask, MonadThrow
           )

runAppIO :: App () -> IO ()
runAppIO m = runExceptT (unApp m) >>= \case
  Left e -> l ["Fatal worker error: " ++ show e]
  Right _ -> pure ()

runApp :: App a -> Handler a
runApp = Handler . withExceptT toServantErr . unApp

  where toServantErr e = err400 { errBody = encode e }

optional :: Bool -> [a] -> [a]
optional True xs = xs
optional False _ = []

class Summarise a where
  -- | One line, to the point version.
  summarise :: a -> String
  -- | Possibly multiline, more information.
  summariseLong :: a -> [String]
  summariseLong = (:[]) . summarise

instance Summarise a => Summarise (Maybe a) where
  summarise = maybe "" summarise
  summariseLong = maybe [] summariseLong

instance Summarise BuildInfo where
  summarise info = intercalate ", " $
    [ "build #" ++ show n
    , "commit = " ++ T.unpack (T.take 7 $ commit info)
    , T.unpack (status info) ++
      optional (lifecycle info == BuildRunning)
        (" (step #" ++ show (length $ steps info) ++ ")")
    ]

    where BuildNumber n = number info

  summariseLong info = summarise info : concatMap detailsOf (steps info)

    where detailsOf s =
            [ "    " ++ T.unpack (actionName a) ++ ": "
                     ++ T.unpack (actionStatus a)
            | a <- actions s
            ]

instance Summarise Task where
  summarise t = intercalate ", "
    [ "task: PHID = " ++ T.unpack (taskPHID t)
    , "ref = " ++ taskRef t
    , summarise (taskInfo t)
    ]
  summariseLong t = case summariseLong (taskInfo t) of
    (_ : xs) -> summarise t : xs
    []       -> [summarise t]

-- * Server

{-
We have one endpoint, with values provided by Phabricator as follows.

/<validation scenario>
 ?build_id=${build.id}
 &commit=${buildable.commit}
 &diff=${buildable.diff}
 &revision=${buildable.revision}
 &initiator=${initiator.phid}
 &repo_callsign=${repository.callsign}
 &repo_phid=${repository.phid}
 &repo_staging_ref=${repository.staging.ref}
 &repo_staging_uri=${repository.staging.uri}
 &repo_uri=${repository.uri}
 &timestamp=${step.timestamp}
 &target=${target.phid}

where <validation scenario> is one of the types of CI jobs
given in: https://git.haskell.org/ghc.git/blob/HEAD:/.circleci/config.yml#l94
e.g "validate-x86_64-linux".
-}
type API = Capture "job_type" String
        :> QueryParam "build_id" String
        :> QueryParam "commit" String
        :> QueryParam "diff" String
        :> QueryParam "revision" String
        :> QueryParam "initiator" String
        :> QueryParam "repo_callsign" String
        :> QueryParam "repo_phid" String
        :> QueryParam "repo_staging_ref" String
        :> QueryParam "repo_staging_uri" String
        :> QueryParam "repo_uri" String
        :> QueryParam "timestamp" String
        :> QueryParam "target" String
        :> Post '[PlainText] T.Text

api :: Proxy API
api = Proxy

server :: Config -> WorkQueue -> ServerT API App
server cfg queue job_type build_id comm diff revision initiator repo_callsign repo_phid
       repo_staging_ref repo_staging_uri repo_uri timestamp target
  = do debugRequest
       buildInfo <- processRequest
       return (linkCircleBuild cfg buildInfo)

  where phab_request =
          [ ("build_id", build_id)
          , ("commit", comm)
          , ("diff", diff)
          , ("revision", revision)
          , ("initiator", initiator)
          , ("repo_callsign", repo_callsign)
          , ("repo_phid", repo_phid)
          , ("repo_staging_ref", repo_staging_ref)
          , ("repo_staging_uri", repo_staging_uri)
          , ("repo_uri", repo_uri)
          , ("timestamp", timestamp)
          , ("target", target)
          , ("job_type", Just job_type)
          ]
        debugRequest = l $
          [ "========================="
          , "|| Phabricator request ||"
          , "=========================" ]
          ++
          [ lbl ++ " = " ++ fromMaybe "N/A" val
          | (lbl, val) <- phab_request
          ] ++
          [ "-------------------------" ]
        processRequest = do
          phab_uri <- nonEmpty "staging URI" repo_staging_uri
          phab_ref <- nonEmpty "staging ref" repo_staging_ref
          target_phid <- nonEmpty "target PHID" target
          enqueueJob cfg queue job_type phab_uri phab_ref (T.pack target_phid)

githubRepoUrl :: Config -> T.Text
githubRepoUrl cfg = "git@github.com:" <> githubRepoUser cfg
                 <> "/" <> githubRepoProject cfg <> ".git"

linkCircleBuild :: Config -> BuildInfo -> T.Text
linkCircleBuild cfg bi = "https://circleci.com/gh/"
                      <> githubRepoUser cfg <> "/"
                      <> githubRepoProject cfg <> "/"
                      <> T.pack (show n)

  where BuildNumber n = number bi

-- FIXME: If the hosts we fetch from and push to are not known to the system,
-- we might have to confirm that we are indeed willing to connect. Any
-- workaround but to make sure the hosts are known in advance?
enqueueJob :: Config -> WorkQueue -> String -> Remote -> Ref -> PHID -> App BuildInfo
enqueueJob cfg queue jobType phabRepoUrl ref phid = do
  withTempDirectory (workDir cfg) ("ghc-diffs") $ \tempdir -> do
    cmd "git" ["clone", phabRepoUrl, tempdir]
    withCurrentDirectory' tempdir $ do
      cmd "git" ["remote", "add", "gh", T.unpack (githubRepoUrl cfg)]
      cmd "git" ["checkout", ref]
      cmd "git" ["checkout", "-b", newRef]
      cmd "git" ["push", "gh", newRef]

  -- As sooon as the code is up, we can ask Circle CI to build it right away.
  -- If there are too many builds running already, Circle CI will simply
  -- queue the build, so we don't have to do that ourselves.
  res <- liftIO . flip runCircleCI (circleApiToken cfg) $
    triggerBuild (projectPoint cfg) opts
  buildInfo <- either circleCIError pure res

  -- The task is handed to the "build watcher thread", which
  -- repeatedly hits Circle CI to get updates on the ongoing
  -- builds.
  let task = Task ref phid (number buildInfo) (Just buildInfo)
  pushTask task queue
  l [ summarise task ++ " pushed in the queue" ]

  return buildInfo

  where opts = TriggerBuildOptions (BuildTag $ T.pack (cleanRef newRef))
          (HashMap.fromList [("CIRCLE_JOB", T.pack jobType)])
        cleanRef s
          | "refs/tags/" `isPrefixOf` s = drop 10 s
          | otherwise = s

        newRef = ref ++ "-" ++ jobType


-- * Worker

builder :: Config -> WorkQueue -> IO ()
builder cfg queue = do
  tasks <- collectTasks queue
  l [ "Collected " ++ show (length tasks) ++ " tasks" ]

  when (not $ null tasks) $ do
    tasks' <- forM tasks $ \t -> do -- forConcurrently?

      l ["Checking CircleCI updates on:" ++ summarise t]
      res <- flip runCircleCI (circleApiToken cfg) $
        getBuild (projectPoint cfg) (taskNum t)

      case res of
        Left e      -> circleCIWarning e >> return (Just t)
        Right info' -> do
          let t' = t { taskInfo = Just info' }
          l ["... OK: " ++ summarise info']

          when (taskInfo t /= Just info') (sendPhabUpdate t')

          case outcome info' of
            Nothing -> return (Just t')
            Just _  -> do
              l ("Build finished!" : summariseLong t')
              return Nothing

    -- The 'Nothing's we get come from builds that
    -- just ended; we put back updated build info for
    -- the others.
    let newTasks = catMaybesQ tasks'
    l ["Putting back " ++ show (length newTasks) ++ " task(s) back in the queue"]

    writeStateFile (stateFile cfg) newTasks
    setTasks queue newTasks

  threadDelay (30 * 1000000)
  builder cfg queue

  where
    sendPhabUpdate :: Task -> IO ()
    sendPhabUpdate t = do
      l ["Sending an update to Phabricator about: " ++ summarise t]
      sendPhabMessage $
        PM (T.pack $ phabApiToken cfg) (taskPHID t) msgtype units

      where msgtype = case maybe Nothing outcome (taskInfo t) of
              Nothing           -> Work
              Just BuildSuccess -> Pass
              Just BuildNoTests -> Pass
              _                 -> Fail

            -- TODO: keep the list of steps from the previous
            -- update and just send the diff to phabricator, to
            -- avoid the duplicates we can see in:
            -- https://phabricator.haskell.org/harbormaster/unit/21613/
            units = case msgtype of
              Work -> []
              _    -> concatMap ciStepToPhabUnit (maybe [] steps $ taskInfo t)

-- * Phabricator

type PhabAPI = "api" :> "harbormaster.sendmessage"
            :> ReqBody '[FormUrlEncoded] PhabMessage
            :> Post '[PlainText] NoContent

phabApi :: Proxy PhabAPI
phabApi = Proxy

sendmessage :: PhabMessage -> ClientM NoContent
sendmessage = client phabApi

data MessageType = Work | Pass | Fail
  deriving (Eq, Show)

data UnitResult = UnitPass | UnitFail | UnitSkip | UnitBroken | UnitUnsound
  deriving (Eq, Show)

resultText :: UnitResult -> T.Text
resultText r = case r of
  UnitPass    -> "pass"
  UnitFail    -> "fail"
  UnitSkip    -> "skip"
  UnitBroken  -> "broken"
  UnitUnsound -> "unsound"

data PhabUnit = PhabUnit
  { phabUnitName :: T.Text
  , result :: UnitResult
  , details :: Maybe T.Text
  } deriving (Eq, Show)

ciStepToPhabUnit :: BuildStep -> [PhabUnit]
ciStepToPhabUnit step = map toUnit (actions step)

  where toUnit act = PhabUnit
          (name step <> ": " <> actionName act)
          -- TODO: refine this?
          (if actionStatus act `elem` ["success", "running"]
             then UnitPass
             else UnitFail
          )
          (Just $ T.unlines
            ( fromMaybe "" (bashCommand act)
            : messages act
            )
          )

data PhabMessage = PM
  { phabToken :: T.Text
  , buildTargetPHID :: PHID
  , msgType :: MessageType
  , unit :: [PhabUnit]
  } deriving (Eq, Show)

instance ToForm PhabMessage where
  toForm (PM a b c d) = toForm $
    [ ( "type" :: T.Text
      , case c of
          Work -> "work" :: T.Text
          Pass -> "pass"
          Fail -> "fail"
      )
    , ( "api.token", a )
    , ( "buildTargetPHID", b )
    ] ++ concat
    [ [ ("unit[" <> T.pack (show i) <> "][name]", phabUnitName unit_i)
      , ("unit[" <> T.pack (show i) <> "][result]", resultText (result unit_i))
      , ("unit[" <> T.pack (show i) <> "][details]", fromMaybe "" (details unit_i))
      ]
    | (i, unit_i) <- zip [1::Int ..] d
    ]

phabClientEnv :: Manager -> ClientEnv
phabClientEnv mgr = ClientEnv mgr url Nothing

  where url = BaseUrl Https "phabricator.haskell.org" 443 ""

sendPhabMessage :: MonadIO m => PhabMessage -> m ()
sendPhabMessage msg = do
  res <- liftIO $ do
    mgr <- newTlsManager
    l ["Sending message to Phabricator (" ++ show (msgType msg) ++ ")"]
    runClientM (sendmessage msg) (phabClientEnv mgr)
  case res of
    Left err -> l ["!!! ERROR: ", show err]
    Right _  -> l ["... OK"]

-- * Config

data Config = Config
  { githubRepoUser :: T.Text
  , githubRepoProject :: T.Text
  , circleApiToken :: AccountAPIToken
  , phabApiToken :: String
  , httpPort :: Int
  , stateFile :: FilePath
  , workDir :: FilePath
  }

getConfig :: FilePath -> IO (Config, Q Task)
getConfig fp = do
  exists <- doesFileExist fp
  when (not exists) $ error ("file '" ++ fp ++ "' does not exist")
  Right c <- Conf.readConfig fp
  let cfg =
        Config <$> pure (Conf.lookupDefault "ghc" "github_repo_user" c)
               <*> pure (Conf.lookupDefault "ghc-diffs" "github_repo_project" c)
               <*> (AccountAPIToken <$> Conf.lookup "circle_api_token" c)
               <*> Conf.lookup "phabricator_api_token" c
               <*> pure (Conf.lookupDefault 8080 "http_port" c)
               <*> pure (Conf.lookupDefault "builds.bin" "state_file" c)
               <*> pure (Conf.lookupDefault "/var/lib/phab-circleci-bridge/" "work_dir" c)
  finalConf <- either (\e -> error $ "Configuration error: " ++ show e) pure cfg
  workDirExists <- doesDirectoryExist (workDir finalConf)
  when (not workDirExists) $ createDirectoryIfMissing True (workDir finalConf)
  stateFileExists <- doesFileExist (stateFile finalConf)
  if stateFileExists
    then (finalConf,) <$> readStateFile (stateFile finalConf)
    else pure (finalConf, emptyQ)

projectPoint :: Config -> ProjectPoint
projectPoint cfg = ProjectPoint (githubRepoUser cfg) (githubRepoProject cfg)

-- * Utilities

cmd :: FilePath -> [String] -> App ()
cmd prog args = do
  l [ "About to run: " ++ unwords (prog:args) ]
  (ex, out, err) <- liftIO $ readProcessWithExitCode prog args ""
  case ex of
    ExitSuccess   -> l ["... OK."]
    ExitFailure n -> do
      l ["... Not OK."]
      badExitCode n prog args out err

withCurrentDirectory' :: FilePath -> App a -> App a
withCurrentDirectory' dir act = do
  old <- liftIO getCurrentDirectory
  liftIO (setCurrentDirectory dir)
  r <- act
  liftIO (setCurrentDirectory old)
  return r

-- * Errors

data AppError
  = BadExitCode Int FilePath [String] String String
  | EmptyQueryParam String
  | CircleCIError ServantError
  | PhabError ServantError
  deriving (Eq, Show)

instance ToJSON AppError where
  toJSON (BadExitCode n prog args out err) =
    object [ "type" .= ("Non-zero exit code" :: String)
           , "code" .= n
           , "prog" .= prog
           , "args" .= args
           , "out"  .= out
           , "err"  .= err
           ]
  toJSON (EmptyQueryParam n) =
    object [ "type" .= ("Missing query param from Phabricator" :: String)
           , "name" .= n
           ]
  toJSON (CircleCIError e) =
    object [ "type" .= ("Circle CI API error" :: String)
           , "response" .= show e
           ]
  toJSON (PhabError e) =
    object [ "type" .= ("Phabricator API error" :: String)
           , "response" .= show e
           ]

badExitCode :: Int -> FilePath -> [String] -> String -> String -> App a
badExitCode ex prog args out err = throwError (BadExitCode ex prog args out err)

nonEmpty :: String -> Maybe a -> App a
nonEmpty lbl = maybe (throwError $ EmptyQueryParam lbl) pure

circleCIError :: ServantError -> App a
circleCIError err = throwError (CircleCIError err)

circleCIWarning :: MonadIO m => ServantError -> m ()
circleCIWarning e = l [ "Circle CI warning: " ++ show e ]

phabError :: ServantError -> App a
phabError err = throwError (PhabError err)

-- * Logging

l :: MonadIO m => [String] -> m ()
l strs = liftIO $ do
  t <- getZonedTime
  let timeStr = formatTime defaultTimeLocale "%d-%m-%Y %H:%M:%S %Z" t ++ "> "
  mapM_ (hPutStrLn stderr . mappend timeStr) strs
