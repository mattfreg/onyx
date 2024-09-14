{-# LANGUAGE BangPatterns          #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE LambdaCase            #-}
{-# LANGUAGE NamedFieldPuns        #-}
{-# LANGUAGE OverloadedRecordDot   #-}
{-# LANGUAGE OverloadedStrings     #-}
{-# LANGUAGE RecordWildCards       #-}
{-# LANGUAGE ViewPatterns          #-}
module Onyx.Build.Common where

import           Codec.Picture
import           Codec.Picture.Types              (dropTransparency,
                                                   promotePixel)
import           Control.Applicative              (liftA2, (<|>))
import           Control.Monad.Extra
import           Control.Monad.IO.Class
import           Control.Monad.Trans.Class        (lift)
import           Control.Monad.Trans.Resource
import           Data.Bifunctor                   (first)
import qualified Data.ByteString                  as B
import qualified Data.ByteString.Lazy             as BL
import           Data.Char                        (isAlphaNum, isAscii,
                                                   isControl, isDigit, isSpace,
                                                   toLower)
import           Data.Conduit                     (runConduit)
import           Data.Conduit.Audio
import qualified Data.EventList.Relative.TimeBody as RTB
import           Data.Foldable                    (toList)
import           Data.Hashable                    (Hashable, hash)
import qualified Data.HashMap.Strict              as HM
import qualified Data.List.NonEmpty               as NE
import           Data.Maybe                       (fromMaybe, isJust)
import qualified Data.Text                        as T
import qualified Data.Text.Encoding               as TE
import           Development.Shake                hiding (phony, (%>))
import           Development.Shake.FilePath
import qualified Numeric.NonNegative.Class        as NNC
import           Onyx.Audio
import           Onyx.Audio.Render
import           Onyx.Audio.Search
import           Onyx.Genre
import           Onyx.Image.DXT
import           Onyx.MIDI.Common
import           Onyx.MIDI.Read                   (mapTrack)
import qualified Onyx.MIDI.Track.Drums            as Drums
import           Onyx.MIDI.Track.Events
import qualified Onyx.MIDI.Track.File             as F
import           Onyx.Project                     hiding (Difficulty)
import           Onyx.Resources                   (onyxAlbum)
import           Onyx.Sections                    (Section (..), simpleSection)
import           Onyx.StackTrace
import           Onyx.Util.Handle                 (Folder (..), Readable,
                                                   crawlFolder)
import           Onyx.Util.Text.Transform         (replaceCharsRB)
import qualified Sound.MIDI.Util                  as U
import           System.IO.Unsafe                 (unsafePerformIO)

data BuildInfo = BuildInfo
  { biSongYaml        :: SongYaml FilePath
  , biYamlDir         :: FilePath
  , biRelative        :: FilePath -> FilePath
  , biAudioLib        :: AudioLibrary
  , biAudioDependPath :: T.Text -> FilePath
  , biOggWavForPlan   :: T.Text -> Int -> FilePath
  , biGenFolder       :: FilePath -- should just be "gen" or similar
  }

biGen :: BuildInfo -> FilePath -> FilePath
biGen bi f = biRelative bi $ biGenFolder bi </> f

shk :: Action a -> StackTraceT (QueueLog Action) a
shk = lift . lift

makePS3Name :: Int -> SongYaml f -> B.ByteString
makePS3Name num songYaml
  = TE.encodeUtf8
  $ T.take 0x1B -- 0x1C is probably fine, but leaving a null char so make_npdata doesn't get confused when making edat
  $ T.toUpper
  $ T.filter (\c -> isAscii c && isAlphaNum c)
  $ "O" <> T.pack (show num)
    <> getTitle  songYaml.metadata
    <> getArtist songYaml.metadata

targetTitle :: SongYaml f -> Target f -> T.Text
targetTitle songYaml target = let
  base = fromMaybe (getTitle songYaml.metadata) $ (targetCommon target).override.title
  in addTitleSuffix target base

targetTitleJP :: SongYaml f -> Target f -> Maybe T.Text
targetTitleJP songYaml target = case (targetCommon target).override.title of
  Just _  -> Nothing -- TODO do we need JP title on targets also
  Nothing -> case songYaml.metadata.titleJP of
    Nothing   -> Nothing
    Just base -> Just $ addTitleSuffix target base

getTargetMetadata :: SongYaml f -> Target f -> Metadata f
getTargetMetadata songYaml target = metadata
  { title        = override.title <|> metadata.title
  , titleJP      = override.titleJP <|> metadata.titleJP
  , artist       = override.artist <|> metadata.artist
  , artistJP     = override.artistJP <|> metadata.artistJP
  , album        = override.album <|> metadata.album
  , genre        = override.genre <|> metadata.genre
  , subgenre     = override.subgenre <|> metadata.subgenre
  , year         = override.year <|> metadata.year
  , fileAlbumArt = override.fileAlbumArt <|> metadata.fileAlbumArt
  , trackNumber  = override.trackNumber <|> metadata.trackNumber
  -- , comments     :: [T.Text]
  , key          = override.key <|> metadata.key
  , author       = override.author <|> metadata.author
  -- , rating       :: Rating
  , previewStart = override.previewStart <|> metadata.previewStart
  , previewEnd   = override.previewEnd <|> metadata.previewEnd
  -- , languages    :: [T.Text]
  -- , difficulty   :: Difficulty -- TODO difficulty should be a Maybe, for other cases as well
  , loadingPhrase = override.loadingPhrase <|> metadata.loadingPhrase
  } where metadata = songYaml.metadata
          override = (targetCommon target).override

addTitleSuffix :: Target f -> T.Text -> T.Text
addTitleSuffix target base = let
  common = targetCommon target
  segments = base : case target of
    RB3 x -> makeLabel []                             x.is2xBassPedal
    RB2 x -> makeLabel ["(RB2 version)" | x.labelRB2] x.is2xBassPedal
    _     -> makeLabel []                             False
  makeLabel sfxs is2x = case common.label_ of
    Just lbl -> [lbl]
    Nothing  -> concat
      [ case common.speed of
        Nothing  -> []
        Just 1   -> []
        Just spd -> let
          intSpeed :: Int
          intSpeed = round $ spd * 100
          in ["(" <> T.pack (show intSpeed) <> "% Speed)"]
      , ["(2x Bass Pedal)" | is2x && common.label2x]
      , sfxs
      ]
  in T.intercalate " " segments

hashRB3 :: (Hashable f, Hashable target) => SongYaml f -> target -> Int
hashRB3 songYaml target = let
  hashed =
    ( target
    , songYaml.metadata.title
    , songYaml.metadata.artist
    -- TODO this should use more info, or find a better way to come up with hashes.
    )
  -- want these to be higher than real DLC, but lower than C3 IDs
  n = hash hashed `mod` 1000000000
  minID = 10000000
  in if n < minID then n + minID else n

crawlFolderBytes :: (MonadIO m) => FilePath -> m (Folder B.ByteString Readable)
crawlFolderBytes p = liftIO $ fmap (first TE.encodeUtf8) $ crawlFolder p

applyTargetMIDI :: TargetCommon f -> F.Song (F.OnyxFile U.Beats) -> F.Song (F.OnyxFile U.Beats)
applyTargetMIDI tgt mid = let
  eval = fmap (U.unapplyTempoMap mid.tempos) . evalPreviewTime False (Just F.getEventsTrack) mid 0 False
  applyEnd = case tgt.end >>= eval . (.notes) of
    Nothing -> id
    Just notesEnd -> \m -> m
      { F.tracks = chopTake notesEnd m.tracks
      -- the RockBand3 module process functions will remove tempos and sigs after [end]
      }
  applyStart = case tgt.start >>= \seg -> liftA2 (,) (eval seg.fadeStart) (eval seg.notes) of
    Nothing -> id
    Just (audioStart, notesStart) -> \m -> m
      { F.tracks
        = mapTrack (RTB.delay $ notesStart - audioStart)
        $ chopDrop notesStart m.tracks
      , F.tempos = case U.trackSplit audioStart $ U.tempoMapToBPS m.tempos of
        -- cut time off the front of the tempo map, and copy the last tempo
        -- from before the cut point to the cut point if needed
        (cut, keep) -> U.tempoMapFromBPS $ case U.trackTakeZero keep of
          [] -> U.trackGlueZero (toList $ snd . snd <$> RTB.viewR cut) keep
          _  -> keep
      , F.timesigs = case U.trackSplit audioStart $ U.measureMapToTimeSigs m.timesigs of
        (cut, keep) -> U.measureMapFromTimeSigs U.Error $ case U.trackTakeZero keep of
          _ : _ -> keep -- already a time signature at the cut point
          []    -> case lastEvent cut of
            Nothing -> keep
            Just (t, sig) -> let
              len = U.timeSigLength sig
              afterSig = audioStart - t
              (_, barRemainder) = properFraction $ afterSig / len :: (Int, U.Beats)
              in if barRemainder == 0
                then U.trackGlueZero [sig] keep -- cut point is on an existing barline
                else let
                  partial = (1 - barRemainder) * len
                  afterPartial = U.trackDrop partial keep
                  in U.trackGlueZero [U.measureLengthToTimeSig partial] $
                    case U.trackTakeZero afterPartial of
                      _ : _ -> keep -- after the partial bar there's an existing signature
                      []    -> Wait partial sig afterPartial -- continue with the pre-cut signature
      }
  applySpeed = case fromMaybe 1 tgt.speed of
    1     -> id
    speed -> \m -> m
      { F.tempos
        = U.tempoMapFromBPS
        $ fmap (* realToFrac speed)
        $ U.tempoMapToBPS m.tempos
      }
  applySections m = case tgt.sections of
    SectionsFull       -> m
    SectionsMinimal    -> modifySections m
      $ makeMinimalSections . RTB.mapMaybe (\s -> simpleSection <$> s.segment)
    SectionsIndividual -> modifySections m
      $ fmap $ \s -> s { segment = Nothing }
  makeMinimalSections = \case
    Wait t1 s1 rest1@(Wait t2 s2 rest2) -> if s1.name == s2.name
      then makeMinimalSections $ Wait t1 s1 $ RTB.delay t2 rest2
      else Wait t1 s1 $ makeMinimalSections rest1
    sections -> sections
  modifySections m f = m
    { F.tracks = m.tracks
      { F.onyxEvents = m.tracks.onyxEvents
        { eventsSections = f $ m.tracks.onyxEvents.eventsSections
        }
      }
    }
  in applySections . applySpeed . applyStart . applyEnd $ mid

previewBoundsTarget
  :: Metadata file -- this should be project info overridden with target info
  -> F.Song (F.OnyxFile U.Beats) -- this should be "gen*/events.mid", no speed/pad/segment edits
  -> TargetCommon file -- used to apply speed and segment edits
  -> U.Seconds -- padding for early notes, calculated after target edits
  -> (Int, Int) -- start and end in milliseconds
previewBoundsTarget meta song tgt pad = let
  song' = applyTargetMIDI tgt { sections = SectionsFull } song
  in previewBounds meta song' pad False

lastEvent :: (NNC.C t) => RTB.T t a -> Maybe (t, a)
lastEvent (Wait !t x RNil) = Just (t, x)
lastEvent (Wait !t _ xs  ) = lastEvent $ RTB.delay t xs
lastEvent RNil             = Nothing

applyTargetLength :: TargetCommon g -> F.Song (f U.Beats) -> U.Seconds -> U.Seconds
applyTargetLength tgt mid = let
  -- TODO get Events track to support sections as segment boundaries
  applyEnd = case tgt.end >>= evalPreviewTime False Nothing mid 0 False . (.fadeEnd) of
    Nothing   -> id
    Just secs -> min secs
  applyStart = case tgt.start >>= evalPreviewTime False Nothing mid 0 False . (.fadeStart) of
    Nothing   -> id
    Just secs -> subtract secs
  applySpeed t = t / realToFrac (fromMaybe 1 tgt.speed)
  in applySpeed . applyStart . applyEnd

getAudioLength :: BuildInfo -> T.Text -> Plan f -> Staction U.Seconds
getAudioLength buildInfo planName = \case
  MoggPlan _ -> do
    let ogg = biGen buildInfo $ "plan" </> T.unpack planName </> "audio.ogg"
    shk $ need [ogg]
    liftIO $ audioSeconds ogg
  StandardPlan x -> let
    parts = concat
      [ toList x.song
      , toList x.crowd
      , toList x.parts >>= toList
      ]
    in case NE.nonEmpty parts of
      Nothing -> return 0
      Just parts' -> do
        let getSamples = loadSamplesFromBuildDirShake (biYamlDir buildInfo) planName
        src <- mapM (manualLeaf (biYamlDir buildInfo) (biAudioLib buildInfo) (audioDepend buildInfo) getSamples (biSongYaml buildInfo)) (Mix parts') >>= lift . lift . buildSource . join
        let _ = src :: AudioSource (ResourceT IO) Float
        return $ realToFrac $ fromIntegral (frames src) / rate src

audioDepend :: BuildInfo -> T.Text -> Staction FilePath
audioDepend buildInfo name = do
  let path = biAudioDependPath buildInfo name
  shk $ need [path]
  return path

data SpecSetting
  = SpecDefault
  | SpecNoPannedMono -- mono is ok if center, but otherwise turn into stereo
  | SpecStereo -- mono always turned into stereo

sourceKick, sourceSnare, sourceKit, sourceToms, sourceCymbals, sourceSimplePart
  :: (MonadResource m)
  => BuildInfo -> [F.PartName] -> TargetCommon g -> F.Song f -> Int -> SpecSetting -> T.Text -> Plan FilePath -> F.PartName -> Integer
  -> Staction (AudioSource m Float)

sourceKick buildInfo gameParts tgt mid pad specSetting planName plan fpart rank = do
  ((spec', _, _), _, _) <- computeDrumsPart fpart plan $ biSongYaml buildInfo
  let spec = adjustSpec specSetting spec'
  src <- case plan of
    MoggPlan x -> channelsToSpec spec (biOggWavForPlan buildInfo planName) (zip x.pans x.vols) $ do
      guard $ rank /= 0
      case HM.lookup fpart x.parts.getParts of
        Just PartDrumKit{kick} -> fromMaybe [] kick
        _                      -> []
    StandardPlan x -> buildAudioToSpec (biYamlDir buildInfo) (biAudioLib buildInfo) (audioDepend buildInfo) (biSongYaml buildInfo) spec planName $ do
      guard $ rank /= 0
      case HM.lookup fpart x.parts.getParts of
        Just PartDrumKit{kick} -> kick
        _                      -> Nothing
  return $ zeroIfMultiple gameParts fpart $ padAudio pad $ applyTargetAudio tgt mid src

sourceSnare buildInfo gameParts tgt mid pad specSetting planName plan fpart rank = do
  ((_, spec', _), _, _) <- computeDrumsPart fpart plan $ biSongYaml buildInfo
  let spec = adjustSpec specSetting spec'
  src <- case plan of
    MoggPlan x -> channelsToSpec spec (biOggWavForPlan buildInfo planName) (zip x.pans x.vols) $ do
      guard $ rank /= 0
      case HM.lookup fpart x.parts.getParts of
        Just PartDrumKit{snare} -> fromMaybe [] snare
        _                       -> []
    StandardPlan x -> buildAudioToSpec (biYamlDir buildInfo) (biAudioLib buildInfo) (audioDepend buildInfo) (biSongYaml buildInfo) spec planName $ do
      guard $ rank /= 0
      case HM.lookup fpart x.parts.getParts of
        Just PartDrumKit{snare} -> snare
        _                       -> Nothing
  return $ zeroIfMultiple gameParts fpart $ padAudio pad $ applyTargetAudio tgt mid src

sourceToms buildInfo gameParts tgt mid pad specSetting planName plan fpart rank = do
  ((_, spec', _), _, _) <- computeDrumsPart fpart plan $ biSongYaml buildInfo
  let spec = adjustSpec specSetting spec'
  src <- case plan of
    MoggPlan x -> channelsToSpec spec (biOggWavForPlan buildInfo planName) (zip x.pans x.vols) $ do
      guard $ rank /= 0
      case HM.lookup fpart x.parts.getParts of
        Just PartDrumKit{toms} -> fromMaybe [] toms
        _                      -> []
    StandardPlan x -> buildAudioToSpec (biYamlDir buildInfo) (biAudioLib buildInfo) (audioDepend buildInfo) (biSongYaml buildInfo) spec planName $ do
      guard $ rank /= 0
      case HM.lookup fpart x.parts.getParts of
        Just PartDrumKit{toms} -> toms
        _                      -> Nothing
  return $ zeroIfMultiple gameParts fpart $ padAudio pad $ applyTargetAudio tgt mid src

sourceCymbals buildInfo gameParts tgt mid pad specSetting planName plan fpart rank = do
  ((_, spec', _), _, _) <- computeDrumsPart fpart plan $ biSongYaml buildInfo
  let spec = adjustSpec specSetting spec'
  src <- case plan of
    MoggPlan x -> channelsToSpec spec (biOggWavForPlan buildInfo planName) (zip x.pans x.vols) $ do
      guard $ rank /= 0
      case HM.lookup fpart x.parts.getParts of
        Just PartDrumKit{toms, kit} -> guard (isJust toms) >> kit
        _                           -> []
    StandardPlan x -> buildAudioToSpec (biYamlDir buildInfo) (biAudioLib buildInfo) (audioDepend buildInfo) (biSongYaml buildInfo) spec planName $ do
      guard $ rank /= 0
      case HM.lookup fpart x.parts.getParts of
        Just PartDrumKit{toms, kit} -> guard (isJust toms) >> Just kit
        _                           -> Nothing
  return $ zeroIfMultiple gameParts fpart $ padAudio pad $ applyTargetAudio tgt mid src

sourceKit buildInfo gameParts tgt mid pad specSetting planName plan fpart rank = do
  ((_, _, spec'), mixMode, _) <- computeDrumsPart fpart plan $ biSongYaml buildInfo
  let spec = adjustSpec specSetting spec'
  src <- case plan of
    MoggPlan x -> let
      build = channelsToSpec spec (biOggWavForPlan buildInfo planName) (zip x.pans x.vols)
      indexSets = do
        guard $ rank /= 0
        case HM.lookup fpart x.parts.getParts of
          Just PartDrumKit{kick, snare, toms, kit} -> case mixMode of
            Drums.D0 -> toList kick <> toList snare <> [kit] <> toList toms
            _        -> [kit] <> toList toms
          Just (PartSingle             kit) -> [kit]
          _                                 -> []
      in mapM build indexSets >>= \case
        []     -> build []
        s : ss -> return $ foldr mix s ss
    StandardPlan x -> let
      build = buildAudioToSpec (biYamlDir buildInfo) (biAudioLib buildInfo) (audioDepend buildInfo) (biSongYaml buildInfo) spec planName
      exprs = do
        guard $ rank /= 0
        case HM.lookup fpart x.parts.getParts of
          Just PartDrumKit{kick, snare, toms, kit} -> case mixMode of
            Drums.D0 -> toList kick <> toList snare <> [kit] <> toList toms
            _        -> [kit] <> toList toms
          Just (PartSingle             kit) -> [kit]
          _                                 -> []
      in mapM (build . Just) exprs >>= \case
        []     -> build Nothing
        s : ss -> return $ foldr mix s ss
  return $ zeroIfMultiple gameParts fpart $ padAudio pad $ applyTargetAudio tgt mid src

getPartSource
  :: (MonadResource m)
  => BuildInfo -> [(Double, Double)] -> T.Text -> Plan FilePath -> F.PartName -> Integer
  -> Staction (AudioSource m Float)
getPartSource buildInfo spec planName plan fpart rank = case plan of
  MoggPlan x -> channelsToSpec spec (biOggWavForPlan buildInfo planName) (zip x.pans x.vols) $ do
    guard $ rank /= 0
    toList (HM.lookup fpart x.parts.getParts) >>= toList >>= toList
  StandardPlan x -> buildPartAudioToSpec (biYamlDir buildInfo) (biAudioLib buildInfo) (audioDepend buildInfo) (biSongYaml buildInfo) spec planName $ do
    guard $ rank /= 0
    HM.lookup fpart x.parts.getParts

sourceStereoParts
  :: (MonadResource m)
  => BuildInfo -> [F.PartName] -> TargetCommon g -> F.Song f -> Int -> T.Text -> Plan FilePath -> [(F.PartName, Integer)]
  -> Staction (AudioSource m Float)
sourceStereoParts buildInfo gameParts tgt mid pad planName plan fpartranks = do
  let spec = [(-1, 0), (1, 0)]
  srcs <- forM fpartranks $ \(fpart, rank)
    -> zeroIfMultiple gameParts fpart
    <$> getPartSource buildInfo spec planName plan fpart rank
  src <- case srcs of
    []     -> buildAudioToSpec (biYamlDir buildInfo) (biAudioLib buildInfo) (audioDepend buildInfo) (biSongYaml buildInfo) spec planName Nothing
    s : ss -> return $ foldr mix s ss
  return $ padAudio pad $ applyTargetAudio tgt mid src

sourceSimplePart buildInfo gameParts tgt mid pad specSetting planName plan fpart rank = do
  let spec = adjustSpec specSetting $ computeSimplePart fpart plan $ biSongYaml buildInfo
  src <- getPartSource buildInfo spec planName plan fpart rank
  return $ zeroIfMultiple gameParts fpart $ padAudio pad $ applyTargetAudio tgt mid src

sourceCrowd
  :: (MonadResource m)
  => BuildInfo -> TargetCommon g -> F.Song f -> Int -> T.Text -> Plan FilePath
  -> Staction (AudioSource m Float)
sourceCrowd buildInfo tgt mid pad planName plan = do
  src <- case plan of
    MoggPlan     x -> channelsToSpec
      [(-1, 0), (1, 0)] (biOggWavForPlan buildInfo planName) (zip x.pans x.vols) x.crowd
    StandardPlan x -> buildAudioToSpec
      (biYamlDir buildInfo) (biAudioLib buildInfo) (audioDepend buildInfo) (biSongYaml buildInfo) [(-1, 0), (1, 0)] planName x.crowd
  return $ padAudio pad $ applyTargetAudio tgt mid src

sourceBacking
  :: (MonadResource m)
  => BuildInfo -> TargetCommon g -> F.Song f -> Int -> T.Text -> Plan FilePath -> [(F.PartName, Integer)]
  -> Staction (AudioSource m Float)
sourceBacking buildInfo tgt mid pad planName plan fparts = do
  let usedParts' = [ fpart | (fpart, rank) <- fparts, rank /= 0 ]
      usedParts =
        [ fpart
        | fpart <- usedParts'
        , case filter (== fpart) usedParts' of
          -- if more than 1 game part maps to this flex part,
          -- the flex part's audio should go in backing track
          _ : _ : _ -> False
          _         -> True
        ]
      spec = [(-1, 0), (1, 0)]
  src <- case plan of
    MoggPlan x -> channelsToSpec spec (biOggWavForPlan buildInfo planName) (zip x.pans x.vols) $ let
      channelsFor fpart = toList (HM.lookup fpart x.parts.getParts) >>= toList >>= toList
      usedChannels = concatMap channelsFor usedParts ++ x.crowd
      in filter (`notElem` usedChannels) [0 .. length x.pans - 1]
    StandardPlan x -> let
      unusedParts = do
        (fpart, pa) <- HM.toList x.parts.getParts
        guard $ notElem fpart usedParts
        return pa
      partAudios = maybe id (\pa -> (PartSingle pa :)) x.song unusedParts
      in do
        unusedSrcs <- mapM (buildPartAudioToSpec (biYamlDir buildInfo) (biAudioLib buildInfo) (audioDepend buildInfo) (biSongYaml buildInfo) spec planName . Just) partAudios
        case unusedSrcs of
          []     -> buildPartAudioToSpec (biYamlDir buildInfo) (biAudioLib buildInfo) (audioDepend buildInfo) (biSongYaml buildInfo) spec planName Nothing
          s : ss -> return $ foldr mix s ss
  return $ padAudio pad $ applyTargetAudio tgt mid src

adjustSpec :: SpecSetting -> [(Double, Double)] -> [(Double, Double)]
adjustSpec SpecDefault      spec     = spec
adjustSpec SpecNoPannedMono [(0, 0)] = [(0, 0)]
adjustSpec SpecNoPannedMono _        = [(-1, 0), (1, 0)]
adjustSpec SpecStereo       _        = [(-1, 0), (1, 0)]

padAudio :: (Monad m) => Int -> AudioSource m Float -> AudioSource m Float
padAudio pad src = if frames src == 0
  -- NOTE: ffmpeg loaded .xma files have length set to 0, so we hack it in Onyx.Audio.buildSource'
  then src
  else padStart (Seconds $ realToFrac pad) src

setAudioLength :: (Monad m) => U.Seconds -> AudioSource m Float -> AudioSource m Float
setAudioLength len src = let
  currentLength = fromIntegral (frames src) / rate src
  requiredLength = realToFrac len
  in case compare currentLength requiredLength of
    EQ -> src
    LT -> padEnd (Seconds $ requiredLength - currentLength) src
    GT -> takeStart (Seconds requiredLength) src

setAudioLengthOrEmpty :: (Monad m) => U.Seconds -> AudioSource m Float -> m (AudioSource m Float)
setAudioLengthOrEmpty secs src = do
  chans <- runConduit $ emptyChannels src
  return $ if length chans == channels src
    then src { frames = 0, source = return () }
    else setAudioLength secs src

isSilentSource :: (Monad m) => AudioSource m Float -> m Bool
isSilentSource src = do
  chans <- runConduit $ emptyChannels src
  return $ length chans == channels src

-- Silences out an audio stream if more than 1 game part maps to the same flex part
zeroIfMultiple :: (Monad m) => [F.PartName] -> F.PartName -> AudioSource m Float -> AudioSource m Float
zeroIfMultiple fparts fpart src = case filter (== fpart) fparts of
  _ : _ : _ -> takeStart (Frames 0) src
  _         -> src

fullGenre :: Metadata f -> FullGenre
fullGenre metadata = interpretGenre metadata.genre metadata.subgenre

-- Second element is a JPEG if it is reasonably square and can be used in CH/PS as is.
loadSquareArtOrJPEG :: SongYaml FilePath -> Staction (Image PixelRGB8, Maybe FilePath)
loadSquareArtOrJPEG songYaml = case songYaml.metadata.fileAlbumArt of
  Just img -> do
    shk $ need [img]
    let ext = map toLower $ takeExtension img
    stackIO $ if elem ext [".png_xbox", ".png_wii"]
      then noJPEG . pixelMap dropTransparency . readRBImage False <$> BL.readFile img
      else if ext == ".png_ps3"
        then noJPEG . pixelMap dropTransparency . readRBImage True <$> BL.readFile img
        else readImage img >>= \case
          Left  err -> fail $ "Failed to load cover art (" ++ img ++ "): " ++ err
          Right dyn -> let
            rgb8 = convertRGB8 dyn
            rgba8 = convertRGBA8 dyn
            aspect = fromIntegral (imageWidth rgb8) / fromIntegral (imageHeight rgb8) :: Double
            nonSquare = aspect > (5/4) || aspect < (4/5)
            in return $ if nonSquare
              then noJPEG $ pixelMap dropTransparency $ backgroundColor (PixelRGBA8 0 0 0 255) $ squareImage 0 rgba8
              else (rgb8, guard (elem ext [".jpg", ".jpeg"]) >> Just img)
  Nothing -> noJPEG <$> stackIO onyxAlbum
  where noJPEG rgb = (rgb, Nothing)

loadRGB8 :: SongYaml FilePath -> Staction (Image PixelRGB8)
loadRGB8 = fmap fst . loadSquareArtOrJPEG

squareImage :: Int -> Image PixelRGBA8 -> Image PixelRGBA8
squareImage pad img = let
  squareSize = max (imageWidth img) (imageHeight img) + pad
  adjustX x = x - quot (squareSize - imageWidth  img) 2
  adjustY y = y - quot (squareSize - imageHeight img) 2
  in generateImage
    (\(adjustX -> x) (adjustY -> y) ->
      if 0 <= x && x < imageWidth img && 0 <= y && y < imageHeight img
        then pixelAt img x y
        else PixelRGBA8 0 0 0 0
    )
    squareSize
    squareSize

backgroundColor :: PixelRGBA8 -> Image PixelRGBA8 -> Image PixelRGBA8
backgroundColor bg img = let
  floatToByte c
    | c < 0     = 0
    | c > 1     = 255
    | otherwise = round $ (c :: Float) * 255
  overlay
    (PixelRGBA8 (promotePixel -> r1) (promotePixel -> g1) (promotePixel -> b1) (promotePixel -> a1))
    (PixelRGBA8 (promotePixel -> r2) (promotePixel -> g2) (promotePixel -> b2) (promotePixel -> a2))
    = PixelRGBA8
      (floatToByte $ r1 * a1 * (1 - a2) + r2 * a2)
      (floatToByte $ g1 * a1 * (1 - a2) + g2 * a2)
      (floatToByte $ b1 * a1 * (1 - a2) + b2 * a2)
      (floatToByte $ a1 * (1 - a2) + a2)
  in generateImage
    (\x y -> overlay bg $ pixelAt img x y)
    (imageWidth img)
    (imageHeight img)

applyTargetAudio :: (MonadResource m) => TargetCommon g -> F.Song f -> AudioSource m Float -> AudioSource m Float
applyTargetAudio tgt mid = let
  eval = evalPreviewTime False Nothing mid 0 False -- TODO get Events track to support sections as segment boundaries
  bounds :: SegmentEdge -> Maybe (U.Seconds, U.Seconds)
  bounds seg = liftA2 (,) (eval seg.fadeStart) (eval seg.fadeEnd)
  toDuration :: U.Seconds -> Duration
  toDuration = Seconds . realToFrac
  applyEnd = case tgt.end >>= bounds of
    Nothing           -> id
    Just (start, end) -> fadeEnd (toDuration $ end - start) . takeStart (toDuration end)
  applyStart = case tgt.start >>= bounds of
    Nothing           -> id
    Just (start, end) -> fadeStart (toDuration $ end - start) . dropStart (toDuration start)
  applySpeed = applySpeedAudio tgt
  in applySpeed . applyStart . applyEnd

applySpeedAudio :: (MonadResource m) => TargetCommon f -> AudioSource m Float -> AudioSource m Float
applySpeedAudio tgt = case fromMaybe 1 tgt.speed of
  1 -> id
  n -> stretchFull (1 / n) 1

data NameRule
  = NameRulePC -- mostly windows but also mac/linux
  | NameRulePCUnicode
  | NameRuleXbox -- stfs files on hard drive. includes pc rules too
  deriving (Eq)

-- Smarter length trim that keeps 1x, 2x, 125, rb3con, etc. at end of name
makeLength :: Int -> T.Text -> T.Text
makeLength n t = if n >= T.length t
  then t
  else case reverse $ T.splitOn "_" t of
    lastPiece : rest@(_ : _) -> let
      (modifiers, notModifiers) = flip span rest $ \x ->
        x == "1x" || x == "2x" || T.all isDigit x || case T.uncons x of
          Just ('v', v) -> T.all isDigit v
          _             -> False
      base = T.intercalate "_" $ reverse notModifiers
      suffix = T.intercalate "_" $ reverse $ lastPiece : modifiers
      base' = T.dropWhileEnd (== '_') $ T.take (max 1 $ n - (T.length suffix + 1)) base
      in T.take n $ base' <> "_" <> suffix
    _ -> T.take n t

validFileNamePiece :: NameRule -> T.Text -> T.Text
validFileNamePiece rule s = let
  trimLength = case rule of
    NameRulePC        -> id
    NameRulePCUnicode -> id
    NameRuleXbox      -> makeLength 42
  invalidChars :: String
  invalidChars = "<>:\"/\\|?*" <> case rule of
    NameRulePC        -> ""
    NameRulePCUnicode -> ""
    NameRuleXbox      -> "+," -- these are only invalid on hard drives? not usb drives apparently
  eachChar c = if (isAscii c || rule == NameRulePCUnicode) && not (isControl c) && notElem c invalidChars
    then c
    else '_'
  fixEnds = T.dropWhile isSpace . T.dropWhileEnd (\c -> isSpace c || c == '.')
  reserved =
    [ ""
    -- rest are invalid names on Windows
    , "CON", "PRN", "AUX", "NUL"
    , "COM1", "COM2", "COM3", "COM4", "COM5", "COM6", "COM7", "COM8", "COM9", "COM0"
    , "LPT1", "LPT2", "LPT3", "LPT4", "LPT5", "LPT6", "LPT7", "LPT8", "LPT9", "LPT0"
    ]
  s' = fixEnds $ trimLength $ T.map eachChar $ case rule of
    NameRulePCUnicode -> s
    _                 -> unsafePerformIO $ replaceCharsRB False s
  in if elem (T.toUpper s') reserved
    then s' <> "_"
    else s'

validFileName :: NameRule -> FilePath -> FilePath
validFileName rule f = let
  (dir, file) = splitFileName f
  in dir </> T.unpack (validFileNamePiece rule $ T.pack file)

makeShortName :: Int -> SongYaml f -> T.Text
makeShortName num songYaml
  = T.dropWhileEnd (== '_')
  -- Short name doesn't have to be name used in paths but it makes things simple.
  -- Max path name is 40 chars (stfs limit) - 14 chars ("_keep.png_xbox") = 26 chars.
  -- Also now used for GH3, which has a 27 char max (40 - 13 for "_song.pak.xen")
  $ T.take 26
  $ "o" <> T.pack (show num)
    <> "_" <> makePart (getTitle  songYaml.metadata)
    <> "_" <> makePart (getArtist songYaml.metadata)
  where makePart = T.toLower . T.filter (\c -> isAscii c && isAlphaNum c)

getPlan :: Maybe T.Text -> SongYaml f -> Maybe (T.Text, Plan f)
getPlan Nothing songYaml = case HM.toList songYaml.plans of
  [pair] -> Just pair
  _      -> Nothing
getPlan (Just p) songYaml = case HM.lookup p songYaml.plans of
  Just found -> Just (p, found)
  Nothing    -> Nothing
