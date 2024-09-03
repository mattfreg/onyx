{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE ImplicitParams        #-}
{-# LANGUAGE LambdaCase            #-}
{-# LANGUAGE MultiWayIf            #-}
{-# LANGUAGE OverloadedRecordDot   #-}
{-# LANGUAGE OverloadedStrings     #-}
{-# LANGUAGE RecordWildCards       #-}
{-# OPTIONS_GHC -fno-warn-ambiguous-fields #-}
module Onyx.Import.Rocksmith where

import           Codec.Picture.Types              (dropTransparency, pixelMap)
import           Control.Monad                    (forM, guard)
import           Control.Monad.IO.Class           (MonadIO)
import           Control.Monad.Trans.Reader       (runReaderT)
import qualified Data.Aeson                       as A
import qualified Data.Aeson.KeyMap                as KM
import           Data.Bits                        ((.&.))
import qualified Data.ByteString.Char8            as B8
import qualified Data.ByteString.Lazy             as BL
import           Data.Char                        (isSpace)
import           Data.Default.Class               (def)
import           Data.Either                      (lefts, rights)
import qualified Data.EventList.Absolute.TimeBody as ATB
import qualified Data.EventList.Relative.TimeBody as RTB
import           Data.Foldable                    (toList)
import qualified Data.HashMap.Strict              as HM
import           Data.List                        (find, sort)
import           Data.List.Extra                  (nubOrd)
import           Data.List.NonEmpty               (NonEmpty ((:|)))
import qualified Data.Map                         as Map
import           Data.Maybe                       (catMaybes, fromMaybe, isJust,
                                                   listToMaybe, mapMaybe)
import qualified Data.Text                        as T
import qualified Data.Text.Encoding               as TE
import           Data.Text.Encoding.Error         (lenientDecode)
import           GHC.ByteOrder                    (ByteOrder (..))
import           Onyx.Audio                       (Audio (..))
import           Onyx.Codec.JSON                  (fromJSON)
import           Onyx.Image.DXT                   (readDDS)
import           Onyx.Import.Base
import           Onyx.Import.FretsOnFire          (fixShortVoxPhrasesTrack)
import           Onyx.MIDI.Common                 (blipEdgesRBNice, fixOverlaps,
                                                   fixOverlapsSimple,
                                                   minSustainLengthRB,
                                                   splitEdgesSimple)
import qualified Onyx.MIDI.Track.File             as F
import           Onyx.MIDI.Track.ProGuitar
import           Onyx.MIDI.Track.Rocksmith
import           Onyx.MIDI.Track.Vocal
import           Onyx.Project
import           Onyx.Rocksmith.BNK               (extractRSOgg)
import           Onyx.Rocksmith.Crypt
import           Onyx.Rocksmith.CST
import           Onyx.Rocksmith.PSARC
import           Onyx.Rocksmith.Sng2014
import           Onyx.StackTrace
import           Onyx.Util.Handle
import           Onyx.Util.Text.Decode            (decodeGeneral)
import qualified Sound.MIDI.Util                  as U
import           System.FilePath                  (takeExtension, (<.>))
import           Text.XML.Light

data RSSong = RSSong
  { rsHeader        :: String
  , rsManifest      :: String
  , rsSngAsset      :: String
  , rsSoundBank     :: String
  , rsAlbumArtLarge :: String
  } deriving (Eq, Show)

-- Import from STFS containing PackageList.txt and .psarc(s)
importRSXbox :: (SendMessage m, MonadIO m) => Folder T.Text Readable -> StackTraceT m [Import m]
importRSXbox dir = case findFile (return "PackageList.txt") dir of
  Nothing -> return []
  Just r -> do
    plist <- TE.decodeUtf8 . BL.toStrict <$> stackIO (useHandle r handleToByteString)
    -- entries are separated by CRLF
    fmap concat $ forM (T.lines plist) $ \pkg -> do
      let psarcPath = T.strip pkg <> ".psarc"
      case findFile (return psarcPath) dir of
        Nothing    -> fatal $ "Couldn't find " <> show psarcPath <> " inside STFS file"
        Just psarc -> importRS psarc

-- Import from .psarc file
importRS :: (SendMessage m, MonadIO m) => Readable -> StackTraceT m [Import m]
importRS psarc = do
  folder <- stackIO $ readPSARCFolder psarc
  let subfolder p = case findFolder p folder of
        Just sub -> return sub
        Nothing  -> fatal $ "Required subfolder not found: " <> show p
  xblocks <- filter (\(f, _) -> takeExtension (T.unpack f) == ".xblock") . folderFiles
    <$> subfolder ["gamexblocks", "nsongs"]
  xblockSongs <- forM xblocks $ \(xblockName, xblock) -> do
    xml <- stackIO (useHandle xblock handleToByteString) >>= \bs -> case parseXMLDoc bs of
      Nothing  -> fatal $ "Couldn't parse XML from " <> T.unpack xblockName
      Just xml -> return xml
    return $ do
      entitySet <- findChildren (QName "entitySet" Nothing Nothing) xml
      entity <- findChildren (QName "entity" Nothing Nothing) entitySet
      let mapping = do
            properties <- findChildren (QName "properties" Nothing Nothing) entity
            prop <- findChildren (QName "property" Nothing Nothing) properties
            propName <- toList $ findAttr (QName "name" Nothing Nothing) prop
            propSet <- findChildren (QName "set" Nothing Nothing) prop
            propValue <- toList $ findAttr (QName "value" Nothing Nothing) propSet
            return (propName, propValue)
      rsHeader <- toList $ lookup "Header" mapping
      rsManifest <- toList $ lookup "Manifest" mapping
      rsSngAsset <- toList $ lookup "SngAsset" mapping
      rsSoundBank <- toList $ lookup "SoundBank" mapping
      rsAlbumArtLarge <- toList $ lookup "AlbumArtLarge" mapping
      return RSSong{..}
  return $ map (importRSSong folder) xblockSongs

importRSSong :: (SendMessage m, MonadIO m) => Folder T.Text Readable -> [RSSong] -> Import m
importRSSong folder song level = do

  let need p = case findFile p folder of
        Just r  -> return r
        Nothing -> fatal $ "Required file not found: " <> T.unpack (T.intercalate "/" $ toList p)
      subfolder p = case findFolder p folder of
        Just sub -> return sub
        Nothing  -> fatal $ "Required subfolder not found: " <> T.unpack (T.intercalate "/" $ toList p)

  audioDirs <- folderSubfolders <$> subfolder (return "audio")
  (audioDir, platform) <- case audioDirs of
    [("windows", audioDir)] -> return (audioDir, PC)
    [("xbox360", audioDir)] -> return (audioDir, Xbox360)
    [("mac"    , audioDir)] -> return (audioDir, Mac)
    [("ps3"    , audioDir)] -> return (audioDir, PS3)
    _                       -> fatal "Couldn't determine platform of .psarc"

  let urn s = case T.splitOn ":" $ T.pack s of
        ["urn", _, _, value] -> return $ T.unpack value
        _                    -> fatal $ "Couldn't parse urn value: " <> show s
      prop k rec = case rec of
        A.Object o -> case KM.lookup k o of
          Nothing -> fatal $ "No key " <> show k <> " in object"
          Just v  -> return v
        _ -> fatal $ "Tried to read key " <> show k <> " of non-object"
      singleKey rec = case rec of
        A.Object o -> case KM.toList o of
          [(_, v)] -> return v
          _        -> fatal "JSON object has more than 1 key, 1 expected"
        _ -> fatal "Unexpected non-object in JSON file"
      getString o = case o of
        A.String s -> return s
        _          -> fatal "Expected string in JSON file"
      getInt o = case o of
        A.Number n -> return $ round n
        _          -> fatal "Expected integer in JSON file"
      getBool o = case o of
        A.Number n -> return $ n /= 0
        A.Bool   b -> return b
        _          -> fatal "Expected boolean (true/false/0/1) in JSON file"
  partsWithVox <- fmap catMaybes $ forM song $ \entity -> inside ("Entity " <> show (rsManifest entity)) $ do
    header <- urn $ rsHeader entity -- urn:database:hsan-db or hson-db
    manifest <- urn $ rsManifest entity -- urn:database:json-db
    sngPath <- urn $ rsSngAsset entity -- urn:application:musicgame-song
    bnkPath <- urn $ rsSoundBank entity -- urn:audio:wwise-sound-bank
    let binFolder = case platform of
          Xbox360 -> "xbox360"
          Mac     -> "macos"
          PS3     -> "ps3"
          PC      -> "generic"
    sngFile <- need $ "songs" :| ["bin", binFolder, T.pack $ sngPath <.> "sng"]
    sng <- case level of
      ImportFull  -> fmap Just $ stackIO (useHandle sngFile handleToByteString) >>= loadSNG platform . BL.toStrict
      ImportQuick -> return Nothing
    -- 1 seen on all pc (dlc + customs) and xbox odlc, 2 seen in xbox+ps3 cdlc
    let manifest1 = "manifests" :| [T.pack header, T.pack $ manifest <.> "json"]
        manifest2 = "manifests" :| ["songs_dlc"  , T.pack $ manifest <.> "json"]
    jsonFile <- errorToEither (need manifest1) >>= \case
      Right x -> return x
      Left  _ -> errorToEither (need manifest2) >>= \case
        Right x -> return x
        Left  _ -> fatal "Couldn't find manifest .json file"
    json <- stackIO (useHandle jsonFile handleToByteString) >>=
      either fatal return . A.eitherDecodeStrict . BL.toStrict
    jsonAttrs <- prop "Entries" json >>= singleKey >>= prop "Attributes"
    arrName <- prop "ArrangementName" jsonAttrs >>= getString
    if arrName == "Vocals"
      then do
        -- for now, only import romaji vocals for japanese songs
        japanese <- errorToEither $ prop "JapaneseVocal" jsonAttrs >>= getBool
        return $ case japanese of
          Right True -> Nothing
          _          -> Just $ Left sng
      else do
        title <- prop "SongName" jsonAttrs >>= getString
        artist <- prop "ArtistName" jsonAttrs >>= getString
        album <- prop "AlbumName" jsonAttrs >>= getString
        year <- prop "SongYear" jsonAttrs >>= getInt
        arrProps <- prop "ArrangementProperties" jsonAttrs
        isLead <- prop "pathLead" arrProps >>= getBool
        isRhythm <- prop "pathRhythm" arrProps >>= getBool
        isBass <- prop "pathBass" arrProps >>= getBool
        isBonus <- prop "bonusArr" arrProps >>= getBool
        isDefault <- prop "represent" arrProps >>= getBool
        let arrmod = case (isDefault, isBonus) of
              (True , _    ) -> RSDefault
              (False, False) -> RSAlternate
              (False, True ) -> RSBonus
            marrtype = case (isLead, isRhythm, isBass, arrName == "Combo") of
              (True , _    , _    , False) -> Just RSLead
              (True , _    , _    , True ) -> Just RSComboLead
              (_    , True , _    , False) -> Just RSRhythm
              (_    , True , _    , True ) -> Just RSComboRhythm
              (_    , _    , True , _    ) -> Just RSBass
              (False, False, False, _    ) -> Nothing
        -- TODO warn if marrtype is Nothing?
        forM marrtype $ \arrtype -> do
          -- I've seen CF files (Timepiece Phase II) that have a null in this tone list
          toneList <- prop "Tones" jsonAttrs >>= \v -> do
            results <- errorToWarning $ mapStackTraceT (`runReaderT` v) fromJSON
            return $ concat $ toList results
          let findTone k = case find ((== k) . t14_Key) (toneList :: [Tone2014]) of
                Nothing -> fatal $ "Couldn't find tone for key: " <> show k
                Just t  -> return t
              findMaybeTone "" = return Nothing
              findMaybeTone k  = Just <$> findTone k
          -- TODO support no base tone - this shouldn't happen,
          -- but does if you compile a custom with no tones
          tones <- inside "Importing RS tones" $ errorToWarning $ do
            fileToneBase <- prop "Tone_Base" jsonAttrs >>= getString >>= findTone
            fileToneA    <- prop "Tone_A" jsonAttrs >>= getString >>= findMaybeTone
            fileToneB    <- prop "Tone_B" jsonAttrs >>= getString >>= findMaybeTone
            fileToneC    <- prop "Tone_C" jsonAttrs >>= getString >>= findMaybeTone
            fileToneD    <- prop "Tone_D" jsonAttrs >>= getString >>= findMaybeTone
            return RSTones{..}
          return $ Right (RSArrSlot arrmod arrtype, sng, bnkPath, (title, artist, album, year), isBass, tones)
  let parts = rights partsWithVox
      maybeVoxSNG = listToMaybe $ lefts partsWithVox
  (_, firstArr, bnk, (title, artist, album, year), _, _) <- case parts of
    []    -> fatal "No entries found in song"
    p : _ -> return p
  art <- case map rsAlbumArtLarge song of
    [] -> return Nothing
    art : _ -> do
      f <- urn art -- urn:image:dds
      bs <- need ("gfxassets" :| ["album_art", T.pack $ f <.> "dds"]) >>= \r ->
        stackIO $ useHandle r handleToByteString
      return $ SoftFile "cover.png" . SoftImage . pixelMap dropTransparency <$> readDDS bs
  -- TODO handle if the bnks are different in different parts?
  -- how does multiplayer handle this?
  bnkFile <- case findFile (return $ T.pack $ bnk <.> "bnk") audioDir of
    Just r  -> return r
    Nothing -> fatal "Couldn't find .bnk file"
  let oggFile = let
        ?endian = case platform of
          PC      -> LittleEndian
          Mac     -> LittleEndian
          Xbox360 -> BigEndian
          PS3     -> BigEndian
        in extractRSOgg bnkFile audioDir
      modifiedBeats = removeDupeTimes $ case maybe [] sng_BPMs firstArr of
        ebeats@(BPM { bpm_Time = 0 } : _) -> ebeats
        ebeats@(BPM { bpm_Time = t } : _) -> let
          newBeatCount = ceiling t
          newBeatDuration = t / fromInteger newBeatCount
          in (<> ebeats) $ do
            i <- [0 .. newBeatCount - 1]
            return BPM
              { bpm_Time            = newBeatDuration * fromIntegral i
              , bpm_Measure         = -1
              , bpm_Beat            = 0
              , bpm_PhraseIteration = 0
              , bpm_Mask            = 0
              }
        [] -> [] -- probably shouldn't happen?
      -- this prevents divide-by-zero issues when a song has two adjacent ebeats
      -- with the same timestamp. see In the Presence of Enemies on CF
      removeDupeTimes (b1 : bs@(b2 : _)) = if bpm_Time b1 == bpm_Time b2
        then removeDupeTimes bs
        else b1 : removeDupeTimes bs
      removeDupeTimes bs = bs
      temps = U.tempoMapFromBPS $ let
        makeTempo b1 b2 = U.makeTempo 1 (realToFrac $ bpm_Time b2 - bpm_Time b1)
        in RTB.fromPairList
          $ zip (0 : repeat 1)
          $ zipWith makeTempo modifiedBeats (drop 1 modifiedBeats)
      sigs = U.measureMapFromLengths U.Truncate $ let
        startsBar = (== 0) . bpm_Beat
        makeBarLengths [] = []
        makeBarLengths (_ : ebeats) = case break startsBar ebeats of
          (inThisBar, rest) -> (1 + fromIntegral (length inThisBar)) : makeBarLengths rest
        assembleMMap lens = RTB.fromPairList $ zip (0 : lens) lens
        in assembleMMap $ makeBarLengths modifiedBeats
      namedParts = moveToLead $ goNameParts [] parts
      goNameParts _ [] = []
      goNameParts prev ((slot, sng, bnkPath, meta, isBass, tones) : rest) = let
        n = length $ filter (== slot) prev
        name = case (slot, n) of
          (RSArrSlot RSDefault RSLead  , 0) -> F.FlexGuitar
          (RSArrSlot RSDefault RSRhythm, 0) -> F.FlexExtra "rhythm"
          (RSArrSlot RSDefault RSBass  , 0) -> F.FlexBass
          _ -> F.FlexExtra $ rsArrSlot slot <> case n of
            0 -> ""
            _ -> "-" <> T.pack (show $ n + 1)
        in ((slot, name), sng, bnkPath, meta, isBass, tones) : goNameParts (slot : prev) rest
      -- if we don't have a Lead part, let another track be assigned to main guitar
      moveToLead input = let
        originalNames = [ name | ((_, name), _, _, _, _, _) <- input ]
        replaceName n1 n2 = do
          orig@((slot, name), sng, bnkPath, meta, isBass, tones) <- input
          return $ if name == n1
            then ((slot, n2), sng, bnkPath, meta, isBass, tones)
            else orig
        in if
          | elem F.FlexGuitar originalNames                 -> input
          | elem (F.FlexExtra "combo-lead"  ) originalNames -> replaceName (F.FlexExtra "combo-lead"  ) F.FlexGuitar
          | elem (F.FlexExtra "combo-rhythm") originalNames -> replaceName (F.FlexExtra "combo-rhythm") F.FlexGuitar
          | elem (F.FlexExtra "rhythm"      ) originalNames -> replaceName (F.FlexExtra "rhythm"      ) F.FlexGuitar
          | otherwise                                       -> input
      toSeconds = realToFrac :: Float -> U.Seconds
      midi = case level of
        ImportFull -> F.Song temps sigs mempty
          { F.onyxParts = Map.fromList $ do
            ((_, partName), Just sng, _, _, isBass, _) <- namedParts
            let capoOffset :: Int
                capoOffset = case meta_CapoFretId $ sng_Metadata sng of
                  -1 -> 0
                  n  -> fromIntegral n
                unapplyCapo 0    = 0
                unapplyCapo fret = fret - capoOffset
                getNotes note = let
                  secs = toSeconds $ notes_Time note
                  beats = U.unapplyTempoMap temps secs
                  len = do
                    -- Sometimes CDLC has notes with sustain of e.g. 0.002s
                    guard $ notes_Sustain note > 0.05
                    let endSecs = secs <> toSeconds (notes_Sustain note)
                    Just $ U.unapplyTempoMap temps endSecs - beats
                  parseMask mask = concat
                    [ [ModHammerOn | mask .&. 0x200 /= 0]
                    , [ModPullOff | mask .&. 0x400 /= 0]
                    -- according to CST, 8 = NOTE_MASK_FRETHANDMUTE, 0x20000 = NOTE_MASK_MUTE ?
                    -- seemingly, chords have 8 (in notes_NoteMask, not chord_Mask!), non-chords have 0x20000
                    , [ModMute | mask .&. 0x20000 /= 0 || mask .&. 0x8 /= 0]
                    , [ModPalmMute | mask .&. 0x40 /= 0]
                    , [ModAccent | mask .&. 0x04000000 /= 0]
                    , [ModLink | mask .&. 0x8000000 /= 0] -- also the next note has mask .&. 0x10000000
                    , [ModHarmonic | mask .&. 0x20 /= 0]
                    , [ModHarmonicPinch | mask .&. 0x8000 /= 0]
                    , [ModTremolo | mask .&. 0x10 /= 0]
                    , [ModIgnore | mask .&. 0x40000 /= 0]
                    -- these next 3 might have more info to import
                    , [ModTap | mask .&. 0x4000 /= 0]
                    , [ModSlap | mask .&. 0x80 /= 0]
                    , [ModPluck | mask .&. 0x0100 /= 0]
                    ]
                  -- TODO remaining modifiers to import:
                  -- ModTap -- how does notes_Tap relate to mask bit?
                  -- ModSlap -- how does notes_Slap relate to mask bit?
                  -- ModPluck -- how does notes_Pluck relate to mask bit?
                  -- ModPickUp -- from notes_PickDirection
                  -- ModPickDown -- from notes_PickDirection
                  -- ModRightHand
                  numNot x n = guard (n /= x) >> Just n
                  in do
                    let noteMods = parseMask (notes_NoteMask note) <> catMaybes
                          [ ModVibrato      .               fromIntegral <$> numNot 0    (notes_Vibrato        note)
                          , ModSlide        . unapplyCapo . fromIntegral <$> numNot (-1) (notes_SlideTo        note)
                          , ModSlideUnpitch . unapplyCapo . fromIntegral <$> numNot (-1) (notes_SlideUnpitchTo note)
                          ]
                    (str, fret, mods, bends) <- case notes_ChordId note of
                      -1 -> let
                        fret = unapplyCapo $ fromIntegral $ notes_FretId note
                        str = case notes_StringIndex note of
                          0 -> S6
                          1 -> S5
                          2 -> S4
                          3 -> S3
                          4 -> S2
                          5 -> S1
                          _ -> S7 -- TODO raise error
                        bends = map (\bd -> (bd32_Time bd, bd32_Step bd)) $ notes_BendData note
                        in [(str, fret, noteMods, bends)]
                      chordID -> do
                        let chord = sng_Chords sng !! fromIntegral chordID
                            chordNotes = case notes_ChordNotesId note of
                              -1   -> Nothing
                              cnid -> Just $ sng_ChordNotes sng !! fromIntegral cnid
                        (str, i) <- zip [S6, S5 ..] [0..]
                        let fret = unapplyCapo $ fromIntegral $ chord_Frets chord !! i
                            -- apparently need to include notes_NoteMask as well,
                            -- because fret-hand-mute chords use that as indicator (mask & 8)
                            mods = nubOrd $ noteMods <> case chordNotes of
                              Nothing -> []
                              Just cn -> parseMask (cn_NoteMask cn !! i) <> catMaybes
                                [ ModVibrato      .               fromIntegral <$> numNot 0    (cn_Vibrato        cn !! i)
                                , ModSlide        . unapplyCapo . fromIntegral <$> numNot (-1) (cn_SlideTo        cn !! i)
                                , ModSlideUnpitch . unapplyCapo . fromIntegral <$> numNot (-1) (cn_SlideUnpitchTo cn !! i)
                                ]
                        guard $ fret >= 0
                        return (str, fret, mods, [] {- TODO -})
                    return (beats, ((fret, str, len), (mods, bends)))
                makeShape fprint = let
                  secs = toSeconds $ fp_StartTime fprint
                  beats = U.unapplyTempoMap temps secs
                  len = let
                    endSecs = toSeconds $ fp_EndTime fprint
                    in U.unapplyTempoMap temps endSecs - beats
                  in do
                    (str, fret) <- zip [S6, S5 ..]
                      $ map fromIntegral
                      $ chord_Frets
                      $ sng_Chords sng !! fromIntegral (fp_ChordId fprint)
                    guard $ fret >= 0
                    return (beats, (unapplyCapo fret, str, len))
                iterBoundaries = zip (sng_PhraseIterations sng)
                  (fmap Just (drop 1 $ sng_PhraseIterations sng) <> [Nothing])
                getPhraseNotes iter1 miter2 = let
                  phrase = sng_Phrases sng !! fromIntegral (pi_PhraseId iter1)
                  lvl = sng_Arrangements sng !! fromIntegral (phrase_MaxDifficulty phrase)
                  inBounds note = pi_StartTime iter1 <= notes_Time note
                    && all (\iter2 -> notes_Time note < pi_StartTime iter2) miter2
                    && notes_PhraseId note /= -1 -- fix for Time Is Running Out (Muse) bass: weird phantom note past [phrase END]
                  in filter inBounds $ arr_Notes lvl
                getPhraseAnchors iter1 miter2 = let
                  phrase = sng_Phrases sng !! fromIntegral (pi_PhraseId iter1)
                  lvl = sng_Arrangements sng !! fromIntegral (phrase_MaxDifficulty phrase)
                  inBounds anchor = pi_StartTime iter1 <= anchor_StartBeatTime anchor
                    && all (\iter2 -> anchor_StartBeatTime anchor < pi_StartTime iter2) miter2
                  in filter inBounds $ arr_Anchors lvl
                getHandShapes iter1 miter2 = let
                  phrase = sng_Phrases sng !! fromIntegral (pi_PhraseId iter1)
                  lvl = sng_Arrangements sng !! fromIntegral (phrase_MaxDifficulty phrase)
                  inBounds fprint = pi_StartTime iter1 <= fp_StartTime fprint
                    && all (\iter2 -> fp_StartTime fprint < pi_StartTime iter2) miter2
                  in filter inBounds $ arr_Fingerprints1 lvl <> arr_Fingerprints2 lvl
                  -- arr_Fingerprints2 is arpeggios, but we'll get that from the mask later
                maxLevelNotes = iterBoundaries >>= uncurry getPhraseNotes
                maxLevelShapes = iterBoundaries >>= uncurry getHandShapes
                notes = RTB.fromAbsoluteEventList
                  $ ATB.fromPairList
                  $ sort
                  $ maxLevelNotes >>= getNotes
                anchors = U.unapplyTempoTrack temps
                  $ RTB.fromAbsoluteEventList
                  $ ATB.fromPairList
                  $ sort
                  $ fmap (\anc -> let
                    t = toSeconds $ anchor_StartBeatTime anc
                    lowFret = unapplyCapo $ fromIntegral $ anchor_FretId anc
                    highFret = lowFret + fromIntegral (anchor_Width anc) - 1
                    in (t, (lowFret, highFret))
                    )
                  $ iterBoundaries >>= uncurry getPhraseAnchors
                shapes = RTB.fromAbsoluteEventList
                  $ ATB.fromPairList
                  $ sort
                  $ maxLevelShapes >>= makeShape
                noteChordInfo = RTB.fromAbsoluteEventList
                  $ ATB.fromPairList
                  $ map (makeChordInfo ChordLocNotes)
                  $ sort
                  $ mapMaybe (\n -> guard (notes_ChordId n /= (-1)) >> Just (notes_Time n, notes_ChordId n))
                  $ maxLevelNotes
                shapeChordInfo = RTB.fromAbsoluteEventList
                  $ ATB.fromPairList
                  $ map (makeChordInfo ChordLocShape)
                  $ sort
                  $ map (\fp -> (fp_StartTime fp, fp_ChordId fp))
                  $ maxLevelShapes
                makeChordInfo loc (t, chordID) = (t', ChordInfo
                  { ciLocation    = loc
                  , ciName        = case TE.decodeUtf8With lenientDecode $ chord_Name chord of
                    ""   -> Nothing
                    name -> Just name
                  , ciFingers     = map (toEnum . fromIntegral) $ filter (/= (-1)) $ chord_Fingers chord
                  , ciArpeggio    = chord_Mask chord .&. 0x00000001 /= 0
                  , ciNop         = chord_Mask chord .&. 0x00000002 /= 0
                  , ciOnce        = Just $ do
                    (str, fret) <- zip [S6, S5 ..] $ chord_Frets chord
                    guard $ fret >= 0
                    return str
                  }) where
                    chord = sng_Chords sng !! fromIntegral chordID
                    t' = U.unapplyTempoMap temps $ toSeconds t
                legalFret = min 27 -- TODO should warn or something. this is just so midi's fromVelocity doesn't throw an error
                trk = RocksmithTrack
                  { rsNotes
                    = blipEdgesRBNice
                    $ fixOverlaps
                    $ fmap (\((fret, str, len), _) -> (legalFret fret, str, len))
                    $ notes
                  , rsPhrases = U.unapplyTempoTrack temps
                    $ RTB.fromAbsoluteEventList
                    $ ATB.fromPairList
                    $ sort
                    $ flip map (sng_PhraseIterations sng)
                    $ \iter -> let
                      t = toSeconds $ pi_StartTime iter
                      phrase = sng_Phrases sng !! fromIntegral (pi_PhraseId iter)
                      name = TE.decodeUtf8With lenientDecode $ phrase_Name phrase
                      in (t, name)
                  , rsSections = U.unapplyTempoTrack temps
                    $ RTB.fromAbsoluteEventList
                    $ ATB.fromPairList
                    $ sort
                    $ flip map (sng_Sections sng)
                    $ \sect -> let
                      t = toSeconds $ sect_StartTime sect
                      name = TE.decodeUtf8With lenientDecode $ sect_Name sect
                      in (t, name)
                  , rsAnchorLow  = fmap (legalFret . fst) anchors
                  , rsAnchorHigh = fmap (legalFret . snd) anchors
                  , rsModifiers  = flip RTB.mapMaybe notes $ \((_, str, len), (mods, _)) -> let
                    mods' = mods <> case len of
                      Just n | n < minSustainLengthRB -> [ModSustain] -- force small note to sustain
                      _                               -> []
                    in guard (not $ null mods') >> Just ([str], mods')
                  , rsTones      = U.unapplyTempoTrack temps
                    $ RTB.fromAbsoluteEventList
                    $ ATB.fromPairList
                    $ sort
                    $ flip map (sng_Tones sng)
                    $ \tid -> let
                      t = toSeconds $ tid_Time tid
                      tone = case tid_ID tid of
                        0 -> ToneA
                        1 -> ToneB
                        2 -> ToneC
                        3 -> ToneD
                        _ -> ToneA -- TODO error?
                      in (t, tone)
                  , rsBends      = U.unapplyTempoTrack temps $ RTB.fromAbsoluteEventList $ ATB.fromPairList $ sort $ do
                    ((_, str, _), (_, bends)) <- RTB.getBodies notes
                    (t, bend) <- bends
                    return (toSeconds t, ([str], realToFrac bend))
                  -- TODO verify/tweak the fixOverlapsSimple usage.
                  -- added to fix processing of In the Presence of Enemies on CF
                  , rsHandShapes
                    = splitEdgesSimple
                    $ fmap (\(fret, str, len) -> (legalFret fret, str, len))
                    $ fixOverlapsSimple shapes
                  , rsChords = RTB.merge noteChordInfo shapeChordInfo
                  }
            return (partName, if isBass
              then mempty { F.onyxPartRSBass   = trk }
              else mempty { F.onyxPartRSGuitar = trk })
          }
        ImportQuick -> emptyChart

  -- Lots of authors don't put their name into CST for some reason,
  -- so it just shows up as Custom Song Creator...
  -- Is it a newer added feature?
  author <- case findFile (return "toolkit.version") folder of
    Nothing -> return Nothing
    Just r -> do
      txt <- decodeGeneral . BL.toStrict <$> stackIO (useHandle r handleToByteString)
      return $ find (`notElem` ["", "Custom Song Creator"]) $ map T.strip
        $ mapMaybe (T.stripPrefix "Package Author:") $ T.lines txt

  let midiWithVox = case maybeVoxSNG of
        Nothing     -> midi
        Just voxSNG -> let

          -- see Metropolis for some weird empty vocal events in instrumental section
          vocals1 = filter
            (B8.any (\c -> not $ isSpace c || c == '+') . vocal_Lyric)
            (maybe [] sng_Vocals voxSNG)

          vocals2 = sort $ do
            v <- vocals1
            let pitch = if 36 <= vocal_Note v && vocal_Note v <= 84
                  then toEnum $ fromIntegral $ vocal_Note v - 36
                  -- just shift octaves to keep in the valid RB space
                  else toEnum $ fromIntegral $ rem (vocal_Note v - 36) 48
                time = toSeconds $ vocal_Time v
                endTime = toSeconds $ vocal_Time v + vocal_Length v
                lyric = decodeGeneral $ vocal_Lyric v
                -- get rid of phrase end marker, make all notes talky
                lyric' = fromMaybe lyric (T.stripSuffix "+" lyric) <> "#"
                phraseEnd = "+" `B8.isSuffixOf` vocal_Lyric v
            return (time, (pitch, endTime, lyric', phraseEnd))

          vocals3 = let
            go = \case
              -- fix small overlaps (see yesowne_p.psarc, many others)
              (t1, (pitch1, tend1, lyric1, end1)) : rest@((t2, _) : _) -> let
                tend1' = min tend1 t2
                in (t1, (pitch1, tend1', lyric1, end1)) : go rest
              -- make sure last note ends phrase even if missing plus (see yasashiku_p.psarc)
              [(t, (pitch, end, lyric, _))] -> [(t, (pitch, end, lyric, True))]
              [] -> []
            in go vocals2

          in midi
            { F.tracks = midi.tracks
              { F.onyxParts = Map.insert F.FlexVocal mempty
                { F.onyxPartVocals = fst $ fixShortVoxPhrasesTrack mempty
                  { vocalNotes
                    = U.unapplyTempoTrack temps
                    $ RTB.fromAbsoluteEventList
                    $ ATB.fromPairList
                    $ do
                      (t, (pitch, tend, _, _)) <- vocals3
                      let on  = (t   , (pitch, True ))
                          off = (tend, (pitch, False))
                      [on, off]
                  , vocalLyrics
                    = U.unapplyTempoTrack temps
                    $ RTB.fromAbsoluteEventList
                    $ ATB.fromPairList
                    $ do
                      (t, (_, _, lyric, _)) <- vocals3
                      return (t, lyric)
                  , vocalPhrase1
                    = U.unapplyTempoTrack temps
                    $ RTB.fromAbsoluteEventList
                    $ ATB.fromPairList
                    $ removeDupePhraseStart
                    $ do
                      (t, (_, tend, _, end)) <- vocals3
                      (t, True) : [(tend, False) | end]
                  }
                } midi.tracks.onyxParts
              }
            }
      removeDupePhraseStart = \case
        pair@(_, True) : pairs -> pair : removeDupePhraseStart (dropWhile snd pairs)
        pair : pairs -> pair : removeDupePhraseStart pairs
        [] -> []
      partsMap = HM.fromList $ do
        ((_, partName), Just sng, _, _, isBass, tones) <- namedParts
        let part = emptyPart
              { proGuitar = Just PartProGuitar
                { difficulty    = Tier 1
                , hopoThreshold = 170
                , tuning        = if isBass
                  -- TODO set gtrGlobal smarter (detect number applied to all offsets)
                  -- TODO import bass-on-guitar correctly (threshold for very low offsets?)
                  then GtrTuning
                    { gtrBase    = Bass4
                    , gtrOffsets = map fromIntegral $ take 4 $ meta_Tuning $ sng_Metadata sng
                    , gtrGlobal  = 0
                    , gtrCapo    = case fromIntegral $ meta_CapoFretId $ sng_Metadata sng of
                      -1 -> 0 -- is capo supposed to be -1? seen in albatross213's Vektor charts (F tuning)
                      n  -> n
                    , gtrName    = Nothing
                    }
                  else GtrTuning
                    { gtrBase    = Guitar6
                    , gtrOffsets = map fromIntegral $ meta_Tuning $ sng_Metadata sng
                    , gtrGlobal  = 0
                    , gtrCapo    = case fromIntegral $ meta_CapoFretId $ sng_Metadata sng of
                      -1 -> 0
                      n  -> n
                    , gtrName    = Nothing
                    }
                , tuningRSBass = Nothing
                , fixFreeform = True -- setting this for cleaner tremolo if we translate to RB protar
                , tones = flip fmap tones $ fmap $ \tone -> let
                  file = T.unpack (t14_Key tone) <.> "tone2014.xml"
                  in SoftFile file $ SoftReadable $ makeHandle file $
                    byteStringSimpleHandle $ BL.fromStrict $ toneBytes tone
                , pickedBass = False -- TODO
                }
              }
        return (partName, part)
      partsMapWithVox = if isJust maybeVoxSNG
        then HM.insert F.FlexVocal (emptyPart :: Part SoftFile)
          { vocal = Just PartVocal
            { difficulty = Tier 1
            , count      = Vocal1
            , gender     = Nothing
            , key        = Nothing
            , lipsyncRB3 = Nothing
            }
          } partsMap
        else partsMap

  return SongYaml
    { metadata = def'
      { title        = Just title
      , artist       = Just artist
      , album        = Just album
      , year         = Just year
      , fileAlbumArt = art
      , author       = author
      }
    , jammit = HM.empty
    , targets = HM.singleton "rs" $ RS def
      { arrangements = do
        ((slot, partName), _, _, _, _, _) <- namedParts
        return (slot, partName)
      }
    , global = def'
      { fileMidi            = SoftFile "notes.mid" $ SoftChart midiWithVox
      , fileSongAnim        = Nothing
      , backgroundVideo     = Nothing
      , fileBackgroundImage = Nothing
      }
    , audio = HM.singleton "song" $ AudioFile AudioInfo
      { md5      = Nothing
      , frames   = Nothing
      , filePath = Just $ SoftFile "song.ogg" $ SoftReadable oggFile
      , commands = []
      , rate     = Nothing
      , channels = 2 -- TODO get real count
      }
    , plans = HM.singleton "rs" $ StandardPlan StandardPlanInfo
      { song        = Just $ Input $ Named "song"
      , parts       = Parts HM.empty
      , crowd       = Nothing
      , comments    = []
      , tuningCents = 0 -- TODO get from manifest .json (CentOffset)
      , fileTempo   = Nothing
      }
    , parts = Parts partsMapWithVox
    }
