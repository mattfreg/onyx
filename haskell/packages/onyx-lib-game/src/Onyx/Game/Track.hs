{-# LANGUAGE BangPatterns          #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE LambdaCase            #-}
{-# LANGUAGE OverloadedRecordDot   #-}
{-# LANGUAGE OverloadedStrings     #-}
{-# LANGUAGE PatternSynonyms       #-}
module Onyx.Game.Track where

import           Control.Applicative              ((<|>))
import           Control.Arrow                    (first)
import           Control.Monad                    (forM, guard)
import           Control.Monad.IO.Class           (MonadIO (..))
import qualified Data.ByteString                  as B
import           Data.Char                        (toLower)
import qualified Data.EventList.Absolute.TimeBody as ATB
import qualified Data.EventList.Relative.TimeBody as RTB
import           Data.Foldable                    (toList)
import           Data.Functor                     (($>))
import qualified Data.HashMap.Strict              as HM
import           Data.List                        (sort, sortOn)
import qualified Data.Map.Strict                  as Map
import           Data.Maybe                       (catMaybes, fromMaybe)
import qualified Data.Set                         as Set
import qualified Data.Text                        as T
import qualified Data.Vector                      as V
import           Numeric.NonNegative.Class        ((-|))
import           Onyx.Build.RB3CH                 (BasicTiming (..),
                                                   basicTiming)
import qualified Onyx.FeedBack.Load               as FB
import qualified Onyx.Game.Time                   as PNF
import           Onyx.Guitar
import           Onyx.MIDI.Common
import qualified Onyx.MIDI.Track.Beat             as Beat
import qualified Onyx.MIDI.Track.Drums            as D
import qualified Onyx.MIDI.Track.Drums.Elite      as ED
import           Onyx.MIDI.Track.Events           (eventsCoda, eventsSections)
import qualified Onyx.MIDI.Track.File             as F
import qualified Onyx.MIDI.Track.FiveFret         as Five
import           Onyx.MIDI.Track.Mania
import qualified Onyx.MIDI.Track.ProGuitar        as PG
import           Onyx.MIDI.Track.Rocksmith
import           Onyx.Mode
import           Onyx.Preferences                 (TrueDrumLayoutHint)
import           Onyx.Project
import qualified Onyx.Reaper.Extract              as RPP
import qualified Onyx.Reaper.Parse                as RPP
import qualified Onyx.Reaper.Scan                 as RPP
import           Onyx.Rocksmith.ArrangementXML
import           Onyx.Sections                    (makeDisplaySection,
                                                   sectionBody)
import           Onyx.StackTrace
import           Onyx.Util.Text.Decode            (decodeGeneral)
import           Onyx.WebPlayer                   (findTremolos, findTrills,
                                                   laneDifficulty)
import qualified Sound.MIDI.Util                  as U
import           System.FilePath                  (takeExtension)

data PreviewTrack
  = PreviewDrums DrumMode (Map.Map Double (PNF.CommonState (PNF.DrumState (D.Gem D.ProType, D.DrumVelocity) (D.Gem D.ProType))))
  | PreviewDrumsTrue [TrueDrumLayoutHint] (Map.Map Double (PNF.CommonState (PNF.TrueDrumState Double (ED.EliteDrumNote ED.FlamStatus) (ED.EliteGem ()))))
  | PreviewFive (Map.Map Double (PNF.CommonState (PNF.GuitarState Double (Maybe Five.Color))))
  | PreviewPG PG.GtrTuning (Map.Map Double (PNF.CommonState (PNF.PGState Double)))
  | PreviewMania PartMania (Map.Map Double (PNF.CommonState PNF.ManiaState))
  deriving (Show)

data PreviewBG
  = PreviewBGVideo (VideoInfo FilePath)
  | PreviewBGImage FilePath
  -- TODO PreviewBGVenueRB
  deriving (Eq, Show)

data PreviewSong = PreviewSong
  { previewTempo    :: U.TempoMap
  , previewMeasures :: U.MeasureMap
  , previewTiming   :: BasicTiming
  , previewTracks   :: [[(T.Text, PreviewTrack)]]
  , previewBG       :: [(T.Text, PreviewBG)]
  , previewSections :: Map.Map Double T.Text
  } deriving (Show)

type IsOverdrive = Bool

displayPartName :: F.FlexPartName -> T.Text
displayPartName = \case
  F.FlexGuitar  -> "Guitar"
  F.FlexBass    -> "Bass"
  F.FlexDrums   -> "Drums"
  F.FlexKeys    -> "Keys"
  F.FlexVocal   -> "Vocal"
  F.FlexExtra t -> T.unwords $ map T.toTitle $ T.words $ T.replace "-" " " t

data HihatEvent
  = HihatEventHitOpen
  | HihatEventHitClosed
  | HihatEventStomp
  | HihatEventSplash
  deriving (Eq)

computeTracks
  :: (SendMessage m)
  => SongYaml FilePath
  -> F.Song (F.OnyxFile U.Beats)
  -> StackTraceT m PreviewSong
computeTracks songYaml song = basicTiming False song (return 0) >>= \timing -> let

  secondsToDouble :: U.Seconds -> Double
  secondsToDouble = realToFrac

  parts = songYaml.parts
  rtbToMap
    = rtbToMapSecs
    . U.applyTempoTrack tempos
  rtbToMapSecs
    = Map.fromList
    . map (first secondsToDouble)
    . ATB.toPairList
    . RTB.toAbsoluteEventList 0
  tempos = song.tempos
  toggle
    = PNF.makeToggle
    . rtbToMap
    . RTB.normalize
  diffPairs = [(Expert, "X"), (Hard, "H"), (Medium, "M"), (Easy, "E")]
  drumDiffPairs = (Nothing, "X+") : [ (Just diff, letter) | (diff, letter) <- diffPairs ]

  makeLanes colors lanes = let
    gemToggle gem = U.trackJoin $ flip fmap lanes $ \(gem', t) -> if gem == gem'
      then Wait 0 True $ Wait t False RNil
      else RNil
    gemSingletons = do
      gem <- colors
      return $ fmap (Map.singleton gem) $ toggle $ gemToggle gem
    in foldr (\x y -> fmap (uncurry Map.union) $ PNF.zipStateMaps x y) Map.empty gemSingletons

  maniaTracks pm fpart = do
    part <- toList $ Map.lookup fpart song.tracks.onyxParts
    diffName <- reverse $ toList pm.charts -- list difficulties in reverse order (hardest first)
    mania <- toList $ Map.lookup diffName part.onyxPartMania
    trk <- toList $ maniaTrack mania
    return (diffName, trk)

  maniaTrack src = let
    assigned :: RTB.T U.Beats (LongNote () Int)
    assigned
      = splitEdges
      $ fmap (\(key, len) -> ((), key, len))
      $ edgeBlips_ minSustainLengthRB
      $ getManiaNormalNotes src
    assignedMap :: Map.Map Double (Map.Map Int (PNF.PNF () ()))
    assignedMap
      = rtbToMap
      $ buildStatus PNF.empty
      $ RTB.collectCoincident
      $ assigned
    buildStatus _    RNil                 = RNil
    buildStatus prev (Wait dt edges rest) = let
      applyEdge edge = case edge of
        Blip _ key -> Map.alter (\case
          Nothing          -> Just $ PNF.N ()
          Just PNF.Empty   -> Just $ PNF.N ()
          Just (PNF.P  ()) -> Just $ PNF.PN () ()
          Just (PNF.PF ()) -> Just $ PNF.PN () ()
          x                -> x -- shouldn't happen
          ) key
        NoteOn () key -> Map.alter (\case
          Nothing          -> Just $ PNF.NF () ()
          Just PNF.Empty   -> Just $ PNF.NF () ()
          Just (PNF.P  ()) -> Just $ PNF.PNF () () ()
          Just (PNF.PF ()) -> Just $ PNF.PNF () () ()
          x                -> x -- shouldn't happen
          ) key
        NoteOff key -> Map.update (\case
          PNF.PF () -> Just $ PNF.P ()
          x         -> Just x -- could happen if Blip or NoteOn was applied first
          ) key
      this = foldr applyEdge (PNF.after prev) edges
      in Wait dt this $ buildStatus this rest
    states = PNF.ManiaState <$> assignedMap
    in do
      guard $ not $ RTB.null $ maniaNotes src
      Just $ (\((((a, b), c), d), e) -> PNF.CommonState a b c d e) <$> do
        states
          `PNF.zipStateMaps` Map.empty
          `PNF.zipStateMaps` Map.empty
          `PNF.zipStateMaps` Map.empty
          `PNF.zipStateMaps` fmap Just beats

  drumTrack fpart pdrums diff = let
    -- TODO support PS real
    -- TODO if kicks = 2, don't emit an X track, only X+
    drumSrc   = maybe mempty (.onyxPartDrums  ) $ Map.lookup fpart song.tracks.onyxParts
    drumSrc2x = maybe mempty (.onyxPartDrums2x) $ Map.lookup fpart song.tracks.onyxParts
    thisSrc = if pdrums.mode == DrumsTrue && D.nullDrums drumSrc && D.nullDrums drumSrc2x
      then maybe mempty (snd . ED.convertEliteDrums tempos . (.onyxPartEliteDrums))
        $ Map.lookup fpart song.tracks.onyxParts
      else case diff of
        Nothing -> if D.nullDrums drumSrc2x then drumSrc else drumSrc2x
        Just _  -> drumSrc
    drumMap :: Map.Map Double [(D.Gem D.ProType, D.DrumVelocity)]
    drumMap = rtbToMap $ RTB.collectCoincident drumPro
    drumPro = let
      ddiff = D.getDrumDifficulty diff thisSrc
      in case pdrums.mode of
        Drums4    -> (\(gem, vel) -> (gem $> D.Tom, vel)) <$> ddiff
        Drums5    -> flip fmap ddiff $ \(gem, vel) -> let
          gem' = case gem of
            D.Kick            -> D.Kick
            D.Red             -> D.Red
            D.Pro D.Yellow () -> D.Pro D.Yellow D.Cymbal
            D.Pro D.Blue   () -> D.Pro D.Blue D.Tom
            D.Orange          -> D.Orange
            D.Pro D.Green  () -> D.Pro D.Green D.Tom
          in (gem', vel)
        DrumsPro  -> D.computePro diff thisSrc
        DrumsReal -> D.computePro diff $ D.psRealToPro thisSrc
        DrumsTrue -> D.computePro diff thisSrc
    hands = RTB.filter (/= D.Kick) $ fmap fst drumPro
    (acts, bres) = case fmap (fst . fst) $ RTB.viewL song.tracks.onyxEvents.eventsCoda of
      Nothing   -> (thisSrc.drumActivation, RTB.empty)
      Just coda ->
        ( U.trackTake coda thisSrc.drumActivation
        , RTB.delay coda $ U.trackDrop coda thisSrc.drumActivation
        )
    drumStates = (\((a, b), c) -> PNF.DrumState a b c) <$> do
      (Set.fromList <$> drumMap)
        `PNF.zipStateMaps` (let
          single = findTremolos hands $ laneDifficulty (fromMaybe Expert diff) thisSrc.drumSingleRoll
          double = findTrills   hands $ laneDifficulty (fromMaybe Expert diff) thisSrc.drumDoubleRoll
          in makeLanes (D.Red : (D.Pro <$> each <*> each)) (RTB.merge single double)
          )
        `PNF.zipStateMaps` toggle acts
    in do
      guard $ not $ Map.null drumMap
      guard $ not $ diff == Nothing && pdrums.kicks == Kicks1x
      Just $ (\((((a, b), c), d), e) -> PNF.CommonState a b c d e) <$> do
        drumStates
          `PNF.zipStateMaps` toggle thisSrc.drumOverdrive
          `PNF.zipStateMaps` toggle bres
          `PNF.zipStateMaps` toggle thisSrc.drumSolo
          `PNF.zipStateMaps` fmap Just beats

  drumTrackTrue fpart pdrums diff = let
    -- TODO if kicks = 2, don't emit an X track, only X+
    thisSrc = maybe mempty (.onyxPartEliteDrums) $ Map.lookup fpart song.tracks.onyxParts
    thisDiff = ED.getDifficulty diff thisSrc
    drumMap :: Map.Map Double [ED.EliteDrumNote ED.FlamStatus]
    drumMap = rtbToMap $ RTB.collectCoincident thisDiff
    (acts, bres) = case fmap (fst . fst) $ RTB.viewL song.tracks.onyxEvents.eventsCoda of
      Nothing   -> (ED.tdActivation thisSrc, RTB.empty)
      Just coda ->
        ( U.trackTake coda $ ED.tdActivation thisSrc
        , RTB.delay coda $ U.trackDrop coda $ ED.tdActivation thisSrc
        )
    maxSolidOpenTime = 1   :: U.Seconds
    fadeOpenTime     = 0.5 :: U.Seconds
    hihatEvents
      = RTB.collectCoincident
      $ RTB.mapMaybe (\tdn -> case ED.tdn_gem tdn of
        ED.HihatFoot
          | ED.tdn_type tdn == ED.GemHihatOpen   -> Just HihatEventSplash
          | otherwise                            -> Just HihatEventStomp
        ED.Hihat
          | ED.tdn_type tdn == ED.GemHihatClosed -> Just HihatEventHitClosed
          | ED.tdn_type tdn == ED.GemHihatOpen   -> Just HihatEventHitOpen
        _                                        -> Nothing
        ) thisDiff
    stomps = Map.union notatedStomps implicitStomps -- Map.union prefers left values in conflict
    notatedStomps
      = rtbToMap
      $ fmap (const $ Just PNF.TrueHihatStompNotated)
      $ RTB.filter (\tdn -> ED.tdn_gem tdn == ED.HihatFoot) thisDiff
    implicitStomps
      = rtbToMapSecs
      $ makeImplicitStomps
      $ U.applyTempoTrack tempos hihatEvents
    makeImplicitStomps = \case
      Wait dt1 events1 rest@(Wait dt2 events2 _) -> let
        isImplicitStomp
          =  dt2 <= maxSolidOpenTime
          && elem HihatEventHitOpen   events1
          && elem HihatEventHitClosed events2
          && notElem HihatEventStomp  events2
          && notElem HihatEventSplash events2
        in if isImplicitStomp
          then RTB.delay dt1 $ RTB.insert dt2 (Just PNF.TrueHihatStompImplicit) $ makeImplicitStomps rest
          else RTB.delay dt1 $ makeImplicitStomps rest
      _ -> RNil
    openZones
      = rtbToMapSecs
      $ PNF.buildPNF
      $ makeOpenZones 0
      $ U.applyTempoTrack tempos
      $ fmap (\xs -> elem HihatEventHitOpen xs || elem HihatEventSplash xs) hihatEvents
    makeOpenZones !passedTime = \case
      Wait dt1 True rest -> let
        timeStart :: Double
        timeStart = realToFrac $ passedTime <> dt1
        timeEnd :: U.Seconds -> Double
        timeEnd len = timeStart + realToFrac len
        thisZone = case rest of
          Wait dt2 _ _ -> if dt2 > maxSolidOpenTime
            then (PNF.TrueHihatZoneFade  timeStart $ timeEnd fadeOpenTime, fadeOpenTime)
            else (PNF.TrueHihatZoneSolid timeStart $ timeEnd dt2         , dt2         )
          RNil -> (PNF.TrueHihatZoneFade timeStart $ timeEnd fadeOpenTime, fadeOpenTime)
        in Wait dt1 ((), Just thisZone) $ makeOpenZones (passedTime <> dt1) rest
      Wait dt1 False rest -> RTB.delay dt1 $ makeOpenZones (passedTime <> dt1) rest
      RNil -> RNil
    drumStates = (\((((a, b), c), d), e) -> PNF.TrueDrumState a b c d e) <$> do
      (Set.fromList <$> drumMap)
        `PNF.zipStateMaps` (makeLanes each $ fmap (\((), gem, len) -> (gem, len)) $ joinEdgesSimple $ ED.tdLanes thisSrc)
        `PNF.zipStateMaps` toggle acts
        `PNF.zipStateMaps` stomps
        `PNF.zipStateMaps` openZones
    in do
      guard $ not $ Map.null drumMap
      guard $ not $ diff == Nothing && pdrums.kicks == Kicks1x
      Just $ (\((((a, b), c), d), e) -> PNF.CommonState a b c d e) <$> do
        drumStates
          `PNF.zipStateMaps` toggle (ED.tdOverdrive thisSrc)
          `PNF.zipStateMaps` toggle bres
          `PNF.zipStateMaps` toggle (ED.tdSolo thisSrc)
          `PNF.zipStateMaps` fmap Just beats

  fiveTrack diff result = let
    thisDiff = fromMaybe mempty $ Map.lookup diff result.notes
    ons = fmap (fst . fst) thisDiff
    assigned :: RTB.T U.Beats (LongNote Bool (Maybe Five.Color, StrumHOPOTap))
    assigned = splitEdges
      $ fmap (\(a, (b, c)) -> (a, b, c))
      $ applyStatus1 False (RTB.normalize result.other.fiveOverdrive)
      $ thisDiff
    assignedMap :: Map.Map Double (Map.Map (Maybe Five.Color) (PNF.PNF (PNF.GuitarSustain Double) StrumHOPOTap))
    assignedMap
      = rtbToMap
      $ RTB.fromAbsoluteEventList
      $ buildFiveStatus PNF.empty
      $ RTB.toAbsoluteEventList 0
      $ RTB.collectCoincident
      $ assigned
    buildFiveStatus _    ANil              = ANil
    buildFiveStatus prev (At t edges rest) = let
      applyEdge edge = case edge of
        Blip _ (color, sht) -> Map.alter (\case
          Nothing                   -> Just $ PNF.N sht
          Just PNF.Empty            -> Just $ PNF.N sht
          Just (PNF.P  prevSustain) -> Just $ PNF.PN prevSustain sht
          Just (PNF.PF prevSustain) -> Just $ PNF.PN prevSustain sht
          x                         -> x -- shouldn't happen
          ) color
        NoteOn od (color, sht) -> let
          sustain = PNF.GuitarSustain
            { startTime = secondsToDouble $ U.applyTempoMap tempos t
            , extended  = True -- TODO
            , overdrive = od
            }
          in Map.alter (\case
            Nothing                   -> Just $ PNF.NF sht sustain
            Just PNF.Empty            -> Just $ PNF.NF sht sustain
            Just (PNF.P  prevSustain) -> Just $ PNF.PNF prevSustain sht sustain
            Just (PNF.PF prevSustain) -> Just $ PNF.PNF prevSustain sht sustain
            x                         -> x -- shouldn't happen
            ) color
        NoteOff (color, _) -> Map.update (\case
          PNF.PF prevSustain -> Just $ PNF.P prevSustain
          x                  -> Just x -- could happen if Blip or NoteOn was applied first
          ) color
      this = foldr applyEdge (PNF.after prev) edges
      in At t this $ buildFiveStatus this rest
    fiveStates = (\((a, b), c) -> PNF.GuitarState a b c) <$> do
      assignedMap
        `PNF.zipStateMaps` (makeLanes (Nothing : map Just each) $ findTremolos ons $ laneDifficulty diff result.other.fiveTremolo)
        `PNF.zipStateMaps` (makeLanes (Nothing : map Just each) $ findTrills   ons $ laneDifficulty diff result.other.fiveTrill  )
    in do
      guard $ not $ RTB.null thisDiff
      Just $ (\((((a, b), c), d), e) -> PNF.CommonState a b c d e) <$> do
        fiveStates
          `PNF.zipStateMaps` toggle result.other.fiveOverdrive
          `PNF.zipStateMaps` toggle result.other.fiveBRE
          `PNF.zipStateMaps` toggle result.other.fiveSolo
          `PNF.zipStateMaps` fmap Just beats

  pgRocksmith rso = let
    notes = let
      eachString str = let
        stringNotes :: RTB.T U.Seconds (IsOverdrive, (StrumHOPOTap, (PG.GtrFret, PG.NoteType), Maybe (U.Seconds, Maybe PG.Slide)))
        stringNotes = RTB.fromAbsoluteEventList $ ATB.fromPairList $ sort $ do
          note <- V.toList (lvl_notes $ rso_level rso) <> do
            V.toList (lvl_chords $ rso_level rso) >>= V.toList . chd_chordNotes
          guard $ PG.getStringIndex 6 str == n_string note
          let time = n_time note
              sht = if n_tap note then Tap
                else if n_hammerOn note || n_pullOff note then HOPO
                  else Strum
              fret = n_fret note
              ntype = PG.NormalNote -- TODO
              sust = flip fmap (n_sustain note) $ \len -> let
                slide = case n_slideTo note <|> n_slideUnpitchTo note of
                  Nothing -> Nothing
                  Just slideToFret -> case compare fret slideToFret of
                    LT -> Just PG.SlideUp
                    GT -> Just PG.SlideDown
                    EQ -> Nothing
                in (len, slide)
          return (time, (False, (sht, (fret, ntype), sust)))
        in rtbToMapSecs
          $ PNF.buildPNF
          $ RTB.fromAbsoluteEventList
          $ ATB.fromPairList
          $ fmap (\(t, (od, (sht, (fret, ntype), msust))) -> let
            now = PNF.PGNote fret ntype sht
            sust = case msust of
              Just (len, Nothing) -> Just (PNF.PGSustain Nothing od, len)
              Just (len, Just slide) -> let
                secsStart = secondsToDouble   t
                secsEnd   = secondsToDouble $ t <> len
                in Just (PNF.PGSustain (Just (slide, secsStart, secsEnd)) od, len)
              Nothing -> Nothing
            in (t, (now, sust))
            )
          $ ATB.toPairList
          $ RTB.toAbsoluteEventList 0 stringNotes
      strSingletons = do
        str <- [minBound .. maxBound]
        return $ Map.singleton str <$> eachString str
      in foldr (\x y -> fmap (uncurry Map.union) $ PNF.zipStateMaps x y) Map.empty strSingletons
    pgStates = (\(((a, b), c), d) -> PNF.PGState a b c d) <$> do
      notes
        `PNF.zipStateMaps` Map.empty -- TODO area :: Maybe PG.StrumArea
        `PNF.zipStateMaps` Map.empty -- TODO chords :: PNF T.Text T.Text
        `PNF.zipStateMaps` Map.empty -- TODO arpeggio :: PNF (Map.Map PG.GtrString PG.GtrFret) ()
    in (\(((((a, b), c), d), e)) -> PNF.CommonState a b c d e) <$> do
      pgStates
        `PNF.zipStateMaps` Map.empty
        `PNF.zipStateMaps` Map.empty
        `PNF.zipStateMaps` Map.empty
        `PNF.zipStateMaps` fmap Just beats

  rsTracks fpart ppg = sequence $ let
    (srcG, srcB) = case Map.lookup fpart song.tracks.onyxParts of
      Nothing   -> (mempty, mempty)
      Just part -> (part.onyxPartRSGuitar, part.onyxPartRSBass)
    in catMaybes
      [ do
        guard $ not $ RTB.null $ rsNotes srcG
        let name = case fpart of
              F.FlexGuitar               -> "RS Lead"
              F.FlexExtra "rhythm"       -> "RS Rhythm"
              F.FlexExtra "bonus-lead"   -> "RS Bonus Lead"
              F.FlexExtra "bonus-rhythm" -> "RS Bonus Rhythm"
              _                          -> displayPartName fpart <> " [RS Guitar]"
        return $ (\rso -> (name, PreviewPG ppg.tuning $ pgRocksmith rso)) <$> buildRS tempos 0 srcG
      , do
        guard $ not $ RTB.null $ rsNotes srcB
        let name = case fpart of
              F.FlexBass               -> "RS Bass"
              F.FlexExtra "bonus-bass" -> "RS Bonus Bass"
              _                        -> displayPartName fpart <> " [RS Bass]"
        return $ (\rso -> (name, PreviewPG ppg.tuning $ pgRocksmith rso)) <$> buildRS tempos 0 srcB
      ]

  pgTrack fpart ppg diff = let
    src = case Map.lookup fpart song.tracks.onyxParts of
      Nothing -> mempty
      Just part
        | not $ PG.nullPG part.onyxPartRealGuitar22 -> part.onyxPartRealGuitar22
        | otherwise                                 -> part.onyxPartRealGuitar
    thisDiff = fromMaybe mempty $ Map.lookup diff src.pgDifficulties
    _tuning = PG.tuningPitches ppg.tuning { PG.gtrGlobal = 0 }
    _flatDefault = maybe False songKeyUsesFlats songYaml.metadata.key
    _chordNames = PG.computeChordNames diff _tuning _flatDefault src
    computed :: RTB.T U.Beats (StrumHOPOTap, [(PG.GtrString, PG.GtrFret, PG.NoteType)], Maybe (U.Beats, Maybe PG.Slide))
    computed = PG.guitarifyFull
      (fromIntegral ppg.hopoThreshold / 480 :: U.Beats)
      thisDiff
    notes = let
      eachString str = let
        stringNotes :: RTB.T U.Beats (IsOverdrive, (StrumHOPOTap, (PG.GtrFret, PG.NoteType), Maybe (U.Beats, Maybe PG.Slide)))
        stringNotes = applyStatus1 False (RTB.normalize src.pgOverdrive) $
          flip RTB.mapMaybe computed $ \(sht, trips, sust) ->
            case [ (fret, ntype) | (str', fret, ntype) <- trips, str == str' ] of
              []       -> Nothing
              pair : _ -> Just (sht, pair, sust)
        in rtbToMap
          $ PNF.buildPNF
          $ RTB.fromAbsoluteEventList
          $ ATB.fromPairList
          $ fmap (\(t, (od, (sht, (fret, ntype), msust))) -> let
            now = PNF.PGNote fret ntype sht
            sust = case msust of
              Just (len, Nothing) -> Just (PNF.PGSustain Nothing od, len)
              Just (len, Just slide) -> let
                secsStart = secondsToDouble $ U.applyTempoMap tempos   t
                secsEnd   = secondsToDouble $ U.applyTempoMap tempos $ t <> len
                in Just (PNF.PGSustain (Just (slide, secsStart, secsEnd)) od, len)
              Nothing -> Nothing
            in (t, (now, sust))
            )
          $ ATB.toPairList
          $ RTB.toAbsoluteEventList 0 stringNotes
      strSingletons = do
        str <- [minBound .. maxBound]
        return $ Map.singleton str <$> eachString str
      in foldr (\x y -> fmap (uncurry Map.union) $ PNF.zipStateMaps x y) Map.empty strSingletons
    pgStates = (\(((a, b), c), d) -> PNF.PGState a b c d) <$> do
      notes
        `PNF.zipStateMaps` Map.empty -- TODO area :: Maybe PG.StrumArea
        `PNF.zipStateMaps` Map.empty -- TODO chords :: PNF T.Text T.Text
        `PNF.zipStateMaps` Map.empty -- TODO arpeggio :: PNF (Map.Map PG.GtrString PG.GtrFret) ()
    in do
      guard $ not $ RTB.null thisDiff.pgNotes
      Just $ (\(((((a, b), c), d), e)) -> PNF.CommonState a b c d e) <$> do
        pgStates
          `PNF.zipStateMaps` toggle src.pgOverdrive
          `PNF.zipStateMaps` toggle (snd <$> src.pgBRE)
          `PNF.zipStateMaps` toggle src.pgSolo
          `PNF.zipStateMaps` fmap Just beats

  beats :: Map.Map Double (Maybe Beat.BeatEvent)
  beats = let
    sourceMidi = song.tracks.onyxBeat.beatLines
    source = if RTB.null sourceMidi
      then (timingBeat timing).beatLines
      else sourceMidi
    makeBeats _         RNil            = RNil
    makeBeats _         (Wait 0 e rest) = Wait 0 (Just e) $ makeBeats False rest
    makeBeats firstLine (Wait t e rest) = let
      t' = t -| 0.5
      in (if firstLine then Wait 0 Nothing else id)
        $ RTB.delay (t - t')
        $ makeBeats True
        $ Wait (t -| 0.5) e rest
    in Map.fromList
      $ map (first $ secondsToDouble . U.applyTempoMap tempos)
      $ ATB.toPairList
      $ RTB.toAbsoluteEventList 0
      $ makeBeats True source

  tracks = fmap (filter $ not . null) $ forM (sortOn fst $ HM.toList parts.getParts) $ \(fpart, part) -> let
    five = case nativeFiveFret part <|> proGuitarToFiveFret part <|> proKeysToFiveFret part of
      Nothing -> []
      Just buildFive -> let
        result = buildFive FiveTypeGuitarExt ModeInput
          { tempo = tempos
          , events = song.tracks.onyxEvents
          , part = fromMaybe mempty $ Map.lookup fpart song.tracks.onyxParts
          }
        name = (case fpart of
          F.FlexGuitar              -> "Guitar"
          F.FlexBass                -> "Bass"
          F.FlexKeys                -> "Keys"
          F.FlexExtra "rhythm"      -> "Rhythm"
          F.FlexExtra "guitar-coop" -> "Guitar Coop"
          _                         -> displayPartName fpart <> " [5]"
          ) <> if result.autochart
            then " (Autochart)"
            else ""
        in diffPairs >>= \(diff, letter) -> case fiveTrack diff result of
          Nothing  -> []
          Just trk -> [(result.autochart, (name <> " (" <> letter <> ")", PreviewFive trk))]
    fiveNative = map snd $ filter (not . fst) five
    fiveAuto   = map snd $ filter fst         five
    drums = case part.drums of
      Nothing     -> []
      Just pdrums -> let
        name = case fpart of
          F.FlexDrums -> case pdrums.mode of
            Drums4    -> "Drums"
            Drums5    -> "Drums"
            DrumsPro  -> "Pro Drums"
            DrumsReal -> "Pro Drums"
            DrumsTrue -> "Pro Drums"
          _           -> displayPartName fpart <> " [D]"
        in drumDiffPairs >>= \(diff, letter) -> let
          standard = case drumTrack fpart pdrums diff of
            Nothing  -> []
            Just trk -> [(name <> " (" <> letter <> ")", PreviewDrums pdrums.mode trk)]
          true = case pdrums.mode of
            DrumsTrue -> case drumTrackTrue fpart pdrums diff of
              Nothing -> []
              Just trkTrue ->
                [ ( case fpart of
                    F.FlexDrums -> "Elite Drums (" <> letter <> ")"
                    _           -> displayPartName fpart <> " [Elite Drums] (" <> letter <> ")"
                  , PreviewDrumsTrue pdrums.trueLayout trkTrue
                  )
                ]
            _         -> []
          in true <> standard
    mania = case part.mania of
      Nothing -> []
      Just pm -> do
        (maniaName, trk) <- maniaTracks pm fpart
        let name = displayPartName fpart <> " [Mania: " <> maniaName <> "]"
        return (name, PreviewMania pm trk)
    pg = case part.proGuitar of
      Nothing     -> []
      Just ppg -> let
        name = case fpart of
          F.FlexGuitar -> "Pro Guitar"
          F.FlexBass   -> "Pro Bass"
          _            -> displayPartName fpart <> " [PG]"
        in diffPairs >>= \(diff, letter) -> case pgTrack fpart ppg diff of
          Nothing  -> []
          Just trk -> [(name <> " (" <> letter <> ")", PreviewPG ppg.tuning trk)]
    in do
      rs <- case part.proGuitar of
        Nothing  -> return []
        Just ppg -> rsTracks fpart ppg
      return $ concat [mania, fiveNative, drums, pg, rs, fiveAuto]

  bgs = concat
    [ case songYaml.global.backgroundVideo of
      Nothing -> []
      Just vi -> [("Background Video", PreviewBGVideo vi)]
    , case songYaml.global.fileBackgroundImage of
      Nothing -> []
      Just f  -> [("Background Image", PreviewBGImage f)]
    ]

  in tracks >>= \trk -> return $ PreviewSong
    { previewTempo    = song.tempos
    , previewMeasures = song.timesigs
    , previewTiming   = timing
    , previewTracks   = trk
    , previewBG       = bgs
    , previewSections = rtbToMap
      $ fmap (sectionBody . makeDisplaySection)
      $ song.tracks.onyxEvents.eventsSections
    }

loadTracks
  :: (SendMessage m, MonadIO m)
  => SongYaml FilePath
  -> FilePath
  -> StackTraceT m PreviewSong
loadTracks songYaml f = do
  song <- case map toLower $ takeExtension f of
    ".rpp" -> do
      txt <- stackIO $ decodeGeneral <$> B.readFile f
      song <- RPP.scanStack txt >>= RPP.parseStack >>= RPP.getMIDI
      F.interpretMIDIFile $ map (fmap $ fmap decodeGeneral) <$> song
    ".chart" -> do
      chart <- FB.chartToBeats <$> FB.loadChartFile f
      FB.chartToMIDI chart >>= F.readMIDIFile' . F.showMIDIFile' -- TODO just convert fixed to onyx simply
    _ -> F.loadMIDI f
  computeTracks songYaml song
