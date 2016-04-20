{-# LANGUAGE GeneralizedNewtypeDeriving #-}

module Main where

import Prelude hiding ((*>))

import Development.Shake
import Data.Hashable (Hashable())
import Data.Typeable (Typeable())
import Data.Binary (Binary())
import Control.DeepSeq (NFData)

import Control.Monad (liftM)
import GHC.IO.Exception (ExitCode (ExitSuccess))

import Data.Time.Clock (getCurrentTime)

opts :: ShakeOptions
opts = shakeOptions { shakeFiles  = ".shake/"
                    , shakeVerbosity = Diagnostic }

curlCmd :: String -> String -> Action ()
curlCmd url destfile = cmd "curl" [url, "-s", "-o", destfile]

newtype URL = URL String deriving (Show,Typeable,Eq,Hashable,Binary,NFData)

vars :: [String]
vars = [ "MAP_URL"
       , "BOUNDS_URL"
       , "SEA_URL"
       , "STYLE_URL"
       ]

data Options = Options
 { mapURL :: String
 , boundsURL :: String
 , seaURL :: String
 , styleURL :: String
 }

getOptions :: Action Options
getOptions = do
  let opts  = mapM getEnv vars
      opts' = liftM sequence opts

  opts'' <- opts'
  
  case opts'' of
    Just xs -> return $ toOpts xs
    Nothing -> fail "Failed to set a required parameter for build!"
    
  where toOpts [ mapUrl
               , boundsUrl
               , seaUrl
               , styleUrl
               ] = Options mapUrl boundsUrl seaUrl styleUrl

buildMap :: IO ()
buildMap = shakeArgs opts $ do
  let opts = getOptions

  getEtag <- addOracle $ \(URL url) -> do
    (Exit c, Stdout out) <- cmd $ "curl -I -L -s " ++ url ++ " | grep ETag"
    if c == ExitSuccess then
        return (out :: String)
      else
        do
          c' <- liftIO getCurrentTime
          return $ show c'
      
  want [".osm2gmap/gmapsupp.img"]

  ".osm2gmap/gmapsupp.img" *> \_ -> do
    need [ ".osm2gmap/mkgmap/dist/mkgmap.jar"
         , ".osm2gmap/split-output"
         , ".osm2gmap/map.osm.pbf"
         , ".osm2gmap/bounds.zip"
         , ".osm2gmap/sea.zip"
         , ".osm2gmap/style.zip"
         ]

    cmd Shell "java -jar .osm2gmap/mkgmap/dist/mkgmap.jar"
      [ "--route"               -- TODO - make all switches configurable
      , "--add-pois-to-areas"
      , "--latin1"
      , "--index"
      , "--gmapsupp"

      , "--family-name=\"OSM Map\""
      , "--series-name=\"OSM Map\""
      , "--description=\"OSM Map\""
      , "--precomp-sea=\".osm2gmap/sea.zip\""
      , "--bounds=\".osm2gmap/bounds.zip\""
      , "--output-dir=\".osm2gmap/\""
      , "--style-file=\".osm2gmap/style.zip\""
      , ".osm2gmap/split-output/*.osm.pbf"
      ]

  ".osm2gmap/split-output" *> \_ -> do
    need [ ".osm2gmap/splitter/dist/splitter.jar" ]
    cmd Shell "java" [ "-jar .osm2gmap/splitter/dist/splitter.jar"
                     , "--output-dir=.osm2gmap/split-output"
                     , ".osm2gmap/map.osm.pbf"
                     ]

  "clean" ~> removeFilesAfter ".osm2gmap" ["//*"]

  ".osm2gmap/bounds.zip" *> \f -> do
    url <- liftM boundsURL opts
    getEtag $ URL url
    curlCmd url f

  ".osm2gmap/style.zip" *> \f -> do
    url <- liftM styleURL opts
    getEtag $ URL url
    curlCmd url f

  ".osm2gmap/map.osm.pbf" *> \f -> do
    url <- liftM mapURL opts
    getEtag $ URL url
    curlCmd url f

  ".osm2gmap/sea.zip" *> \f -> do
    url <- liftM seaURL opts
    getEtag $ URL url
    curlCmd url f

  ".osm2gmap/mkgmap/dist/mkgmap.jar" *> \_ -> do
    need [ ".osm2gmap/mkgmap/build.xml" ]
    cmd (Cwd ".osm2gmap/mkgmap") "ant"

  ".osm2gmap/mkgmap/build.xml" *> \_ ->
    cmd "svn" ["co", "http://svn.mkgmap.org.uk/mkgmap/trunk",  ".osm2gmap/mkgmap"]

  ".osm2gmap/splitter/build.xml" *> \_ ->
    cmd "svn" ["co", "http://svn.mkgmap.org.uk/splitter/trunk",  ".osm2gmap/splitter"]

  ".osm2gmap/splitter/dist/splitter.jar" *> \_ -> do
    need [".osm2gmap/splitter/build.xml"]
    cmd (Cwd ".osm2gmap/splitter") "ant"

main :: IO ()
main = buildMap
