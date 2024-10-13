{-# LANGUAGE LambdaCase          #-}
{-# LANGUAGE NoFieldSelectors    #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE RecordWildCards     #-}
module Onyx.Neversoft.Pak where

import qualified Codec.Compression.Zlib.Internal as Z
import           Control.Monad                   (forM, forM_, guard,
                                                  replicateM)
import           Control.Monad.ST.Lazy           (runST)
import           Data.Binary.Get
import           Data.Binary.Put
import           Data.Bits                       ((.&.))
import qualified Data.ByteString                 as B
import qualified Data.ByteString.Lazy            as BL
import           Data.Char                       (isAscii, isSpace)
import qualified Data.HashMap.Strict             as HM
import           Data.List                       (sortOn)
import           Data.Maybe                      (fromMaybe, isJust,
                                                  listToMaybe)
import qualified Data.Text                       as T
import qualified Data.Text.Encoding              as TE
import           Data.Word
import           GHC.ByteOrder
import           Numeric                         (readHex, showHex)
import           Onyx.Neversoft.CRC              (QBKey (..), putQBKeyBE)
import           Onyx.StackTrace                 (SendMessage, StackTraceT,
                                                  errorToEither, fatal, inside,
                                                  warnNoContext)
import           Onyx.Util.Binary                (runGetM)

data Node = Node
  { nodeFileType       :: QBKey
  , nodeOffset         :: Word32
  , nodeSize           :: Word32
  , nodeFilenamePakKey :: QBKey
  , nodeFilenameKey    :: QBKey
  , nodeFilenameCRC    :: QBKey
  , nodeUnknown        :: Word32
  , nodeFlags          :: Word32
  , nodeName           :: Maybe B.ByteString -- snippet of filename seen in PS2 GH3 when flags (LE) is 0x20
  } deriving (Show, Read)

-- Credit to unpak.pl by Tarragon Allen (tma).
-- Used in GHWT and onward.
decompressPakGH4 :: (MonadFail m) => BL.ByteString -> m BL.ByteString
decompressPakGH4 bs = do
  -- conveniently, start and next are relative to this CHNK, not the whole file
  [magic, start, len, next, _flags, _size] <- runGetM (replicateM 6 getWord32be) bs
  if magic /= 0x43484e4b -- CHNK
    then return BL.empty
    else do
      let buf = BL.take (fromIntegral len) $ BL.drop (fromIntegral start) bs
      dec <- tryDecompress Z.rawFormat False buf
      case next of
        0xffffffff -> return dec
        _          -> (dec <>) <$> decompressPakGH4 (BL.drop (fromIntegral next) bs)

-- TODO this apparently doesn't work for PS3 ("invalid block type") at least qb.pab.ps3
decompressPakGH3 :: (MonadFail m) => BL.ByteString -> m BL.ByteString
decompressPakGH3 bs = tryDecompress Z.zlibFormat True $ BL.pack [0x58, 0x85] <> bs

-- decompresses stream, optionally ignores "input ended prematurely" error
tryDecompress :: (MonadFail m) => Z.Format -> Bool -> BL.ByteString -> m BL.ByteString
tryDecompress format ignoreTruncate bs = either fail return $ runST $ let
  go input output = \case
    Z.DecompressInputRequired f                               -> case input of
      []     -> f B.empty >>= go [] output
      x : xs -> f x       >>= go xs output
    Z.DecompressOutputAvailable out getNext                   -> do
      next <- getNext
      go input (out : output) next
    Z.DecompressStreamEnd _unread                             -> return $ Right $ BL.fromChunks $ reverse output
    Z.DecompressStreamError Z.TruncatedInput | ignoreTruncate -> return $ Right $ BL.fromChunks $ reverse output
    Z.DecompressStreamError err                               -> return $
      Left $ "Decompression error: " <> show err
  in go (BL.toChunks bs) [] $ Z.decompressST format Z.defaultDecompressParams

decompressPak :: (MonadFail m) => BL.ByteString -> m BL.ByteString
decompressPak bs = if BL.take 4 bs == "CHNK"
  then decompressPakGH4 bs
  else return $ fromMaybe bs $ decompressPakGH3 bs -- if gh3 decompression fails, assume it's uncompressed

-- .pak header values are big endian on 360/PS3, but little on PS2

data PakFormat = PakFormat
  { pakByteOrder     :: ByteOrder
  , pakNewPabOffsets :: Bool
  -- in WoR, pak and pab are processed separately. offsets are always relative to start of pab.
  -- in GH3 it's as if they are one file. offsets are computed just like no-pab pak files.
  } deriving (Show)

pakFormatGH3 :: ByteOrder -> PakFormat
pakFormatGH3 endian = PakFormat { pakByteOrder = endian, pakNewPabOffsets = False }

pakFormatWoR :: PakFormat
pakFormatWoR = PakFormat { pakByteOrder = BigEndian, pakNewPabOffsets = True }

getPakNodes :: (MonadFail m) => PakFormat -> Bool -> BL.ByteString -> m [Node]
getPakNodes fmt hasPab = runGetM $ let
  go = do
    posnOffset <- if hasPab && fmt.pakNewPabOffsets
      then return 0
      else fromIntegral <$> bytesRead
    let getW32 = case fmt.pakByteOrder of
          BigEndian    -> getWord32be
          LittleEndian -> getWord32le
        getQBKey = QBKey <$> getW32
    nodeFileType       <- getQBKey
    nodeOffset         <- (+ posnOffset) <$> getW32
    nodeSize           <- getW32
    nodeFilenamePakKey <- getQBKey
    nodeFilenameKey    <- getQBKey
    nodeFilenameCRC    <- getQBKey
    nodeUnknown        <- getW32
    nodeFlags          <- getW32
    nodeName           <- if nodeFlags .&. 0x20 == 0x20
      then Just . B.takeWhile (/= 0) <$> getByteString 0xA0
      else return Nothing
    (Node{..} :) <$> if elem nodeFileType ["last", ".last"]
      then return []
      else go
  in go

splitPakNodes :: (MonadFail m) => PakFormat -> BL.ByteString -> Maybe BL.ByteString -> m [(Node, BL.ByteString)]
splitPakNodes _ pak _
  | "\\\\Dummy file" `BL.isPrefixOf` pak
  -- these are seen in GH3 PS2, songs/*_{gfx,sfx}.pak.ps2
  = return []
splitPakNodes fmt pak maybePab = do
  pak'      <- decompressPak pak
  maybePab' <- mapM decompressPak maybePab
  nodes     <- getPakNodes fmt (isJust maybePab') pak'
  let dataSection = case maybePab' of
        Nothing  -> pak'
        Just pab -> if fmt.pakNewPabOffsets
          then pab
          else let
            -- in GHWT qb.pak.xen, the pak is 0x10000 bytes long.
            -- but the offsets in the pab start at 0x9000
            -- (the 0x1000-multiple after the last node details).
            -- we could either do that, or the below, where hopefully we can
            -- assume the first node is at the start of the pab.
            -- ...nevermind, gh3 ps2 DATAP/zones/global/global_net.pak.ps2
            -- has a useless pab we should ignore? very strange
            specifiedPakLength = case nodes of
              node : _ -> fromIntegral node.nodeOffset
              []       -> 0
            in BL.take specifiedPakLength pak' <> pab
      attachData :: Node -> (Node, BL.ByteString)
      attachData node = let
        goToData
          = BL.take (fromIntegral node.nodeSize  )
          . BL.drop (fromIntegral node.nodeOffset)
        in (node, goToData dataSection)
  return $ map attachData nodes

-- Tries possible pak+pab formats until one parses (seemingly) correctly.
splitPakNodesAuto :: (SendMessage m) => BL.ByteString -> Maybe BL.ByteString -> StackTraceT m ([(Node, BL.ByteString)], PakFormat)
splitPakNodesAuto pak maybePab = let
  tryFormat ctx fmt = errorToEither $ inside ctx $ do
    nodes <- splitPakNodes fmt pak maybePab
    case reverse nodes of
      (node, bs) : _
        | elem node.nodeFileType ["last", ".last"]
          && bs == BL.replicate 4 0xAB
        -> return nodes
      _ -> fatal "Pak didn't contain proper 'last', probably not the right format"
  -- Have to try GH3 format before WoR format; otherwise GH3 can get wrongly detected as WoR
  in if "\\\\Dummy file" `BL.isPrefixOf` pak
    then return ([], pakFormatGH3 LittleEndian)
    else tryFormat ".pak autodetect: GH3 format, little endian" (pakFormatGH3 LittleEndian) >>= \case
      Right result -> return (result, pakFormatGH3 LittleEndian)
      Left err1 -> tryFormat ".pak autodetect: GH3 format, big endian" (pakFormatGH3 BigEndian) >>= \case
        Right result -> return (result, pakFormatGH3 BigEndian)
        Left err2 -> tryFormat ".pak autodetect: WoR format" pakFormatWoR >>= \case
          Right result -> return (result, pakFormatWoR)
          Left err3 -> do
            warnNoContext err1
            warnNoContext err2
            warnNoContext err3
            fatal ".pak format autodetect failed"

buildPak :: [(Node, BL.ByteString)] -> BL.ByteString
buildPak nodes = let
  -- previously sorted according to original position, but don't think it's necessary
  -- nodes' = sortOn (nodeOffset . fst) nodes
  fixNodes _    []                  = []
  fixNodes posn ((node, bs) : rest) = let
    len = fromIntegral $ BL.length bs
    in node
      { nodeOffset = posn
      , nodeSize = len
      } : fixNodes (padLength $ posn + len) rest
  dataStart = 0x1000 -- TODO support if this needs to be higher
  padLength n = 0x10 + case quotRem n 0x10 of
    (_, 0) -> n
    (q, _) -> (q + 1) * 0x10
  padData bs = bs <> let
    len = BL.length bs
    in BL.replicate (padLength len - len) 0
  putHeader (i, Node{..}) = do
    putQBKeyBE nodeFileType
    putWord32be $ nodeOffset - 32 * i
    putWord32be nodeSize
    putQBKeyBE nodeFilenamePakKey
    putQBKeyBE nodeFilenameKey
    putQBKeyBE nodeFilenameCRC
    putWord32be nodeUnknown
    putWord32be nodeFlags
    forM_ nodeName $ \bs -> do
      putByteString bs
      putByteString $ B.replicate (0xA0 - B.length bs) 0
  header = runPut $ mapM_ putHeader $ zip [0..] $ fixNodes dataStart nodes
  header' = BL.take (fromIntegral dataStart) $ header <> BL.replicate (fromIntegral dataStart) 0
  in BL.concat $ [header'] <> map (padData . snd) nodes <> [BL.replicate 0xCF0 0xAB]

qsBank :: [(Node, BL.ByteString)] -> HM.HashMap Word32 T.Text
qsBank nodes = HM.fromList $ do
  (node, nodeData) <- nodes
  guard $ elem node.nodeFileType [".qs.en", ".qs"]
  fromMaybe [] $ parseQS nodeData

parseQS :: BL.ByteString -> Maybe [(Word32, T.Text)]
parseQS bs = do
  t <- if "\xFF\xFE" `BL.isPrefixOf` bs
    then T.stripPrefix "\xFEFF" $ TE.decodeUtf16LE $ BL.toStrict bs
    else return $ TE.decodeLatin1 $ BL.toStrict bs -- ghwt ps2
  fmap concat $ forM (T.lines t) $ \ln ->
    if T.all isSpace ln
      then return []
      else do
        (hex, "") <- listToMaybe $ readHex $ T.unpack $ T.take 8 ln
        str <- T.stripPrefix "\"" (T.strip $ T.drop 8 ln) >>= T.stripSuffix "\""
        return [(hex, str)]

makeQS :: [(Word32, T.Text)] -> BL.ByteString
makeQS entries = BL.fromStrict $ TE.encodeUtf16LE $ let
  lns = T.unlines $ do
    (w, t) <- sortOn snd entries -- Sort not necessary, but official ones are
    let hex = T.pack $ showHex w ""
        hex' = T.replicate (8 - T.length hex) "0" <> hex
    return $ hex' <> " \"" <> t <> "\""
  in "\xFEFF" <> lns <> "\n\n" -- Extra newlines probably not necessary

worMetadataString :: T.Text -> T.Text
worMetadataString = noSortCrash . noBrackets . fancyQuotes where
  -- I don't yet know how to do simple double quotes inside a qs string (if it's possible).
  -- \q \Q \" don't work
  -- So for now, we replace with left/right quotes, which are supported by WoR, in a simple alternating pattern.
  fancyQuotes t
    = T.concat
    $ concat
    $ map (\(x, y) -> [x, y])
    $ zip ("" : cycle ["“", "”"]) (T.splitOn "\"" t)
  -- These aren't in the fonts used for title/artist
  noBrackets = T.replace "[" "(" . T.replace "]" ")"
  -- The first character (after ignored words) of title/artist must be ASCII.
  -- Otherwise WoR crashes when you sort by title/artist in the song list.
  -- Æ and “ were observed to crash; ASCII punctuation appears to be fine.
  -- Likely it's in the code that is supposed to put it under a category header.
  noSortCrash t = case T.stripPrefix "\\L" t of
    Nothing -> noSortCrash' t
    Just t' -> "\\L" <> noSortCrash' t'
  noSortCrash' t = case dropIgnored $ T.unpack $ T.toLower t of
    c : _ -> if isAscii c
      then t
      else ". " <> t
    "" -> "."
  dropIgnored = \case
    -- dunno if any other leading words are ignored
    't' : 'h' : 'e' : ' ' : xs -> dropIgnored xs
    'a' :             ' ' : xs -> dropIgnored xs
    'a' : 'n' :       ' ' : xs -> dropIgnored xs
    xs                         -> xs
