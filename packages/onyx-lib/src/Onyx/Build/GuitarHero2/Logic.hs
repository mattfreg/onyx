{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE LambdaCase            #-}
{-# LANGUAGE NoFieldSelectors      #-}
{-# LANGUAGE OverloadedRecordDot   #-}
{-# LANGUAGE OverloadedStrings     #-}
{-# LANGUAGE RecordWildCards       #-}
{-# LANGUAGE StrictData            #-}
{-# LANGUAGE TupleSections         #-}
module Onyx.Build.GuitarHero2.Logic where

import           Control.Monad                        (guard, void)
import           Control.Monad.Random                 (evalRand, mkStdGen)
import           Data.Bifunctor                       (bimap)
import qualified Data.EventList.Relative.TimeBody     as RTB
import           Data.Foldable                        (toList)
import           Data.Hashable                        (hash)
import qualified Data.Map                             as Map
import           Data.Maybe                           (catMaybes, fromMaybe,
                                                       isJust, isNothing)
import qualified Data.Text                            as T
import qualified Numeric.NonNegative.Class            as NNC
import           Onyx.Build.Common                    (getTargetMetadata)
import           Onyx.Build.RB3CH                     (BasicTiming (..),
                                                       basicTiming)
import qualified Onyx.Build.RB3CH                     as RB3
import           Onyx.Guitar
import           Onyx.Harmonix.Ark.GH2                (GH2DXExtra (..))
import qualified Onyx.Harmonix.DTA                    as D
import qualified Onyx.Harmonix.DTA.Serialize          as D
import qualified Onyx.Harmonix.DTA.Serialize.GH2      as D
import qualified Onyx.Harmonix.DTA.Serialize.Magma    as Magma
import           Onyx.Harmonix.DTA.Serialize.RockBand (AnimTempo (..))
import           Onyx.Harmonix.GH2.BandBass
import           Onyx.Harmonix.GH2.BandDrums
import           Onyx.Harmonix.GH2.BandKeys
import           Onyx.Harmonix.GH2.BandSinger
import           Onyx.Harmonix.GH2.Events
import           Onyx.Harmonix.GH2.File
import           Onyx.Harmonix.GH2.PartDrum
import           Onyx.Harmonix.GH2.PartGuitar
import           Onyx.Harmonix.GH2.Triggers
import           Onyx.MIDI.Common                     (Difficulty (..),
                                                       LongNote (..), Mood (..),
                                                       splitEdges)
import qualified Onyx.MIDI.Track.Drums                as RB
import qualified Onyx.MIDI.Track.Events               as RB
import qualified Onyx.MIDI.Track.File                 as F
import qualified Onyx.MIDI.Track.FiveFret             as RB
import qualified Onyx.MIDI.Track.Vocal                as RB
import           Onyx.Mode
import           Onyx.Overdrive                       (removeNotelessOD)
import           Onyx.Project
import           Onyx.Reductions                      (completeFiveResult)
import           Onyx.Sections                        (makeGH2Section,
                                                       sectionBody)
import           Onyx.StackTrace
import qualified Sound.MIDI.Util                      as U

gh2Pad
  :: (SendMessage m)
  => F.Song (GH2File U.Beats)
  -> StackTraceT m (F.Song (GH2File U.Beats), Int)
gh2Pad rb3@(F.Song tmap _ trks) = let
  firstEvent rtb = case RTB.viewL rtb of
    Just ((dt, _), _) -> dt
    Nothing           -> 999
  firstNoteBeats = foldr min 999 $ concat
    [ map (firstEvent . partGems) $ Map.elems $ partDifficulties $ gh2PartGuitar     trks
    , map (firstEvent . partGems) $ Map.elems $ partDifficulties $ gh2PartBass       trks
    , map (firstEvent . partGems) $ Map.elems $ partDifficulties $ gh2PartRhythm     trks
    , map (firstEvent . partGems) $ Map.elems $ partDifficulties $ gh2PartGuitarCoop trks
    ]
  firstNoteSeconds = U.applyTempoMap tmap firstNoteBeats
  -- no idea but just going with similar value to what Magma enforces for RB
  padSeconds = max 0 $ ceiling $ 2.6 - (realToFrac firstNoteSeconds :: Rational)
  in case padSeconds of
    0 -> do
      return (rb3, 0)
    _ -> do
      warn $ "Padding song by " ++ show padSeconds ++ "s due to early notes."
      return (F.padAnyFile padSeconds rb3, padSeconds)

data GH2AudioSection
  = GH2PartStereo F.PartName
  | GH2PartMono F.PartName
  | GH2Band -- stereo
  | GH2Silent -- mono

data GH2Audio = GH2Audio
  { audioSections :: [GH2AudioSection]
  , leadChannels  :: [Int]
  , coopChannels  :: [Int]
  , drumChannels  :: [Int]
  , backChannels  :: [Int]
  , leadTrack     :: F.PartName
  , coopTrack     :: F.PartName
  , drumTrack     :: Maybe F.PartName
  , coopType      :: GH2Coop
  , animBass      :: Maybe F.PartName
  , animDrums     :: Maybe F.PartName
  , animVocal     :: Maybe F.PartName
  , animKeys      :: Maybe F.PartName
  , practice      :: [Maybe F.PartName]
  , leadPractice  :: Int
  , coopPractice  :: Int
  , drumPractice  :: Maybe Int
  }

computeGH2Audio
  :: (Monad m)
  => SongYaml f
  -> TargetGH2 f
  -> Bool -- xbox 360
  -> (F.PartName -> Bool) -- True if part has own audio
  -> StackTraceT m GH2Audio
computeGH2Audio song target is360 hasAudio = do
  let canGetFiveFret = \case
        Nothing   -> False
        Just part -> isJust $ anyFiveFret part
  leadTrack <- if canGetFiveFret $ getPart target.guitar song
    then return target.guitar
    else fatal "computeGH2Audio: no lead guitar part selected"
  let drumTrack = do
        guard target.gh2Deluxe
        case getPart target.drums song >>= anyDrums of
          Nothing -> Nothing
          Just _  -> Just target.drums
      specifiedCoop = case target.coop of
        GH2Bass   -> target.bass
        GH2Rhythm -> target.rhythm
      (coopTrack, coopType) = if canGetFiveFret $ getPart specifiedCoop song
        then (specifiedCoop, target.coop)
        else (leadTrack    , GH2Rhythm  )
      leadAudio = hasAudio leadTrack
      coopAudio = leadTrack /= coopTrack && hasAudio coopTrack
      drumAudio = maybe False hasAudio drumTrack
      count = \case
        GH2PartStereo _ -> 2
        GH2PartMono   _ -> 1
        GH2Band         -> 2
        GH2Silent       -> 1
      maxChannels = if is360 then 12 else 6 -- don't know actual 360 max but we won't reach it

      -- order: band, guitar, bass, drums, silent
      bandSection = [GH2Band]
      silentSection = do
        guard $ not leadAudio || not coopAudio || (isJust drumTrack && not drumAudio)
        [GH2Silent]
      drumSection = do
        guard drumAudio
        GH2PartStereo <$> toList drumTrack
      remainingLeadCoop = maxChannels - sum (map count $ concat [bandSection, silentSection, drumSection])
      leadSection = do
        guard leadAudio
        if (coopAudio && remainingLeadCoop >= 3) || (not coopAudio && remainingLeadCoop >= 2)
          then [GH2PartStereo leadTrack]
          else [GH2PartMono   leadTrack]
      coopSection = do
        guard coopAudio
        if maxChannels - sum (map count $ concat [bandSection, silentSection, drumSection, leadSection]) >= 2
          then [GH2PartStereo coopTrack]
          else [GH2PartMono   coopTrack]

      audioSections = concat [bandSection, leadSection, coopSection, drumSection, silentSection]
      indexes before section = take (sum $ map count section) [sum (map count before) ..]
      leadChannels = if leadAudio
        then indexes bandSection leadSection
        else indexes (concat [bandSection, leadSection, coopSection, drumSection]) silentSection
      coopChannels = if coopAudio
        then indexes (concat [bandSection, leadSection]) coopSection
        else indexes (concat [bandSection, leadSection, coopSection, drumSection]) silentSection
      drumChannels = if drumAudio
        then indexes (concat [bandSection, leadSection, coopSection]) drumSection
        else if isJust drumTrack
          then indexes (concat [bandSection, leadSection, coopSection, drumSection]) silentSection
          else []
      backChannels = [0, 1] -- should always be this for our output
      (practice, leadPractice, coopPractice, drumPractice) = if target.practiceAudio
        then let
          -- From testing, you can't just have 1 channel and assign it to both lead and bass/rhythm;
          -- you get no audio. I'm guessing any channels for an instrument other than the one
          -- you're playing are muted, even if they're also assigned to the one you're playing.
          contentsLead = guard leadAudio >> Just leadTrack
          contentsCoop = guard coopAudio >> Just coopTrack
          contentsDrum = case drumTrack of
            Nothing -> []
            Just _  -> [guard drumAudio >> drumTrack]
          allContents = [contentsLead, contentsCoop] <> contentsDrum
          in (allContents, 0, 1, guard (not $ null contentsDrum) >> Just 2)
        else ([Nothing], 0, 0, 0 <$ drumTrack) -- we'll make a single mono silent track
      animBass  = target.bass  <$ (getPart target.bass  song >>= (.grybo))
      animDrums = target.drums <$ (getPart target.drums song >>= (.drums))
      animVocal = target.vocal <$ (getPart target.vocal song >>= (.vocal))
      animKeys  = target.keys  <$ (getPart target.keys  song >>= (.grybo))
  return GH2Audio{..}

-- GH2DX uses solo format of "note on solo start, note on solo end".
-- For simplicity, if one solo ends right when another one begins,
-- just join them together (don't emit anything at their shared edge)
makeSoloEdges :: (NNC.C t) => RTB.T t Bool -> RTB.T t ()
makeSoloEdges = void . RTB.filter (odd . length) . RTB.collectCoincident

midiRB3toGH2
  :: (SendMessage m)
  => SongYaml f
  -> TargetGH2 f
  -> GH2Audio
  -> F.Song (F.OnyxFile U.Beats)
  -> StackTraceT m U.Seconds
  -> StackTraceT m (F.Song (GH2File U.Beats), Int)
midiRB3toGH2 song target audio inputMid@(F.Song tmap mmap onyx) getAudioLength = do
  timing <- basicTiming False inputMid getAudioLength
  let makeMoods origMoods gems = let
        moods = if RTB.null origMoods
          then RB3.makeMoods tmap timing gems
          else origMoods
        bools = flip fmap moods $ \case
          Mood_idle_realtime -> False
          Mood_idle          -> False
          Mood_idle_intense  -> False
          Mood_play          -> True
          Mood_mellow        -> True
          Mood_intense       -> True
          Mood_play_solo     -> True
        in (const () <$> RTB.filter not bools, const () <$> RTB.filter id bools) -- (idle, play)
      makeGRYBO fpart = case completeFiveResult False mmap <$> getFive' fpart of
        Nothing -> return mempty
        Just result -> do
          let gap = fromIntegral result.settings.sustainGap / 480
              editNotes
                = fromClosed'
                . noOpenNotes result.settings.detectMutedOpens
                . noExtendedSustains' standardBlipThreshold gap
              makeDiff diff notes = do
                let notes' = editNotes notes
                od <- removeNotelessOD
                  mmap
                  [(fpart, [(show diff, void notes')])]
                  ((fpart,) <$> result.other.fiveOverdrive)
                let emitted = emitGuitar5 notes'
                return PartDifficulty
                  { partStarPower  = snd <$> od
                  , partPlayer1    = result.other.fivePlayer1
                  , partPlayer2    = result.other.fivePlayer2
                  , partGems       = RTB.mapMaybe sequence emitted.fiveGems
                  , partForceHOPO  = if target.gh2Deluxe then emitted.fiveForceHOPO  else RTB.empty
                  , partForceStrum = if target.gh2Deluxe then emitted.fiveForceStrum else RTB.empty
                  , partForceTap   = if target.gh2Deluxe then emitted.fiveTap        else RTB.empty
                  }
              (idle, play) = makeMoods result.other.fiveMood
                $ maybe mempty (splitEdges . fmap (\((fret, sht), len) -> (fret, sht, len)))
                $ Map.lookup Expert result.notes
          diffs <- fmap Map.fromList
            $ mapM (\(diff, notes) -> (diff,) <$> makeDiff diff notes)
            $ Map.toList result.notes
          return mempty
            { partDifficulties = diffs
            , partFretPosition = result.other.fiveFretPosition
            , partIdle         = idle
            , partPlay         = play
            , partHandMap      = flip fmap result.other.fiveHandMap $ \case
              RB.HandMap_Default   -> HandMap_Default
              RB.HandMap_NoChords  -> HandMap_NoChords
              RB.HandMap_AllChords -> HandMap_AllChords
              RB.HandMap_Solo      -> HandMap_Solo
              RB.HandMap_DropD     -> HandMap_DropD2
              RB.HandMap_DropD2    -> HandMap_DropD2
              RB.HandMap_AllBend   -> HandMap_Solo
              RB.HandMap_Chord_C   -> HandMap_Default
              RB.HandMap_Chord_D   -> HandMap_Default
              RB.HandMap_Chord_A   -> HandMap_Default
            , partSoloEdge     = if target.gh2Deluxe
              then makeSoloEdges result.other.fiveSolo
              else RTB.empty
            }
      makeDrum fpart = case getPart fpart song >>= anyDrums of
        Nothing      -> mempty
        Just builder -> let
          trackOrig = drumResultToTrack $ builder
            (if target.is2xBassPedal then DrumTargetRB2x else DrumTargetRB1x)
            ModeInput
              { tempo  = tmap
              , events = F.getEventsTrack onyx
              , part   = F.getFlexPart fpart onyx
              }
          in GH2DrumTrack
            { gh2drumDifficulties = flip fmap trackOrig.drumDifficulties $ \diff -> GH2DrumDifficulty
              { gh2drumStarPower = trackOrig.drumOverdrive
              , gh2drumPlayer1   = trackOrig.drumPlayer1
              , gh2drumPlayer2   = trackOrig.drumPlayer2
              , gh2drumGems      = fmap fst diff.drumGems
              }
            , gh2drumSoloEdge = if target.gh2Deluxe
              then makeSoloEdges trackOrig.drumSolo
              else RTB.empty
            }
      makeBandBass :: FiveResult -> BandBassTrack U.Beats
      makeBandBass result = mempty
        { bassIdle  = idle
        , bassPlay  = play
        , bassStrum
          = void
          . RTB.collectCoincident
          . fromMaybe mempty
          $ Map.lookup Expert result.notes
        } where (idle, play) = makeMoods result.other.fiveMood
                  $ maybe mempty (splitEdges . fmap (\((fret, sht), len) -> (fret, sht, len)))
                  $ Map.lookup Expert result.notes
      makeBandDrums trk = mempty
        { drumsIdle = idle
        , drumsPlay = play
        , drumsKick  = void $ flip RTB.filter anims $ \case
          RB.KickRF -> True
          _         -> False
        , drumsCrash = void $ RTB.collectCoincident $ flip RTB.filter anims $ \case
          RB.Crash1{}        -> True
          RB.Crash2{}        -> True
          RB.Crash1RHChokeLH -> True
          RB.Crash2RHChokeLH -> True
          _                  -> False
        } where (idle, play) = makeMoods trk.drumMood $ Blip () () <$ anims
                anims = (RB.fillDrumAnimation (0.25 :: U.Seconds) tmap trk).drumAnimation
      makeBandKeys :: FiveResult -> BandKeysTrack U.Beats
      makeBandKeys result = let
        (idle, play) = makeMoods result.other.fiveMood
          $ maybe mempty (splitEdges . fmap (\((fret, sht), len) -> (fret, sht, len)))
          $ Map.lookup Expert result.notes
        in mempty { keysIdle = idle, keysPlay = play }
      makeBandSinger trk = let
        (idle, play) = makeMoods trk.vocalMood
          $ fmap (\case (p, True) -> NoteOn () p; (p, False) -> NoteOff p)
          $ RB.vocalNotes trk
        in mempty { singerIdle = idle, singerPlay = play }
      events = mempty
        { eventsSections      = fmap (makeGH2Section . sectionBody) onyx.onyxEvents.eventsSections
        , eventsOther         = foldr RTB.merge RTB.empty
          [ RTB.cons (timingMusicStart timing) MusicStart RTB.empty
          , RTB.cons (timingEnd        timing) End        RTB.empty
          ]
        }
      triggers = mempty
        { triggersBacking = onyx.onyxEvents.eventsBacking
        }
      getFive' fpart = do
        builder <- getPart fpart song >>= anyFiveFret
        return $ builder FiveTypeGuitar ModeInput
          { tempo  = tmap
          , events = onyx.onyxEvents
          , part   = F.getFlexPart fpart onyx
          }
  gh2PartGuitar <- makeGRYBO audio.leadTrack
  coopTrack <- if audio.coopTrack == audio.leadTrack
    then return gh2PartGuitar
    else makeGRYBO audio.coopTrack
  let gh2 = GH2File
        { gh2PartGuitarCoop = mempty
        , gh2PartBass = case audio.coopType of
            GH2Rhythm -> mempty
            GH2Bass   -> coopTrack
        , gh2PartRhythm = case audio.coopType of
            GH2Rhythm -> coopTrack
            GH2Bass   -> mempty
        , gh2PartDrum = maybe mempty makeDrum audio.drumTrack
        , gh2BandBass       = maybe mempty (\part -> maybe mempty makeBandBass $ getFive' part) audio.animBass
        , gh2BandDrums      = maybe mempty (\part -> makeBandDrums (F.getFlexPart part onyx).onyxPartDrums) audio.animDrums
        , gh2BandKeys       = maybe mempty (\part -> maybe mempty makeBandKeys $ getFive' part) audio.animKeys
        , gh2BandSinger     = maybe mempty (\part -> makeBandSinger (F.getFlexPart part onyx).onyxPartVocals) audio.animVocal
        , gh2Events         = events
        , gh2Triggers       = triggers
        , ..
        }
  gh2Pad $ F.Song tmap mmap gh2

bandMembers :: SongYaml f -> GH2Audio -> Maybe [Either D.BandMember T.Text]
bandMembers song audio = let
  vocal = case audio.animVocal of
    Nothing    -> Nothing
    Just fpart -> Just $ fromMaybe Magma.Male $ getPart fpart song >>= (.vocal) >>= (.gender)
  bass = True -- we'll just assume there's always a bassist (not required though - Jordan)
  keys = isJust audio.animKeys
  drums = True -- crashes if missing
  in case (vocal, bass, keys, drums) of
    (Just Magma.Male, True, False, True) -> Nothing -- the default configuration
    _                                    -> Just $ map Left $ concat
      [ toList $ (\case Magma.Male -> D.MetalSinger; Magma.Female -> D.FemaleSinger) <$> vocal
      , [D.MetalBass     | bass ]
      , [D.MetalKeyboard | keys && isNothing vocal] -- singer overrides keyboard, can't have both
      , [D.MetalDrummer  | drums]
      ]

adjustSongText :: T.Text -> T.Text
adjustSongText = T.replace "&" "+"
  -- GH2 doesn't have & in the start-of-song-display font.
  -- In the song list it just displays as + anyway.
  -- TODO we need to do non-latin-1 replacement
  -- TODO any other text we need to do this on, author maybe? other gh2dx metadata?

-- Pass along guitar's (probably imported) hopo threshold
getDefaultHOPOThreshold :: SongYaml f -> GH2Audio -> Maybe Integer
getDefaultHOPOThreshold song audio = fmap (fromIntegral . (.hopoThreshold))
  $ getPart audio.leadTrack song >>= (.grybo)
  -- could support other converted modes I guess but this is realistically
  -- the only place weird thresholds would come from

makeGH2DTA :: SongYaml f -> T.Text -> (Int, Int) -> TargetGH2 f -> GH2Audio -> T.Text -> D.SongPackage
makeGH2DTA song key preview target audio title = D.SongPackage
  { D.name = adjustSongText title
  , D.artist = adjustSongText $ getArtist metadata
  , D.caption = guard (not metadata.cover) >> Just "performed_by"
  , D.song = makeSong target.gh2Deluxe
  , D.song_vs = if target.gh2Deluxe then Just $ makeSong False else Nothing
  , D.animTempo = KTempoMedium
  , D.preview = bimap fromIntegral fromIntegral preview
  , D.quickplay = evalRand D.randomQuickplay $ mkStdGen $ hash key
  , D.practiceSpeeds = Just [100, 90, 75, 60]
  , D.songCoop = Nothing
  , D.songPractice1 = Just $ prac 90
  , D.songPractice2 = Just $ prac 75
  , D.songPractice3 = Just $ prac 60
  , D.band = bandMembers song audio
  } where
    metadata = getTargetMetadata song $ GH2 target
    coop = case audio.coopType of GH2Bass -> "bass"; GH2Rhythm -> "rhythm"
    prac :: Int -> D.Song
    prac speed = D.Song
      { D.songName = if target.practiceAudio
        then "songs/" <> key <> "/" <> key <> "_p" <> T.pack (show speed)
        else "songs/" <> key <> "/" <> key <> "_empty"
      , D.tracks = D.DictList $ filter (\(_, ns) -> not $ null ns)
        [ ("guitar", [fromIntegral audio.leadPractice])
        , (coop    , [fromIntegral audio.coopPractice])
        , ("drum"  , maybe [] (\n -> [fromIntegral n]) audio.drumPractice)
        ]
      , D.pans = 0 <$ audio.practice
      , D.vols = 0 <$ audio.practice
      , D.cores = (-1) <$ audio.practice
      , D.midiFile = "songs/" <> key <> "/" <> key <> ".mid"
      , D.hopoThreshold = threshold
      }
    makeSong includeTrack3 = D.Song
      { D.songName      = "songs/" <> key <> "/" <> key
      , D.tracks        = D.DictList $ filter (\(_, ns) -> not $ null ns) $
        [ ("guitar", map fromIntegral audio.leadChannels)
        , (coop    , map fromIntegral audio.coopChannels)
        ] <> if includeTrack3
          then if null audio.drumChannels
            -- GH2DX2 in some configurations requires a third tracks entry, even when there is no drum part
            then [("fake", map fromIntegral audio.backChannels)]
            else [("drum", map fromIntegral audio.drumChannels)]
          else []
      , D.pans          = audio.audioSections >>= \case
        GH2PartStereo _ -> [-1, 1]
        GH2PartMono   _ -> [0]
        GH2Band         -> [-1, 1]
        GH2Silent       -> [0]
      , D.vols          = audio.audioSections >>= \case
        GH2PartStereo _ -> [0, 0]
        GH2PartMono   _ -> [20 * (log 2 / log 10)] -- compensate for half volume later
        GH2Band         -> [0, 0]
        GH2Silent       -> [0]
      , D.cores         = audio.audioSections >>= \case
        GH2PartStereo p -> if p == audio.leadTrack then [1, 1] else [-1, -1]
        GH2PartMono p   -> if p == audio.leadTrack then [1] else [-1]
        GH2Band         -> [-1, -1]
        GH2Silent       -> [-1]
      , D.midiFile      = "songs/" <> key <> "/" <> key <> ".mid"
      , D.hopoThreshold = threshold
      }
    threshold = getDefaultHOPOThreshold song audio

makeGH2DTA360 :: SongYaml f -> T.Text -> (Int, Int) -> TargetGH2 f -> GH2Audio -> T.Text -> D.SongPackage
makeGH2DTA360 song key preview target audio title = D.SongPackage
  { D.name = adjustSongText title
  , D.artist = adjustSongText $ getArtist metadata
  , D.caption = guard (not metadata.cover) >> Just "performed_by"
  , D.song = makeSong target.gh2Deluxe
  , D.song_vs = if target.gh2Deluxe then Just $ makeSong False else Nothing
  , D.animTempo = KTempoMedium
  , D.preview = bimap fromIntegral fromIntegral preview
  , D.quickplay = evalRand D.randomQuickplay $ mkStdGen $ hash key
  , D.practiceSpeeds = Nothing
  , D.songCoop = Nothing
  , D.songPractice1 = Nothing
  , D.songPractice2 = Nothing
  , D.songPractice3 = Nothing
  , D.band = bandMembers song audio
  } where
    metadata = getTargetMetadata song $ GH2 target
    coop = case target.coop of GH2Bass -> "bass"; GH2Rhythm -> "rhythm"
    makeSong includeTrack3 = D.Song
      { D.songName      = "songs/" <> key <> "/" <> key
      , D.tracks        = D.DictList $ filter (\(_, ns) -> not $ null ns) $
        [ ("guitar", map fromIntegral audio.leadChannels)
        , (coop    , map fromIntegral audio.coopChannels)
        ] <> [("drum", map fromIntegral audio.drumChannels) | includeTrack3]
      , D.pans          = audio.audioSections >>= \case
        GH2PartStereo _ -> [-1, 1]
        GH2PartMono   _ -> [0] -- note, we don't use actually any mono on 360
        GH2Band         -> [-1, 1]
        GH2Silent       -> [0]
      , D.vols          = audio.audioSections >>= \case
        GH2PartStereo _ -> [0, 0]
        GH2PartMono   _ -> [20 * (log 2 / log 10)] -- compensate for half volume later
        GH2Band         -> [0, 0]
        GH2Silent       -> [0]
      , D.cores         = audio.audioSections >>= \case
        GH2PartStereo p -> if p == audio.leadTrack then [1, 1] else [-1, -1]
        GH2PartMono p   -> if p == audio.leadTrack then [1] else [-1]
        GH2Band         -> [-1, -1]
        GH2Silent       -> [-1]
      , D.midiFile      = "songs/" <> key <> "/" <> key <> ".mid"
      , D.hopoThreshold = getDefaultHOPOThreshold song audio
      }

addDXExtra :: GH2DXExtra -> [D.Chunk T.Text] -> [D.Chunk T.Text]
addDXExtra extra = map $ \case
  D.Parens (D.Tree _ [D.Sym "artist", artist]) -> D.Parens $ D.Tree 0
    [ D.Sym "artist"
    , D.Braces $ D.Tree 0 $ let
      setter k v = D.Braces $ D.Tree 0 [D.Sym "set", D.Var k, v]
      in catMaybes
        [ pure $ D.Sym "do"
        , setter "songalbum"      . D.String <$> extra.songalbum
        , setter "author"         . D.String <$> extra.author
        , setter "songyear"       . D.String <$> extra.songyear
        , setter "songgenre"      . D.String <$> extra.songgenre
        , setter "songorigin"     . D.String <$> extra.songorigin
        , setter "songduration"   . D.Int    <$> extra.songduration
        , setter "songguitarrank" . D.Int    <$> extra.songguitarrank
        , setter "songbassrank"   . D.Int    <$> extra.songbassrank
        , setter "songrhythmrank" . D.Int    <$> extra.songrhythmrank
        , setter "songdrumrank"   . D.Int    <$> extra.songdrumrank
        , pure $ setter "songartist" artist
        ]
    , artist
    ]
  chunk -> chunk
