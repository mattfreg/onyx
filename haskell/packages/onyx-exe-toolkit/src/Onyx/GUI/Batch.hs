{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE ImplicitParams        #-}
{-# LANGUAGE LambdaCase            #-}
{-# LANGUAGE OverloadedRecordDot   #-}
{-# LANGUAGE OverloadedStrings     #-}
{-# LANGUAGE RecordWildCards       #-}
{-# OPTIONS_GHC -fno-warn-ambiguous-fields #-}
{-# OPTIONS_GHC -fno-warn-incomplete-uni-patterns #-}
module Onyx.GUI.Batch where

import           Onyx.GUI.Core

import           Control.Applicative                ((<|>))
import           Control.Monad.Extra                ((>=>))
import           Data.Default.Class                 (def)
import qualified Data.HashMap.Strict                as HM
import           Data.List                          (find)
import           Data.Maybe                         (fromMaybe, isJust)
import qualified Data.Text                          as T
import           Graphics.UI.FLTK.LowLevel.FLTKHS   (Height (..),
                                                     Rectangle (..), Size (..),
                                                     Width (..))
import qualified Graphics.UI.FLTK.LowLevel.FLTKHS   as FL
import           Graphics.UI.FLTK.LowLevel.GlWindow ()
import           Onyx.Harmonix.Ark.GH2              (GH2InstallLocation (..))
import           Onyx.Import
import           Onyx.MIDI.Track.File               (FlexPartName (..))
import           Onyx.Mode                          (anyDrums, anyFiveFret)
import           Onyx.Preferences                   (Preferences (..),
                                                     readPreferences)
import           Onyx.Project
import           Onyx.StackTrace
import           System.FilePath                    (takeDirectory)

batchPagePreview
  :: (?preferences :: Preferences)
  => (Event -> IO ())
  -> Rectangle
  -> FL.Ref FL.Group
  -> ((Project -> FilePath) -> IO ())
  -> IO ()
batchPagePreview sink rect tab build = do
  pack <- FL.packNew rect Nothing
  makeTemplateRunner
    sink
    "Build web previews"
    (maybe "%input_dir%" T.pack (prefDirPreview ?preferences) <> "/%input_base%_player")
    (\template -> build $ \proj -> T.unpack $ templateApplyInput proj Nothing template)
  FL.end pack
  FL.setResizable tab $ Just pack
  return ()

batchPageRB3
  :: (?preferences :: Preferences)
  => (Event -> IO ())
  -> Rectangle
  -> FL.Ref FL.Group
  -> (Bool -> (Project -> ([(TargetRB3 FilePath, RB3Create)], SongYaml FilePath)) -> IO ())
  -> IO ()
batchPageRB3 sink rect tab build = do
  pack <- FL.packNew rect Nothing
  getSpeed <- padded 10 0 5 0 (Size (Width 800) (Height 35)) $ \rect' -> let
    centerRect = trimClock 0 250 0 250 rect'
    in centerFixed rect' $ speedPercent True centerRect
  getToms <- padded 5 10 5 10 (Size (Width 800) (Height 35)) $ \rect' -> do
    box <- FL.checkButtonNew rect' (Just "Convert non-Pro Drums to all toms")
    FL.setTooltip box "When importing from a FoF/PS/CH chart where no Pro Drums are detected, tom markers will be added over the whole drum chart if this box is checked."
    return $ FL.getValue box
  getPreset <- padded 5 10 5 10 (Size (Width 800) (Height 35)) $ \rect' -> do
    makePresetDropdown rect' batchPartPresetsRB3
  getKicks <- padded 5 10 5 10 (Size (Width 800) (Height 35)) $ \rect' -> do
    fn <- horizRadio rect'
      [ ("1x Bass Pedal", Kicks1x, False)
      , ("2x Bass Pedal", Kicks2x, False)
      , ("Both", KicksBoth, True)
      ]
    return $ fromMaybe KicksBoth <$> fn
  let getTargetSong isXbox usePath template = do
        speed <- stackIO getSpeed
        toms <- stackIO getToms
        (isDefaultPreset, preset) <- stackIO getPreset
        kicks <- stackIO getKicks
        newPreferences <- readPreferences
        let qcPossible = speed == 1 && isDefaultPreset
        return (qcPossible, \proj -> let
          defRB3 = def :: TargetRB3 FilePath
          tgt = preset yaml defRB3
            { common = defRB3.common
              { speed = Just speed
              , label2x = prefLabel2x newPreferences
              }
            , legalTempos = prefLegalTempos newPreferences
            , magma = prefMagma newPreferences
            , songID = if prefRBNumberID newPreferences
              then SongIDAutoInt
              else SongIDAutoSymbol
            }
          -- TODO need to use anyDrums
          kicksConfigs = case (kicks, maybe Kicks1x (.kicks) $ getPart FlexDrums yaml >>= (.drums)) of
            (_        , Kicks1x) -> [(False, ""   )]
            (Kicks1x  , _      ) -> [(False, "_1x")]
            (Kicks2x  , _      ) -> [(True , "_2x")]
            (KicksBoth, _      ) -> [(False, "_1x"), (True, "_2x")]
          fout kicksLabel = (if isXbox then trimXbox newPreferences else id) $ T.unpack $ foldr ($) template
            [ templateApplyInput proj $ Just $ RB3 tgt
            , let
              modifiers = T.concat
                [ T.pack $ case tgt.common.speed of
                  Just n | n /= 1 -> "_" <> show (round $ n * 100 :: Int)
                  _               -> ""
                , kicksLabel
                ]
              in T.intercalate modifiers . T.splitOn "%modifiers%"
            ]
          yaml
            = (if toms then id else forceProDrums)
            $ projectSongYaml proj
          in
            ( [ ((tgt :: TargetRB3 FilePath) { is2xBassPedal = is2x }, usePath $ fout kicksLabel)
              | (is2x, kicksLabel) <- kicksConfigs
              ]
            , yaml
            )
          )
  makeTemplateRunner
    sink
    "Create Xbox 360 CON files"
    (maybe "%input_dir%" T.pack (prefDirRB ?preferences) <> "/%input_base%%modifiers%_rb3con")
    (\template -> sink $ EventOnyx $ getTargetSong True RB3CON template >>= \(qcPossible, x) -> stackIO $ build qcPossible x)
  makeTemplateRunner
    sink
    "Create PS3 PKG files"
    (maybe "%input_dir%" T.pack (prefDirRB ?preferences) <> "/%input_base%%modifiers%.pkg")
    (\template -> sink $ EventOnyx $ getTargetSong False RB3PKG template >>= \(qcPossible, x) -> stackIO $ build qcPossible x)
  makeTemplateRunner
    sink
    "Create Magma projects"
    (maybe "%input_dir%" T.pack (prefDirRB ?preferences) <> "/%input_base%%modifiers%_project")
    (\template -> sink $ EventOnyx $ getTargetSong False RB3Magma template >>= \(_, x) -> stackIO $ build False x)
  FL.end pack
  FL.setResizable tab $ Just pack
  return ()

batchPageGH1
  :: (?preferences :: Preferences)
  => (Event -> IO ())
  -> Rectangle
  -> FL.Ref FL.Group
  -> ((Project -> (TargetGH1 FilePath, GH1Create)) -> IO ())
  -> IO ()
batchPageGH1 sink rect tab build = do
  pack <- FL.packNew rect Nothing
  getSpeed <- padded 10 0 5 0 (Size (Width 800) (Height 35)) $ \rect' -> let
    centerRect = trimClock 0 250 0 250 rect'
    in centerFixed rect' $ speedPercent True centerRect
  let getTargetSong usePath template go = sink $ EventOnyx $ readPreferences >>= \newPrefs -> stackIO $ do
        speed <- getSpeed
        go $ \proj -> let
          leadPart = find (hasPartWith anyFiveFret $ projectSongYaml proj)
            [ FlexGuitar
            , FlexExtra "rhythm"
            , FlexKeys
            , FlexBass
            , FlexDrums
            , FlexExtra "dance"
            ]
          tgt = (def :: TargetGH1 FilePath)
            { common = (def :: TargetGH1 FilePath).common
              { speed = Just speed
              }
            , guitar = fromMaybe (FlexExtra "undefined") leadPart
            , offset = prefGH2Offset newPrefs
            }
          fout = T.unpack $ foldr ($) template
            [ templateApplyInput proj $ Just $ GH1 tgt
            , let
              modifiers = T.pack $ case tgt.common.speed of
                Just n | n /= 1 -> "_" <> show (round $ n * 100 :: Int)
                _               -> ""
              in T.intercalate modifiers . T.splitOn "%modifiers%"
            ]
          in (tgt, usePath fout)
  padded 5 10 5 10 (Size (Width 500) (Height 35)) $ \r -> do
    btn <- FL.buttonNew r $ Just "Add to PS2 ARK as Bonus Songs"
    color <- taskColor
    FL.setColor btn color
    FL.setCallback btn $ \_ -> do
      picker <- FL.nativeFileChooserNew $ Just FL.BrowseFile
      FL.setTitle picker "Select .HDR file"
      FL.showWidget picker >>= \case
        FL.NativeFileChooserPicked -> (fmap T.unpack <$> FL.getFilename picker) >>= \case
          Nothing -> return ()
          Just f  -> let
            gen = takeDirectory f
            in getTargetSong id "" $ \song -> do
              build $ \proj -> let
                (tgt, _) = song proj
                in (tgt, GH1ARK gen)
        _ -> return ()
  makeTemplateRunner
    sink
    "Create PS2 DIY folders"
    "%input_dir%/%input_base%%modifiers%_gh1"
    (\template -> getTargetSong GH1DIYPS2 template build)
  FL.end pack
  FL.setResizable tab $ Just pack
  return ()

batchPageGH3
  :: (?preferences :: Preferences)
  => (Event -> IO ())
  -> Rectangle
  -> FL.Ref FL.Group
  -> ((Project -> (TargetGH3 FilePath, GH3Create)) -> IO ())
  -> IO ()
batchPageGH3 sink rect tab build = do
  pack <- FL.packNew rect Nothing
  getSpeed <- padded 10 0 5 0 (Size (Width 800) (Height 35)) $ \rect' -> let
    centerRect = trimClock 0 250 0 250 rect'
    in centerFixed rect' $ speedPercent True centerRect
  let getTargetSong xbox usePath template go = sink $ EventOnyx $ readPreferences >>= \newPrefs -> stackIO $ do
        speed <- getSpeed
        go $ \proj -> let
          hasPart = hasPartWith anyFiveFret $ projectSongYaml proj
          leadPart = find hasPart
            [ FlexGuitar
            , FlexExtra "rhythm"
            , FlexKeys
            , FlexBass
            , FlexDrums
            , FlexExtra "dance"
            ]
          coopPart = find (\(p, _) -> hasPart p && leadPart /= Just p)
            [ (FlexGuitar        , GH2Rhythm)
            , (FlexExtra "rhythm", GH2Rhythm)
            , (FlexBass          , GH2Bass  )
            , (FlexKeys          , GH2Rhythm)
            , (FlexDrums         , GH2Rhythm)
            , (FlexExtra "dance" , GH2Rhythm)
            ]
          tgt = (def :: TargetGH3 FilePath)
            { common = (def :: TargetGH3 FilePath).common
              { speed = Just speed
              }
            , guitar = fromMaybe (FlexExtra "undefined") leadPart
            , bass = case coopPart of
              Just (x, GH2Bass) -> x
              _                 -> (def :: TargetGH3 FilePath).bass
            , rhythm = case coopPart of
              Just (x, GH2Rhythm) -> x
              _                   -> (def :: TargetGH3 FilePath).rhythm
            , coop = case coopPart of
              Just (_, coop) -> coop
              _              -> (def :: TargetGH3 FilePath).coop
            }
          fout = (if xbox then trimXbox newPrefs else id) $ T.unpack $ foldr ($) template
            [ templateApplyInput proj $ Just $ GH3 tgt
            , let
              modifiers = T.pack $ case tgt.common.speed of
                Just n | n /= 1 -> "_" <> show (round $ n * 100 :: Int)
                _               -> ""
              in T.intercalate modifiers . T.splitOn "%modifiers%"
            ]
          in (tgt, usePath fout)
  makeTemplateRunner
    sink
    "Create Xbox 360 LIVE files"
    (maybe "%input_dir%" T.pack (prefDirRB ?preferences) <> "/%input_base%%modifiers%_gh3live")
    (\template -> getTargetSong True GH3LIVE template build)
  makeTemplateRunner
    sink
    "Create PS3 PKG files"
    (maybe "%input_dir%" T.pack (prefDirRB ?preferences) <> "/%input_base%%modifiers%.pkg")
    (\template -> getTargetSong False GH3PKG template build)
  FL.end pack
  FL.setResizable tab $ Just pack
  return ()

batchPageGH2
  :: (?preferences :: Preferences)
  => (Event -> IO ())
  -> Rectangle
  -> FL.Ref FL.Group
  -> ((Project -> (TargetGH2 FilePath, GH2Create)) -> IO ())
  -> IO ()
batchPageGH2 sink rect tab build = do
  pack <- FL.packNew rect Nothing
  getSpeed <- padded 10 0 5 0 (Size (Width 800) (Height 35)) $ \rect' -> let
    centerRect = trimClock 0 250 0 250 rect'
    in centerFixed rect' $ speedPercent True centerRect
  (getPracticeAudio, getDeluxe) <- padded 5 10 5 10 (Size (Width 800) (Height 35)) $ \rect' -> do
    let [rectA, rectB] = splitHorizN 2 rect'
    boxA <- FL.checkButtonNew rectA $ Just "Make practice mode audio for PS2"
    getDeluxe <- gh2DeluxeSelector sink rectB
    return (FL.getValue boxA, getDeluxe)
  let getTargetSong xbox usePath template go = sink $ EventOnyx $ readPreferences >>= \newPrefs -> stackIO $ do
        speed <- getSpeed
        practiceAudio <- getPracticeAudio
        deluxe2x <- getDeluxe
        go $ \proj -> let
          defGH2 = def :: TargetGH2 FilePath
          hasPart = hasPartWith anyFiveFret $ projectSongYaml proj
          leadPart = find hasPart
            [ FlexGuitar
            , FlexExtra "rhythm"
            , FlexKeys
            , FlexBass
            , FlexDrums
            , FlexExtra "dance"
            ]
          coopPart = find (\(p, _) -> hasPart p && leadPart /= Just p)
            [ (FlexGuitar        , GH2Rhythm)
            , (FlexExtra "rhythm", GH2Rhythm)
            , (FlexBass          , GH2Bass  )
            , (FlexKeys          , GH2Rhythm)
            , (FlexDrums         , GH2Rhythm)
            , (FlexExtra "dance" , GH2Rhythm)
            ]
          tgt = defGH2
            { common = defGH2.common
              { speed = Just speed
              }
            , practiceAudio = practiceAudio
            , guitar = fromMaybe (FlexExtra "undefined") leadPart
            , bass = case coopPart of
              Just (x, GH2Bass) -> x
              _                 -> defGH2.bass
            , rhythm = case coopPart of
              Just (x, GH2Rhythm) -> x
              _                   -> defGH2.rhythm
            , coop = case coopPart of
              Just (_, coop) -> coop
              _              -> defGH2.coop
            , offset = prefGH2Offset newPrefs
            , gh2Deluxe = isJust deluxe2x
            , is2xBassPedal = fromMaybe False deluxe2x
            }
          fout = (if xbox then trimXbox newPrefs else id) $ T.unpack $ foldr ($) template
            [ templateApplyInput proj $ Just $ GH2 tgt
            , let
              modifiers = T.pack $ case tgt.common.speed of
                Just n | n /= 1 -> "_" <> show (round $ n * 100 :: Int)
                _               -> ""
              in T.intercalate modifiers . T.splitOn "%modifiers%"
            ]
          in (tgt, usePath fout)
  padded 5 10 5 10 (Size (Width 500) (Height 35)) $ \r -> do
    btn <- FL.buttonNew r $ Just "Add to PS2 ARK as Bonus Songs"
    color <- taskColor
    FL.setColor btn color
    FL.setCallback btn $ \_ -> do
      picker <- FL.nativeFileChooserNew $ Just FL.BrowseFile
      FL.setTitle picker "Select .HDR file"
      FL.showWidget picker >>= \case
        FL.NativeFileChooserPicked -> (fmap T.unpack <$> FL.getFilename picker) >>= \case
          Nothing -> return ()
          Just f  -> let
            gen = takeDirectory f
            in getTargetSong False id "" $ \song -> do
              build $ \proj -> let
                (tgt, _) = song proj
                in (tgt, GH2ARK gen GH2AddBonus)
        _ -> return ()
  makeTemplateRunner
    sink
    "Create PS2 DIY folders"
    "%input_dir%/%input_base%%modifiers%_gh2"
    (\template -> getTargetSong False GH2DIYPS2 template build)
  makeTemplateRunner
    sink
    "Create Xbox 360 LIVE files"
    (maybe "%input_dir%" T.pack (prefDirRB ?preferences) <> "/%input_base%%modifiers%_gh2live")
    (\template -> warnCombineXboxGH2 sink $ getTargetSong True GH2LIVE template build)
  FL.end pack
  FL.setResizable tab $ Just pack
  return ()

batchPageGHWOR
  :: (?preferences :: Preferences)
  => (Event -> IO ())
  -> Rectangle
  -> FL.Ref FL.Group
  -> ((Project -> ((TargetGH5 FilePath, GHWORCreate), SongYaml FilePath)) -> IO ())
  -> IO ()
batchPageGHWOR sink rect tab build = do
  pack <- FL.packNew rect Nothing
  getSpeed <- padded 10 0 5 0 (Size (Width 800) (Height 35)) $ \rect' -> let
    centerRect = trimClock 0 250 0 250 rect'
    in centerFixed rect' $ speedPercent True centerRect
  getProTo4 <- padded 5 10 5 10 (Size (Width 800) (Height 35)) $ \rect' -> do
    fn <- horizRadio rect'
      [ ("Pro Drums to 5 lane", False, not $ prefGH4Lane ?preferences)
      , ("Pro Drums to 4 lane", True, prefGH4Lane ?preferences)
      ]
    return $ fromMaybe False <$> fn
  let getTargetSong isXbox usePath template = do
        speed <- stackIO getSpeed
        proTo4 <- stackIO getProTo4
        newPreferences <- readPreferences
        return $ \proj -> let
          hasPart p = isJust $ HM.lookup p (projectSongYaml proj).parts.getParts >>= anyFiveFret
          pickedGuitar = find hasPart
            [ FlexGuitar
            , FlexExtra "rhythm"
            , FlexKeys
            , FlexBass
            ]
          pickedBass = find (\p -> hasPart p && pickedGuitar /= Just p)
            [ FlexGuitar
            , FlexExtra "rhythm"
            , FlexBass
            , FlexKeys
            ]
          defGH5 = def :: TargetGH5 FilePath
          tgt = (defGH5 :: TargetGH5 FilePath)
            { common = defGH5.common
              { speed = Just speed
              }
            , guitar = fromMaybe defGH5.guitar pickedGuitar
            , bass = fromMaybe defGH5.bass $ pickedBass <|> pickedGuitar
            , drums = getDrumsOrDance $ projectSongYaml proj
            , proTo4 = proTo4
            }
          fout = (if isXbox then trimXbox newPreferences else id) $ T.unpack $ foldr ($) template
            [ templateApplyInput proj $ Just $ GH5 tgt
            , let
              modifiers = T.concat
                [ T.pack $ case tgt.common.speed of
                  Just n | n /= 1 -> "_" <> show (round $ n * 100 :: Int)
                  _               -> ""
                ]
              in T.intercalate modifiers . T.splitOn "%modifiers%"
            ]
          in ((tgt, usePath fout), projectSongYaml proj)
  makeTemplateRunner
    sink
    "Create Xbox 360 LIVE files"
    (maybe "%input_dir%" T.pack (prefDirRB ?preferences) <> "/%input_base%%modifiers%_ghwor")
    (\template -> warnXboxGHWoR sink $ getTargetSong True GHWORLIVE template >>= stackIO . build)
  makeTemplateRunner
    sink
    "Create PS3 PKG files"
    (maybe "%input_dir%" T.pack (prefDirRB ?preferences) <> "/%input_base%%modifiers%.pkg")
    (\template -> warnXboxGHWoR sink $ getTargetSong False GHWORPKG template >>= stackIO . build)
  FL.end pack
  FL.setResizable tab $ Just pack
  return ()

batchPageRR
  :: (?preferences :: Preferences)
  => (Event -> IO ())
  -> Rectangle
  -> FL.Ref FL.Group
  -> ((Project -> ((TargetRR FilePath, RRCreate), SongYaml FilePath)) -> IO ())
  -> IO ()
batchPageRR sink rect tab build = do
  pack <- FL.packNew rect Nothing
  getSpeed <- padded 10 0 5 0 (Size (Width 800) (Height 35)) $ \rect' -> let
    centerRect = trimClock 0 250 0 250 rect'
    in centerFixed rect' $ speedPercent True centerRect
  getProTo4 <- padded 5 10 5 10 (Size (Width 800) (Height 35)) $ \rect' -> do
    fn <- horizRadio rect'
      [ ("Pro Drums to 6 pad", False, False)
      , ("Pro Drums to 4 pad", True, True)
      ]
    return $ fromMaybe False <$> fn
  let getTargetSong isXbox usePath template = do
        speed <- stackIO getSpeed
        proTo4 <- stackIO getProTo4
        newPreferences <- readPreferences
        return $ \proj -> let
          hasPart p = isJust $ HM.lookup p (projectSongYaml proj).parts.getParts >>= anyFiveFret
          pickedGuitar = find hasPart
            [ FlexGuitar
            , FlexExtra "rhythm"
            , FlexKeys
            , FlexBass
            ]
          pickedBass = find (\p -> hasPart p && pickedGuitar /= Just p)
            [ FlexGuitar
            , FlexExtra "rhythm"
            , FlexBass
            , FlexKeys
            ]
          defRR = def :: TargetRR FilePath
          tgt = (defRR :: TargetRR FilePath)
            { common = defRR.common
              { speed = Just speed
              }
            , guitar = fromMaybe defRR.guitar pickedGuitar
            , bass = fromMaybe defRR.bass $ pickedBass <|> pickedGuitar
            , drums = getDrumsOrDance $ projectSongYaml proj
            , proTo4 = proTo4
            }
          fout = (if isXbox then trimXbox newPreferences else id) $ T.unpack $ foldr ($) template
            [ templateApplyInput proj $ Just $ RR tgt
            , let
              modifiers = T.concat
                [ T.pack $ case tgt.common.speed of
                  Just n | n /= 1 -> "_" <> show (round $ n * 100 :: Int)
                  _               -> ""
                ]
              in T.intercalate modifiers . T.splitOn "%modifiers%"
            ]
          in ((tgt, usePath fout), projectSongYaml proj)
  makeTemplateRunner
    sink
    "Create Xbox 360 LIVE files"
    (maybe "%input_dir%" T.pack (prefDirRB ?preferences) <> "/%input_base%%modifiers%_rr")
    (\template -> sink $ EventOnyx $ getTargetSong True RRLIVE template >>= stackIO . build)
  makeTemplateRunner
    sink
    "Create RPCS3 PKG files"
    (maybe "%input_dir%" T.pack (prefDirRB ?preferences) <> "/%input_base%%modifiers%.pkg")
    (\template -> sink $ EventOnyx $ getTargetSong False RRPKG template >>= stackIO . build)
  FL.end pack
  FL.setResizable tab $ Just pack
  return ()

batchPageRB2
  :: (?preferences :: Preferences)
  => (Event -> IO ())
  -> Rectangle
  -> FL.Ref FL.Group
  -> ((Project -> ([(TargetRB2 FilePath, RB2Create)], SongYaml FilePath)) -> IO ())
  -> IO ()
batchPageRB2 sink rect tab build = do
  pack <- FL.packNew rect Nothing
  getSpeed <- padded 10 0 5 0 (Size (Width 800) (Height 35)) $ \rect' -> let
    centerRect = trimClock 0 250 0 250 rect'
    in centerFixed rect' $ speedPercent True centerRect
  getPreset <- padded 5 10 5 10 (Size (Width 800) (Height 35)) $ \rect' -> do
    makePresetDropdown rect' batchPartPresetsRB2
  getKicks <- padded 5 10 5 10 (Size (Width 800) (Height 35)) $ \rect' -> do
    fn <- horizRadio rect'
      [ ("1x Bass Pedal", Kicks1x, False)
      , ("2x Bass Pedal", Kicks2x, False)
      , ("Both", KicksBoth, True)
      ]
    return $ fromMaybe KicksBoth <$> fn
  let getTargetSong isXbox usePath template = do
        speed <- stackIO getSpeed
        preset <- stackIO getPreset
        kicks <- stackIO getKicks
        newPreferences <- readPreferences
        return $ \proj -> let
          tgt = preset yaml def
            { common      = (def :: TargetRB2 FilePath).common
              { speed   = Just speed
              , label2x = prefLabel2x newPreferences
              }
            , legalTempos = prefLegalTempos newPreferences
            , magma       = prefMagma newPreferences
            , songID      = if prefRBNumberID newPreferences
              then SongIDAutoInt
              else SongIDAutoSymbol
            , ps3Encrypt  = prefPS3Encrypt newPreferences
            }
          -- TODO need to use anyDrums
          kicksConfigs = case (kicks, maybe Kicks1x (.kicks) $ getPart FlexDrums yaml >>= (.drums)) of
            (_        , Kicks1x) -> [(False, ""   )]
            (Kicks1x  , _      ) -> [(False, "_1x")]
            (Kicks2x  , _      ) -> [(True , "_2x")]
            (KicksBoth, _      ) -> [(False, "_1x"), (True, "_2x")]
          fout kicksLabel = (if isXbox then trimXbox newPreferences else id) $ T.unpack $ foldr ($) template
            [ templateApplyInput proj $ Just $ RB2 tgt
            , let
              modifiers = T.concat
                [ T.pack $ case tgt.common.speed of
                  Just n | n /= 1 -> "_" <> show (round $ n * 100 :: Int)
                  _               -> ""
                , kicksLabel
                ]
              in T.intercalate modifiers . T.splitOn "%modifiers%"
            ]
          yaml
            = forceProDrums
            $ projectSongYaml proj
          in
            ( [ ((tgt :: TargetRB2 FilePath) { is2xBassPedal = is2x }, usePath $ fout kicksLabel)
              | (is2x, kicksLabel) <- kicksConfigs
              ]
            , yaml
            )
  makeTemplateRunner
    sink
    "Create Xbox 360 CON files"
    (maybe "%input_dir%" T.pack (prefDirRB ?preferences) <> "/%input_base%%modifiers%_rb2con")
    (\template -> sink $ EventOnyx $ getTargetSong True RB2CON template >>= stackIO . build)
  makeTemplateRunner
    sink
    "Create PS3 PKG files"
    (maybe "%input_dir%" T.pack (prefDirRB ?preferences) <> "/%input_base%%modifiers%.pkg")
    (\template -> sink $ EventOnyx $ getTargetSong False RB2PKG template >>= stackIO . build)
  FL.end pack
  FL.setResizable tab $ Just pack
  return ()

batchPagePS
  :: (?preferences :: Preferences)
  => (Event -> IO ())
  -> Rectangle
  -> FL.Ref FL.Group
  -> ((Project -> (TargetPS FilePath, PSCreate)) -> IO ())
  -> IO ()
batchPagePS sink rect tab build = do
  pack <- FL.packNew rect Nothing
  getSpeed <- padded 10 0 5 0 (Size (Width 800) (Height 35)) $ \rect' -> let
    centerRect = trimClock 0 250 0 250 rect'
    in centerFixed rect' $ speedPercent True centerRect
  getPreset <- padded 5 10 5 10 (Size (Width 800) (Height 35)) $ \rect' -> do
    makePresetDropdown rect' batchPartPresetsCH
  let getTargetSong usePath template = do
        speed <- getSpeed
        preset <- getPreset
        return $ \proj -> let
          defPS = def :: TargetPS FilePath
          tgt = preset (projectSongYaml proj) defPS
            { common = defPS.common
              { speed = Just speed
              }
            }
          fout = T.unpack $ foldr ($) template
            [ templateApplyInput proj $ Just $ PS tgt
            , let
              modifiers = T.pack $ case tgt.common.speed of
                Just n | n /= 1 -> "_" <> show (round $ n * 100 :: Int)
                _               -> ""
              in T.intercalate modifiers . T.splitOn "%modifiers%"
            ]
          in (tgt, usePath fout)
  makeTemplateRunner
    sink
    "Create CH folders"
    (maybe "%input_dir%" T.pack (prefDirCH ?preferences) <> "/%artist% - %title%")
    (getTargetSong PSDir >=> build)
  makeTemplateRunner
    sink
    "Create CH .sng files"
    (maybe "%input_dir%" T.pack (prefDirCH ?preferences) <> "/%artist% - %title%.sng")
    (getTargetSong PSSng >=> build)
  makeTemplateRunner
    sink
    "Create CH zips"
    (maybe "%input_dir%" T.pack (prefDirCH ?preferences) <> "/%input_base%%modifiers%_ps.zip")
    (getTargetSong PSZip >=> build)
  FL.end pack
  FL.setResizable tab $ Just pack
  return ()

forceProDrums :: SongYaml f -> SongYaml f
forceProDrums song = song
  { parts = flip fmap song.parts $ \part -> case part.drums of
    Nothing    -> part
    Just drums -> part
      { drums = Just drums
        { mode = case drums.mode of
          Drums4 -> DrumsPro
          mode   -> mode
        }
      }
  }

-- Batch mode presets for changing parts around

hasPartWith :: (Part f -> Maybe a) -> SongYaml f -> FlexPartName -> Bool
hasPartWith p song flex = isJust $ getPart flex song >>= p

getDrumsOrDance :: SongYaml f -> FlexPartName
getDrumsOrDance song
  | hasPartWith Just song (FlexExtra "dance") && not (hasPartWith anyDrums song FlexDrums)
    = FlexExtra "dance"
  | otherwise = FlexDrums

batchPartPresetsRB3 :: [(T.Text, (Bool, SongYaml f -> TargetRB3 f -> TargetRB3 f))]
batchPartPresetsRB3 =
  [ ("Default part configuration", (True, \song tgt -> tgt
    { drums = getDrumsOrDance song
    }))
  , ("Fill empty parts with first guitar, then drums", (False, \song tgt -> let
    fillPart p defPart parts = case filter (hasPartWith p song) (defPart : parts) of
      part : _ -> part
      []       -> defPart
    in tgt
      { guitar = fillPart anyFiveFret FlexGuitar [FlexDrums, FlexExtra "dance"]
      , bass = fillPart anyFiveFret FlexBass [FlexGuitar, FlexDrums, FlexExtra "dance"]
      , keys = fillPart anyFiveFret FlexKeys [FlexGuitar, FlexDrums, FlexExtra "dance"]
      , drums = fillPart anyDrums FlexDrums [FlexGuitar, FlexExtra "dance"]
      }))
  , ("Copy guitar to bass/keys/drums", (False, \_song tgt -> tgt
    { bass = FlexGuitar
    , keys = FlexGuitar
    , drums = FlexGuitar
    }))
  , ("Copy drums/dance to guitar/bass/keys", (False, \song tgt -> let
    dod = getDrumsOrDance song
    in tgt
      { guitar = dod
      , bass   = dod
      , keys   = dod
      , drums  = dod
      }
    ))
  ]

batchPartPresetsRB2 :: [(T.Text, SongYaml f -> TargetRB2 f -> TargetRB2 f)]
batchPartPresetsRB2 =
  [ ("Default part configuration", \song tgt -> tgt
    { drums = getDrumsOrDance song
    })
  , ("Copy guitar to bass if empty", \song tgt -> tgt
    { bass = if hasPartWith anyFiveFret song FlexBass then FlexBass else FlexGuitar
    , drums = getDrumsOrDance song
    })
  , ("Copy guitar to bass", \song tgt -> tgt
    { bass = FlexGuitar
    , drums = getDrumsOrDance song
    })
  , ("Keys on guitar/bass if empty", \song tgt -> tgt
    { guitar = if hasPartWith anyFiveFret song FlexGuitar then FlexGuitar else FlexKeys
    , bass   = if hasPartWith anyFiveFret song FlexBass   then FlexBass   else FlexKeys
    , drums = getDrumsOrDance song
    })
  , ("Keys on guitar", \song tgt -> tgt
    { guitar = FlexKeys
    , drums = getDrumsOrDance song
    })
  , ("Keys on bass", \song tgt -> tgt
    { bass = FlexKeys
    , drums = getDrumsOrDance song
    })
  , ("Copy drums/dance to guitar/bass if empty", \song tgt -> let
    dod = getDrumsOrDance song
    in tgt
      { guitar = if hasPartWith anyFiveFret song FlexGuitar then FlexGuitar else dod
      , bass   = if hasPartWith anyFiveFret song FlexBass   then FlexBass   else dod
      , drums  = dod
      }
    )
  , ("Copy drums/dance to guitar/bass", \song tgt -> let
    dod = getDrumsOrDance song
    in tgt
      { guitar = dod
      , bass   = dod
      , drums  = dod
      }
    )
  ]

batchPartPresetsCH :: [(T.Text, SongYaml f -> TargetPS f -> TargetPS f)]
batchPartPresetsCH =
  [ ("Default part configuration", \song tgt -> tgt
    { drums = getDrumsOrDance song
    })
  , ("Copy drums/dance to guitar if empty", \song tgt -> let
    dod = getDrumsOrDance song
    in tgt
      { guitar = if hasPartWith anyFiveFret song FlexGuitar then FlexGuitar else dod
      , drums = dod
      }
    )
  , ("Copy drums/dance to guitar", \song tgt -> let
    dod = getDrumsOrDance song
    in tgt
      { guitar = dod
      , drums = dod
      }
    )
  , ("Copy drums/dance to rhythm if empty", \song tgt -> let
    dod = getDrumsOrDance song
    in tgt
      { rhythm = if hasPartWith anyFiveFret song $ FlexExtra "rhythm" then FlexExtra "rhythm" else dod
      , drums = dod
      }
    )
  , ("Copy drums/dance to rhythm", \song tgt -> let
    dod = getDrumsOrDance song
    in tgt
      { rhythm = dod
      , drums = dod
      }
    )
  , ("Copy guitar and drums to each other if one is missing", \song tgt -> let
    fillPart p defPart parts = case filter (hasPartWith p song) (defPart : parts) of
      part : _ -> part
      []       -> defPart
    TargetPS{..} = tgt
    in TargetPS
      { guitar = fillPart anyFiveFret FlexGuitar [FlexDrums]
      , drums = fillPart anyDrums FlexDrums [FlexGuitar]
      , ..
      }
    )
  ]
