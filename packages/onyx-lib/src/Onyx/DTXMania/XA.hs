{- |

DTX .xa audio decoding

Ported from <https://github.com/Dridi/bjxa>

Licensed under the GNU General Public License v3

-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE NoFieldSelectors      #-}
{-# LANGUAGE OverloadedRecordDot   #-}
{-# LANGUAGE OverloadedStrings     #-}
{-# LANGUAGE RecordWildCards       #-}
{-# LANGUAGE StrictData            #-}
module Onyx.DTXMania.XA (sourceXA) where

import           Control.Monad                (forM, replicateM)
import           Control.Monad.IO.Class       (MonadIO (liftIO))
import           Control.Monad.Trans.Class    (lift)
import           Control.Monad.Trans.Resource (MonadResource)
import           Control.Monad.Trans.State    (StateT, evalStateT, gets, modify)
import           Data.Binary.Get
import           Data.Bits
import qualified Data.ByteString              as B
import qualified Data.ByteString.Lazy         as BL
import           Data.Conduit                 (yield)
import qualified Data.Conduit                 as C
import           Data.Conduit.Audio
import           Data.Int
import qualified Data.Vector.Storable         as V
import           Data.Word                    (Word8)
import           System.IO

data XAState = XAState
  { prev0 :: Int16
  , prev1 :: Int16
  } deriving (Show)

data XAHeader = XAHeader
  { dataLength  :: Int
  , samples     :: Frames
  , rate        :: Rate
  , bits        :: Int
  , channels    :: Channels
  , initState   :: [XAState]
  , blockSize   :: Int
  , blockSizeXA :: Int
  } deriving (Show)

blockInflater :: Int -> B.ByteString -> ([Int16], Word8)
blockInflater 8 src =
  ( map (\b -> fromIntegral b `shiftL` 8) $ drop 1 $ B.unpack src
  , B.head src
  )
blockInflater 4 src =
  ( do
    b <- drop 1 $ B.unpack src
    [   fromIntegral (b .&. 0xF0) `shiftL` 8
      , fromIntegral (b .&. 0x0F) `shiftL` 12
      ]
  , B.head src
  )
blockInflater 6 src =
  ( let
    f (a : b : c : xs) = let
      s :: Int32
      s =   (fromIntegral a `shiftL` 16)
        .|. (fromIntegral b `shiftL` 8)
        .|. fromIntegral c
      in  [ fromIntegral $ (s .&. 0x00fc0000) `shiftR` 8
          , fromIntegral $ (s .&. 0x0003f000) `shiftR` 2
          , fromIntegral $ (s .&. 0x00000fc0) `shiftL` 4
          , fromIntegral $ (s .&. 0x0000003f) `shiftL` 10
          ] ++ f xs
    f _ = []
    in f $ drop 1 $ B.unpack src
  , B.head src
  )
blockInflater n _ = error $ "Missing blockInflater for " <> show n <> " bits"

gainFactor :: [(Int16, Int16)]
gainFactor =
  [ (  0,    0)
  , (240,    0)
  , (460, -208)
  , (392, -220)
  , (488, -240)
  ]

decodeInflated :: (MonadIO m) => [Int16] -> Int -> Word8 -> StateT [XAState] m (V.Vector Int16)
decodeInflated shorts channel prof = let
  (k0, k1) = gainFactor !! fromIntegral (prof `shiftR` 4)
  range = fromIntegral $ prof .&. 0xF
  in fmap V.fromList $ forM shorts $ \short -> do
    XAState prev0 prev1 <- gets (!! channel)
    let ranged = fromIntegral $ short `shiftR` range :: Int32
        sampleGain = fromIntegral prev0 * fromIntegral k0 + fromIntegral prev1 * fromIntegral k1 :: Int32
        sample = ranged + quot sampleGain 256
        sample' = if sample > fromIntegral (maxBound :: Int16)
          then maxBound
          else if sample < fromIntegral (minBound :: Int16)
            then minBound
            else fromIntegral sample
    modify $ let
      f i s = if i == channel
        then XAState sample' prev0
        else s
      in zipWith f [0..]
    return sample'

sourceXA :: (MonadIO f, MonadResource m) => FilePath -> f (AudioSource m Int16)
sourceXA f = do
  headerBytes <- liftIO $ withBinaryFile f ReadMode $ \h -> BL.hGet h headerSizeXA
  let readHeader = do
        "KWD1"        <- getByteString 4
        dataLength <- fromIntegral <$> getWord32le
        samples    <- fromIntegral <$> getWord32le
        rate       <- fromIntegral <$> getWord16le
        bits       <- fromIntegral <$> getWord8
        channels   <- fromIntegral <$> getWord8
        initState  <- replicateM channels $ do
          prev0 <- getInt16le
          prev1 <- getInt16le
          return XAState{..}
        let blockSize   = bits * 4 + 1
            blockSizeXA = blockSize * channels
        return XAHeader{..}
  xa <- case runGetOrFail readHeader headerBytes of
    Left  (_, _, err) -> liftIO $ ioError $ userError $ "[" <> f <> "] " <> err
    Right (_, _, x  ) -> return x
  return AudioSource
    { rate     = xa.rate
    , frames   = xa.samples
    , channels = xa.channels
    , source   = C.bracketP
      (openBinaryFile f ReadMode)
      hClose
      $ \h -> liftIO (hSeek h AbsoluteSeek $ fromIntegral headerSizeXA) >> let
        numBlocks = xa.dataLength `quot` xa.blockSize
        go blocksLeft samplesLeft
          | blocksLeft  <= 0 = return ()
          | samplesLeft <= 0 = return ()
          | otherwise        = do
            blocks <- fmap (map $ V.take samplesLeft) $
              forM [0 .. xa.channels - 1] $ \i -> do
                block <- liftIO $ B.hGet h xa.blockSize
                let (shorts, prof) = blockInflater xa.bits block
                decodeInflated shorts i prof
            lift $ yield $ case blocks of
              [x] -> x
              _   -> interleave blocks
            go (blocksLeft - 1) (samplesLeft - blockSamplesXA)
        in evalStateT (go numBlocks xa.samples) xa.initState
    }

headerSizeXA :: Int
headerSizeXA = 32

blockSamplesXA :: Int
blockSamplesXA = 32
