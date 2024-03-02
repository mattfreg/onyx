{-# LANGUAGE DeriveFoldable      #-}
{-# LANGUAGE DeriveFunctor       #-}
{-# LANGUAGE DeriveTraversable   #-}
{-# LANGUAGE GADTs               #-}
{-# LANGUAGE LambdaCase          #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE RecordWildCards     #-}
module Onyx.Game.Audio
( projectAudio, withAL, AudioHandle(..)
, playSource
) where

import           Control.Concurrent           (threadDelay)
import           Control.Concurrent.Async     (async, forConcurrently,
                                               mapConcurrently_)
import           Control.Concurrent.MVar
import           Control.Exception            (bracket)
import           Control.Monad                (forM, forM_, join)
import           Control.Monad.IO.Class       (MonadIO, liftIO)
import           Control.Monad.Trans.Resource
import           Data.Conduit                 (runConduit, (.|))
import qualified Data.Conduit                 as C
import qualified Data.Conduit.Audio           as CA
import           Data.Conduit.Audio.Sndfile   (sourceSndFrom)
import           Data.Foldable                (toList)
import qualified Data.HashMap.Strict          as HM
import           Data.IORef
import qualified Data.List.NonEmpty           as NE
import           Data.List.Split              (splitPlaces)
import qualified Data.Set                     as Set
import qualified Data.Text                    as T
import qualified Data.Vector.Storable         as V
import           Foreign                      hiding (void)
import           Foreign.C                    (CFloat (..), CInt (..),
                                               CUInt (..))
import           Onyx.Audio
import           Onyx.Audio.Render            (computeChannelsPlan,
                                               loadSamplesFromBuildDir,
                                               manualLeaf)
import           Onyx.Audio.Search
import           Onyx.Harmonix.MOGG
import           Onyx.Import
import           Onyx.Project
import           Onyx.StackTrace              (QueueLog, StackTraceT,
                                               errorToWarning, fatal)
import           Onyx.Util.Handle             (Readable, fileReadable)
import           Path                         (parseAbsDir)
import qualified Sound.OpenAL                 as AL
import           Sound.OpenAL                 (($=))
import           System.FilePath              (takeDirectory, (<.>), (</>))

{-
{-# NOINLINE lockAL #-}
lockAL :: MVar ()
lockAL = unsafePerformIO $ newMVar ()

checkAL :: String -> IO a -> IO a
checkAL desc f = withMVar lockAL $ \() -> do
  _ <- AL.get AL.alErrors
  x <- f
  errs <- AL.get AL.alErrors
  unless (null errs) $ putStrLn $ desc <> ": " <> show errs
  return x
-}

-- | Can be swapped out with checkAL to see OpenAL errors
doAL :: String -> IO a -> IO a
doAL _ f = f

_sndSecsSpeed :: (MonadResource m) => Double -> Maybe Double -> FilePath -> IO (CA.AudioSource m Int16)
_sndSecsSpeed pos mspeed f = do
  src <- sourceSndFrom (CA.Seconds pos) f
  let adjustSpeed = maybe id (\speed -> stretchRealtime (recip speed) 1) mspeed
  return $ CA.mapSamples CA.integralSample $ adjustSpeed src

-- TODO it would be nice if we could switch audio devices seamlessly on default device change.
-- see https://github.com/kcat/openal-soft/issues/555
withAL :: (Bool -> IO a) -> IO a
withAL fn = let
  destroyContext ctx = do
    AL.currentContext $= Nothing
    AL.destroyContext ctx
  in bracket (AL.openDevice Nothing) (mapM_ AL.closeDevice) $ \mdev -> do
    case mdev of
      Nothing -> fn False
      Just dev -> bracket (AL.createContext dev []) (mapM_ destroyContext) $ \mctx -> do
        case mctx of
          Nothing -> fn False
          Just ctx -> do
            AL.currentContext $= Just ctx
            fn True

data AudioState = Filling | Playing

{-
emptySources :: [AL.Source] -> IO ()
emptySources srcs = do
  srcs' <- flip filterM srcs $ \src -> do
    cur <- doAL "emptySources buffersQueued" $ AL.buffersQueued src
    proc <- doAL "emptySources buffersProcessed" $ AL.buffersProcessed src
    if cur == 0
      then do
        doAL "emptySources deleteObjectNames source" $ AL.deleteObjectNames [src]
        return False
      else do
        -- this runs into problems because sometimes an unqueued buffer still
        -- can't be deleted for a bit! that's why we don't use this anymore
        when (proc /= 0) $ doAL "emptySources unqueueBuffers" (AL.unqueueBuffers src proc)
          >>= doAL "emptySources deleteObjectNames buffers" . AL.deleteObjectNames
        return True
  case srcs' of
    [] -> return ()
    _ -> do
      putStrLn $ "Waiting for " <> show (length srcs') <> " to empty"
      threadDelay 5000
      emptySources srcs'
-}

foreign import ccall unsafe
  alSourcei :: AL.ALuint -> AL.ALenum -> AL.ALint -> IO ()

data AudioHandle = AudioHandle
  { audioStop    :: IO ()
  , audioSetGain :: Float -> IO ()
  }

data AssignedSource
  = AssignedMono Float Float -- pan vol
  | AssignedStereo Float -- vol
  deriving (Show)

-- | Splits off adjacent L/R pairs into stereo sources for OpenAL
assignSources :: [Float] -> [Float] -> [AssignedSource]
assignSources ((-1) : 1 : ps) (v1 : v2 : vs) | v1 == v2
  = AssignedStereo v1 : assignSources ps vs
assignSources (p : ps) (v : vs)
  = AssignedMono p v : assignSources ps vs
assignSources _ _ = []

playSources
  :: Float
  -> [([Float], [Float], CA.AudioSource (ResourceT IO) Int16)]
  -> IO AudioHandle
playSources initGain inputs = do
  readies <- forConcurrently inputs $ \(pans, vols, ca) -> do
    readySource pans vols initGain ca
  mapConcurrently_ sourceWait readies
  doAL "playSources play" $ AL.play $ concatMap sourceAL readies
  let handles = map sourceHandle readies
  return AudioHandle
    { audioStop    = mapConcurrently_ audioStop handles
    , audioSetGain = \g -> mapConcurrently_ (\h -> audioSetGain h g) handles
    }

playSource
  :: [Float] -- ^ channel pans, -1 (L) to 1 (R)
  -> [Float] -- ^ channel volumes, in decibels
  -> Float -- ^ initial gain, 0 to 1
  -> CA.AudioSource (ResourceT IO) Int16
  -> IO AudioHandle
playSource pans vols initGain ca = do
  ready <- readySource pans vols initGain ca
  sourceWait ready
  doAL "playSource play" $ AL.play $ sourceAL ready
  return $ sourceHandle ready

readySource
  :: [Float] -- ^ channel pans, -1 (L) to 1 (R)
  -> [Float] -- ^ channel volumes, in decibels
  -> Float -- ^ initial gain, 0 to 1
  -> CA.AudioSource (ResourceT IO) Int16
  -> IO ReadySource
readySource pans vols initGain ca = do
  let assigned = assignSources pans vols
      srcCount = length assigned
      floatRate = realToFrac $ CA.rate ca
  srcs <- doAL "playSource genObjectNames sources" $ AL.genObjectNames srcCount
  forM_ srcs $ \src -> do
    with src $ \p -> do
      srcID <- peek $ castPtr p -- this is dumb but OpenAL pkg doesn't expose constructor
      doAL "playSource setting direct mode" $ do
        alSourcei srcID 0x1033 1 -- this is AL_DIRECT_CHANNELS_SOFT (should use c2hs!)
  let setGain g = forM_ (zip srcs $ assigned) $ \(src, srcAssigned) -> let
        volDB = case srcAssigned of
          AssignedMono _ vol -> vol
          AssignedStereo vol -> vol
        in doAL "playSource setting sourceGain" $ do
          AL.sourceGain src $= CFloat (g * (10 ** (volDB / 20)))
  setGain initGain
  firstFull <- newEmptyMVar
  stopper <- newIORef False
  stopped <- newEmptyMVar
  let queueSize = 10 -- TODO rework so this is in terms of frames/seconds, not buffer chunks
      waitTime = 5000
      t1 = runResourceT $ runConduit $ CA.source (CA.reorganize CA.chunkSize ca) .| let
        loop currentBuffers audioState = liftIO (readIORef stopper) >>= \case
          True -> liftIO $ do
            doAL "playSource stopping sources" $ AL.stop srcs
            doAL "playSource deleting sources" $ AL.deleteObjectNames srcs
            doAL "playSource deleting remaining buffers" $ AL.deleteObjectNames $ Set.toList currentBuffers
            putMVar stopped ()
          False -> do
            current <- liftIO $ doAL "playSource buffersQueued" $ AL.buffersQueued $ head srcs
            if current < queueSize
              then do
                -- liftIO $ putStrLn $ "Filling because queue has " <> show current
                C.await >>= \case
                  Nothing -> do
                    case audioState of
                      Filling -> liftIO $ putMVar firstFull ()
                      _       -> return ()
                    liftIO $ threadDelay waitTime
                    loop currentBuffers Playing
                  Just chunk -> do
                    bufs <- liftIO $ doAL "playSource genObjectNames buffers" $ AL.genObjectNames srcCount
                    let grouped = groupChannels assigned $ CA.deinterleave (CA.channels ca) chunk
                        groupChannels (AssignedMono pan _ : xs) (chan : ys) = let
                          (ratioL, ratioR) = stereoPanRatios pan
                          newStereo = V.generate (V.length chan * 2) $ \i -> case quotRem i 2 of
                            (j, 0) -> CA.integralSample $ ratioL * CA.fractionalSample (chan V.! j)
                            (j, _) -> CA.integralSample $ ratioR * CA.fractionalSample (chan V.! j)
                          in newStereo : groupChannels xs ys
                        groupChannels (AssignedStereo{} : xs) (c1 : c2 : ys) = let
                          interleaved = CA.interleave [c1, c2]
                          in interleaved : groupChannels xs ys
                        groupChannels _ _ = []
                    forM_ (zip bufs grouped) $ \(buf, chan') -> do
                      liftIO $ V.unsafeWith chan' $ \p -> do
                        let _ = p :: Ptr Int16
                        doAL "playSource set bufferData" $ AL.bufferData buf $= AL.BufferData
                          (AL.MemoryRegion p $ fromIntegral $ V.length chan' * sizeOf (V.head chan'))
                          AL.Stereo16
                          floatRate
                    forM_ (zip srcs bufs) $ \(src, buf) -> do
                      liftIO $ doAL "playSource queueBuffers" $ AL.queueBuffers src [buf]
                    let newBuffers = Set.fromList bufs
                    loop (Set.union currentBuffers newBuffers) audioState
              else do
                -- liftIO $ putStrLn "Queue is full"
                case audioState of
                  Filling -> liftIO $ putMVar firstFull ()
                  _       -> return ()
                removedBuffers <- fmap Set.unions $ liftIO $ forM srcs $ \src -> doAL "playSource buffersProcessed" (AL.buffersProcessed src) >>= \case
                  0 -> return Set.empty
                  n -> do
                    -- liftIO $ putStrLn $ "Removing " <> show n <> " finished buffers"
                    bufs <- doAL "playSource unqueueBuffers" $ AL.unqueueBuffers src n
                    doAL "playSource deleteObjectNames buffers" $ AL.deleteObjectNames bufs
                    return $ Set.fromList bufs
                liftIO $ threadDelay waitTime
                loop (Set.difference currentBuffers removedBuffers) Playing
        in loop Set.empty Filling
  _ <- async t1
  return ReadySource
    { sourceWait = takeMVar firstFull
    , sourceAL   = srcs
    , sourceHandle = AudioHandle
      { audioStop = writeIORef stopper True >> takeMVar stopped
      , audioSetGain = setGain
      }
    }

data ReadySource = ReadySource
  { sourceWait   :: IO ()
  , sourceAL     :: [AL.Source]
  , sourceHandle :: AudioHandle
  }

-- | Use libvorbisfile to read an OGG
oggSecsSpeed :: (MonadResource m) => Double -> Maybe Double -> Readable -> IO (CA.AudioSource m Int16)
oggSecsSpeed pos mspeed ogg = do
  src <- sourceVorbis (CA.Seconds pos) ogg
  let adjustSpeed = maybe id (\speed -> stretchRealtime (recip speed) 1) mspeed
  return $ CA.mapSamples CA.integralSample $ adjustSpeed src

data PlanAudio t a = PlanAudio
  { expr :: Audio t a
  , pans :: [Double]
  , vols :: [Double]
  } deriving (Functor, Foldable, Traversable)

splitPlanSources
  :: (MonadIO m)
  => T.Text
  -> Project
  -> AudioLibrary
  -> [Audio CA.Duration AudioInput]
  -> StackTraceT (QueueLog m) [PlanAudio CA.Duration FilePath]
splitPlanSources planName proj lib audios = let
  evalAudioInput = \case
    Named name -> do
      afile <- maybe (fatal "Undefined audio name") return $ HM.lookup name (projectSongYaml proj).audio
      let buildDependency n = shakeBuild1 proj [] $ "gen/audio" </> T.unpack n <.> "wav"
          getSamples = loadSamplesFromBuildDir
            (shakeBuild1 proj [])
            planName
      case afile of
        AudioFile ainfo -> searchInfo (takeDirectory $ projectLocation proj) lib buildDependency ainfo
        AudioSnippet expr -> join <$> mapM evalAudioInput expr
        AudioSamples _info -> manualLeaf
          (takeDirectory $ projectLocation proj)
          lib
          buildDependency
          getSamples
          (projectSongYaml proj)
          (Named name)
    JammitSelect{} -> fatal "Jammit audio not supported in preview yet" -- TODO
    Mogg{} -> fatal "MOGG channel audio not supported in preview yet" -- TODO
  in fmap concat $ forM audios $ \audio -> do
    let chans = computeChannelsPlan (projectSongYaml proj) audio
        pans = case chans of
          1 -> [0]
          2 -> [-1, 1]
          _ -> replicate chans 0
        vols = replicate chans 0
    evaled <- forM audio $ \aud -> do
      aud' <- evalAudioInput aud
      return (aud, aud')
    -- for mix and merge, split into multiple AL sources
    case evaled of
      -- mix: same pans and vols for each input
      -- TODO this appears to not work if mixing mono and stereo together
      Mix parts -> return [PlanAudio (join $ fmap snd partExpr) pans vols | partExpr <- NE.toList parts]
      -- merge: split pans and vols to go with the appropriate input
      Merge parts -> do
        let partChannels = map (computeChannelsPlan (projectSongYaml proj) . fmap fst) $ NE.toList parts
        return $ zipWith3
          (\x p v -> PlanAudio (join $ fmap snd x) p v)
          (NE.toList parts)
          (splitPlaces partChannels pans)
          (splitPlaces partChannels vols)
      expr -> return [PlanAudio (join $ fmap snd expr) pans vols]

projectAudio :: (MonadIO m) => T.Text -> Project -> StackTraceT (QueueLog m) (Maybe (Double -> Maybe Double -> Float -> IO AudioHandle))
projectAudio k proj = case lookup k $ HM.toList (projectSongYaml proj).plans of
  Just (MoggPlan x) -> errorToWarning $ do
    -- TODO maybe silence crowd channels
    mogg <- shakeBuild1 proj [] $ "gen/plan/" <> T.unpack k <> "/audio.mogg"
    let ogg = moggToOgg $ fileReadable mogg
    return $ \t speed gain -> oggSecsSpeed t speed ogg >>= playSource (map realToFrac x.pans) (map realToFrac x.vols) gain
  Just (StandardPlan x) -> errorToWarning $ do
    let audios = toList x.song ++ (toList x.parts >>= toList) -- :: [PlanAudio Duration AudioInput]
    lib <- newAudioLibrary
    audioDirs <- getAudioDirs proj
    forM_ audioDirs $ \dir -> do
      p <- parseAbsDir dir
      addAudioDir lib p
    planAudios <- splitPlanSources k proj lib audios
    case NE.nonEmpty planAudios of
      Nothing -> fatal "No audio in plan"
      Just ne -> return $ \t mspeed gain -> do
        inputs <- forM ne $ \paudio -> do
          src <- buildSource' $ Drop Start (CA.Seconds t) paudio.expr
          let src' = CA.mapSamples CA.integralSample
                $ maybe id (\speed -> stretchRealtime (recip speed) 1) mspeed src
          return
            ( map realToFrac paudio.pans
            , map realToFrac paudio.vols
            , src'
            )
        playSources gain $ NE.toList inputs
  {-
  Just _ -> errorToWarning $ do
    wav <- shakeBuild1 proj [] $ "gen/plan/" <> T.unpack k <> "/everything.wav"
    return $ \t speed -> _sndSecsSpeed t speed wav >>= playSource [-1, 1] [0, 0]
  -}
  Nothing -> return Nothing
