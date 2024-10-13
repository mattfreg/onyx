{-# LANGUAGE CPP          #-}
{-# LANGUAGE LambdaCase   #-}
{-# LANGUAGE ViewPatterns #-}
-- | OS-specific functions to open and show files.
module Onyx.Util.Files (osOpenFile, osShowFolder, commonDir, fixFileCase, copyDirRecursive, copyDirRecursiveMergeDTA, shortWindowsPath) where

import           Control.Monad            (forM_)
import           Control.Monad.IO.Class   (MonadIO (..))
import qualified Data.ByteString.Char8    as B8
import qualified System.Directory         as Dir
import           System.FilePath          (takeDirectory, takeExtension, (</>))

-- Windows only
#ifdef WINDOWS
import           Control.Monad            (when)
import           Data.List                (intercalate)
import           Data.List.Split          (splitOn)
import           Foreign                  (Ptr, nullPtr, ptrToIntPtr,
                                           withArrayLen, withMany)
import           Foreign.C                (CInt (..), CWString, withCWString)
import           Graphics.Win32.GDI.Types (HWND)
import           System.IO                (IOMode (ReadWriteMode),
                                           withBinaryFile)
import           System.Win32.Info        (getShortPathName)
import           System.Win32.Types       (HINSTANCE, INT, LPCWSTR)

-- Mac/Linux only
#else
import           System.Process           (callProcess)

-- Mac only
#ifdef MACOSX
import           Foreign                  (Ptr, withArrayLen, withMany)
import           Foreign.C                (CInt (..), CString, withCString)

-- Linux only
#else
import           Data.Maybe               (fromMaybe)
import qualified Data.Text                as T
import           System.Directory         (doesPathExist, listDirectory)
import           System.FilePath          (dropTrailingPathSeparator,
                                           splitFileName)
import           System.Info              (os)
import           System.IO                (stderr, stdout)
import           System.IO.Silently       (hSilence)

#endif
#endif

copyDirRecursive :: (MonadIO m) => FilePath -> FilePath -> m ()
copyDirRecursive src dst = liftIO $ do
  Dir.createDirectoryIfMissing False dst
  ents <- Dir.listDirectory src
  forM_ ents $ \ent -> do
    let pathFrom = src </> ent
        pathTo = dst </> ent
    isDir <- Dir.doesDirectoryExist pathFrom
    if isDir
      then copyDirRecursive pathFrom pathTo
      else Dir.copyFile pathFrom pathTo

copyDirRecursiveMergeDTA :: (MonadIO m) => FilePath -> FilePath -> m ()
copyDirRecursiveMergeDTA src dst = liftIO $ do
  Dir.createDirectoryIfMissing False dst
  ents <- Dir.listDirectory src
  forM_ ents $ \ent -> do
    let pathFrom = src </> ent
        pathTo = dst </> ent
    isDir <- Dir.doesDirectoryExist pathFrom
    destExists <- Dir.doesFileExist pathTo
    if isDir
      then copyDirRecursiveMergeDTA pathFrom pathTo
      else if takeExtension pathTo == ".dta" && destExists
        then do
          x <- B8.readFile pathFrom
          y <- B8.readFile pathTo
          B8.writeFile pathTo $ x <> B8.singleton '\n' <> y
        else Dir.copyFile pathFrom pathTo

osOpenFile :: (MonadIO m) => FilePath -> m ()
osShowFolder :: (MonadIO m) => FilePath -> [FilePath] -> m ()

commonDir :: [FilePath] -> IO (Maybe (FilePath, [FilePath]))
commonDir fs = do
  fs' <- liftIO $ mapM Dir.makeAbsolute fs
  return $ case map takeDirectory fs' of
    dir : dirs | all (== dir) dirs -> Just (dir, fs')
    _                              -> Nothing

-- | On case-sensitive systems, finds a file in a case-insensitive manner.
fixFileCase :: (MonadIO m) => FilePath -> m FilePath

-- | On Windows, get a DOS short path so Unixy C code can deal with it.
-- TODO this doesn't consistently work!
-- For example short paths are not enabled by default on non-system drive letters.
-- The only consistent solution is to read files on the Haskell side instead of C.
shortWindowsPath :: (MonadIO m) => Bool -> FilePath -> m FilePath

#ifdef WINDOWS

-- note, on 32-bit this needed to be stdcall (Win32 package uses CPP to switch this)
-- but we're not supporting 32-bit anymore
foreign import ccall safe "ShellExecuteW"
  c_ShellExecute :: HWND -> LPCWSTR -> LPCWSTR -> LPCWSTR -> LPCWSTR -> INT -> IO HINSTANCE

foreign import ccall safe "onyx_ShowFiles"
  c_ShowFiles :: CWString -> Ptr CWString -> CInt -> IO ()

osOpenFile f = liftIO $ withCWString f $ \wstr -> do
  -- COM must be init'd before this. we now do this in onyxInitCOM in win_open_folder.cpp
  n <- c_ShellExecute nullPtr nullPtr wstr nullPtr nullPtr 5
  if ptrToIntPtr n > 32
    then return ()
    else error $ "osOpenFile: ShellExecuteW return code " ++ show n

osShowFolder dir [] = osOpenFile dir
osShowFolder dir fs = liftIO $
  withCWString dir $ \cdir ->
  withMany withCWString fs $ \cfiles ->
  withArrayLen cfiles $ \len pcfiles ->
  c_ShowFiles cdir pcfiles $ fromIntegral len

fixFileCase = return

shortWindowsPath create f = liftIO $ do
  -- First ensure the file exists (if we're intending to write to it)
  when create $ withBinaryFile f ReadWriteMode $ \_ -> return ()
  -- Can't use forward slashes, you get invalid path error
  let allBackslash = intercalate "\\" $ splitOn "/" f
  -- The weird prefix lets you go beyond MAX_PATH
  getShortPathName $ "\\\\?\\" <> allBackslash

#else

#ifdef MACOSX

osOpenFile f = liftIO $ callProcess "open" [f]

foreign import ccall safe "onyx_ShowFiles"
  c_ShowFiles :: Ptr CString -> CInt -> IO ()

osShowFolder dir [] = osOpenFile dir
osShowFolder _   fs = do
  liftIO $ withMany withCString fs $ \cstrs -> do
    withArrayLen cstrs $ \len pcstrs -> do
      c_ShowFiles pcstrs $ fromIntegral len

fixFileCase = return

shortWindowsPath _ = return

#else

-- TODO this should be done on a forked thread

osOpenFile f = liftIO $ case os of
  "linux" -> hSilence [stdout, stderr] $ callProcess "xdg-open" [f]
  _       -> return ()

osShowFolder dir _ = osOpenFile dir

fixFileCase f = fromMaybe f <$> fixFileCaseMaybe f

fixFileCaseMaybe :: (MonadIO m) => FilePath -> m (Maybe FilePath)
fixFileCaseMaybe (dropTrailingPathSeparator -> f) = liftIO $ do
  let (dropTrailingPathSeparator -> dir, entry) = splitFileName f
  doesPathExist f >>= \case
    True -> return $ Just f -- entry exists, no problem
    False -> if f == dir
      then return Nothing -- we're at root, drive, or cwd, and it doesn't exist
      else fixFileCaseMaybe dir >>= \case
        Nothing -> return Nothing -- dir doesn't exist
        Just dir' -> do
          -- dir exists, now we need to look for entry
          entries <- listDirectory dir'
          let compForm = T.toCaseFold . T.pack
              entry' = compForm entry
          case filter ((== entry') . compForm) entries of
            []    -> return Nothing
            e : _ -> return $ Just $ dir' </> e

shortWindowsPath _ = return

#endif

#endif
