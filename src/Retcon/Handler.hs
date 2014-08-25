--
-- Copyright © 2013-2014 Anchor Systems, Pty Ltd and Others
--
-- The code in this file, and the program it is a part of, is
-- made available to you by its authors as open source software:
-- you can redistribute it and/or modify it under the terms of
-- the 3-clause BSD licence.
--

-- | Description: Dispatch events with a retcon configuration.

{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings     #-}
{-# LANGUAGE RankNTypes            #-}
{-# LANGUAGE ScopedTypeVariables   #-}
{-# LANGUAGE TemplateHaskell       #-}

module Retcon.Handler where

import Control.Applicative
import Control.Exception
import Control.Exception.Enclosed (tryAny)
import Control.Monad.Error.Class
import Control.Monad.Logger
import Control.Monad.Reader
import Data.Aeson
import Data.Bifunctor
import Data.Either
import Data.Maybe
import Data.Monoid
import Data.Proxy
import Data.Text (Text)
import qualified Data.Text as T
import Database.PostgreSQL.Simple
import GHC.TypeLits

import Retcon.Config
import Retcon.DataSource
import Retcon.Diff
import Retcon.Document
import Retcon.Error
import Retcon.MergePolicy
import Retcon.Monad
import Retcon.Options

-- | Check that two symbols are the same.
same :: (KnownSymbol a, KnownSymbol b) => Proxy a -> Proxy b -> Bool
same a b = isJust (sameSymbol a b)

-- | Extract the type-level information from a 'ForeignKey'.
--
-- The triple contains the entity, data source, and key in that order.
foreignKeyValue :: forall entity source. (RetconDataSource entity source)
                => ForeignKey entity source
                -> (String, String, String)
foreignKeyValue (ForeignKey key) =
    let entity = symbolVal (Proxy :: Proxy entity)
        source = symbolVal (Proxy :: Proxy source)
    in (entity, source, key)

-- | Encode a 'ForeignKey' as a 'String'.
encodeForeignKey :: forall entity source. (RetconDataSource entity source)
                 => ForeignKey entity source
                 -> String
encodeForeignKey = show . foreignKeyValue

-- | The unique identifier used to identify a unique 'entity' document within
-- retcon.
newtype RetconEntity entity => InternalKey entity =
    InternalKey { unInternalKey :: Int }
  deriving (Eq, Ord, Show)

-- | Extract the type-level information from an 'InternalKey'.
--
-- The pair contains the entity, and the key in that order.
internalKeyValue :: forall entity. RetconEntity entity
                 => InternalKey entity
                 -> (String, Int)
internalKeyValue (InternalKey key) =
    let entity = symbolVal (Proxy :: Proxy entity)
    in (entity, key)

-- | Create a new 'InternalKey' for an entity.
--
-- The new 'InternalKey' is recorded in the database.
createInternalKey :: forall entity. (RetconEntity entity)
                  => RetconHandler (InternalKey entity)
createInternalKey = do
    conn <- asks retconConnection
    let entity = symbolVal (Proxy :: Proxy entity)

    res <- liftIO $ query conn "INSERT INTO retcon (entity) VALUES (?) RETURNING id" (Only entity)

    case res of
        []  -> throwError $ RetconDBError "Cannot create new internal key."
        (Only key:_) -> do
            opt <- asks retconOptions
            when (optVerbose opt) $ $logDebug $ "Created internal key"
            return $ InternalKey key

-- | Translate a 'ForeignKey' to an 'InternalKey'
--
-- This involves looking for the specific @entity@, @source@, and 'ForeignKey'
-- in a translation table in the database.
lookupInternalKey :: (RetconDataSource entity source)
                  => ForeignKey entity source
                  -> RetconHandler (Maybe (InternalKey entity))
lookupInternalKey fk = do
    conn <- asks retconConnection

    (results :: [Only Int]) <- liftIO $ query conn "SELECT id FROM retcon_fk WHERE entity = ? AND source = ? AND fk = ? LIMIT 1" $ foreignKeyValue fk
    case results of
      Only key:_ -> return $ Just (InternalKey key)
      []         -> return Nothing
    -- If it exists, return it
    -- Otherwise:
    --     Allocate a new internal key.
    --     Record it in the database.
    --     Return it.

-- | Record a 'ForeignKey' associated with an 'InternalKey'.
recordForeignKey :: forall entity source. (RetconDataSource entity source)
                 => InternalKey entity
                 -> ForeignKey entity source
                 -> RetconHandler ()
recordForeignKey ik fk = do
    conn <- asks retconConnection
    opt <- asks retconOptions

    let (entity, source, fid) = foreignKeyValue fk
    let (entity', iid) = internalKeyValue ik
    let values = (entity, iid, source, fid)
    let sql = "INSERT INTO retcon_fk (entity, id, source, fk) VALUES (?, ?, ?, ?)"

    liftIO $ execute conn sql values
    when (optVerbose opt) $ $logDebug $ T.pack $ concat
        [ "Recorded "
        , show fk
        , " for "
        , show ik
        ]

    return ()

-- | Resolve the 'ForeignKey' associated with an 'InternalKey' for a given data
-- source.
lookupForeignKey :: forall entity source. (RetconDataSource entity source)
                 => InternalKey entity
                 -> RetconHandler (Maybe (ForeignKey entity source))
lookupForeignKey (InternalKey key) = do
    conn <- asks retconConnection

    let entity = symbolVal (Proxy :: Proxy entity)
    let source = symbolVal (Proxy :: Proxy source)

    (results::[Only String]) <- liftIO $ query conn "SELECT fk FROM retcon_fk WHERE entity = ? AND source = ? AND id = ?" (entity, source, key)

    return $ case results of
        Only key:_ -> Just (ForeignKey key :: ForeignKey entity source)
        []         -> Nothing

-- | Operations to be performed in response to data source events.
data RetconOperation entity source =
      RetconCreate (ForeignKey entity source) -- ^ Create a new document.
    | RetconDelete (InternalKey entity)       -- ^ Delete an existing document.
    | RetconUpdate (InternalKey entity)       -- ^ Update an existing document.
    | RetconProblem (ForeignKey entity source) RetconError -- ^ Record an error.
    deriving (Show)

-- | Interact with the data source which triggered in an event to identify
-- the operation to be performed.
--
-- This function should be able to return a 'RetconProblem' value, but currently
-- doesn't.
determineOperation :: (RetconDataSource entity source)
                   => ForeignKey entity source
                   -> RetconHandler (RetconOperation entity source)
determineOperation fk = do
    ik' <- lookupInternalKey fk
    case ik' of
        Nothing -> return $ RetconCreate fk
        Just ik -> do
            doc' <- join . first RetconError <$> tryAny
                (liftIO . runDataSourceAction $ getDocument fk)
            return $ case doc' of
                Left  _ -> RetconDelete ik
                Right _ -> RetconUpdate ik

-- | Perform the action/s described by a 'RetconOperation' value.
runOperation :: (RetconDataSource entity source)
             => RetconOperation entity source
             -> RetconHandler ()
runOperation event =
    case event of
        RetconCreate  fk -> create fk
        RetconDelete  ik -> delete ik
        RetconUpdate  ik -> update ik
        RetconProblem fk err -> reportError fk err

-- | Parse a request string and handle an event.
dispatch :: String -> RetconHandler ()
dispatch work = do
    let (entity_str, source_str, key) = read work :: (String, String, String)
    entities <- asks (retconEntities . retconConfig)
    case someSymbolVal entity_str of
        SomeSymbol (entity :: Proxy entity_ty) ->
            forM_ entities $ \(SomeEntity e) ->
                when (same e entity) $ forM_ (entitySources e) $ \(SomeDataSource (sp :: Proxy st) :: SomeDataSource et) -> do
                    case someSymbolVal source_str of
                        SomeSymbol (source :: Proxy source_ty) -> do
                          let fk = ForeignKey key :: ForeignKey et st
                          when (same source sp) (process fk)

-- | Run the retcon process on an event.
retcon :: RetconOptions
       -> RetconConfig
       -> Connection
       -> String -- ^ Key to use.
       -> IO (Either RetconError ())
retcon opts config conn key = do
    runRetconHandler opts config conn . dispatch $ key

-- | Process an event on a specified 'ForeignKey'.
--
-- This function is responsible for determining the type of event which has
-- occured and invoking the correct 'RetconDataSource' actions and retcon
-- algorithms to handle it.
process :: forall entity source. (RetconDataSource entity source)
        => ForeignKey entity source
        -> RetconHandler ()
process fk = do
    $logDebug . T.pack . concat $ [ "EVENT against ", show $ length sources
                                  , " sources"
                                  ]

    determineOperation fk >>= runOperation
  where
    sources = entitySources (Proxy :: Proxy entity)

-- | Process a creation event.
create :: forall entity source. (RetconDataSource entity source)
       => ForeignKey entity source
       -> RetconHandler ()
create fk = do
    $logDebug "CREATE"

    -- Allocate a new InternalKey to represent this entity.
    ik <- createInternalKey
    recordForeignKey ik fk

    -- Use the new Document as the initial document.
    doc' <- join . first RetconError <$> tryAny (liftIO $ runDataSourceAction $ getDocument fk)

    case doc' of
        Left _ -> do
            deleteState ik
            throwError (RetconSourceError "Notification of a new document which doesn't exist")
        Right doc -> do
            putInitialDocument ik doc
            setDocuments ik . map (const doc) $ entitySources (Proxy :: Proxy entity)
    return ()

-- | Process a deletion event.
delete :: (RetconEntity entity)
       => InternalKey entity
       -> RetconHandler ()
delete ik = do
    $logDebug "DELETE"

    -- Delete from data sources.
    results <- carefully $ deleteDocuments ik

    -- TODO: Log things.

    -- Delete the internal associated with the key.
    deleteState ik

-- | Process an update event.
update :: RetconEntity entity
       => InternalKey entity
       -> RetconHandler ()
update ik = do
    $logDebug "UPDATE"

    -- Fetch documents.
    docs <- carefully $ getDocuments ik
    let valid = rights docs

    -- Find or calculate the initial document.
    --
    -- TODO This is fragile in the case that only one data sources has a document.
    initial <- fromMaybe (calculateInitialDocument valid) <$>
               getInitialDocument ik

    -- Build the diff.
    let diffs = map (diff initial) valid
    let (diff, fragments) = mergeDiffs ignoreConflicts diffs

    -- Apply the diff to each source document.
    --
    -- TODO: We replace documents we couldn't get with the initial document. The
    -- initial document may not be "valid".
    let output = map (applyDiff diff . either (const initial) id) docs

    -- TODO: Record changes in database.

    -- Save documents.
    results <- carefully $ setDocuments ik output

    -- TODO: Log all the failures.

    return ()

-- | Report an error in determining the operation, communicating with the data
-- source or similar.
reportError :: (RetconDataSource entity source)
            => ForeignKey entity source
            -> RetconError
            -> RetconHandler ()
reportError fk err = do
    $logError . T.pack . concat $ [ "Could not process event for "
                                  , show . foreignKeyValue $ fk
                                  , ". "
                                  , show err
                                  ]
    return ()

-- | Get 'Document's corresponding to an 'InternalKey' for all sources for an
-- entity.
getDocuments :: forall entity. (RetconEntity entity)
             => InternalKey entity
             -> RetconHandler [Either RetconError Document]
getDocuments ik =
    forM (entitySources (Proxy :: Proxy entity)) $
        \(SomeDataSource (Proxy :: Proxy source)) ->
            -- Flatten any nested errors.
            join . first RetconError <$> tryAny (do
                -- Lookup the foreign key for this data source.
                mkey <- lookupForeignKey ik
                -- If there was a key, use it to fetch the document.
                case mkey of
                    Just (fk :: ForeignKey entity source) ->
                        liftIO . runDataSourceAction $ getDocument fk
                    Nothing ->
                        return . Left $ RetconFailed)

-- | Set 'Document's corresponding to an 'InternalKey' for all sources for an
-- entity.
setDocuments :: forall entity. (RetconEntity entity)
             => InternalKey entity
             -> [Document]
             -> RetconHandler [Either RetconError ()]
setDocuments ik docs =
    forM (zip docs (entitySources (Proxy :: Proxy entity))) $
        \(doc, SomeDataSource (Proxy :: Proxy source)) ->
            join . first RetconError <$> tryAny (do
                (fk :: Maybe (ForeignKey entity source)) <- lookupForeignKey ik
                fk' <- liftIO $ runDataSourceAction $ setDocument doc fk
                -- TODO: Save ForeignKey to database.
                case fk' of
                    Left err -> return $ Left err
                    Right new_fk -> do
                        recordForeignKey ik new_fk
                        return $ Right ()
            )

-- | Delete a document.
deleteDocuments :: forall entity. (RetconEntity entity)
                => InternalKey entity
                -> RetconHandler [Either RetconError ()]
deleteDocuments ik =
    forM (entitySources (Proxy :: Proxy entity)) $
        \(SomeDataSource (Proxy :: Proxy source)) ->
            join . first RetconError <$> tryAny (do
                (fk' :: Maybe (ForeignKey entity source)) <- lookupForeignKey ik
                case fk' of
                    Nothing -> return $ Right ()
                    Just fk -> liftIO $ runDataSourceAction $ deleteDocument fk
            )

-- | Delete the internal state associated with an 'InternalKey'.
deleteState :: forall entity. (RetconEntity entity)
            => InternalKey entity
            -> RetconHandler ()
deleteState ik = do
    let key = T.pack . show . internalKeyValue $ ik
    opt <- asks retconOptions

    $logInfo $ T.concat ["DELETE state for ", key]

    deleteInitialDocument ik
    n_fk <- deleteForeignKeys ik
    n_ik <- deleteInternalKey ik

    when (optVerbose opt) $ do
        $logDebug $ T.concat [ "Deleted foreign key/s for ", key, ": "
                             , T.pack . show $ n_fk
                             ]
        $logDebug $ T.concat [ "Deleted internal key/s for ", key, ": "
                             , T.pack . show $ n_ik
                             ]

    return ()

-- | Fetch the initial document, if any, last used for an 'InternalKey'.
getInitialDocument :: forall entity. (RetconEntity entity)
       => InternalKey entity
       -> RetconHandler (Maybe Document)
getInitialDocument ik = do
    conn <- asks retconConnection

    results <- liftIO $ query conn selectQ (internalKeyValue ik)
    case results of
        Only v:_ ->
          case fromJSON v of
            Error err   -> return Nothing
            Success doc -> return (Just doc)
        []       -> return Nothing
    where
        selectQ = "SELECT document FROM retcon_initial WHERE entity = ? AND id = ?"

-- | Write the initial document associated with an 'InternalKey' to the database.
putInitialDocument :: forall entity. (RetconEntity entity)
        => InternalKey entity
        -> Document
        -> RetconHandler ()
putInitialDocument ik doc = do
    conn <- asks retconConnection

    let (entity, ikValue) = internalKeyValue ik
    void $ liftIO $ execute conn upsertQ (entity, ikValue, ikValue, entity, toJSON doc)
    where
        upsertQ = "BEGIN; DELETE FROM retcon_initial WHERE entity = ? AND id = ?; INSERT INTO retcon_initial (id, entity, document) values (?, ?, ?); COMMIT;"

-- | Delete the initial document for an 'InternalKey'.
deleteInitialDocument :: forall entity. (RetconEntity entity)
        => InternalKey entity
        -> RetconHandler ()
deleteInitialDocument ik = do
    conn <- asks retconConnection
    void $ liftIO $ execute conn deleteQ (internalKeyValue ik)
    where
        deleteQ = "DELETE FROM retcon_initial WHERE entity = ? AND id = ?"

deleteForeignKeys ik = do
    conn <- asks retconConnection
    liftIO $ execute conn "DELETE FROM retcon_fk WHERE entity = ? AND id = ?" $ internalKeyValue ik

deleteInternalKey ik = do
    conn <- asks retconConnection
    liftIO $ execute conn "DELETE FROM retcon WHERE entity = ? AND id = ?" $ internalKeyValue ik

-- | Insert a diff into the database
putDiffIntoDb :: forall l entity source. (RetconDataSource entity source, ToJSON l)
       => ForeignKey entity source
       -> Diff l
       -> RetconHandler (Maybe Int)
putDiffIntoDb fk (Diff _ diffOps) = do
    conn <- asks retconConnection
    ik <- lookupInternalKey fk
    case ik of
        Nothing  -> return Nothing
        Just ik' -> do
            let toInsert = insertT (foreignKeyValue fk) ik'
            (results :: [Only Int]) <- liftIO $ returning conn insertQ [toInsert]
            case results of
                Only did:_ -> do
                    let postedDiffs = map (putDiffOpIntoDb fk did) diffOps
                    return $ Just did
                []         -> return Nothing
    where
        insertQ = "INSERT INTO retcon_diff (entity, source, id, submitted, processed) VALUES (?, ?, ?, now, FALSE) RETURNING diff_id"
        insertT (entity, source, key) ik = (entity, source, show $ docId ik)
        docId i = snd $ internalKeyValue i

-- | Insert a single DiffOp into the database
putDiffOpIntoDb :: forall l entity source. (RetconDataSource entity source, ToJSON l)
       => ForeignKey entity source
       -> Int
       -> DiffOp l
       -> RetconHandler ()
putDiffOpIntoDb fk did diffOp = do
    conn <- asks retconConnection
    ik <- lookupInternalKey fk
    case ik of
        Nothing  -> error "No internal key"
        Just ik' -> do
            let toInsert = insertT (foreignKeyValue fk) (internalKeyValue ik') did diffOp
            void $ liftIO $ execute conn insertQ toInsert
    where
        insertQ = "INSERT INTO retcon_diff_portion (entity, source, id, diff_id, portion, accepted) VALUES (?, ?, ?, ?, ?, FALSE)"
        insertT (entity, source, key) (_, ident) did diffOp = (entity, source, ident, did, toJSON diffOp)

-- | Get all diffs for a Document
-- Use for displaying diffs
getInitialDocumentDiffs :: forall entity. (RetconEntity entity)
       => InternalKey entity
       -> RetconHandler [Diff Int]
getInitialDocumentDiffs ik = do
    conn <- asks retconConnection
    (results :: [Only Int]) <- liftIO $ query conn selectQ (internalKeyValue ik)
    let ids = map fromOnly results
    let rawDiffs = map (\d -> Diff d []) ids
    mapM completeDiff rawDiffs
    where
        selectQ = "SELECT diff_id FROM retcon_diff WHERE entity = ? AND id = ?"

-- | Build a Diff object from a Diff ID
-- Use for displaying diffs
completeDiff :: Diff Int -> RetconHandler (Diff Int)
completeDiff (Diff diff_id _) = do
    diffOps <- getDbDiffOps diff_id
    return $ Diff diff_id diffOps

-- | Get DiffOp objects belonging to a Diff ID
-- Use for displaying diffs
getDbDiffOps :: (FromJSON l) => Int -> RetconHandler [DiffOp l]
getDbDiffOps diff_id = do
    conn <- asks retconConnection
    (results :: [Only Value]) <- liftIO $ query conn selectQ (Only diff_id)
    return . catMaybes . map (constructDiffOpFromDb . fromOnly) $ results
    where
        selectQ = "SELECT portion FROM retcon_diff_portion WHERE diff_id = ?"

constructDiffOpFromDb :: (FromJSON l) => Value -> Maybe (DiffOp l)
constructDiffOpFromDb v =
    case (fromJSON v :: (FromJSON l) => Result (DiffOp l)) of
        Error e   -> Nothing
        Success d -> Just d
