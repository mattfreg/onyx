{-# LANGUAGE LambdaCase #-}
module Onyx.Resources where

import qualified Codec.Picture         as P
import           Control.Arrow         (first)
import           Control.Monad         (guard)
import qualified Data.ByteString       as B
import qualified Data.ByteString.Char8 as B8
import           Data.Char             (isAlpha)
import qualified Data.HashMap.Strict   as HM
import           Data.List             (isPrefixOf)
import           Data.Maybe            (mapMaybe)
import qualified Data.Text             as T
import           Data.Text.Encoding    (decodeUtf8)
import qualified Onyx.Harmonix.DTA     as D
import           System.Directory      (getHomeDirectory)
import           System.Environment    (getExecutablePath)
import           System.FilePath       (takeDirectory, takeFileName, (</>))
import           System.IO.Unsafe      (unsafePerformIO)

getResourcesPath :: FilePath -> IO FilePath
getResourcesPath f = do
  exe <- getExecutablePath
  -- previously filename was just ghc but on newer stack it seems to be e.g. ghc-9.6.2
  resDir <- if "ghc" `isPrefixOf` takeFileName exe
    then (</> ".local/bin/onyx-files/onyx-resources") <$> getHomeDirectory -- we're in ghci, use installed resources
    else return $ takeDirectory exe </> "onyx-resources"
  return $ resDir </> f

magmaV1Dir, magmaV2Dir, magmaCommonDir, rb3Updates, kanwadict, itaijidict, makeFSB4exe, xma2encodeExe :: IO FilePath
magmaV1Dir       = getResourcesPath "magma-v1"
magmaV2Dir       = getResourcesPath "magma-v2"
magmaCommonDir   = getResourcesPath "magma-common"
rb3Updates       = getResourcesPath "rb3-updates"
kanwadict        = getResourcesPath "kanwadict"
itaijidict       = getResourcesPath "itaijidict"
makeFSB4exe      = getResourcesPath "makefsb4/makefsb4.exe"
xma2encodeExe    = getResourcesPath "xma2encode.exe"

xboxKV :: IO FilePath
xboxKV = getResourcesPath "KV.bin"

rb3Thumbnail :: IO FilePath
rb3Thumbnail = getResourcesPath "rb3.png"

rb2Thumbnail :: IO FilePath
rb2Thumbnail = getResourcesPath "rb2.png"

gh2Thumbnail :: IO FilePath
gh2Thumbnail = getResourcesPath "gh2.png"

gh3Thumbnail :: IO FilePath
gh3Thumbnail = getResourcesPath "gh3.png"

ghWoRThumbnail :: IO FilePath
ghWoRThumbnail = getResourcesPath "ghwor.png"

powerGigThumbnail :: IO FilePath
powerGigThumbnail = getResourcesPath "pg.png"

powerGigTitleThumbnail :: IO FilePath
powerGigTitleThumbnail = getResourcesPath "pg-title.png"

rrThumbnail :: IO FilePath
rrThumbnail = getResourcesPath "rr.png"

emptyMilo :: IO FilePath
emptyMilo = getResourcesPath "empty.milo_xbox"

emptyMiloRB2 :: IO FilePath
emptyMiloRB2 = getResourcesPath "empty-rb2.milo_xbox"

emptyWeightsRB2 :: IO FilePath
emptyWeightsRB2 = getResourcesPath "empty-rb2_weights.bin"

webDisplay :: IO FilePath
webDisplay = getResourcesPath "player"

onyxAlbum :: IO (P.Image P.PixelRGB8)
onyxAlbum = getResourcesPath "album.png" >>= P.readImage >>= \case
  Left  err -> error $ "panic! couldn't decode default album art into image: " ++ err
  Right dyn -> return $ P.convertRGB8 dyn

{-# NOINLINE missingSongData #-}
missingSongData :: D.DTA T.Text
missingSongData = unsafePerformIO $ do
  getResourcesPath "missing_song_data.dta" >>= fmap (D.readDTA . decodeUtf8) . B.readFile

colorMapDrums, colorMapGRYBO, colorMapGHL, colorMapRS, colorMapRSLow :: IO FilePath
colorMapDrums = getResourcesPath "rockband_drums.png"
colorMapGRYBO = getResourcesPath "rockband_guitarbass.png"
colorMapGHL   = getResourcesPath "rockband_ghl.png"
colorMapRS    = getResourcesPath "rocksmith_standard.png"
colorMapRSLow = getResourcesPath "rocksmith_lowbass.png"

{-# NOINLINE shiftJISTable #-}
shiftJISTable :: HM.HashMap B.ByteString Char
shiftJISTable = unsafePerformIO $ do
  getResourcesPath "shift-jis.txt" >>=
    fmap (HM.fromList . map (first B.pack) . read) . readFile

{-# NOINLINE cmuDict #-}
cmuDict :: HM.HashMap B.ByteString [[CMUPhoneme]]
cmuDict = unsafePerformIO $ do
  let parseLine b = do
        guard $ not $ B.null b
        guard $ isAlpha $ B8.head b
        case B8.words b of
          [] -> Nothing
          word : phones -> do
            let word' = B8.takeWhile (/= '(') word
            phones' <- mapM (`HM.lookup` phonemeTable) phones
            Just (word', [phones'])
      phonemeTable :: HM.HashMap B.ByteString CMUPhoneme
      phonemeTable = HM.fromList $ let
        consonants = do
          phone <- [minBound .. maxBound]
          return (B8.pack $ drop 4 $ show phone, CMUConsonant phone)
        vowels = do
          phone <- [minBound .. maxBound]
          stress <- ["", "0", "1", "2"]
          return (B8.pack $ drop 4 (show phone) <> stress, CMUVowel phone)
        in consonants <> vowels
  getResourcesPath "cmudict-0.7b" >>=
    fmap (HM.fromListWith (flip (<>)) . mapMaybe parseLine . B8.lines) . B.readFile
    -- flip is because fromListWith calls "f newVal oldVal"

data CMUConsonant
  = CMU_B  -- stop
  | CMU_CH -- affricate
  | CMU_D  -- stop
  | CMU_DH -- fricative
  | CMU_F  -- fricative
  | CMU_G  -- stop
  | CMU_HH -- aspirate
  | CMU_JH -- affricate
  | CMU_K  -- stop
  | CMU_L  -- liquid
  | CMU_M  -- nasal
  | CMU_N  -- nasal
  | CMU_NG -- nasal
  | CMU_P  -- stop
  | CMU_R  -- liquid
  | CMU_S  -- fricative
  | CMU_SH -- fricative
  | CMU_T  -- stop
  | CMU_TH -- fricative
  | CMU_V  -- fricative
  | CMU_W  -- semivowel
  | CMU_Y  -- semivowel
  | CMU_Z  -- fricative
  | CMU_ZH -- fricative
  deriving (Eq, Ord, Show, Read, Enum, Bounded)

data CMUVowel
  = CMU_AA -- vowel
  | CMU_AE -- vowel
  | CMU_AH -- vowel
  | CMU_AO -- vowel
  | CMU_AW -- vowel
  | CMU_AY -- vowel
  | CMU_EH -- vowel
  | CMU_ER -- vowel
  | CMU_EY -- vowel
  | CMU_IH -- vowel
  | CMU_IY -- vowel
  | CMU_OW -- vowel
  | CMU_OY -- vowel
  | CMU_UH -- vowel
  | CMU_UW -- vowel
  deriving (Eq, Ord, Show, Read, Enum, Bounded)

data CMUPhoneme
  = CMUConsonant !CMUConsonant
  | CMUVowel     !CMUVowel
  deriving (Eq, Ord, Show)
