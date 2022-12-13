{-# LANGUAGE LambdaCase        #-}
{-# LANGUAGE MultiWayIf        #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TupleSections     #-}
module Onyx.Import where

import           Control.Applicative          ((<|>))
import qualified Control.Monad.Catch          as MC
import           Control.Monad.Extra          (anyM, forM, forM_, guard)
import           Control.Monad.IO.Class       (MonadIO (..))
import           Control.Monad.Trans.Resource
import           Data.Bifunctor               (first)
import qualified Data.ByteString              as B
import qualified Data.ByteString.Char8        as B8
import qualified Data.ByteString.Lazy         as BL
import           Data.Char                    (isAlpha, toLower)
import           Data.Foldable                (toList)
import           Data.Functor                 (void)
import           Data.Functor.Identity
import           Data.Hashable
import qualified Data.HashMap.Strict          as Map
import           Data.Int                     (Int32)
import           Data.List.Extra              (stripSuffix)
import           Data.List.NonEmpty           (NonEmpty ((:|)))
import           Data.Maybe                   (fromMaybe, isJust, mapMaybe)
import qualified Data.Text                    as T
import           Data.Text.Encoding           (encodeUtf8)
import qualified Data.Text.Encoding           as TE
import           Onyx.Build
import           Onyx.Build.GuitarHero2.Logic (adjustSongText)
import           Onyx.Codec.JSON              (loadYaml)
import           Onyx.GuitarPro               (parseGP, parseGPX)
import           Onyx.Harmonix.Ark
import           Onyx.Harmonix.Ark.GH2        (GH2Installation (..),
                                               GameGH (..), SongSort (..),
                                               addBonusSongGH1, addBonusSongGH2,
                                               detectGameGH)
import           Onyx.Harmonix.DTA            (Chunk (..), DTA (..), Tree (..),
                                               readFileDTA)
import           Onyx.Import.Amplitude2016    (importAmplitude)
import           Onyx.Import.Base             (ImportLevel (..), saveImport)
import           Onyx.Import.BMS              (importBMS)
import           Onyx.Import.DTXMania         (importDTX, importSet)
import           Onyx.Import.Freetar          (importFreetar)
import           Onyx.Import.FretsOnFire      (importFoF)
import qualified Onyx.Import.GuitarHero1      as GH1
import qualified Onyx.Import.GuitarHero2      as GH2
import           Onyx.Import.GuitarPro        (importGPIF)
import           Onyx.Import.Magma            (importMagma)
import           Onyx.Import.Neversoft        (importGH3Disc, importGH3PS2,
                                               importNeversoftGH)
import           Onyx.Import.PowerGig         (importPowerGig)
import           Onyx.Import.RockBand         (importRB4, importRBA,
                                               importSTFSFolder)
import           Onyx.Import.RockRevolution   (importRR)
import           Onyx.Import.Rocksmith        as RS
import           Onyx.Import.StepMania        (importSM)
import           Onyx.ISO                     (folderISO)
import           Onyx.PlayStation.PKG         (getDecryptedUSRDIR, loadPKG,
                                               pkgFolder, tryDecryptEDAT)
import           Onyx.Preferences
import           Onyx.Project
import           Onyx.StackTrace
import           Onyx.Util.Handle             (Folder (..), crawlFolder,
                                               fileReadable, findFile,
                                               findFileCI, findFolder)
import           Onyx.Xbox.ISO                (loadXboxISO)
import           Onyx.Xbox.STFS               (getSTFSFolder)
import qualified Sound.Jammit.Base            as J
import qualified System.Directory             as Dir
import           System.FilePath              (dropExtension,
                                               dropTrailingPathSeparator,
                                               splitExtension, takeDirectory,
                                               takeExtension, takeFileName,
                                               (-<.>), (<.>), (</>))
import qualified System.IO                    as IO
import qualified System.IO.Temp               as Temp
import           System.Random                (randomRIO)

data Project = Project
  { projectLocation :: FilePath -- path to song.yml
  , projectSongYaml :: SongYaml FilePath
  , projectRelease  :: Maybe ReleaseKey -- delete the temp import dir early if you want
  , projectSource   :: FilePath -- absolute path to the source STFS file, PS dir, etc.
  , projectTemplate :: FilePath -- string you can append "_whatever" to for generated files
  }

resourceTempDir :: (MonadResource m) => m (ReleaseKey, FilePath)
resourceTempDir = do
  tmp <- liftIO Temp.getCanonicalTemporaryDirectory
  let ignoringIOErrors ioe = ioe `MC.catch` (\e -> const (return ()) (e :: IOError))
  allocate
    (Temp.createTempDirectory tmp "onyx")
    (ignoringIOErrors . Dir.removePathForcibly)

data Importable m = Importable
  { impTitle   :: Maybe T.Text
  , impArtist  :: Maybe T.Text
  , impAuthor  :: Maybe T.Text
  , impFormat  :: T.Text
  , impPath    :: FilePath
  , impIndex   :: Maybe Int
  , impProject :: StackTraceT m Project
  , imp2x      :: Bool -- True if only 2x bass pedal
  }

findAllSongs :: (SendMessage m, MonadResource m)
  => FilePath -> StackTraceT m [Importable m]
findAllSongs fp' = do
  (subs, imps) <- findSongs fp'
  concat . (imps :) <$> mapM findAllSongs subs

findSongs :: (SendMessage m, MonadResource m)
  => FilePath -> StackTraceT m ([FilePath], [Importable m])
findSongs fp' = inside ("searching: " <> fp') $ fmap (fromMaybe ([], [])) $ errorToWarning $ do
  fp <- stackIO $ Dir.makeAbsolute fp'
  let found imp = foundMany [imp]
      foundMany imps = return ([], imps)
      withYaml index loc isDir key fyml = loadYaml fyml >>= \yml -> return Project
        { projectLocation = fyml
        , projectSongYaml = yml
        , projectRelease = key
        , projectSource = loc
        , projectTemplate = fromMaybe
          ( (if isDir then id else dropExtension)
          $ dropTrailingPathSeparator loc
          ) (stripSuffix "_rb3con" loc <|> stripSuffix "_rb2con" loc)
          <> maybe "" (\i -> "_" <> show (i :: Int)) index
        }
      importFrom index loc isDir fn = do
        (key, tmp) <- resourceTempDir
        () <- fn tmp
        withYaml index loc isDir (Just key) (tmp </> "song.yml")
      foundFoF loc = do
        -- loc can be a .ini or .chart
        let dir = takeDirectory loc
        foundImport "Frets on Fire/Phase Shift/Clone Hero" dir $ importFoF dir
      foundHDR hdr = do
        let dir = takeDirectory hdr
        stackIO (crawlFolder dir) >>= foundGEN dir
      foundGEN loc gen = stackIO (detectGameGH gen) >>= \case
        Nothing -> do
          warn $ "Couldn't detect GH game version for: " <> loc
          return ([], [])
        Just GameGH2DX2 -> GH2.importGH2 loc gen >>= foundImports "Guitar Hero II (DX)" loc
        Just GameGH2 -> GH2.importGH2 loc gen >>= foundImports "Guitar Hero II" loc
        Just GameGH1 -> GH1.importGH1 loc gen >>= foundImports "Guitar Hero (1)" loc
        Just GameRB -> do
          (hdr, arks) <- stackIO $ loadGEN gen
          folder <- loadArkFolder hdr arks
          importSTFSFolder loc (first TE.decodeLatin1 folder) >>= foundImports "Rock Band (.ARK)" loc
      foundDTXSet loc = importSet loc >>= foundImports "DTXMania (set.def)" (takeDirectory loc)
      foundDTX loc = foundImport "DTXMania" loc $ importDTX loc
      foundBME loc = foundImport "Be-Music Source" loc $ importBMS loc
      foundYaml loc = do
        let dir = takeDirectory loc
        yml <- loadYaml loc
        let _ = yml :: SongYaml FilePath
        found Importable
          { impTitle = _title $ _metadata yml
          , impArtist = _artist $ _metadata yml
          , impAuthor = _author $ _metadata yml
          , impFormat = "Onyx"
          , impPath = dir
          , impIndex = Nothing
          , impProject = withYaml Nothing dir True Nothing loc
          , imp2x = any (maybe False ((== Kicks2x) . drumsKicks) . partDrums) $ _parts yml
          }
      foundRBProj loc = foundImport "Magma Project" loc $ importMagma loc
      foundAmplitude loc = do
        let dir = takeDirectory loc
        foundImport "Amplitude (2016)" dir $ importAmplitude loc
      foundSTFS loc = do
        folder <- stackIO $ getSTFSFolder loc
        mconcat <$> sequence
          [ case findFile ("songs" :| ["songs.dta"]) folder of
            Just _ -> do
              imps <- importSTFSFolder loc folder
              foundImports "Rock Band (Xbox 360 CON/LIVE)" loc imps
            Nothing -> return ([], [])
          , case findFile ("config" :| ["songs.dta"]) folder of
            Just _ -> do
              imps <- GH2.importGH2DLC loc folder
              foundImports "Guitar Hero II (Xbox 360 DLC)" loc imps
            Nothing -> return ([], [])
          , if any (\(name, _) -> ".xen" `T.isSuffixOf` name) $ folderFiles folder
            then do
              imps <- importNeversoftGH loc folder
              foundImports "Guitar Hero (Neversoft) (360)" loc imps
            else return ([], [])
          , importRSXbox folder >>= foundImports "Rocksmith" loc
          , case mapMaybe (\(name, _) -> T.stripSuffix ".hdr.e.2" name) $ folderFiles folder of
            []    -> return ([], [])
            bases -> do
              imps <- concat <$> mapM (importPowerGig folder) bases
              foundImports "Power Gig (Xbox 360 DLC)" loc imps
          , case findFolder ["data"] folder of
            Just dataDir -> foundImports "Rock Revolution (Xbox 360 DLC)" loc $ importRR dataDir
            Nothing -> return ([], [])
          ]
      foundRS psarc = importRS (fileReadable psarc) >>= foundImports "Rocksmith" psarc
      foundRSPS3 edat = do
        mpsarc <- tryDecryptEDAT "" (B8.pack $ takeFileName edat) $ fileReadable edat
        case mpsarc of
          Nothing    -> fatal "Couldn't decrypt .psarc.edat"
          Just psarc -> importRS psarc >>= foundImports "Rocksmith" edat
      foundPS3 loc = do
        usrdirs <- stackIO (pkgFolder <$> loadPKG loc) >>= getDecryptedUSRDIR
        fmap mconcat $ forM usrdirs $ \(_, folderBS) -> let
          folder = first TE.decodeLatin1 folderBS
          in mconcat <$> sequence
            [ case findFile ("songs" :| ["songs.dta"]) folder of
              Just _ -> do
                imps <- importSTFSFolder loc folder
                foundImports "Rock Band (PS3 .pkg)" loc imps
              Nothing -> return ([], [])
            , if any (\(name, _) -> ".PS3" `T.isSuffixOf` name) $ folderFiles folder
              then do
                imps <- importNeversoftGH loc folder
                foundImports "Guitar Hero (Neversoft) (PS3)" loc imps
              else return ([], [])
            ]
      foundGP loc = do
        let imp level = parseGP loc >>= \gpif -> importGPIF gpif level
        foundImports "Guitar Pro (.gp)" loc [imp]
      foundGPX loc = do
        let imp level = parseGPX loc >>= \gpif -> importGPIF gpif level
        foundImports "Guitar Pro (.gpx)" loc [imp]
      foundPowerGig loc dir hdrName = do
        let base = T.takeWhile (/= '.') $ T.pack hdrName
        imps <- importPowerGig dir base
        foundImports "Power Gig" loc imps
      foundFreetar loc = foundImports "Freetar" loc [importFreetar loc]
      found360Game loc dir
        | isJust $ findFileCI ("gen" :| ["main_xbox.hdr"]) dir
          = case findFolder ["gen"] dir of
            Nothing  -> return ([], []) -- shouldn't happen
            Just gen -> foundGEN loc gen
        | isJust $ findFileCI ("Data" :| ["Frontend", "FE_Config.lua"]) dir = let
          songsDir = fromMaybe mempty $ findFolder ["Data", "Songs"] dir
          in foundImports "Rock Revolution (360)" loc $ importRR songsDir
        | isJust $ findFileCI ("DATA" :| ["MOVIES", "BIK", "GH3_Intro.bik.xen"]) dir
          = importGH3Disc loc dir >>= foundImports "Guitar Hero III (360)" loc
        | isJust $ findFileCI ("DATA" :| ["MOVIES", "BIK", "AO_Long_1.bik.xen"]) dir
          = importGH3Disc loc dir >>= foundImports "Guitar Hero: Aerosmith (360)" loc
        | isJust $ findFileCI ("DATA" :| ["MOVIES", "BIK", "loading_flipbook.bik.xen"]) dir
          = warn "Guitar Hero World Tour not supported (yet)" >> return ([], [])
        | isJust $ findFileCI ("data" :| ["compressed", "ZONES", "Z_GH6Intro.pak.xen"]) dir
          = warn "Guitar Hero: Warriors of Rock disc not supported yet" >> return ([], [])
        | isJust $ findFileCI (pure "Data.hdr.e.2") dir
          = foundPowerGig loc dir "Data.hdr.e.2"
        | otherwise = warn "Unrecognized Xbox 360 game" >> return ([], [])
      foundGH3PS2 hed = do
        let loc = takeDirectory hed
        dir <- stackIO $ crawlFolder loc
        imps <- importGH3PS2 loc dir
        foundImports "Guitar Hero III (PS2)" loc imps
      foundISO iso = stackIO (loadXboxISO $ fileReadable iso) >>= \case
        Just xiso -> found360Game iso $ first TE.decodeLatin1 xiso
        Nothing   -> do
          contents <- stackIO $ fmap (first TE.decodeLatin1) $ folderISO $ fileReadable iso
          case findFolder ["GEN"] contents of
            Just gen -> foundGEN iso gen
            Nothing  -> case findFileCI (pure "DATAP.HED") contents of
              Just _ -> do
                imps <- importGH3PS2 iso contents
                foundImports "Guitar Hero III (PS2)" iso imps
              Nothing -> return ([], [])
      foundImports fmt path imports = do
        isDir <- stackIO $ Dir.doesDirectoryExist path
        let single = null $ drop 1 imports
        fmap ([],) $ forM (zip [0..] imports) $ \(i, imp) -> do
          quick <- imp ImportQuick
          let index = guard (not single) >> Just i
          return Importable
            { impTitle = _title $ _metadata quick
            , impArtist = _artist $ _metadata quick
            , impAuthor = _author $ _metadata quick
            , impFormat = fmt
            , impPath = path
            , impIndex = index
            , impProject = importFrom index path isDir $ \dout ->
              void $ imp ImportFull >>= stackIO . saveImport dout
            , imp2x = any (maybe False ((== Kicks2x) . drumsKicks) . partDrums) $ _parts quick
            }
      foundImport fmt path imp = foundImports fmt path [imp]
  isDir <- stackIO $ Dir.doesDirectoryExist fp
  if isDir
    then do
      ents <- stackIO $ Dir.listDirectory fp
      let lookFor [] = do
            hasRBDTA <- stackIO $ anyM Dir.doesFileExist
              [fp </> "songs/songs.dta", fp </> "songs/gen/songs.dtb"]
            -- filter older supported stepmania formats when a newer one is present
            let sm = map (map toLower) $ filter ((== ".sm") . map toLower . takeExtension) ents
                filtered = flip filter ents $ \x -> case splitExtension $ map toLower x of
                  (name, ".dwi") -> notElem (name <.> "sm") sm
                  _              -> True
            if hasRBDTA
              then stackIO (crawlFolder fp)
                >>= importSTFSFolder fp
                >>= foundImports "Rock Band Extracted" fp
              else return (map (fp </>) filtered, [])
          lookFor ((file, use) : rest) = case filter ((== file) . map toLower) ents of
            match : _ -> use $ fp </> match
            []        -> lookFor rest
      -- These filenames stop the directory traversal, to prevent songs being picked up twice
      lookFor
        -- Don't look in the Onyx gen folder and probably find built artifacts
        [ ("song.yml", foundYaml)
        -- Make sure we don't pick up song.ini and notes.chart separately
        , ("song.ini", foundFoF)
        , ("notes.chart", foundFoF)
        -- Don't pick up specific .dtx files as well as the set file
        , ("set.def", foundDTXSet)
        -- Just to be helpful if a hdr/ark set is extracted next to it
        , ("main.hdr", foundHDR)
        , ("main_ps3.hdr", foundHDR)
        , ("main_xbox.hdr", foundHDR)
        -- Needed so we don't also pick up game-specific files like a Harmonix GEN folder or Power Gig Data.hdr.e.2
        , ("default.xex", \xex -> let dir = takeDirectory xex in stackIO (crawlFolder dir) >>= found360Game xex)
        ]
    else do
      case map toLower $ takeExtension fp of
        ".rbproj" -> foundRBProj fp
        ".songdta_ps4" -> foundImport "Rock Band 4" (takeDirectory fp) $ importRB4 fp
        ".moggsong" -> stackIO (Dir.doesFileExist $ fp -<.> "songdta_ps4") >>= \case
          True  -> return ([], []) -- rb4, ignore this and import .songdta_ps4 instead
          False -> foundAmplitude fp
        ".chart" -> foundFoF fp
        ".dtx" -> foundDTX fp
        ".gda" -> foundDTX fp
        ".sm" -> foundImport "StepMania" fp $ importSM fp
        ".dwi" -> foundImport "StepMania" fp $ importSM fp
        ".bms" -> foundBME fp
        ".bme" -> foundBME fp
        ".bml" -> foundBME fp
        ".psarc" -> foundRS fp
        ".edat" | map toLower (takeExtension $ dropExtension fp) == ".psarc"
          -> foundRSPS3 fp
        ".pkg" -> foundPS3 fp
        ".gp" -> foundGP fp
        ".gpx" -> foundGPX fp
        ".2" -> do -- assuming this is Data.hdr.e.2
          let dir = takeDirectory fp
          folder <- stackIO $ crawlFolder dir
          foundPowerGig fp folder $ takeFileName fp
        ".sng" -> foundFreetar fp
        ".iso" -> foundISO fp
        _ -> case map toLower $ takeFileName fp of
          "song.yml" -> foundYaml fp
          "song.ini" -> foundFoF fp
          "set.def" -> foundDTXSet fp
          "main.hdr" -> foundHDR fp
          "main_ps3.hdr" -> foundHDR fp
          "main_xbox.hdr" -> foundHDR fp
          "default.xex" -> do
            let dir = takeDirectory fp
            stackIO (crawlFolder dir) >>= found360Game fp
          "datap.hed" -> foundGH3PS2 fp
          _ -> do
            magic <- stackIO $ IO.withBinaryFile fp IO.ReadMode $ \h -> BL.hGet h 4
            case magic of
              "RBSF" -> foundImport "Magma RBA" fp $ importRBA fp
              "CON " -> foundSTFS fp
              "LIVE" -> foundSTFS fp
              _      -> return ([], [])

openProject :: (SendMessage m, MonadResource m) =>
  Maybe Int -> FilePath -> StackTraceT m Project
openProject i fp = do
  (_, imps) <- findSongs fp
  case i of
    Nothing -> case imps of
      [imp] -> impProject imp
      []    -> fatal $ "Couldn't find a song at location: " <> fp
      _     -> fatal $ unlines
        $ ("Found more than 1 song at location: " <> fp) : do
          (j, imp) <- zip [0 :: Int ..] imps
          let f = maybe "?" T.unpack
          return $ show j <> ": " <> f (impTitle imp) <> " (" <> f (impArtist imp) <> ")"
    Just j  -> case drop j imps of
      imp : _ -> impProject imp
      []      -> fatal $ "Couldn't find song #" <> show j <> " at location: " <> fp

withProject :: (SendMessage m, MonadResource m) =>
  Maybe Int -> FilePath -> (Project -> StackTraceT m a) -> StackTraceT m a
withProject i fp fn = do
  proj <- openProject i fp
  x <- fn proj
  stackIO $ mapM_ release $ projectRelease proj
  return x

getAudioDirs :: (SendMessage m, MonadIO m) => Project -> StackTraceT m [FilePath]
getAudioDirs proj = do
  jmt <- stackIO J.findJammitDir
  let addons = maybe id (:) jmt [takeDirectory $ projectLocation proj]
  dirs <- prefAudioDirs <$> readPreferences
  mapM (stackIO . Dir.canonicalizePath) $ addons ++ dirs

shakeBuild1 :: (MonadIO m) =>
  Project -> [(T.Text, Target)] -> FilePath -> StackTraceT (QueueLog m) FilePath
shakeBuild1 proj extraTargets = fmap runIdentity . shakeBuildMany proj extraTargets . Identity

shakeBuildMany :: (MonadIO m, Functor f, Foldable f) =>
  Project -> [(T.Text, Target)] -> f FilePath -> StackTraceT (QueueLog m) (f FilePath)
shakeBuildMany proj extraTargets buildables = do
  audioDirs <- getAudioDirs proj
  shakeBuild audioDirs (projectLocation proj) extraTargets $ toList buildables
  return $ fmap (takeDirectory (projectLocation proj) </>) buildables

buildCommon :: (MonadIO m) => Target -> (String -> FilePath) -> Project -> StackTraceT (QueueLog m) FilePath
buildCommon target getBuildable proj = do
  let targetHash = show $ hash target `mod` 100000000
      buildable = getBuildable targetHash
  shakeBuild1 proj [(T.pack targetHash, target)] buildable

randomRBSongID :: (MonadIO m) => m Int32
randomRBSongID = liftIO $ randomRIO (10000000, 1000000000)

buildRB3CON :: (MonadIO m) => TargetRB3 -> Project -> StackTraceT (QueueLog m) FilePath
buildRB3CON rb3 proj = do
  songID <- randomRBSongID
  let rb3' = rb3 { rb3_SongID = SongIDInt songID }
  buildCommon (RB3 rb3') (\targetHash -> "gen/target" </> targetHash </> "rb3con") proj

buildRB3PKG :: (MonadIO m) => TargetRB3 -> Project -> StackTraceT (QueueLog m) FilePath
buildRB3PKG rb3 proj = do
  songID <- randomRBSongID
  let rb3' = rb3 { rb3_SongID = SongIDInt songID }
  buildCommon (RB3 rb3') (\targetHash -> "gen/target" </> targetHash </> "rb3-ps3.pkg") proj

buildRB2CON :: (MonadIO m) => TargetRB2 -> Project -> StackTraceT (QueueLog m) FilePath
buildRB2CON rb2 proj = do
  songID <- randomRBSongID
  let rb2' = rb2 { rb2_SongID = SongIDInt songID }
  buildCommon (RB2 rb2') (\targetHash -> "gen/target" </> targetHash </> "rb2con") proj

buildRB2PKG :: (MonadIO m) => TargetRB2 -> Project -> StackTraceT (QueueLog m) FilePath
buildRB2PKG rb2 proj = do
  songID <- randomRBSongID
  let rb2' = rb2 { rb2_SongID = SongIDInt songID }
  buildCommon (RB2 rb2') (\targetHash -> "gen/target" </> targetHash </> "rb2-ps3.pkg") proj

buildMagmaV2 :: (MonadIO m) => TargetRB3 -> Project -> StackTraceT (QueueLog m) FilePath
buildMagmaV2 rb3 = buildCommon (RB3 rb3) $ \targetHash -> "gen/target" </> targetHash </> "magma"

buildPSDir :: (MonadIO m) => TargetPS -> Project -> StackTraceT (QueueLog m) FilePath
buildPSDir ps = buildCommon (PS ps) $ \targetHash -> "gen/target" </> targetHash </> "ps"

buildPSZip :: (MonadIO m) => TargetPS -> Project -> StackTraceT (QueueLog m) FilePath
buildPSZip ps = buildCommon (PS ps) $ \targetHash -> "gen/target" </> targetHash </> "ps.zip"

buildGH1Dir :: (MonadIO m) => TargetGH1 -> Project -> StackTraceT (QueueLog m) FilePath
buildGH1Dir gh1 = buildCommon (GH1 gh1) $ \targetHash -> "gen/target" </> targetHash </> "gh1"

buildGH2Dir :: (MonadIO m) => TargetGH2 -> Project -> StackTraceT (QueueLog m) FilePath
buildGH2Dir gh2 = buildCommon (GH2 gh2) $ \targetHash -> "gen/target" </> targetHash </> "gh2"

buildGH2LIVE :: (MonadIO m) => TargetGH2 -> Project -> StackTraceT (QueueLog m) FilePath
buildGH2LIVE gh2 = buildCommon (GH2 gh2) $ \targetHash -> "gen/target" </> targetHash </> "gh2live"

buildGH3LIVE :: (MonadIO m) => TargetGH3 -> Project -> StackTraceT (QueueLog m) FilePath
buildGH3LIVE gh3 = buildCommon (GH3 gh3) $ \targetHash -> "gen/target" </> targetHash </> "gh3live"

buildGH3PKG :: (MonadIO m) => TargetGH3 -> Project -> StackTraceT (QueueLog m) FilePath
buildGH3PKG gh3 = buildCommon (GH3 gh3) $ \targetHash -> "gen/target" </> targetHash </> "ps3.pkg"

buildGHWORLIVE :: (MonadIO m) => TargetGH5 -> Project -> StackTraceT (QueueLog m) FilePath
buildGHWORLIVE gh5 = buildCommon (GH5 gh5) $ \targetHash -> "gen/target" </> targetHash </> "ghworlive"

buildGHWORPKG :: (MonadIO m) => TargetGH5 -> Project -> StackTraceT (QueueLog m) FilePath
buildGHWORPKG gh5 = buildCommon (GH5 gh5) $ \targetHash -> "gen/target" </> targetHash </> "ps3.pkg"

installGH1 :: (MonadIO m) => TargetGH1 -> Project -> FilePath -> StackTraceT (QueueLog m) ()
installGH1 gh1 proj gen = do
  stackIO (crawlFolder gen >>= detectGameGH) >>= \case
    Nothing         -> fatal "Couldn't detect what game this ARK is for."
    Just GameGH1    -> return ()
    Just GameGH2    -> fatal "This appears to be a Guitar Hero II or 80's ARK!"
    Just GameGH2DX2 -> fatal "This appears to be a Guitar Hero II Deluxe ARK!"
    Just GameRB     -> fatal "This appears to be a Rock Band ARK!"
  dir <- buildGH1Dir gh1 proj
  files <- stackIO $ Dir.listDirectory dir
  dta <- stackIO $ readFileDTA $ dir </> "songs-inner.dta"
  sym <- stackIO $ B.readFile $ dir </> "symbol"
  let chunks = treeChunks $ topTree $ fmap (B8.pack . T.unpack) dta
      filePairs = flip mapMaybe files $ \f -> do
        guard $ elem (takeExtension f) [".mid", ".vgs", ".voc"]
        return (sym <> B8.pack (dropWhile isAlpha f), dir </> f)
  let toBytes = B8.pack . T.unpack
  prefs <- readPreferences
  stackIO $ addBonusSongGH1 GH2Installation
    { gh2i_GEN              = gen
    , gh2i_symbol           = sym
    , gh2i_song             = chunks
    , gh2i_coop_max_scores  = [] -- not used
    , gh2i_shop_title       = Just $ toBytes $ targetTitle (projectSongYaml proj) $ GH1 gh1 -- not used
    , gh2i_shop_description = Just $ toBytes $ T.unlines
      [ "Artist: " <> getArtist (_metadata $ projectSongYaml proj)
      , "Album: "  <> getAlbum  (_metadata $ projectSongYaml proj)
      , "Author: " <> getAuthor (_metadata $ projectSongYaml proj)
      ]
    , gh2i_author           = toBytes . adjustSongText <$> _author (_metadata $ projectSongYaml proj)
    , gh2i_album_art        = Nothing -- not used
    , gh2i_files            = filePairs
    , gh2i_sort             = guard (prefSortGH2 prefs) >> if prefArtistSort prefs
      then Just SongSortArtistTitle
      else Just SongSortTitleArtist
    , gh2i_loading_phrase   = toBytes <$> gh1_LoadingPhrase gh1
    }

installGH2 :: (MonadIO m) => TargetGH2 -> Project -> FilePath -> StackTraceT (QueueLog m) ()
installGH2 gh2 proj gen = do
  isDX2 <- stackIO (crawlFolder gen >>= detectGameGH) >>= \case
    Nothing         -> fatal "Couldn't detect what game this ARK is for."
    Just GameGH1    -> fatal "This appears to be a Guitar Hero (1) ARK!"
    Just GameGH2    -> do
      lg "ARK detected as GH2, no drums support."
      return False
    Just GameGH2DX2 -> do
      lg "ARK detected as GH2 Deluxe with drums support."
      return True
    Just GameRB     -> fatal "This appears to be a Rock Band ARK!"
  dir <- buildGH2Dir gh2 proj
  files <- stackIO $ Dir.listDirectory dir
  dta <- stackIO $ readFileDTA $ if isDX2
    then dir </> "songs-inner-dx2.dta"
    else dir </> "songs-inner.dta"
  sym <- stackIO $ B.readFile $ dir </> "symbol"
  coop <- stackIO $ readFileDTA $ dir </> "coop_max_scores.dta"
  let chunks = treeChunks $ topTree $ fmap (B8.pack . T.unpack) dta
      filePairs = flip mapMaybe files $ \f -> do
        guard $ elem (takeExtension f) [".mid", ".vgs", ".voc"]
        return (sym <> B8.pack (dropWhile isAlpha f), dir </> f)
  coopNums <- case coop of
    DTA 0 (Tree _ [Parens (Tree _ [Sym _, Parens (Tree _ nums)])]) -> forM nums $ \case
      Int n -> return $ fromIntegral n
      _     -> fatal "unexcepted non-int in coop scores list"
    _ -> fatal "Couldn't read coop scores list"
  let toBytes = B8.pack . T.unpack
  prefs <- readPreferences
  stackIO $ addBonusSongGH2 GH2Installation
    { gh2i_GEN              = gen
    , gh2i_symbol           = sym
    , gh2i_song             = chunks
    , gh2i_coop_max_scores  = coopNums
    , gh2i_shop_title       = Just $ toBytes $ targetTitle (projectSongYaml proj) $ GH2 gh2
    , gh2i_shop_description = Just $ toBytes $ T.unlines
      [ "Artist: " <> getArtist (_metadata $ projectSongYaml proj)
      , "Album: "  <> getAlbum  (_metadata $ projectSongYaml proj)
      , "Author: " <> getAuthor (_metadata $ projectSongYaml proj)
      ]
    , gh2i_author           = toBytes . adjustSongText <$> _author (_metadata $ projectSongYaml proj)
    , gh2i_album_art        = Just $ dir </> "cover.png_ps2"
    , gh2i_files            = filePairs
    , gh2i_sort             = guard (prefSortGH2 prefs) >> if prefArtistSort prefs
      then Just SongSortArtistTitle
      else Just SongSortTitleArtist
    , gh2i_loading_phrase   = toBytes <$> gh2_LoadingPhrase gh2
    }

makeGH1DIY :: (MonadIO m) => TargetGH1 -> Project -> FilePath -> StackTraceT (QueueLog m) ()
makeGH1DIY gh1 proj dout = do
  dir <- buildGH1Dir gh1 proj
  stackIO $ Dir.createDirectoryIfMissing False dout
  files <- stackIO $ Dir.listDirectory dir
  sym <- stackIO $ fmap B8.unpack $ B.readFile $ dir </> "symbol"
  let filePairs = flip mapMaybe files $ \f -> let ext = takeExtension f in if
        | elem ext [".vgs", ".mid"]               -> Just (sym <> dropWhile isAlpha f, dir </> f)
        | ext == ".dta" && f /= "songs-inner.dta" -> Just (f, dir </> f)
        | otherwise                               -> Nothing
  stackIO $ forM_ filePairs $ \(dest, src) -> Dir.copyFile src $ dout </> dest
  let s = T.pack sym
  stackIO $ B.writeFile (dout </> "README.txt") $ encodeUtf8 $ T.intercalate "\r\n"
    [ "Instructions for GH1 song installation"
    , ""
    , "You must have a tool that can edit .ARK files such as arkhelper,"
    , "and a tool that can edit .dtb files such as dtab (which arkhelper can use automatically)."
    , ""
    , "1. Add the contents of songs.dta to: config/gen/songs.dtb"
    , "2. Make a new folder: songs/" <> s <> "/ and copy the .mid and .vgs files into it"
    , "3. Edit either config/gen/campaign.dtb or config/gen/store.dtb to add your song as a career or bonus song respectively"
    , "4. If added as a bonus song, edit ghui/eng/gen/locale.dtb with the key '" <> s <> "_shop_desc' if you want a description in the shop"
    -- TODO also mention loading tip in locale.dtb?
    ]

makeGH2DIY :: (MonadIO m) => TargetGH2 -> Project -> FilePath -> StackTraceT (QueueLog m) ()
makeGH2DIY gh2 proj dout = do
  dir <- buildGH2Dir gh2 proj
  stackIO $ Dir.createDirectoryIfMissing False dout
  files <- stackIO $ Dir.listDirectory dir
  sym <- stackIO $ fmap B8.unpack $ B.readFile $ dir </> "symbol"
  let filePairs = flip mapMaybe files $ \f -> let ext = takeExtension f in if
        | elem ext [".voc", ".vgs", ".mid"]       -> Just (sym <> dropWhile isAlpha f          , dir </> f)
        | ext == ".dta" && f /= "songs-inner.dta" && f /= "songs-inner-dx2.dta"
          -> Just (f, dir </> f)
        | ext == ".png_ps2"                       -> Just ("us_logo_" <> sym <> "_keep.png_ps2", dir </> f)
        | otherwise                               -> Nothing
  stackIO $ forM_ filePairs $ \(dest, src) -> Dir.copyFile src $ dout </> dest
  let s = T.pack sym
  stackIO $ B.writeFile (dout </> "README.txt") $ encodeUtf8 $ T.intercalate "\r\n"
    [ "Instructions for GH2 song installation"
    , ""
    , "You must have a tool that can edit .ARK files such as arkhelper,"
    , "and a tool that can edit .dtb files such as dtab (which arkhelper can use automatically)."
    , ""
    , "1. Add the contents of songs.dta to: config/gen/songs.dtb"
    , "  (For GH2 Deluxe 2.0, use songs-dx2.dta instead)"
    , "2. (possibly optional) Add the contents of coop_max_scores.dta to: config/gen/coop_max_scores.dtb"
    , "3. Make a new folder: songs/" <> s <> "/ and copy all .mid, .vgs, and .voc files into it"
    , "4. Edit either config/gen/campaign.dtb or config/gen/store.dtb to add your song as a career or bonus song respectively"
    , "5. If added as a bonus song, copy the .png_ps2 to ui/image/og/gen/us_logo_" <> s <> "_keep.png_ps2 if you want album art in the shop"
    , "6. If added as a bonus song, edit ui/eng/gen/locale.dtb with keys '" <> s <> "' and '" <> s <> "_shop_desc' if you want a title/description in the shop"
    -- TODO also mention loading tip in locale.dtb?
    ]

buildPlayer :: (MonadIO m) => Maybe T.Text -> Project -> StackTraceT (QueueLog m) FilePath
buildPlayer mplan proj = do
  planName <- case mplan of
    Just planName -> return planName
    Nothing       -> case Map.toList $ _plans $ projectSongYaml proj of
      [(planName, _)] -> return planName
      []              -> fatal "Project has no audio plans"
      _ : _ : _       -> fatal "Project has more than 1 audio plan"
  shakeBuild1 proj [] $ "gen/plan" </> T.unpack planName </> "web"

choosePlan :: (Monad m) => Maybe T.Text -> Project -> StackTraceT m T.Text
choosePlan (Just plan) _    = return plan
choosePlan Nothing     proj = case Map.keys $ _plans $ projectSongYaml proj of
  [p]   -> return p
  plans -> fatal $ "No plan selected, and the project doesn't have exactly 1 plan: " <> show plans

proKeysHanging :: (MonadIO m) => Maybe T.Text -> Project -> StackTraceT (QueueLog m) ()
proKeysHanging mplan proj = do
  plan <- choosePlan mplan proj
  void $ shakeBuild1 proj [] $ "gen/plan" </> T.unpack plan </> "hanging"