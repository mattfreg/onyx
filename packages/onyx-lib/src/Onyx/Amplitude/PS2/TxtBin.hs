-- gen/*.txt.bin files (and other *.bin)
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE LambdaCase            #-}
{-# LANGUAGE NoFieldSelectors      #-}
{-# LANGUAGE OverloadedRecordDot   #-}
{-# LANGUAGE OverloadedStrings     #-}
{-# LANGUAGE RecordWildCards       #-}
{-# LANGUAGE StrictData            #-}
module Onyx.Amplitude.PS2.TxtBin
( TxtBin(..), Node(..), NodeContents(..)
, getTxtBin, putTxtBin
, txtBinToDTA, txtBinToTracedDTA, dtaToTxtBin
) where

import           Control.Monad.Extra       (forM, forM_, mapMaybeM, replicateM)
import           Control.Monad.Trans.Class (lift)
import           Control.Monad.Trans.State
import           Data.Binary.Get
import           Data.Binary.Put
import           Data.Bits
import qualified Data.ByteString           as B
import qualified Data.ByteString.Char8     as B8
import qualified Data.ByteString.Lazy      as BL
import           Data.Int
import           Data.List.Extra           (chunksOf, foldl', nubOrd)
import qualified Data.Map                  as Map
import           Data.Maybe                (fromMaybe)
import           Data.Word
import qualified Onyx.Harmonix.DTA         as D
import           Onyx.StackTrace

data TxtBin = TxtBin
  { sources :: [B.ByteString]
  , node    :: Node
  } deriving (Show)

data Node = Node
  { lineNumber :: Word32
  -- ^ don't have the source files to check but this seems plausible
  -- to use line number in error screens
  , fileIndex  :: Word32
  -- ^ pretty sure this is file index since e.g. default_config.txt.bin
  -- has numbers 0 to 29, and 30 entries in source files list
  , contents   :: [NodeContents]
  } deriving (Show)

data NodeContents
  = I Int32
  | S B.ByteString
  | F Float
  | N Node
  deriving (Show)

getLenStr :: Get B.ByteString
getLenStr = do
  len <- getWord32le
  getByteString $ fromIntegral len

getTxtBin :: Get TxtBin
getTxtBin = do
  2 <- getWord8
  sources <- getWord32le >>= \n -> replicateM (fromIntegral n) getLenStr
  node <- getNode
  return TxtBin{..}

getNode :: Get Node
getNode = do
  len <- fromIntegral <$> getWord16le
  id1 <- getWord32le
  id2 <- getWord32le
  let numTypeWords = case quotRem len 16 of
        (n, 0) -> n
        (n, _) -> n + 1
  typeWords <- replicateM numTypeWords getWord32le
  contents <- forM [0 .. len - 1] $ \i -> do
    let typeTag = case quotRem i 16 of
          (x, y) -> ((typeWords !! x) `shiftR` (y * 2)) .&. 0x3
    case typeTag of
      0 -> I <$> getInt32le
      1 -> S <$> getLenStr
      2 -> F <$> getFloatle
      3 -> N <$> getNode
      _ -> fail "shouldn't happen"
  return $ Node id1 id2 contents

putTxtBin :: TxtBin -> BL.ByteString
putTxtBin tb = runPut $ do

  let putLenStr :: B.ByteString -> Put
      putLenStr b = do
        putWord32le $ fromIntegral $ B.length b
        putByteString b

  putWord8 2
  putWord32le $ fromIntegral $ length tb.sources
  mapM_ putLenStr tb.sources

  let putNode :: Node -> Put
      putNode node = do
        let numChildren = length node.contents
        putWord16le $ fromIntegral numChildren
        putWord32le node.lineNumber
        putWord32le node.fileIndex
        let typeTags = map (\case
              I _ -> 0
              S _ -> 1
              F _ -> 2
              N _ -> 3
              ) node.contents <> repeat 0
            numTypeBytes = case quotRem numChildren 16 of
              (n, 0) -> n       * 4
              (n, _) -> (n + 1) * 4
            typeBytes = take numTypeBytes
              $ map (\tags -> sum $ zipWith shiftL tags [0, 2, 4, 6])
              $ chunksOf 4 typeTags
        mapM_ putWord8 typeBytes
        forM_ node.contents $ \case
          I int -> putInt32le int
          S str -> putLenStr str
          F flt -> putFloatle flt
          N sub -> putNode sub

  putNode tb.node

-- Discards source and line number info
txtBinToDTA :: TxtBin -> D.DTA B.ByteString
txtBinToDTA tb = let
  encodeNode (Node _ _ vals) = flip map vals $ \case
    I int  -> D.Int int
    S str  -> if B8.elem ' ' str || B8.elem '\'' str || B8.elem '\n' str
      then D.String str
      else D.Sym str
    F flt  -> D.Float flt
    N node -> D.Parens $ D.Tree 0 $ encodeNode node
  in D.DTA 0 $ D.Tree 0 $ encodeNode tb.node

-- Includes source and line number info
txtBinToTracedDTA :: TxtBin -> D.DTA B.ByteString
txtBinToTracedDTA tb = let
  sourceList = D.Braces $ D.Tree 0 $ map D.String tb.sources
  encodeNode (Node x y vals) = let
    traceNumbers = D.Brackets $ D.Tree 0
      [ D.Int $ fromIntegral x
      , D.Int $ fromIntegral y
      ]
    in (traceNumbers :) $ flip map vals $ \case
      I int  -> D.Int int
      S str  -> if B8.elem ' ' str || B8.elem '\'' str || B8.elem '\n' str
        then D.String str
        else D.Sym str
      F flt  -> D.Float flt
      N node -> D.Parens $ D.Tree 0 $ encodeNode node
  in D.DTA 0 $ D.Tree 0 $ sourceList : encodeNode tb.node

newtype TraceState = TraceState
  { nextLineForFile :: Map.Map Word32 Word32
  }

-- supported trace info formats:
-- ([x y] ...) exact line and file numbers
-- ([y] ...)   y is file index, generate unique line number
-- (...)       0 is file index, generate unique line number

dtaToTxtBin :: (SendMessage m) => D.DTA B.ByteString -> StackTraceT m TxtBin
dtaToTxtBin (D.DTA _ (D.Tree _ root)) = do
  (sourceList, root') <- case root of
    D.Braces (D.Tree _ sourceChunks) : rest -> do
      sources <- flip mapMaybeM sourceChunks $ \case
        D.String s -> return $ Just s
        D.Sym s -> return $ Just s
        x -> do
          warn $ "Unrecognized source file reference (expected string): " <> show x
          return Nothing
      return (sources, rest)
    _ -> return (["(onyx dta-to-bin)"], root)

  let exactTraceInfo :: [(Word32, Word32)]
      exactTraceInfo = root >>= getExactTraceInfo
      getExactTraceInfo = \case
        D.Brackets (D.Tree _ [D.Int x, D.Int y]) -> [(fromIntegral x, fromIntegral y)]
        D.Parens (D.Tree _ xs) -> xs >>= getExactTraceInfo
        _ -> []
      fileIndexes = nubOrd $ map snd exactTraceInfo
      initialTraceState = TraceState $ Map.fromList $ do
        i <- fileIndexes
        return (i, foldl' max 0 [ line | (line, j) <- exactTraceInfo, i == j ] + 1)

      makeNode chunks = do
        let freshLine fileIndex rest = do
              ts <- lift get
              let x = fromMaybe 1 $ Map.lookup fileIndex ts.nextLineForFile
              lift $ put $ TraceState $ Map.insert fileIndex (x + 1) ts.nextLineForFile
              return (x, fileIndex, rest)
        (x, y, chunks') <- case chunks of
          D.Brackets (D.Tree _ [D.Int x, D.Int y]) : rest ->
            return (fromIntegral x, fromIntegral y, rest)
          D.Brackets (D.Tree _ [D.Int y]) : rest -> freshLine (fromIntegral y) rest
          _ -> freshLine 0 chunks
        contents <- flip mapMaybeM chunks' $ \case
          D.Int      int             -> return $ Just $ I int
          D.Sym      str             -> return $ Just $ S str
          D.String   str             -> return $ Just $ S str
          D.Float    flt             -> return $ Just $ F flt
          D.Parens   (D.Tree _ tree) -> Just . N <$> makeNode tree
          chunk                      -> do
            warn $ "Unrecognized DTA chunk for .bin conversion: " <> show chunk
            return Nothing
        return $ Node x y contents

  TxtBin sourceList <$> mapStackTraceT (`evalStateT` initialTraceState) (makeNode root')
