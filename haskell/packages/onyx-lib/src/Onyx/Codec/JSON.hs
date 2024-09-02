{-# LANGUAGE DefaultSignatures #-}
{-# LANGUAGE LambdaCase        #-}
{-# LANGUAGE PatternSynonyms   #-}
{-# LANGUAGE ViewPatterns      #-}
module Onyx.Codec.JSON where

import           Control.Applicative        (liftA2)
import qualified Control.Exception          as Exc
import           Control.Monad              (forM, unless)
import           Control.Monad.Codec
import           Control.Monad.IO.Class     (MonadIO)
import           Control.Monad.Trans.Class  (lift)
import           Control.Monad.Trans.Reader
import           Control.Monad.Trans.State
import qualified Data.Aeson                 as A
import qualified Data.Aeson.KeyMap          as KM
import qualified Data.ByteString            as B
import qualified Data.ByteString.Lazy       as BL
import           Data.Fixed                 (Fixed, HasResolution)
import qualified Data.HashMap.Strict        as HM
import qualified Data.HashSet               as HS
import           Data.List.NonEmpty         (NonEmpty ((:|)))
import qualified Data.List.NonEmpty         as NE
import           Data.Profunctor            (dimap)
import           Data.Scientific
import qualified Data.Text                  as T
import qualified Data.Text.Encoding         as TE
import qualified Data.Vector                as V
import qualified Data.Yaml                  as Y
import           Onyx.Codec.Common
import           Onyx.StackTrace
import           Onyx.YAMLTree              (readYAMLTree)

type JSONCodec m a = ValueCodec m A.Value a

class StackJSON a where
  stackJSON :: (SendMessage m) => JSONCodec m a
  default stackJSON :: (A.ToJSON a, A.FromJSON a, SendMessage m) => JSONCodec m a
  stackJSON = aesonCodec

  stackJSONList :: (SendMessage m) => JSONCodec m [a]
  stackJSONList = listCodec stackJSON

fuzzy :: (Monad m) => T.Text -> JSONCodec m ()
fuzzy s = Codec
  { codecOut = makeOut $ \() -> A.String s
  , codecIn = let
    f = T.toLower . T.filter (/= ' ')
    s' = f s
    in lift ask >>= \case
      A.String t -> if f t == s'
        then return ()
        else expected $ show s
      _ -> expected "a string"
  }

aesonCodec :: (A.ToJSON a, A.FromJSON a, Monad m) => JSONCodec m a
aesonCodec = Codec
  { codecOut = makeOut A.toJSON
  , codecIn = lift ask >>= \v -> case A.fromJSON v of
    A.Success x -> return x
    A.Error err -> fatal err
  }

listCodec :: (Monad m) => JSONCodec m a -> JSONCodec m [a]
listCodec elt = Codec
  { codecOut = makeOut $ A.Array . V.fromList . map (makeValue' elt)
  , codecIn = lift ask >>= \case
    A.Array vect -> forM (zip [0..] $ V.toList vect) $ \(i, x) ->
      inside ("array element " ++ show (i :: Int)) $
        parseFrom x $ codecIn elt
    _ -> expected "array"
  }

asObject :: (Monad m) => T.Text -> ObjectCodec m A.Value a -> JSONCodec m a
asObject err codec = Codec
  { codecIn = inside ("parsing " ++ T.unpack err) $ lift ask >>= \case
    A.Object obj -> let
      f = withReaderT (const $ KM.toHashMapText obj) . mapReaderT (`evalStateT` HS.empty)
      in mapStackTraceT f $ codecIn codec
    _ -> expected "object"
  , codecOut = makeOut $ A.Object . KM.fromHashMapText . HM.fromList . makeObject codec
  }

asStrictObject :: (Monad m) => T.Text -> ObjectCodec m A.Value a -> JSONCodec m a
asStrictObject err codec = asObject err Codec
  { codecOut = codecOut codec
  , codecIn = codecIn codec <* strictKeys
  }

object :: (Monad m) => StackParser m (HM.HashMap T.Text A.Value) a -> StackParser m A.Value a
object p = lift ask >>= \case
  A.Object o -> parseFrom (KM.toHashMapText o) p
  _          -> expected "an object"

-- TODO cleanup
requiredKey :: (Monad m) => T.Text -> StackParser m A.Value a -> StackParser m (HM.HashMap T.Text A.Value) a
requiredKey k p = lift ask >>= \hm -> case HM.lookup k hm of
  Nothing -> parseFrom (A.Object $ KM.fromHashMapText hm) $
    expected $ "to find required key " ++ show k ++ " in object"
  Just v  -> inside ("required key " ++ show k) $ parseFrom v p

-- TODO cleanup
optionalKey :: (Monad m) => T.Text -> StackParser m A.Value a -> StackParser m (HM.HashMap T.Text A.Value) (Maybe a)
optionalKey k p = lift ask >>= \hm -> case HM.lookup k hm of
  Nothing -> return Nothing
  Just v  -> fmap Just $ inside ("optional key " ++ show k) $ parseFrom v p

-- TODO cleanup
expectedKeys :: (Monad m) => [T.Text] -> StackParser m (HM.HashMap T.Text A.Value) ()
expectedKeys keys = do
  hm <- lift ask
  let unknown = HS.fromList (HM.keys hm) `HS.difference` HS.fromList keys
  unless (HS.null unknown) $ fatal $ "Unrecognized object keys: " ++ show (HS.toList unknown)

instance StackJSON Int
instance StackJSON Integer
instance StackJSON Scientific
instance StackJSON Double
instance StackJSON Float
instance (HasResolution a) => StackJSON (Fixed a)
instance StackJSON T.Text
instance StackJSON Bool
instance StackJSON A.Value

instance (StackJSON a) => StackJSON [a] where
  stackJSON = stackJSONList

instance (StackJSON a) => StackJSON (NonEmpty a) where
  stackJSON = Codec
    { codecIn = codecIn c >>= \case
      x : xs -> return $ x :| xs
      []     -> expected "non-empty array"
    , codecOut = makeOut $ makeValue' c . NE.toList
    } where c = stackJSONList

instance (StackJSON a) => StackJSON (V.Vector a) where
  stackJSON = dimap V.toList V.fromList stackJSONList

instance StackJSON Char where
  stackJSONList = aesonCodec

instance (StackJSON a, StackJSON b) => StackJSON (Either a b) where
  stackJSON = eitherCodec stackJSON stackJSON

maybeCodec :: (Monad m) => JSONCodec m a -> JSONCodec m (Maybe a)
maybeCodec c = Codec
  { codecOut = makeOut $ maybe A.Null $ makeValue' c
  , codecIn = lift ask >>= \case
    A.Null -> return Nothing
    _      -> Just <$> codecIn c
  }

instance (StackJSON a) => StackJSON (Maybe a) where
  stackJSON = maybeCodec stackJSON

onlyKey :: (Monad m) => T.Text -> StackParser m A.Value a -> StackParser m (HM.HashMap T.Text A.Value) a
onlyKey k p = lift ask >>= \hm -> case HM.toList hm of
  [(k', v)] | k == k' -> inside ("only key " ++ show k) $ parseFrom v p
  _ -> parseFrom (A.Object $ KM.fromHashMapText hm) $
    expected $ "to find only key " ++ show k ++ " in object"

mapping :: (Monad m) => StackParser m A.Value a -> StackParser m A.Value (HM.HashMap T.Text a)
mapping p = lift ask >>= \case
  A.Object o -> HM.traverseWithKey (\k x -> inside ("mapping key " ++ show k) $ parseFrom x p) $ KM.toHashMapText o
  _          -> expected "an object"

mappingToJSON :: (StackJSON a) => HM.HashMap T.Text a -> A.Value
mappingToJSON = A.toJSON . fmap toJSON

dict :: (Monad m) => JSONCodec m a -> JSONCodec m (HM.HashMap T.Text a)
dict c = Codec
  { codecOut = makeOut $ A.toJSON . fmap (makeValue' c)
  , codecIn = mapping $ codecIn c
  }

pattern OneKey :: T.Text -> A.Value -> A.Value
pattern OneKey k v <- A.Object (HM.toList . KM.toHashMapText -> [(k, v)]) where
  OneKey k v = A.Object $ KM.fromHashMapText $ HM.fromList [(k, v)]

pair :: (Monad m) => JSONCodec m a -> JSONCodec m b -> JSONCodec m (a, b)
pair xf yf = Codec
  { codecOut = makeOut $ \(x, y) -> toJSON [makeValue' xf x, makeValue' yf y]
  , codecIn = lift ask >>= \case
    A.Array (V.toList -> [x, y]) -> liftA2 (,)
      (inside "first item of a pair"  $ parseFrom x $ codecIn xf)
      (inside "second item of a pair" $ parseFrom y $ codecIn yf)
    _ -> expected "exactly 2 chunks"
  }

instance (StackJSON a, StackJSON b) => StackJSON (a, b) where
  stackJSON = pair stackJSON stackJSON

-- TODO find a safer way to do this
fromEmptyObject :: (StackJSON a) => a
fromEmptyObject = case runPureLog $ runReaderT (runStackTraceT $ codecIn stackJSON) $ A.object [] of
  (Right x , _) -> x
  (Left err, _) -> error $ Exc.displayException err

toJSON :: (StackJSON a) => a -> A.Value
toJSON = makeValue stackJSON

fromJSON :: (SendMessage m, StackJSON a) => StackParser m A.Value a
fromJSON = codecIn stackJSON

-- | 'Y.encodeFile' as of 2019-09-18 has been observed to be bugged on Windows,
-- because it does not truncate or remove an existing file at the location.
yamlEncodeFile :: (Y.ToJSON a) => FilePath -> a -> IO ()
yamlEncodeFile f x = B.writeFile f $ Y.encode x

loadYaml :: (SendMessage m, StackJSON a, MonadIO m) => FilePath -> StackTraceT m a
loadYaml fp = do
  yaml <- readYAMLTree fp
  mapStackTraceT (`runReaderT` yaml) fromJSON

-- This should use Data.Aeson.eitherDecodeStrictText but we need to upgrade (all platforms) to aeson-2.2.1.0 first
decodeJSONText :: (MonadFail m) => T.Text -> m A.Value
decodeJSONText t = either fail return $ A.eitherDecodeStrict' $ TE.encodeUtf8 t

embeddedJSON :: (SendMessage m) => JSONCodec m a -> JSONCodec m a
embeddedJSON c = Codec
  { codecIn = codecIn stackJSON >>= \t -> case A.decodeStrict $ TE.encodeUtf8 t of
    Nothing       -> fail $ "Couldn't decode embedded JSON string: " <> show t
    Just newValue -> inside "embedded JSON" $ parseFrom newValue $ codecIn c
  , codecOut = makeOut $ A.toJSON . TE.decodeUtf8 . BL.toStrict . A.encode . makeValue' c
  }
