{-# LANGUAGE OverloadedStrings #-}

module Retcon.Network.Ekg where

import           Control.Applicative
import           Control.Concurrent
import           Control.Monad
import           Data.Int
import           Data.Map               (Map)
import qualified Data.Map               as M
import           Data.Monoid
import qualified Data.Text              as T
import           System.IO.Unsafe
import           System.Log.Logger
import           System.Metrics         (createCounter, createGauge)
import qualified System.Metrics         as Ekg
import           System.Metrics.Counter (Counter)
import qualified System.Metrics.Counter as Counter
import           System.Metrics.Gauge   (Gauge)
import qualified System.Metrics.Gauge   as Gauge

import           Retcon.Configuration
import           Retcon.Identifier

-- | Name of server component for logging.
ekgLogName :: String
ekgLogName = "Retcon.Ekg"

-- | EKG metrics

-- Global MVar to track ekg meters
metersMVar :: MVar Meters
metersMVar = unsafePerformIO $ do
    dummyGauge <- Gauge.new
    newMVar (Meters mempty dummyGauge)
{-# NOINLINE metersMVar #-}

-- | All counter values are from startup

data DataSourceMeters = DataSourceMeters
    { sourceNumNotifications :: Gauge -- ^ Number of pending notifications from the data source.
    , sourceNumKeys          :: Gauge -- ^ Number of tracked foreign keys for the data source.
    }

data EntityMeters = EntityMeters
    { entityNumNotifications :: Gauge   -- ^ Number of pending notifications for the entity.
    , entityNumCreates       :: Counter -- ^ Number of inferred creates for the entity.
    , entityNumUpdates       :: Counter -- ^ Number of inferred updates for the entity.
    , entityNumDeletes       :: Counter -- ^ Number of inferred deletes for the entity.
    , entityNumConflicts     :: Gauge   -- ^ Number of unresolved conflicts for the entity.
    , entityNumKeys          :: Gauge   -- ^ Number of tracked internal keys for the entity.
    , entityDataSourceMeters :: Map SourceName DataSourceMeters
    }

data Meters = Meters
    { entityMeters           :: Map EntityName EntityMeters
    , serverNumNotifications :: Gauge -- ^ Number of pending notifications for the server
    }

getDataSourceMeters :: Meters -> EntityName -> SourceName -> Either String DataSourceMeters
getDataSourceMeters m en sn =
    case getEntityMeters m en of
        Left err -> Left err
        Right em -> case M.lookup sn (entityDataSourceMeters em) of
            Nothing -> Left $ "No metrics for entity and data source: " <> n
            Just dm -> Right dm
  where
    n = T.unpack $ ename en <> "/" <> sname sn

getEntityMeters :: Meters -> EntityName -> Either String EntityMeters
getEntityMeters (Meters m _) en =
    case M.lookup en m of
        Nothing -> Left $ "No metrics for entity: " <> show en
        Just em -> Right em

updateEntityMeter :: (EntityMeters -> IO ()) -> EntityName -> IO ()
updateEntityMeter f en = do
    meters <- readMVar metersMVar
    case getEntityMeters meters en of
        Left err -> warningM ekgLogName err
        Right em -> f em

updateSourceMeter :: (DataSourceMeters -> IO ()) -> EntityName -> SourceName -> IO ()
updateSourceMeter f en sn = do
    meters <- readMVar metersMVar
    case getDataSourceMeters meters en sn of
        Left err -> warningM ekgLogName err
        Right dm -> f dm

updateServerMeter :: (Meters -> IO ()) -> IO ()
updateServerMeter f = readMVar metersMVar >>= f

setSourceNotifications, setSourceKeys
    :: Int64 -> EntityName -> SourceName -> IO ()
incCreates, incUpdates, incDeletes
    ::          EntityName               -> IO ()
setEntityNotifications, setEntityKeys, setConflicts
    :: Int64 -> EntityName               -> IO ()
setServerNotifications
    :: Int64                             -> IO ()

setSourceNotifications n = updateSourceMeter (flip Gauge.set n . sourceNumNotifications)
setSourceKeys n          = updateSourceMeter (flip Gauge.set n . sourceNumKeys)
incCreates               = updateEntityMeter (Counter.inc      . entityNumCreates)
incUpdates               = updateEntityMeter (Counter.inc      . entityNumUpdates)
incDeletes               = updateEntityMeter (Counter.inc      . entityNumDeletes)
setConflicts n           = updateEntityMeter (flip Gauge.set n . entityNumConflicts)
setEntityNotifications n = updateEntityMeter (flip Gauge.set n . entityNumNotifications)
setEntityKeys n          = updateEntityMeter (flip Gauge.set n . entityNumKeys)
setServerNotifications n = updateServerMeter (flip Gauge.set n . serverNumNotifications)

initialiseMeters :: Ekg.Store -> Configuration -> IO ()
initialiseMeters store (Configuration eMap _) = do
    let entities = M.assocs eMap
    meters <- forM entities $ \(eName, e) -> do
        em <- initialiseEntity (eName, e)
        return (eName, em)
    ql <- createGauge "notifications" store
    _ <- swapMVar metersMVar $ Meters (M.fromList meters) ql
    return ()
  where
    initialiseEntity :: (EntityName, Entity) -> IO EntityMeters
    initialiseEntity (EntityName eName, e) = do
        let sourceNames = M.keys $ entitySources e
        em <- forM sourceNames $ \s -> do
            sourceMeters <- initialiseSource (EntityName eName) s
            return (s, sourceMeters)
        let baseName = "entities." <> eName
        EntityMeters <$> createGauge   (baseName <> ".notifications") store
                     <*> createCounter (baseName <> ".creates")       store
                     <*> createCounter (baseName <> ".updates")       store
                     <*> createCounter (baseName <> ".deletes")       store
                     <*> createGauge   (baseName <> ".conflicts")       store
                     <*> createGauge   (baseName <> ".internal_keys") store
                     <*> pure (M.fromList em)

    initialiseSource :: EntityName -> SourceName -> IO DataSourceMeters
    initialiseSource (EntityName e) (SourceName s) = let baseName = "entities." <> e <> ".datasources." <> s in
        DataSourceMeters <$> createGauge (baseName <> ".notifications") store
                         <*> createGauge (baseName <> ".foreign_keys")  store
