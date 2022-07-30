{-# LANGUAGE LambdaCase        #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards   #-}
module Build.RockBand (rbRules) where

import           Audio
import           Build.Common
import qualified C3
import           Codec.Picture
import           Config                                hiding (Difficulty)
import           Control.Monad.Codec.Onyx              (makeValue, valueId)
import           Control.Monad.Extra
import           Control.Monad.IO.Class
import           Control.Monad.Trans.Resource
import           Control.Monad.Trans.StackTrace
import           Data.Bifunctor                        (second)
import qualified Data.ByteString                       as B
import qualified Data.ByteString.Char8                 as B8
import qualified Data.ByteString.Lazy                  as BL
import           Data.Conduit.Audio
import           Data.Conduit.Audio.Sndfile
import           Data.Default.Class                    (def)
import qualified Data.DTA                              as D
import qualified Data.DTA.Serialize                    as D
import qualified Data.DTA.Serialize.Magma              as Magma
import qualified Data.DTA.Serialize.RB3                as D
import qualified Data.EventList.Absolute.TimeBody      as ATB
import qualified Data.EventList.Relative.TimeBody      as RTB
import           Data.Foldable                         (toList)
import           Data.Hashable                         (Hashable)
import qualified Data.HashMap.Strict                   as HM
import           Data.List                             (sortOn)
import qualified Data.List.NonEmpty                    as NE
import qualified Data.Map                              as Map
import           Data.Maybe                            (fromMaybe, isJust,
                                                        isNothing, mapMaybe)
import           Data.SimpleHandle                     (Folder (..))
import           Data.String                           (IsString, fromString)
import qualified Data.Text                             as T
import qualified Data.Text.Encoding                    as TE
import           Data.Version                          (showVersion)
import           DeriveHelpers                         (mergeEmpty)
import           Development.Shake                     hiding (phony, (%>),
                                                        (&%>))
import           Development.Shake.FilePath
import           Difficulty
import           DryVox                                (clipDryVox,
                                                        toDryVoxFormat,
                                                        vocalTubes)
import           Genre
import qualified Magma
import           MoggDecrypt
import           NPData                                (npdContentID,
                                                        packNPData,
                                                        rb2CustomMidEdatConfig,
                                                        rb3CustomMidEdatConfig)
import           OSFiles                               (shortWindowsPath)
import           Paths_onyxite_customs_lib             (version)
import           PlayStation.PKG                       (makePKG)
import           Preferences                           (MagmaSetting (..))
import           PrettyDTA
import           Reaper.Build                          (TuningInfo (..),
                                                        makeReaperShake)
import           RenderAudio
import           Resources                             (emptyMilo, emptyMiloRB2,
                                                        emptyWeightsRB2,
                                                        getResourcesPath)
import           RockBand.Codec                        (mapTrack)
import qualified RockBand.Codec.Drums                  as RBDrums
import           RockBand.Codec.Events
import qualified RockBand.Codec.File                   as RBFile
import           RockBand.Codec.File                   (saveMIDI, shakeMIDI)
import           RockBand.Codec.ProGuitar
import           RockBand.Codec.Venue
import           RockBand.Common
import           RockBand.Milo                         (MagmaLipsync (..),
                                                        autoLipsync,
                                                        defaultTransition,
                                                        englishSyllables,
                                                        lipsyncAdjustSpeed,
                                                        lipsyncFromMIDITrack,
                                                        lipsyncPad,
                                                        loadVisemesRB3,
                                                        magmaMilo, parseLipsync)
import qualified RockBand.ProGuitar.Play               as PGPlay
import           RockBand.Sections                     (makeRB2Section,
                                                        makeRB3Section,
                                                        makeRBN2Sections)
import qualified RockBand2                             as RB2
import qualified RockBand3                             as RB3
import qualified Sound.File.Sndfile                    as Snd
import qualified Sound.MIDI.File.Event                 as E
import qualified Sound.MIDI.File.Event.SystemExclusive as SysEx
import qualified Sound.MIDI.Util                       as U
import           STFS.Package                          (rb2pkg, rb3pkg, runGetM)
import           System.IO                             (IOMode (ReadMode),
                                                        hFileSize,
                                                        withBinaryFile)
import           Text.Transform                        (replaceCharsRB)

rbRules :: BuildInfo -> FilePath -> TargetRB3 FilePath -> Maybe TargetRB2 -> QueueLog Rules ()
rbRules buildInfo dir rb3 mrb2 = do
  let songYaml = biSongYaml buildInfo
      rel = biRelative buildInfo
      thisFullGenre = fullGenre songYaml

  let pkg :: (IsString a) => a
      pkg = fromString $ T.unpack $ makeShortName (hashRB3 songYaml rb3) songYaml
  (planName, plan) <- case getPlan (tgt_Plan $ rb3_Common rb3) songYaml of
    Nothing   -> fail $ "Couldn't locate a plan for this target: " ++ show rb3
    Just pair -> return pair
  let planDir = rel $ "gen/plan" </> T.unpack planName

  let pathMagmaKick        = dir </> "magma/kick.wav"
      pathMagmaSnare       = dir </> "magma/snare.wav"
      pathMagmaDrums       = dir </> "magma/drums.wav"
      pathMagmaBass        = dir </> "magma/bass.wav"
      pathMagmaGuitar      = dir </> "magma/guitar.wav"
      pathMagmaKeys        = dir </> "magma/keys.wav"
      pathMagmaVocal       = dir </> "magma/vocal.wav"
      pathMagmaCrowd       = dir </> "magma/crowd.wav"
      pathMagmaDryvox0     = dir </> "magma/dryvox0.wav"
      pathMagmaDryvox1     = dir </> "magma/dryvox1.wav"
      pathMagmaDryvox2     = dir </> "magma/dryvox2.wav"
      pathMagmaDryvox3     = dir </> "magma/dryvox3.wav"
      pathMagmaDryvoxSine  = dir </> "magma/dryvox-sine.wav"
      pathMagmaSong        = dir </> "magma/song-countin.wav"
      pathMagmaCover       = dir </> "magma/cover.bmp"
      pathMagmaCoverV1     = dir </> "magma/cover-v1.bmp"
      pathMagmaMid         = dir </> "magma/notes.mid"
      pathMagmaRPP         = dir </> "magma/notes.RPP"
      pathMagmaMidV1       = dir </> "magma/notes-v1.mid"
      pathMagmaProj        = dir </> "magma/magma.rbproj"
      pathMagmaProjV1      = dir </> "magma/magma-v1.rbproj"
      pathMagmaC3          = dir </> "magma/magma.c3"
      pathMagmaSetup       = dir </> "magma"
      pathMagmaRba         = dir </> "magma.rba"
      pathMagmaRbaV1       = dir </> "magma-v1.rba"
      pathMagmaExport      = dir </> "notes-magma-export.mid"
      pathMagmaExport2     = dir </> "notes-magma-added.mid"
      pathMagmaDummyMono   = dir </> "magma/dummy-mono.wav"
      pathMagmaDummyStereo = dir </> "magma/dummy-stereo.wav"
      pathMagmaPad         = dir </> "magma/pad.txt"
      pathMagmaEditedParts = dir </> "magma/edited-parts.txt"

  let magmaParts = map ($ rb3) [rb3_Drums, rb3_Bass, rb3_Guitar, rb3_Keys, rb3_Vocal]
      loadEditedParts :: Staction (DifficultyRB3, Maybe VocalCount)
      loadEditedParts = shk $ read <$> readFile' pathMagmaEditedParts
      loadMidiResults :: Staction (RBFile.Song (RBFile.RawFile U.Beats), DifficultyRB3, Maybe VocalCount, Int)
      loadMidiResults = do
        mid <- shakeMIDI $ planDir </> "raw.mid" :: Staction (RBFile.Song (RBFile.RawFile U.Beats))
        (diffs, vc) <- loadEditedParts
        pad <- shk $ read <$> readFile' pathMagmaPad
        return (mid, diffs, vc, pad)
  pathMagmaKick   %> \out -> do
    (mid, DifficultyRB3{..}, _, pad) <- loadMidiResults
    s <- sourceKick        buildInfo magmaParts (rb3_Common rb3) mid pad True planName plan (rb3_Drums  rb3) rb3DrumsRank
    runAudio (clampIfSilent s) out
  pathMagmaSnare  %> \out -> do
    (mid, DifficultyRB3{..}, _, pad) <- loadMidiResults
    s <- sourceSnare       buildInfo magmaParts (rb3_Common rb3) mid pad True planName plan (rb3_Drums  rb3) rb3DrumsRank
    runAudio (clampIfSilent s) out
  pathMagmaDrums  %> \out -> do
    (mid, DifficultyRB3{..}, _, pad) <- loadMidiResults
    s <- sourceKit         buildInfo magmaParts (rb3_Common rb3) mid pad True planName plan (rb3_Drums  rb3) rb3DrumsRank
    runAudio (clampIfSilent s) out
  pathMagmaBass   %> \out -> do
    (mid, DifficultyRB3{..}, _, pad) <- loadMidiResults
    s <- sourceSimplePart  buildInfo magmaParts (rb3_Common rb3) mid pad True planName plan (rb3_Bass   rb3) rb3BassRank
    runAudio (clampIfSilent s) out
  pathMagmaGuitar %> \out -> do
    (mid, DifficultyRB3{..}, _, pad) <- loadMidiResults
    s <- sourceSimplePart  buildInfo magmaParts (rb3_Common rb3) mid pad True planName plan (rb3_Guitar rb3) rb3GuitarRank
    runAudio (clampIfSilent s) out
  pathMagmaKeys   %> \out -> do
    (mid, DifficultyRB3{..}, _, pad) <- loadMidiResults
    s <- sourceSimplePart  buildInfo magmaParts (rb3_Common rb3) mid pad True planName plan (rb3_Keys   rb3) rb3KeysRank
    runAudio (clampIfSilent s) out
  pathMagmaVocal  %> \out -> do
    (mid, DifficultyRB3{..}, _, pad) <- loadMidiResults
    s <- sourceSimplePart  buildInfo magmaParts (rb3_Common rb3) mid pad True planName plan (rb3_Vocal  rb3) rb3VocalRank
    runAudio (clampIfSilent s) out
  pathMagmaCrowd  %> \out -> do
    (mid, DifficultyRB3{}, _, pad) <- loadMidiResults
    s <- sourceCrowd       buildInfo            (rb3_Common rb3) mid pad      planName plan
    runAudio (clampIfSilent s) out
  pathMagmaSong   %> \out -> do
    (mid, DifficultyRB3{..}, _, pad) <- loadMidiResults
    s <- sourceSongCountin buildInfo            (rb3_Common rb3) mid pad True planName plan
      [ (rb3_Drums  rb3, rb3DrumsRank )
      , (rb3_Guitar rb3, rb3GuitarRank)
      , (rb3_Bass   rb3, rb3BassRank  )
      , (rb3_Keys   rb3, rb3KeysRank  )
      , (rb3_Vocal  rb3, rb3VocalRank )
      ]
    runAudio (clampIfSilent s) out
  let saveClip m out vox = do
        let fmt = Snd.Format Snd.HeaderFormatWav Snd.SampleFormatPcm16 Snd.EndianFile
            clip = clipDryVox $ U.applyTempoTrack (RBFile.s_tempos m)
              $ fmap isJust $ vocalTubes vox
        unclippedVox <- shk $ buildSource $ Input pathMagmaVocal
        unclipped <- case frames unclippedVox of
          0 -> shk $ buildSource $ Input pathMagmaSong
          _ -> return unclippedVox
        lg $ "Writing a clipped dry vocals file to " ++ out
        stackIO $ runResourceT $ sinkSnd out fmt $ toDryVoxFormat $ clip unclipped
        lg $ "Finished writing dry vocals to " ++ out
  pathMagmaDryvox0 %> \out -> do
    m <- shakeMIDI pathMagmaMid
    saveClip m out $ RBFile.fixedPartVocals $ RBFile.s_tracks m
  pathMagmaDryvox1 %> \out -> do
    m <- shakeMIDI pathMagmaMid
    saveClip m out $ RBFile.fixedHarm1 $ RBFile.s_tracks m
  pathMagmaDryvox2 %> \out -> do
    m <- shakeMIDI pathMagmaMid
    saveClip m out $ RBFile.fixedHarm2 $ RBFile.s_tracks m
  pathMagmaDryvox3 %> \out -> do
    m <- shakeMIDI pathMagmaMid
    saveClip m out $ RBFile.fixedHarm3 $ RBFile.s_tracks m
  pathMagmaDryvoxSine %> \out -> do
    m <- shakeMIDI pathMagmaMid
    let fmt = Snd.Format Snd.HeaderFormatWav Snd.SampleFormatPcm16 Snd.EndianFile
    liftIO $ runResourceT $ sinkSnd out fmt $ RB2.dryVoxAudio m
  pathMagmaDummyMono   %> buildAudio (Silence 1 $ Seconds 31) -- we set preview start to 0:00 so these can be short
  pathMagmaDummyStereo %> buildAudio (Silence 2 $ Seconds 31)
  pathMagmaCover %> shk . copyFile' (rel "gen/cover.bmp")
  pathMagmaCoverV1 %> \out -> liftIO $ writeBitmap out $ generateImage (\_ _ -> PixelRGB8 0 0 255) 256 256
  let title = targetTitle songYaml $ RB3 rb3
  pathMagmaProj %> \out -> do
    editedParts <- loadEditedParts
    p <- makeMagmaProj songYaml rb3 plan editedParts pkg pathMagmaMid $ return title
    liftIO $ D.writeFileDTA_latin1 out $ D.serialize (valueId D.stackChunks) p
  pathMagmaC3 %> \out -> do
    midi <- shakeMIDI pathMagmaMid
    c3 <- makeC3 songYaml plan rb3 midi pkg
    liftIO $ B.writeFile out $ TE.encodeUtf8 $ C3.showC3 c3
  let magmaNeededAudio = do
        ((kickSpec, snareSpec, _), _) <- computeDrumsPart (rb3_Drums rb3) plan songYaml
        return $ concat
          [ guard (maybe False (/= def) $ getPart (rb3_Drums  rb3) songYaml) >> concat
            [ [pathMagmaDrums]
            , [pathMagmaKick | not $ null kickSpec]
            , [pathMagmaSnare | not $ null snareSpec]
            ]
          , guard (maybe False (/= def) $ getPart (rb3_Bass   rb3) songYaml) >> [pathMagmaBass  ]
          , guard (maybe False (/= def) $ getPart (rb3_Guitar rb3) songYaml) >> [pathMagmaGuitar]
          , guard (maybe False (/= def) $ getPart (rb3_Keys   rb3) songYaml) >> [pathMagmaKeys  ]
          , case fmap vocalCount $ getPart (rb3_Vocal rb3) songYaml >>= partVocal of
            Nothing     -> []
            Just Vocal1 -> [pathMagmaVocal, pathMagmaDryvox0]
            Just Vocal2 -> [pathMagmaVocal, pathMagmaDryvox1, pathMagmaDryvox2]
            Just Vocal3 -> [pathMagmaVocal, pathMagmaDryvox1, pathMagmaDryvox2, pathMagmaDryvox3]
          , [pathMagmaSong, pathMagmaCrowd]
          ]
  pathMagmaRPP %> \out -> do
    auds <- magmaNeededAudio
    let auds' = filter (`notElem` [pathMagmaDryvox1, pathMagmaDryvox2, pathMagmaDryvox3]) auds
        tunings = TuningInfo
          { tuningGuitars = do
            (fpart, part) <- HM.toList $ getParts $ _parts songYaml
            fpart' <- toList $ lookup fpart
              [ (rb3_Guitar rb3, RBFile.FlexGuitar)
              , (rb3_Bass   rb3, RBFile.FlexBass  )
              ]
            pg <- toList $ partProGuitar part
            return (fpart', pgTuning pg)
          , tuningCents = _tuningCents plan
          }
    makeReaperShake tunings pathMagmaMid pathMagmaMid auds' out
  phony pathMagmaSetup $ do
    -- Just make all the Magma prereqs, but don't actually run Magma
    auds <- magmaNeededAudio
    shk $ need $ auds ++ [pathMagmaCover, pathMagmaMid, pathMagmaProj, pathMagmaC3, pathMagmaRPP]
  pathMagmaRba %> \out -> do
    shk $ need [pathMagmaSetup]
    lg "# Running Magma v2 (C3)"
    mapStackTraceT (liftIO . runResourceT) (Magma.runMagma pathMagmaProj out) >>= lg
  let blackVenueTrack = mempty
        { venueCameraRB3        = RTB.singleton 0 V3_coop_all_far
        , venuePostProcessRB3   = RTB.singleton 0 V3_film_b_w
        , venueLighting         = RTB.singleton 0 Lighting_blackout_fast
        }
  pathMagmaExport %> \out -> do
    shk $ need [pathMagmaMid, pathMagmaProj]
    let magma = mapStackTraceT (liftIO . runResourceT) (Magma.runMagmaMIDI pathMagmaProj out) >>= lg
        fallback = do
          userMid <- shakeMIDI pathMagmaMid
          saveMIDI out userMid
            { RBFile.s_tracks = (RBFile.s_tracks userMid)
              { RBFile.fixedVenue = blackVenueTrack
              -- TODO sections if midi didn't supply any
              }
            }
    case rb3_Magma rb3 of
      MagmaRequire -> do
        lg "# Running Magma v2 to export MIDI"
        magma
      MagmaTry -> do
        lg "# Running Magma v2 to export MIDI (with fallback)"
        errorToWarning magma >>= \case
          Nothing -> do
            lg "Falling back to black venue MIDI due to a Magma error"
            fallback
          Just () -> return ()
      MagmaDisable -> fallback
  let midRealSections :: RBFile.Song (RBFile.OnyxFile U.Beats) -> Staction (RTB.T U.Beats T.Text)
      midRealSections = notSingleSection . fmap snd . eventsSections . RBFile.onyxEvents . RBFile.s_tracks
      -- also applies the computed pad + tempo hacks
      getRealSections' :: Staction (RTB.T U.Beats T.Text)
      getRealSections' = do
        raw <- fmap (applyTargetMIDI $ rb3_Common rb3) $ shakeMIDI $ planDir </> "raw.mid"
        let sects = fmap snd $ eventsSections $ RBFile.onyxEvents $ RBFile.s_tracks raw
        (_, _, _, RB3.TrackAdjust adjuster) <- RB3.magmaLegalTempos
          (sum (RTB.getTimes sects) + 20) -- whatever
          (RBFile.s_tempos raw)
          (RBFile.s_signatures raw)
        padSeconds <- shk $ read <$> readFile' pathMagmaPad
        let padBeats = padSeconds * 2
        notSingleSection $ RTB.delay (fromInteger padBeats) $ adjuster sects
      notSingleSection rtb = case RTB.toPairList rtb of
        [_] -> do
          warn "Only one practice section event; removing it"
          return RTB.empty
        _   -> return rtb
  pathMagmaExport2 %> \out -> do
    -- Using Magma's "export MIDI" option overwrites animations/venue
    -- with autogenerated ones, even if they were actually authored.
    -- We already generate moods and drum animations ourselves,
    -- so the only things we need to get from Magma are venue,
    -- and percent sections.
    userMid <- shakeMIDI pathMagmaMid
    magmaMid <- shakeMIDI pathMagmaExport
    sects <- getRealSections'
    let trackOr x y = if x == mergeEmpty then y else x
        user = RBFile.s_tracks userMid
        magma = RBFile.s_tracks magmaMid
        reauthor f = f user `trackOr` f magma
    saveMIDI out $ userMid
      { RBFile.s_tracks = user
        { RBFile.fixedVenue = case _autogenTheme $ _global songYaml of
          Nothing -> blackVenueTrack
          Just _  -> let
            onlyLightingPP venue = mempty
              { venueSpotKeys = venueSpotKeys venue
              , venueSpotVocal = venueSpotVocal venue
              , venueSpotGuitar = venueSpotGuitar venue
              , venueSpotDrums = venueSpotDrums venue
              , venueSpotBass = venueSpotBass venue
              , venuePostProcessRB3 = venuePostProcessRB3 venue
              , venuePostProcessRB2 = venuePostProcessRB2 venue
              , venueLighting = venueLighting venue
              , venueLightingCommands = venueLightingCommands venue
              }
            onlyCamera venue = mempty
              { venueCameraRB3 = venueCameraRB3 venue
              , venueCameraRB2 = venueCameraRB2 venue
              , venueDirectedRB2 = venueDirectedRB2 venue
              }
            onlyOther venue = mempty
              { venueSingGuitar = venueSingGuitar venue
              , venueSingDrums = venueSingDrums venue
              , venueSingBass = venueSingBass venue
              , venueBonusFX = venueBonusFX venue
              , venueBonusFXOptional = venueBonusFXOptional venue
              , venueFog = venueFog venue
              }
            in mconcat
              [ reauthor $ onlyLightingPP . RBFile.fixedVenue
              , reauthor $ onlyCamera . RBFile.fixedVenue
              , reauthor $ onlyOther . RBFile.fixedVenue
              ]
        , RBFile.fixedEvents = if RTB.null sects
          then RBFile.fixedEvents magma
          else (RBFile.fixedEvents magma)
            { eventsSections = fmap makeRB3Section sects
            }
        }
      }

  [pathMagmaMid, pathMagmaPad, pathMagmaEditedParts] &%> \_ -> do
    input <- shakeMIDI $ planDir </> "raw.mid"
    (_, mixMode) <- computeDrumsPart (rb3_Drums rb3) plan songYaml
    sects <- ATB.toPairList . RTB.toAbsoluteEventList 0 <$> midRealSections input
    let (magmaSects, invalid) = makeRBN2Sections sects
        magmaSects' = RTB.fromAbsoluteEventList $ ATB.fromPairList magmaSects
        adjustEvents trks = trks
          { RBFile.onyxEvents = (RBFile.onyxEvents trks)
            { eventsSections = magmaSects'
            }
          }
        input' = input { RBFile.s_tracks = adjustEvents $ RBFile.s_tracks input }
    (output, diffs, vc, pad) <- case plan of
      MoggPlan{} -> do
        (output, diffs, vc) <- RB3.processRB3
          rb3
          songYaml
          (applyTargetMIDI (rb3_Common rb3) input')
          mixMode
          (applyTargetLength (rb3_Common rb3) input <$> getAudioLength buildInfo planName plan)
        return (output, diffs, vc, 0)
      Plan{} -> RB3.processRB3Pad
        rb3
        songYaml
        (applyTargetMIDI (rb3_Common rb3) input')
        mixMode
        (applyTargetLength (rb3_Common rb3) input <$> getAudioLength buildInfo planName plan)
    liftIO $ writeFile pathMagmaPad $ show pad
    liftIO $ writeFile pathMagmaEditedParts $ show (diffs, vc)
    case invalid of
      [] -> return ()
      _  -> lg $ "The following sections were swapped out for Magma (but will be readded in CON output): " ++ show invalid
    saveMIDI pathMagmaMid output

  let pathDta = dir </> "stfs/songs/songs.dta"
      pathMid = dir </> "stfs/songs" </> pkg </> pkg <.> "mid"
      pathOgg = dir </> "audio.ogg"
      pathMogg = dir </> "stfs/songs" </> pkg </> pkg <.> "mogg"
      pathPng = dir </> "stfs/songs" </> pkg </> "gen" </> (pkg ++ "_keep.png_xbox")
      pathMilo = dir </> "stfs/songs" </> pkg </> "gen" </> pkg <.> "milo_xbox"
      pathCon = dir </> "rb3con"

  pathDta %> \out -> do
    song <- shakeMIDI pathMid
    editedParts <- loadEditedParts
    songPkg <- makeRB3DTA songYaml plan rb3 False editedParts song pkg
    liftIO $ writeUtf8CRLF out $ prettyDTA pkg songPkg $ makeC3DTAComments (_metadata songYaml) plan rb3
  pathMid %> shk . copyFile' pathMagmaExport2
  pathOgg %> \out -> case plan of
    MoggPlan{} -> do
      -- TODO apply segment boundaries
      let speed = fromMaybe 1 $ tgt_Speed $ rb3_Common rb3
      pad <- shk $ read <$> readFile' (dir </> "magma/pad.txt")
      case (speed, pad :: Int) of
        (1, 0) -> shk $ copyFile' (planDir </> "audio.ogg") out
        _      -> do
          input <- shk $ buildSource $ Input $ planDir </> "audio.ogg"
          let src = padStart (Seconds $ realToFrac pad)
                $ stretchFullSmart (1 / speed) 1 input
          runAudio src out
    Plan{..} -> do
      (_, mixMode) <- computeDrumsPart (rb3_Drums rb3) plan songYaml
      (DifficultyRB3{..}, _) <- loadEditedParts
      let partsBeforeSong = concat
            [ [pathMagmaKick   | rb3DrumsRank  /= 0 && mixMode /= RBDrums.D0]
            , [pathMagmaSnare  | rb3DrumsRank  /= 0 && notElem mixMode [RBDrums.D0, RBDrums.D4]]
            , [pathMagmaDrums  | rb3DrumsRank  /= 0]
            , [pathMagmaBass   | rb3BassRank   /= 0]
            , [pathMagmaGuitar | rb3GuitarRank /= 0]
            , [pathMagmaKeys   | rb3KeysRank   /= 0]
            , [pathMagmaVocal  | rb3VocalRank  /= 0]
            , [pathMagmaCrowd  | isJust _crowd]
            ]
          parts = case NE.nonEmpty partsBeforeSong of
            Nothing -> return pathMagmaSong
            Just ne -> ne <> return pathMagmaSong
      src <- shk $ buildSource $ Merge $ fmap Input parts
      runAudio src out
  pathMogg %> \out -> case plan of
    MoggPlan{} -> do
      -- TODO apply segment boundaries
      let speed = fromMaybe 1 $ tgt_Speed $ rb3_Common rb3
      pad <- shk $ read <$> readFile' (dir </> "magma/pad.txt")
      case (speed, pad :: Int) of
        (1, 0) -> shk $ copyFile' (planDir </> "audio.mogg") out
        _      -> do
          shk $ need [pathOgg]
          mapStackTraceT (liftIO . runResourceT) $ oggToMogg pathOgg out
    Plan{} -> do
      shk $ need [pathOgg]
      mapStackTraceT (liftIO . runResourceT) $ oggToMogg pathOgg out
  pathPng  %> shk . copyFile' (rel "gen/cover.png_xbox")
  pathMilo %> \out -> case getPart (rb3_Vocal rb3) songYaml >>= partVocal of
    -- TODO apply segment boundaries
    -- TODO add member assignments and anim style in BandSongPref, and anim style
    -- TODO include rb3 format venue in milo (with speed/pad adjustments) but only if dlc (not rbn2)
    Nothing   -> stackIO emptyMilo >>= \mt -> shk $ copyFile' mt out
    Just pvox -> do
      let srcs = case (vocalLipsyncRB3 pvox, vocalCount pvox) of
            (Just lrb3, _     ) -> lipsyncSources lrb3
            (Nothing  , Vocal1) -> [LipsyncVocal Nothing]
            (Nothing  , Vocal2) -> [LipsyncVocal $ Just Vocal1, LipsyncVocal $ Just Vocal2]
            (Nothing  , Vocal3) -> [LipsyncVocal $ Just Vocal1, LipsyncVocal $ Just Vocal2, LipsyncVocal $ Just Vocal3]
      midi <- shakeMIDI $ planDir </> "raw.mid"
      vmap <- loadVisemesRB3
      pad <- shk $ read <$> readFile' (dir </> "magma/pad.txt")
      let vox = RBFile.getFlexPart (rb3_Vocal rb3) $ RBFile.s_tracks midi
          lip = lipsyncFromMIDITrack vmap . mapTrack (U.applyTempoTrack $ RBFile.s_tempos midi)
          auto = autoLipsync defaultTransition vmap englishSyllables . mapTrack (U.applyTempoTrack $ RBFile.s_tempos midi)
          write = stackIO . BL.writeFile out
          padSeconds = fromIntegral (pad :: Int) :: U.Seconds
          speed = realToFrac $ fromMaybe 1 $ tgt_Speed $ rb3_Common rb3 :: Rational
          fromSource = fmap (lipsyncPad padSeconds . lipsyncAdjustSpeed speed) . \case
            LipsyncTrack1 -> return $ lip $ RBFile.onyxLipsync1 vox
            LipsyncTrack2 -> return $ lip $ RBFile.onyxLipsync2 vox
            LipsyncTrack3 -> return $ lip $ RBFile.onyxLipsync3 vox
            LipsyncTrack4 -> return $ lip $ RBFile.onyxLipsync4 vox
            LipsyncVocal mvc -> return $ auto $ case mvc of
              Nothing     -> RBFile.onyxPartVocals vox
              Just Vocal1 -> RBFile.onyxHarm1 vox
              Just Vocal2 -> RBFile.onyxHarm2 vox
              Just Vocal3 -> RBFile.onyxHarm3 vox
            LipsyncFile f -> stackIO (BL.fromStrict <$> B.readFile f) >>= runGetM parseLipsync
      lips <- mapM fromSource srcs
      case lips of
        []                    -> stackIO emptyMilo >>= \mt -> shk $ copyFile' mt out
        [l1]                  -> write $ magmaMilo $ MagmaLipsync1 l1
        [l1, l2]              -> write $ magmaMilo $ MagmaLipsync2 l1 l2
        [l1, l2, l3]          -> write $ magmaMilo $ MagmaLipsync3 l1 l2 l3
        l1 : l2 : l3 : l4 : _ -> write $ magmaMilo $ MagmaLipsync4 l1 l2 l3 l4
  pathCon %> \out -> do
    let files = [pathDta, pathMid, pathMogg, pathMilo]
          ++ [pathPng | isJust $ _fileAlbumArt $ _metadata songYaml]
    shk $ need files
    lg "# Producing RB3 CON file"
    mapStackTraceT (mapQueueLog $ liftIO . runResourceT) $ rb3pkg
      (getArtist (_metadata songYaml) <> " - " <> title)
      (T.pack $ "Compiled by Onyx Music Game Toolkit version " <> showVersion version)
      (dir </> "stfs")
      out

  let rb3ps3Root = dir </> "rb3-ps3"
      rb3ps3DTA = rb3ps3Root </> "songs/songs.dta"
      rb3ps3Mogg = rb3ps3Root </> "songs" </> pkg </> pkg <.> "mogg"
      rb3ps3Mid = rb3ps3Root </> "songs" </> pkg </> pkg <.> "mid.edat"
      rb3ps3Art = rb3ps3Root </> "songs" </> pkg </> "gen" </> (pkg ++ "_keep.png_ps3")
      rb3ps3Milo = rb3ps3Root </> "songs" </> pkg </> "gen" </> pkg <.> "milo_ps3"
      -- don't think we need weights.bin or .pan
      rb3ps3Pkg = dir </> "rb3-ps3.pkg"
      rb3ps3Folder = makePS3Name (hashRB3 songYaml rb3) songYaml
      rb3ps3EDATConfig = rb3CustomMidEdatConfig rb3ps3Folder
      rb3ps3ContentID = npdContentID rb3ps3EDATConfig

  rb3ps3DTA %> \out -> do
    song <- shakeMIDI pathMid
    editedParts <- loadEditedParts
    songPkg <- makeRB3DTA songYaml plan rb3 True editedParts song pkg
    liftIO $ writeUtf8CRLF out $ prettyDTA pkg songPkg $ makeC3DTAComments (_metadata songYaml) plan rb3
  rb3ps3Mid %> \out -> if rb3_PS3Encrypt rb3
    then do
      shk $ need [pathMid]
      fin  <- shortWindowsPath False pathMid
      fout <- shortWindowsPath True  out
      stackIO $ packNPData rb3ps3EDATConfig fin fout $ B8.pack pkg <> ".mid.edat"
    else shk $ copyFile' pathMid out
  rb3ps3Art %> shk . copyFile' (rel "gen/cover.png_ps3")
  rb3ps3Mogg %> \out -> do
    -- PS3 RB3 can't play unencrypted moggs
    shk $ need [pathMogg]
    moggType <- stackIO $ withBinaryFile pathMogg ReadMode $ \h -> B.hGet h 1
    fin  <- shortWindowsPath False pathMogg
    fout <- shortWindowsPath True  out
    case B.unpack moggType of
      [0xA] -> stackIO $ encryptRB1 fin fout
      _     -> shk $ copyFile' pathMogg out
  rb3ps3Milo %> shk . copyFile' pathMilo
  phony rb3ps3Root $ do
    shk $ need [rb3ps3DTA, rb3ps3Mogg, rb3ps3Mid, rb3ps3Art, rb3ps3Milo]

  rb3ps3Pkg %> \out -> do
    shk $ need [rb3ps3Root]
    let container name inner = Folder { folderSubfolders = [(name, inner)], folderFiles = [] }
    main <- container "USRDIR" . container rb3ps3Folder <$> crawlFolderBytes rb3ps3Root
    extra <- stackIO (getResourcesPath "pkg-contents/rb3") >>= crawlFolderBytes
    stackIO $ makePKG rb3ps3ContentID (main <> extra) out

  -- Guitar rules
  dir </> "protar-mpa.mid" %> \out -> do
    input <- shakeMIDI pathMagmaMid
    let gtr17   = RBFile.onyxPartRealGuitar   $ RBFile.getFlexPart (rb3_Guitar rb3) $ RBFile.s_tracks input
        gtr22   = RBFile.onyxPartRealGuitar22 $ RBFile.getFlexPart (rb3_Guitar rb3) $ RBFile.s_tracks input
        bass17  = RBFile.onyxPartRealGuitar   $ RBFile.getFlexPart (rb3_Bass   rb3) $ RBFile.s_tracks input
        bass22  = RBFile.onyxPartRealGuitar22 $ RBFile.getFlexPart (rb3_Bass   rb3) $ RBFile.s_tracks input
        pgThres = maybe 170 pgHopoThreshold $ getPart (rb3_Guitar rb3) songYaml >>= partProGuitar
        pbThres = maybe 170 pgHopoThreshold $ getPart (rb3_Bass   rb3) songYaml >>= partProGuitar
        playTrack thres cont name t = let
          expert = fromMaybe mempty $ Map.lookup Expert $ pgDifficulties t
          auto = PGPlay.autoplay (fromIntegral thres / 480) (RBFile.s_tempos input) expert
          msgToSysEx msg
            = E.SystemExclusive $ SysEx.Regular $ PGPlay.sendCommand (cont, msg) ++ [0xF7]
          in U.setTrackName name $ msgToSysEx <$> auto
    saveMIDI out input
      { RBFile.s_tracks = RBFile.RawFile
          [ playTrack pgThres PGPlay.Mustang "GTR17"  $ if nullPG gtr17  then gtr22  else gtr17
          , playTrack pgThres PGPlay.Squier  "GTR22"  $ if nullPG gtr22  then gtr17  else gtr22
          , playTrack pbThres PGPlay.Mustang "BASS17" $ if nullPG bass17 then bass22 else bass17
          , playTrack pbThres PGPlay.Squier  "BASS22" $ if nullPG bass22 then bass17 else bass22
          ]
      }

  case mrb2 of
    Nothing -> return ()
    Just rb2 -> do

      pathMagmaMidV1 %> \out -> shakeMIDI pathMagmaMid >>= RB2.convertMIDI >>= saveMIDI out

      pathMagmaProjV1 %> \out -> do
        editedParts <- loadEditedParts
        p <- makeMagmaProj songYaml rb3 plan editedParts pkg pathMagmaMid $ return title
        let makeDummy (Magma.Tracks dl dkt dk ds b g v k bck) = Magma.Tracks
              dl
              (makeDummyKeep dkt)
              (makeDummyKeep dk)
              (makeDummyKeep ds)
              (makeDummyMono b)
              (makeDummyMono g)
              (makeDummyMono v)
              (makeDummyMono k) -- doesn't matter
              (makeDummyMono bck)
            makeDummyMono af = af
              { Magma.audioFile = "dummy-mono.wav"
              , Magma.channels = 1
              , Magma.pan = [0]
              , Magma.vol = [0]
              }
            makeDummyKeep af = case Magma.channels af of
              1 -> af
                { Magma.audioFile = "dummy-mono.wav"
                }
              _ -> af
                { Magma.audioFile = "dummy-stereo.wav"
                , Magma.channels = 2
                , Magma.pan = [-1, 1]
                , Magma.vol = [0, 0]
                }
        liftIO $ D.writeFileDTA_latin1 out $ D.serialize (valueId D.stackChunks) p
          { Magma.project = (Magma.project p)
            { Magma.albumArt = Magma.AlbumArt "cover-v1.bmp"
            , Magma.midi = (Magma.midi $ Magma.project p)
              { Magma.midiFile = "notes-v1.mid"
              }
            , Magma.projectVersion = 5
            , Magma.languages = let
                lang s = elem s $ _languages $ _metadata songYaml
                eng = lang "English"
                fre = lang "French"
                ita = lang "Italian"
                spa = lang "Spanish"
                in Magma.Languages
                  { Magma.english  = Just $ eng || not (or [eng, fre, ita, spa])
                  , Magma.french   = Just fre
                  , Magma.italian  = Just ita
                  , Magma.spanish  = Just spa
                  , Magma.german   = Nothing
                  , Magma.japanese = Nothing
                  }
            , Magma.dryVox = (Magma.dryVox $ Magma.project p)
              { Magma.dryVoxFileRB2 = Just "dryvox-sine.wav"
              }
            , Magma.tracks = makeDummy $ Magma.tracks $ Magma.project p
            , Magma.metadata = (Magma.metadata $ Magma.project p)
              { Magma.genre = rbn1Genre thisFullGenre
              , Magma.subGenre = "subgenre_" <> rbn1Subgenre thisFullGenre
              , Magma.author = T.strip $ T.take 75 $ Magma.author $ Magma.metadata $ Magma.project p
              -- Magma v1 (but not v2) complains if track number is over 99
              , Magma.trackNumber = min 99 $ Magma.trackNumber $ Magma.metadata $ Magma.project p
              }
            , Magma.gamedata = (Magma.gamedata $ Magma.project p)
              { Magma.previewStartMs = 0 -- for dummy audio. will reset after magma
              }
            }
          }

      pathMagmaRbaV1 %> \out -> do
        shk $ need [pathMagmaDummyMono, pathMagmaDummyStereo, pathMagmaDryvoxSine, pathMagmaCoverV1, pathMagmaMidV1, pathMagmaProjV1]
        lg "# Running Magma v1 (without 10 min limit)"
        errorToWarning (mapStackTraceT (liftIO . runResourceT) $ Magma.runMagmaV1 pathMagmaProjV1 out) >>= \case
          Just output -> lg output
          Nothing     -> do
            lg "Magma v1 failed; optimistically bypassing."
            stackIO $ B.writeFile out B.empty

      -- Magma v1 rba to con
      do
        let doesRBAExist = do
              shk $ need [pathMagmaRbaV1]
              stackIO $ (/= 0) <$> withBinaryFile pathMagmaRbaV1 ReadMode hFileSize
            rb2CON = dir </> "rb2con"
            rb2OriginalDTA = dir </> "rb2-original.dta"
            rb2DTA = dir </> "rb2/songs/songs.dta"
            rb2Mogg = dir </> "rb2/songs" </> pkg </> pkg <.> "mogg"
            rb2Mid = dir </> "rb2/songs" </> pkg </> pkg <.> "mid"
            rb2Art = dir </> "rb2/songs" </> pkg </> "gen" </> (pkg ++ "_keep.png_xbox")
            rb2Weights = dir </> "rb2/songs" </> pkg </> "gen" </> (pkg ++ "_weights.bin")
            rb2Milo = dir </> "rb2/songs" </> pkg </> "gen" </> pkg <.> "milo_xbox"
            rb2Pan = dir </> "rb2/songs" </> pkg </> pkg <.> "pan"
            fixDict = HM.fromList . fixAssoc . HM.toList
            fixDictList = D.DictList . fixAssoc . D.fromDictList
            fixAssoc = mapMaybe $ \(k, v) -> case k of
              "guitar" -> Just (k, v)
              "bass"   -> Just (k, v)
              "keys"   -> Nothing
              "drum"   -> Just (k, v)
              "vocals" -> Just (k, v)
              "band"   -> Just (k, v)
              _        -> Nothing
        rb2OriginalDTA %> \out -> do
          ex <- doesRBAExist
          if ex
            then Magma.getRBAFile 0 pathMagmaRbaV1 out
            else do
              shk $ need [pathDta]
              (_, rb3DTA, _) <- readRB3DTA pathDta
              let newDTA :: D.SongPackage
                  newDTA = D.SongPackage
                    { D.name = D.name rb3DTA
                    , D.artist = D.artist rb3DTA
                    , D.master = not $ _cover $ _metadata songYaml
                    , D.song = D.Song
                      -- most of this gets rewritten later anyway
                      { D.songName = D.songName $ D.song rb3DTA
                      , D.tracksCount = Nothing
                      , D.tracks = D.tracks $ D.song rb3DTA
                      , D.pans = D.pans $ D.song rb3DTA
                      , D.vols = D.vols $ D.song rb3DTA
                      , D.cores = D.cores $ D.song rb3DTA
                      , D.drumSolo = D.drumSolo $ D.song rb3DTA -- needed
                      , D.drumFreestyle = D.drumFreestyle $ D.song rb3DTA -- needed
                      , D.midiFile = D.midiFile $ D.song rb3DTA
                      -- not used
                      , D.vocalParts = Nothing
                      , D.crowdChannels = Nothing
                      , D.hopoThreshold = Nothing
                      , D.muteVolume = Nothing
                      , D.muteVolumeVocals = Nothing
                      }
                    , D.songScrollSpeed = D.songScrollSpeed rb3DTA
                    , D.bank = D.bank rb3DTA
                    , D.animTempo = D.animTempo rb3DTA
                    , D.songLength = D.songLength rb3DTA
                    , D.preview = D.preview rb3DTA
                    , D.rank = fixDict $ D.rank rb3DTA
                    , D.genre = Just $ rbn1Genre thisFullGenre
                    , D.decade = Just $ case D.yearReleased rb3DTA of
                      Nothing -> "the10s"
                      Just y
                        | 1960 <= y && y < 1970 -> "the60s"
                        | 1970 <= y && y < 1980 -> "the70s"
                        | 1980 <= y && y < 1990 -> "the80s"
                        | 1990 <= y && y < 2000 -> "the90s"
                        | 2000 <= y && y < 2010 -> "the00s"
                        | 2010 <= y && y < 2020 -> "the10s"
                        | otherwise -> "the10s"
                    , D.vocalGender = D.vocalGender rb3DTA
                    , D.version = 0
                    , D.fake = Nothing
                    , D.downloaded = Just True
                    , D.songFormat = 4
                    , D.albumArt = Just True
                    , D.yearReleased = D.yearReleased rb3DTA
                    , D.yearRecorded = D.yearRecorded rb3DTA
                    , D.basePoints = Just 0 -- TODO why did I put this?
                    , D.videoVenues = Nothing
                    , D.dateReleased = Nothing
                    , D.dateRecorded = Nothing
                    , D.rating = D.rating rb3DTA
                    , D.subGenre = Just $ "subgenre_" <> rbn1Subgenre thisFullGenre
                    , D.songId = D.songId rb3DTA
                    , D.tuningOffsetCents = D.tuningOffsetCents rb3DTA
                    , D.context = Just 2000
                    , D.gameOrigin = Just "rb2"
                    , D.ugc = Just True
                    , D.albumName = D.albumName rb3DTA
                    , D.albumTrackNumber = D.albumTrackNumber rb3DTA
                    , D.packName = D.packName rb3DTA
                    -- not present
                    , D.drumBank = Nothing
                    , D.bandFailCue = Nothing
                    , D.solo = Nothing
                    , D.shortVersion = Nothing
                    , D.vocalTonicNote = Nothing
                    , D.songTonality = Nothing
                    , D.songKey = Nothing
                    , D.realGuitarTuning = Nothing
                    , D.realBassTuning = Nothing
                    , D.guidePitchVolume = Nothing
                    , D.encoding = Nothing
                    , D.extraAuthoring = Nothing
                    , D.alternatePath = Nothing
                    }
              liftIO $ D.writeFileDTA_latin1 out $ D.DTA 0 $ D.Tree 0 [D.Parens (D.Tree 0 (D.Sym pkg : makeValue D.stackChunks newDTA))]
        let writeRB2DTA isPS3 out = do
              shk $ need [rb2OriginalDTA, pathDta]
              (_, magmaDTA, _) <- readRB3DTA rb2OriginalDTA
              (_, rb3DTA, _) <- readRB3DTA pathDta
              let newDTA :: D.SongPackage
                  newDTA = magmaDTA
                    { D.name = targetTitle songYaml $ RB2 rb2
                    , D.artist = D.artist rb3DTA
                    , D.albumName = D.albumName rb3DTA
                    , D.master = not $ _cover $ _metadata songYaml
                    , D.version = 0
                    -- if version is not 0, you get a message
                    -- "can't play this song until all players in your session purchase it!"
                    , D.song = (D.song magmaDTA)
                      { D.tracksCount = Nothing
                      , D.tracks = fixDictList $ D.tracks $ D.song rb3DTA
                      , D.midiFile = Just $ "songs/" <> pkg <> "/" <> pkg <> ".mid"
                      , D.songName = "songs/" <> pkg <> "/" <> pkg
                      , D.pans = D.pans $ D.song rb3DTA
                      , D.vols = D.vols $ D.song rb3DTA
                      , D.cores = D.cores $ D.song rb3DTA
                      , D.crowdChannels = D.crowdChannels $ D.song rb3DTA
                      }
                    , D.songId = Just $ case rb2_SongID rb2 of
                        SongIDSymbol s   -> Right s -- could override on PS3 but shouldn't happen
                        SongIDInt i      -> Left $ fromIntegral i
                        SongIDAutoSymbol -> if isPS3
                          then Left $ fromIntegral $ hashRB3 songYaml rb3 -- PS3 needs real number ID
                          else Right pkg
                        SongIDAutoInt    -> Left $ fromIntegral $ hashRB3 songYaml rb3
                    , D.preview = D.preview rb3DTA -- because we told magma preview was at 0s earlier
                    , D.songLength = D.songLength rb3DTA -- magma v1 set this to 31s from the audio file lengths
                    , D.rating = case (isPS3, D.rating rb3DTA) of
                      (True, 4) -> 2 -- Unrated causes it to be locked in game on PS3
                      (_   , x) -> x
                    }
              liftIO $ writeLatin1CRLF out $ prettyDTA pkg newDTA $ makeC3DTAComments (_metadata songYaml) plan rb3
        rb2DTA %> writeRB2DTA False
        rb2Mid %> \out -> do
          ex <- doesRBAExist
          RBFile.Song tempos sigs trks <- if ex
            then do
              shk $ need [pathMagmaRbaV1]
              liftIO $ Magma.getRBAFile 1 pathMagmaRbaV1 out
              RBFile.loadMIDI out
            else shakeMIDI pathMagmaMidV1
          sects <- getRealSections'
          let mid = RBFile.Song tempos sigs trks
                { RBFile.fixedEvents = if RTB.null sects
                  then RBFile.fixedEvents trks
                  else (RBFile.fixedEvents trks)
                    { eventsSections = fmap makeRB2Section sects
                    }
                , RBFile.fixedVenue = if RBFile.fixedVenue trks == mempty
                  then VenueTrack
                    { venueCameraRB3        = RTB.empty
                    , venueCameraRB2        = RTB.flatten $ RTB.singleton 0
                      [ CameraCut
                      , FocusBass
                      , FocusDrums
                      , FocusGuitar
                      , FocusVocal
                      , NoBehind
                      , OnlyFar
                      , NoClose
                      ]
                    , venueDirectedRB2      = RTB.empty
                    , venueSingGuitar       = RTB.empty
                    , venueSingDrums        = RTB.empty
                    , venueSingBass         = RTB.empty
                    , venueSpotKeys         = RTB.empty
                    , venueSpotVocal        = RTB.empty
                    , venueSpotGuitar       = RTB.empty
                    , venueSpotDrums        = RTB.empty
                    , venueSpotBass         = RTB.empty
                    , venuePostProcessRB3   = RTB.empty
                    , venuePostProcessRB2   = RTB.singleton 0 V2_video_security
                    , venueLighting         = RTB.singleton 0 Lighting_
                    , venueLightingCommands = RTB.empty
                    , venueLightingMode     = RTB.singleton 0 ModeVerse
                    , venueBonusFX          = RTB.empty
                    , venueBonusFXOptional  = RTB.empty
                    , venueFog              = RTB.empty
                    }
                  else RBFile.fixedVenue trks
                }
          saveMIDI out mid
        rb2Mogg %> shk . copyFile' pathMogg
        rb2Milo %> \out -> do
          -- TODO replace this with our own lipsync milo, ignore magma
          ex <- doesRBAExist
          if ex
            then stackIO $ Magma.getRBAFile 3 pathMagmaRbaV1 out
            else stackIO emptyMiloRB2 >>= \mt -> shk $ copyFile' mt out
        rb2Weights %> \out -> do
          ex <- doesRBAExist
          if ex
            then stackIO $ Magma.getRBAFile 5 pathMagmaRbaV1 out
            else stackIO emptyWeightsRB2 >>= \mt -> shk $ copyFile' mt out
        rb2Art %> shk . copyFile' (rel "gen/cover.png_xbox")
        rb2Pan %> \out -> liftIO $ B.writeFile out B.empty
        rb2CON %> \out -> do
          shk $ need [rb2DTA, rb2Mogg, rb2Mid, rb2Art, rb2Weights, rb2Milo, rb2Pan]
          lg "# Producing RB2 CON file"
          mapStackTraceT (mapQueueLog $ liftIO . runResourceT) $ rb2pkg
            (getArtist (_metadata songYaml) <> " - " <> targetTitle songYaml (RB2 rb2))
            (T.pack $ "Compiled by Onyx Music Game Toolkit version " <> showVersion version)
            (dir </> "rb2")
            out

        let rb2ps3Root = dir </> "rb2-ps3"
            rb2ps3DTA = rb2ps3Root </> "songs/songs.dta"
            rb2ps3Mogg = rb2ps3Root </> "songs" </> pkg </> pkg <.> "mogg"
            rb2ps3Mid = rb2ps3Root </> "songs" </> pkg </> pkg <.> "mid.edat"
            rb2ps3Art = rb2ps3Root </> "songs" </> pkg </> "gen" </> (pkg ++ "_keep.png_ps3")
            rb2ps3Milo = rb2ps3Root </> "songs" </> pkg </> "gen" </> pkg <.> "milo_ps3"
            rb2ps3Weights = rb2ps3Root </> "songs" </> pkg </> "gen" </> (pkg ++ "_weights.bin")
            rb2ps3Pan = rb2ps3Root </> "songs" </> pkg </> pkg <.> "pan"
            rb2ps3Pkg = dir </> "rb2-ps3.pkg"
            rb2ps3Folder = makePS3Name (hashRB3 songYaml rb3) songYaml
            rb2ps3EDATConfig = rb2CustomMidEdatConfig rb2ps3Folder
            rb2ps3ContentID = npdContentID rb2ps3EDATConfig

        rb2ps3DTA %> writeRB2DTA True
        rb2ps3Mid %> \out -> if rb2_PS3Encrypt rb2
          then do
            shk $ need [rb2Mid]
            fin  <- shortWindowsPath False rb2Mid
            fout <- shortWindowsPath True  out
            stackIO $ packNPData rb2ps3EDATConfig fin fout $ B8.pack pkg <> ".mid.edat"
          else shk $ copyFile' rb2Mid out
        rb2ps3Art %> shk . copyFile' (rel "gen/cover.png_ps3")
        rb2ps3Mogg %> \out -> do
          -- PS3 RB3 can't play unencrypted moggs (RB2 might be fine, but we may as well be compatible)
          shk $ need [rb2Mogg]
          moggType <- stackIO $ withBinaryFile rb2Mogg ReadMode $ \h -> B.hGet h 1
          fin  <- shortWindowsPath False rb2Mogg
          fout <- shortWindowsPath True  out
          case B.unpack moggType of
            [0xA] -> stackIO $ encryptRB1 fin fout
            _     -> shk $ copyFile' rb2Mogg out
        rb2ps3Weights %> shk . copyFile' rb2Weights
        rb2ps3Milo %> shk . copyFile' rb2Milo
        rb2ps3Pan %> shk . copyFile' rb2Pan
        phony rb2ps3Root $ do
          shk $ need [rb2ps3DTA, rb2ps3Mogg, rb2ps3Mid, rb2ps3Art, rb2ps3Weights, rb2ps3Milo, rb2ps3Pan]

        rb2ps3Pkg %> \out -> do
          shk $ need [rb2ps3Root]
          let container name inner = Folder { folderSubfolders = [(name, inner)], folderFiles = [] }
          main <- container "USRDIR" . container rb2ps3Folder <$> crawlFolderBytes rb2ps3Root
          extra <- stackIO (getResourcesPath "pkg-contents/rb2") >>= crawlFolderBytes
          stackIO $ makePKG rb2ps3ContentID (main <> extra) out

-- Magma RBProj rules
makeMagmaProj :: SongYaml f -> TargetRB3 f -> Plan f -> (DifficultyRB3, Maybe VocalCount) -> T.Text -> FilePath -> Action T.Text -> Staction Magma.RBProj
makeMagmaProj songYaml rb3 plan (DifficultyRB3{..}, voxCount) pkg mid thisTitle = do
  song <- shakeMIDI mid
  ((kickPVs, snarePVs, kitPVs), mixMode) <- computeDrumsPart (rb3_Drums rb3) plan songYaml
  let (pstart, _) = previewBounds songYaml song
      maxPStart = 570000 :: Int -- 9:30.000
      thisFullGenre = fullGenre songYaml
      perctype = RBFile.getPercType song
      silentDryVox :: Int -> Magma.DryVoxPart
      silentDryVox n = Magma.DryVoxPart
        { Magma.dryVoxFile = "dryvox" <> T.pack (show n) <> ".wav"
        , Magma.dryVoxEnabled = True
        }
      emptyDryVox = Magma.DryVoxPart
        { Magma.dryVoxFile = ""
        , Magma.dryVoxEnabled = False
        }
      disabledFile = Magma.AudioFile
        { Magma.audioEnabled = False
        , Magma.channels = 0
        , Magma.pan = []
        , Magma.vol = []
        , Magma.audioFile = ""
        }
      pvFile :: [(Double, Double)] -> T.Text -> Magma.AudioFile
      pvFile pvs f = Magma.AudioFile
        { Magma.audioEnabled = True
        , Magma.channels = fromIntegral $ length pvs
        , Magma.pan = map (realToFrac . fst) pvs
        , Magma.vol = map (realToFrac . snd) pvs
        , Magma.audioFile = f
        }
  title <- T.map (\case '"' -> '\''; c -> c) <$> shk thisTitle
  pstart' <- if pstart > maxPStart
    then do
      warn $ "Preview start time of " ++ show pstart ++ "ms too late for C3 Magma; changed to " ++ show maxPStart ++ "ms"
      return maxPStart
    else return pstart
  songName <- replaceCharsRB True title
  artistName <- replaceCharsRB True $ getArtist $ _metadata songYaml
  albumName <- replaceCharsRB True $ getAlbum $ _metadata songYaml
  let fixString = T.strip . T.map (\case '"' -> '\''; c -> c)
  return Magma.RBProj
    { Magma.project = Magma.Project
      { Magma.toolVersion = "110411_A"
      , Magma.projectVersion = 24
      , Magma.metadata = Magma.Metadata
        -- "song_name: This field must be less than 100 characters."
        -- also, can't begin or end with whitespace
        { Magma.songName = T.strip $ T.take 99 $ fixString songName
        -- "artist_name: This field must be less than 75 characters."
        , Magma.artistName = T.strip $ T.take 74 $ fixString artistName
        , Magma.genre = rbn2Genre thisFullGenre
        , Magma.subGenre = "subgenre_" <> rbn2Subgenre thisFullGenre
        , Magma.yearReleased = fromIntegral $ max 1960 $ getYear $ _metadata songYaml
        -- "album_name: This field must be less than 75 characters."
        , Magma.albumName = T.strip $ T.take 74 $ fixString albumName
        -- "author: This field must be less than 75 characters."
        , Magma.author = T.strip $ T.take 74 $ fixString $ getAuthor $ _metadata songYaml
        , Magma.releaseLabel = "Onyxite Customs"
        , Magma.country = "ugc_country_us"
        , Magma.price = 160
        , Magma.trackNumber = fromIntegral $ getTrackNumber $ _metadata songYaml
        , Magma.hasAlbum = True
        }
      , Magma.gamedata = Magma.Gamedata
        { Magma.previewStartMs = fromIntegral pstart'
        , Magma.rankDrum    = max 1 rb3DrumsTier
        , Magma.rankBass    = max 1 rb3BassTier
        , Magma.rankGuitar  = max 1 rb3GuitarTier
        , Magma.rankVocals  = max 1 rb3VocalTier
        , Magma.rankKeys    = max 1 rb3KeysTier
        , Magma.rankProKeys = max 1 rb3ProKeysTier
        , Magma.rankBand    = max 1 rb3BandTier
        , Magma.vocalScrollSpeed = 2300
        , Magma.animTempo = case _animTempo $ _global songYaml of
          Left  D.KTempoSlow   -> 16
          Left  D.KTempoMedium -> 32
          Left  D.KTempoFast   -> 64
          Right n              -> n
        , Magma.vocalGender = fromMaybe Magma.Female $ getPart (rb3_Vocal rb3) songYaml >>= partVocal >>= vocalGender
        , Magma.vocalPercussion = fromMaybe Magma.Tambourine perctype
        , Magma.vocalParts = case voxCount of
          Nothing     -> 0
          Just Vocal1 -> 1
          Just Vocal2 -> 2
          Just Vocal3 -> 3
        , Magma.guidePitchVolume = -3
        }
      , Magma.languages = let
        lang s = elem s $ _languages $ _metadata songYaml
        eng = lang "English"
        fre = lang "French"
        ita = lang "Italian"
        spa = lang "Spanish"
        ger = lang "German"
        jap = lang "Japanese"
        in Magma.Languages
          { Magma.english  = Just $ eng || not (or [eng, fre, ita, spa, ger, jap])
          , Magma.french   = Just fre
          , Magma.italian  = Just ita
          , Magma.spanish  = Just spa
          , Magma.german   = Just ger
          , Magma.japanese = Just jap
          }
      , Magma.destinationFile = T.pack $ T.unpack pkg <.> "rba"
      , Magma.midi = Magma.Midi
        { Magma.midiFile = "notes.mid"
        , Magma.autogenTheme = Left $ fromMaybe Magma.DefaultTheme $ _autogenTheme $ _global songYaml
        }
      , Magma.dryVox = Magma.DryVox
        { Magma.part0 = case voxCount of
          Nothing     -> emptyDryVox
          Just Vocal1 -> silentDryVox 0
          _           -> silentDryVox 1
        , Magma.part1 = if voxCount == Just Vocal2 || voxCount == Just Vocal3
          then silentDryVox 2
          else emptyDryVox
        , Magma.part2 = if voxCount == Just Vocal3
          then silentDryVox 3
          else emptyDryVox
        , Magma.dryVoxFileRB2 = Nothing
        , Magma.tuningOffsetCents = fromIntegral $ _tuningCents plan -- TODO should do both this and c3 cents?
        }
      , Magma.albumArt = Magma.AlbumArt "cover.bmp"
      , Magma.tracks = Magma.Tracks
        { Magma.drumLayout = case mixMode of
          RBDrums.D0 -> Magma.Kit
          RBDrums.D1 -> Magma.KitKickSnare
          RBDrums.D2 -> Magma.KitKickSnare
          RBDrums.D3 -> Magma.KitKickSnare
          RBDrums.D4 -> Magma.KitKick
        , Magma.drumKick = if rb3DrumsRank == 0 || mixMode == RBDrums.D0
          then disabledFile
          else pvFile kickPVs "kick.wav"
        , Magma.drumSnare = if rb3DrumsRank == 0 || elem mixMode [RBDrums.D0, RBDrums.D4]
          then disabledFile
          else pvFile snarePVs "snare.wav"
        , Magma.drumKit = if rb3DrumsRank == 0
          then disabledFile
          else pvFile kitPVs "drums.wav"
        , Magma.bass = if rb3BassRank == 0
          then disabledFile
          else pvFile (computeSimplePart (rb3_Bass rb3) plan songYaml) "bass.wav"
        , Magma.guitar = if rb3GuitarRank == 0
          then disabledFile
          else pvFile (computeSimplePart (rb3_Guitar rb3) plan songYaml) "guitar.wav"
        , Magma.vocals = if rb3VocalRank == 0
          then disabledFile
          else pvFile (computeSimplePart (rb3_Vocal rb3) plan songYaml) "vocal.wav"
        , Magma.keys = if rb3KeysRank == 0
          then disabledFile
          else pvFile (computeSimplePart (rb3_Keys rb3) plan songYaml) "keys.wav"
        , Magma.backing = pvFile [(-1, 0), (1, 0)] "song-countin.wav"
        }
      }
    }

makeRB3DTA :: (MonadIO m, SendMessage m, Hashable f) => SongYaml f -> Plan f -> TargetRB3 f -> Bool -> (DifficultyRB3, Maybe VocalCount) -> RBFile.Song (RBFile.FixedFile U.Beats) -> T.Text -> StackTraceT m D.SongPackage
makeRB3DTA songYaml plan rb3 isPS3 (DifficultyRB3{..}, vocalCount) song filename = do
  ((kickPV, snarePV, kitPV), _) <- computeDrumsPart (rb3_Drums rb3) plan songYaml
  let thresh = 170 -- everything gets forced anyway
      (pstart, pend) = previewBounds songYaml song
      len = RBFile.songLengthMS song
      perctype = RBFile.getPercType song
      thisFullGenre = fullGenre songYaml
      lookupPart rank part parts = guard (rank /= 0) >> HM.lookup part (getParts parts)
      -- all the following are only used for Plan, not MoggPlan.
      -- we don't need to handle more than 1 game part mapping to the same flex part,
      -- because no specs will change - we'll just zero out the game parts
      channelIndices before inst = take (length inst) $ drop (length $ concat before) [0..]
      partChannels, drumChannels, bassChannels, guitarChannels, keysChannels, vocalChannels, crowdChannels, songChannels :: [(Double, Double)]
      partChannels = concat
        [ drumChannels
        , bassChannels
        , guitarChannels
        , keysChannels
        , vocalChannels
        ]
      drumChannels   = case rb3DrumsRank  of 0 -> []; _ -> kickPV ++ snarePV ++ kitPV
      bassChannels   = case rb3BassRank   of 0 -> []; _ -> computeSimplePart (rb3_Bass   rb3) plan songYaml
      guitarChannels = case rb3GuitarRank of 0 -> []; _ -> computeSimplePart (rb3_Guitar rb3) plan songYaml
      keysChannels   = case rb3KeysRank   of 0 -> []; _ -> computeSimplePart (rb3_Keys   rb3) plan songYaml
      vocalChannels  = case rb3VocalRank  of 0 -> []; _ -> computeSimplePart (rb3_Vocal  rb3) plan songYaml
      crowdChannels = case plan of
        MoggPlan{}   -> undefined -- not used
        Plan    {..} -> case _crowd of
          Nothing -> []
          Just _  -> [(-1, 0), (1, 0)]
      songChannels = [(-1, 0), (1, 0)]
      -- If there are 6 channels in total, the actual mogg will have an extra 7th to avoid oggenc 5.1 issue.
      -- Leaving off pan/vol/core for the last channel is fine in RB3, but may cause issues with RB4 (ForgeTool).
      extend6 seven xs = if length xs == 6 then xs <> [seven] else xs
  songName <- replaceCharsRB False $ targetTitle songYaml $ RB3 rb3
  artistName <- replaceCharsRB False $ getArtist $ _metadata songYaml
  albumName <- mapM (replaceCharsRB False) $ _album $ _metadata songYaml
  return D.SongPackage
    { D.name = songName
    , D.artist = Just artistName
    , D.master = not $ _cover $ _metadata songYaml
    , D.songId = Just $ case rb3_SongID rb3 of
      SongIDSymbol s   -> Right s
      SongIDInt i      -> Left $ fromIntegral i
      SongIDAutoSymbol -> if isPS3
        then Left $ fromIntegral $ hashRB3 songYaml rb3 -- PS3 needs real number ID
        else Right filename
      SongIDAutoInt    -> Left $ fromIntegral $ hashRB3 songYaml rb3
    , D.song = D.Song
      { D.songName = "songs/" <> filename <> "/" <> filename
      , D.tracksCount = Nothing
      , D.tracks = D.DictList $ map (second $ map fromIntegral) $ filter (not . null . snd) $ case plan of
        MoggPlan{..} -> let
          getChannels rank fpart = maybe [] (concat . toList) $ lookupPart rank fpart _moggParts
          -- * the below trick does not work. RB3 freezes if a part doesn't have any channels.
          -- * so instead above we just allow doubling up on channels.
          -- * this works ok; the audio will cut out if either player misses, and whammy does not bend pitch.
          -- allParts = map ($ rb3) [rb3_Drums, rb3_Bass, rb3_Guitar, rb3_Keys, rb3_Vocal]
          -- getChannels rank fpart = case filter (== fpart) allParts of
          --   _ : _ : _ -> [] -- more than 1 game part maps to this flex part
          --   _         -> maybe [] (concat . toList) $ lookupPart rank fpart _moggParts
          in sortOn snd -- sorting numerically for ForgeTool (RB4) compatibility
            [ ("drum"  , getChannels rb3DrumsRank  $ rb3_Drums  rb3)
            , ("bass"  , getChannels rb3BassRank   $ rb3_Bass   rb3)
            , ("guitar", getChannels rb3GuitarRank $ rb3_Guitar rb3)
            , ("keys"  , getChannels rb3KeysRank   $ rb3_Keys   rb3)
            , ("vocals", getChannels rb3VocalRank  $ rb3_Vocal  rb3)
            ]
        Plan{} ->
          [ ("drum"  , channelIndices [] drumChannels)
          , ("bass"  , channelIndices [drumChannels] bassChannels)
          , ("guitar", channelIndices [drumChannels, bassChannels] guitarChannels)
          , ("keys"  , channelIndices [drumChannels, bassChannels, guitarChannels] keysChannels)
          , ("vocals", channelIndices [drumChannels, bassChannels, guitarChannels, keysChannels] vocalChannels)
          ]
      , D.vocalParts = Just $ case vocalCount of
        Nothing     -> 0
        Just Vocal1 -> 1
        Just Vocal2 -> 2
        Just Vocal3 -> 3
      , D.pans = map realToFrac $ case plan of
        MoggPlan{..} -> _pans
        Plan{}       -> extend6 0 $ map fst $ partChannels ++ crowdChannels ++ songChannels
      , D.vols = map realToFrac $ case plan of
        MoggPlan{..} -> _vols
        Plan{}       -> extend6 0 $ map snd $ partChannels ++ crowdChannels ++ songChannels
      , D.cores = case plan of
        MoggPlan{..} -> map (const (-1)) _pans
        Plan{}       -> extend6 (-1) $ map (const (-1)) $ partChannels ++ crowdChannels ++ songChannels
        -- TODO: 1 for guitar channels?
      , D.drumSolo = D.DrumSounds $ T.words $ case fmap drumsLayout $ getPart (rb3_Drums rb3) songYaml >>= partDrums of
        Nothing             -> "kick.cue snare.cue tom1.cue tom2.cue crash.cue"
        Just StandardLayout -> "kick.cue snare.cue tom1.cue tom2.cue crash.cue"
        Just FlipYBToms     -> "kick.cue snare.cue tom2.cue tom1.cue crash.cue"
      , D.drumFreestyle = D.DrumSounds $ T.words
        "kick.cue snare.cue hat.cue ride.cue crash.cue"
      , D.crowdChannels = let
        chans = case plan of
          MoggPlan{..} -> _moggCrowd
          Plan{}       -> take (length crowdChannels) [length partChannels ..]
        in guard (not $ null chans) >> Just (map fromIntegral chans)
      , D.hopoThreshold = Just thresh
      , D.muteVolume = Nothing
      , D.muteVolumeVocals = Nothing
      , D.midiFile = Nothing
      }
    , D.bank = Just $ case perctype of
      Nothing               -> "sfx/tambourine_bank.milo"
      Just Magma.Tambourine -> "sfx/tambourine_bank.milo"
      Just Magma.Cowbell    -> "sfx/cowbell_bank.milo"
      Just Magma.Handclap   -> "sfx/handclap_bank.milo"
    , D.drumBank = Just $ case fmap drumsKit $ getPart (rb3_Drums rb3) songYaml >>= partDrums of
      Nothing            -> "sfx/kit01_bank.milo"
      Just HardRockKit   -> "sfx/kit01_bank.milo"
      Just ArenaKit      -> "sfx/kit02_bank.milo"
      Just VintageKit    -> "sfx/kit03_bank.milo"
      Just TrashyKit     -> "sfx/kit04_bank.milo"
      Just ElectronicKit -> "sfx/kit05_bank.milo"
    , D.animTempo = _animTempo $ _global songYaml
    , D.bandFailCue = Nothing
    , D.songScrollSpeed = 2300
    , D.preview = (fromIntegral pstart, fromIntegral pend)
    , D.songLength = Just $ fromIntegral len
    , D.rank = HM.fromList
      [ ("drum"       , rb3DrumsRank    )
      , ("bass"       , rb3BassRank     )
      , ("guitar"     , rb3GuitarRank   )
      , ("vocals"     , rb3VocalRank    )
      , ("keys"       , rb3KeysRank     )
      , ("real_keys"  , rb3ProKeysRank  )
      , ("real_guitar", rb3ProGuitarRank)
      , ("real_bass"  , rb3ProBassRank  )
      , ("band"       , rb3BandRank     )
      ]
    , D.solo = let
      kwds :: [T.Text]
      kwds = concat
        [ ["guitar" | RBFile.hasSolo Guitar song]
        , ["bass" | RBFile.hasSolo Bass song]
        , ["drum" | RBFile.hasSolo Drums song]
        , ["keys" | RBFile.hasSolo Keys song]
        , ["vocal_percussion" | RBFile.hasSolo Vocal song]
        ]
      in guard (not $ null kwds) >> Just kwds
    , D.songFormat = 10
    , D.version = fromMaybe 1 $ rb3_Version rb3
    , D.fake = Nothing
    , D.gameOrigin = Just $ if rb3_Harmonix rb3 then "rb3_dlc" else "ugc_plus"
    , D.ugc = Nothing
    , D.rating = case (isPS3, fromIntegral $ fromEnum (_rating $ _metadata songYaml) + 1) of
      (True, 4) -> 2 -- Unrated (on RB2 at least) causes it to be locked in game on PS3
      (_   , x) -> x
    , D.genre = Just $ rbn2Genre thisFullGenre
    , D.subGenre = Just $ "subgenre_" <> rbn2Subgenre thisFullGenre
    , D.vocalGender = Just $ fromMaybe Magma.Female $ getPart (rb3_Vocal rb3) songYaml >>= partVocal >>= vocalGender
    -- TODO is it safe to have no vocal_gender?
    , D.shortVersion = Nothing
    , D.yearReleased = Just $ fromIntegral $ getYear $ _metadata songYaml
    , D.yearRecorded = Nothing
    -- confirmed: you can have (album_art 1) with no album_name/album_track_number
    , D.albumArt = Just $ isJust $ _fileAlbumArt $ _metadata songYaml
    -- haven't tested behavior if you have album_name but no album_track_number
    , D.albumName = albumName
    , D.albumTrackNumber = fmap fromIntegral $ _trackNumber $ _metadata songYaml
    , D.packName = Nothing
    , D.vocalTonicNote = fmap songKey $ _key $ _metadata songYaml
    , D.songTonality = fmap songTonality $ _key $ _metadata songYaml
    , D.songKey = Nothing
    , D.tuningOffsetCents = Just $ fromIntegral $ _tuningCents plan
    , D.realGuitarTuning = flip fmap (getPart (rb3_Guitar rb3) songYaml >>= partProGuitar) $ \pg ->
      map fromIntegral $ encodeTuningOffsets (pgTuning pg) TypeGuitar
    , D.realBassTuning = flip fmap (getPart (rb3_Bass rb3) songYaml >>= partProGuitar) $ \pg ->
      map fromIntegral $ encodeTuningOffsets (pgTuning pg) TypeBass
    , D.guidePitchVolume = Just (-3)
    , D.encoding = Just "utf8"
    , D.extraAuthoring = Nothing
    , D.alternatePath = Nothing
    , D.context = Nothing
    , D.decade = Nothing
    , D.downloaded = Nothing
    , D.basePoints = Nothing
    , D.videoVenues = Nothing
    , D.dateReleased = Nothing
    , D.dateRecorded = Nothing
    }

makeC3 :: (Monad m) => SongYaml f -> Plan f -> TargetRB3 f -> RBFile.Song (RBFile.FixedFile U.Beats) -> T.Text -> StackTraceT m C3.C3
makeC3 songYaml plan rb3 midi pkg = do
  let (pstart, _) = previewBounds songYaml midi
      DifficultyRB3{..} = difficultyRB3 rb3 songYaml
      title = targetTitle songYaml $ RB3 rb3
      numSongID = case rb3_SongID rb3 of
        SongIDInt i -> Just i
        _           -> Nothing
      hasCrowd = case plan of
        MoggPlan{..} -> not $ null _moggCrowd
        Plan{..}     -> isJust _crowd
  return C3.C3
    { C3.song = fromMaybe (getTitle $ _metadata songYaml) $ tgt_Title $ rb3_Common rb3
    , C3.artist = getArtist $ _metadata songYaml
    , C3.album = getAlbum $ _metadata songYaml
    , C3.customID = pkg
    , C3.version = fromIntegral $ fromMaybe 1 $ rb3_Version rb3
    , C3.isMaster = not $ _cover $ _metadata songYaml
    , C3.encodingQuality = 5
    , C3.crowdAudio = guard hasCrowd >> Just "crowd.wav"
    , C3.crowdVol = guard hasCrowd >> Just 0
    , C3.is2xBass = rb3_2xBassPedal rb3
    , C3.rhythmKeys = _rhythmKeys $ _metadata songYaml
    , C3.rhythmBass = _rhythmBass $ _metadata songYaml
    , C3.karaoke = getKaraoke plan
    , C3.multitrack = getMultitrack plan
    , C3.convert = _convert $ _metadata songYaml
    , C3.expertOnly = _expertOnly $ _metadata songYaml
    , C3.proBassDiff = case rb3ProBassRank of 0 -> Nothing; r -> Just $ fromIntegral r
    , C3.proBassTuning4 = flip fmap (getPart (rb3_Bass rb3) songYaml >>= partProGuitar) $ \pg -> T.concat
      [ "(real_bass_tuning ("
      , T.unwords $ map (T.pack . show) $ encodeTuningOffsets (pgTuning pg) TypeBass
      , "))"
      ]
    , C3.proGuitarDiff = case rb3ProGuitarRank of 0 -> Nothing; r -> Just $ fromIntegral r
    , C3.proGuitarTuning = flip fmap (getPart (rb3_Guitar rb3) songYaml >>= partProGuitar) $ \pg -> T.concat
      [ "(real_guitar_tuning ("
      , T.unwords $ map (T.pack . show) $ encodeTuningOffsets (pgTuning pg) TypeGuitar
      , "))"
      ]
    , C3.disableProKeys = case getPart (rb3_Keys rb3) songYaml of
      Nothing   -> False
      Just part -> isJust (partGRYBO part) && isNothing (partProKeys part)
    , C3.tonicNote = fmap songKey $ _key $ _metadata songYaml
    , C3.tuningCents = 0
    , C3.songRating = fromEnum (_rating $ _metadata songYaml) + 1
    , C3.drumKitSFX = maybe 0 (fromEnum . drumsKit) $ getPart (rb3_Drums rb3) songYaml >>= partDrums
    , C3.hopoThresholdIndex = 2 -- 170 ticks (everything gets forced anyway)
    , C3.muteVol = -96
    , C3.vocalMuteVol = -12
    , C3.soloDrums = RBFile.hasSolo Drums midi
    , C3.soloGuitar = RBFile.hasSolo Guitar midi
    , C3.soloBass = RBFile.hasSolo Bass midi
    , C3.soloKeys = RBFile.hasSolo Keys midi
    , C3.soloVocals = RBFile.hasSolo Vocal midi
    , C3.songPreview = Just $ fromIntegral pstart
    , C3.checkTempoMap = True
    , C3.wiiMode = False
    , C3.doDrumMixEvents = True -- is this a good idea?
    , C3.packageDisplay = getArtist (_metadata songYaml) <> " - " <> title
    , C3.packageDescription = "Created with Magma: C3 Roks Edition (forums.customscreators.com) and ONYX (git.io/onyx)."
    , C3.songAlbumArt = "cover.bmp"
    , C3.packageThumb = ""
    , C3.encodeANSI = True  -- is this right?
    , C3.encodeUTF8 = False -- is this right?
    , C3.useNumericID = isJust numSongID
    , C3.uniqueNumericID = case numSongID of
      Nothing -> ""
      Just i  -> T.pack $ show i
    , C3.uniqueNumericID2X = "" -- will use later if we ever create combined 1x/2x C3 Magma projects
    , C3.toDoList = C3.defaultToDo
    }