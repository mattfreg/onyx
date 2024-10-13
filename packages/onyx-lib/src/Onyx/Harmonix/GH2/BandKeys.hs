{- |
BAND KEYS
-}
{-# LANGUAGE DeriveGeneric      #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE DerivingVia        #-}
{-# LANGUAGE OverloadedStrings  #-}
{-# LANGUAGE RecordWildCards    #-}
module Onyx.Harmonix.GH2.BandKeys where

import           Control.Monad.Codec
import qualified Data.EventList.Relative.TimeBody as RTB
import           GHC.Generics                     (Generic)
import           Onyx.DeriveHelpers
import           Onyx.Harmonix.GH2.PartGuitar     (Tempo (..))
import           Onyx.MIDI.Read

data BandKeysTrack t = BandKeysTrack
  { keysTempo :: RTB.T t Tempo
  , keysIdle  :: RTB.T t ()
  , keysPlay  :: RTB.T t ()
  } deriving (Eq, Ord, Show, Generic)
    deriving (Semigroup, Monoid, Mergeable) via GenericMerge (BandKeysTrack t)

instance TraverseTrack BandKeysTrack where
  traverseTrack fn (BandKeysTrack a b c) = BandKeysTrack
    <$> fn a <*> fn b <*> fn c

instance ParseTrack BandKeysTrack where
  parseTrack = do
    keysTempo    <- keysTempo    =. command
    -- didn't actually see double tempo on keys
    keysIdle     <- keysIdle     =. commandMatch ["idle"]
    keysPlay     <- keysPlay     =. commandMatch ["play"]
    return BandKeysTrack{..}
