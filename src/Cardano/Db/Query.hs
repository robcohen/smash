{-# LANGUAGE FlexibleContexts    #-}
{-# LANGUAGE NumericUnderscores  #-}
{-# LANGUAGE OverloadedStrings   #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Cardano.Db.Query
  ( DBFail (..)
  , queryPoolMetadata
  , queryBlockCount
  , queryBlockNo
  , queryBlockId
  , queryMeta
  , queryLatestBlock
  , queryLatestBlockNo
  , queryCheckPoints
  , queryDelistedPool
  , queryReservedTicker
  , queryAdminUsers
  ) where

import           Cardano.Prelude            hiding (Meta, from, isJust,
                                             isNothing, maybeToEither)

import           Control.Monad              (join)
import           Control.Monad.Extra        (mapMaybeM)
import           Control.Monad.Trans.Reader (ReaderT)

import           Data.ByteString.Char8      (ByteString)
import           Data.Maybe                 (catMaybes, listToMaybe)
import           Data.Word                  (Word64)

import           Database.Esqueleto         (Entity, PersistField, SqlExpr,
                                             Value, countRows, desc, entityVal,
                                             from, isNothing, just, limit, not_,
                                             orderBy, select, unValue, val,
                                             where_, (==.), (^.))
import           Database.Persist.Sql       (SqlBackend, selectList)

import           Cardano.Db.Error
import           Cardano.Db.Schema
import qualified Cardano.Db.Types           as Types

-- | Get the 'Block' associated with the given hash.
-- We use the @Types.PoolId@ to get the nice error message out.
queryPoolMetadata :: MonadIO m => Types.PoolId -> Types.PoolMetadataHash -> ReaderT SqlBackend m (Either DBFail PoolMetadata)
queryPoolMetadata poolId poolMetadataHash = do
  res <- select . from $ \ poolMetadata -> do
            where_ (poolMetadata ^. PoolMetadataHash ==. val poolMetadataHash)
            pure poolMetadata
  pure $ maybeToEither (DbLookupPoolMetadataHash poolId poolMetadataHash) entityVal (listToMaybe res)

-- | Count the number of blocks in the Block table.
queryBlockCount :: MonadIO m => ReaderT SqlBackend m Word
queryBlockCount = do
  res <- select . from $ \ (_ :: SqlExpr (Entity Block)) -> do
            pure countRows
  pure $ maybe 0 unValue (listToMaybe res)

queryBlockNo :: MonadIO m => Word64 -> ReaderT SqlBackend m (Maybe Block)
queryBlockNo blkNo = do
  res <- select . from $ \ blk -> do
            where_ (blk ^. BlockBlockNo ==. just (val blkNo))
            pure blk
  pure $ fmap entityVal (listToMaybe res)

-- | Get the 'BlockId' associated with the given hash.
queryBlockId :: MonadIO m => ByteString -> ReaderT SqlBackend m (Either DBFail BlockId)
queryBlockId hash = do
  res <- select . from $ \ blk -> do
            where_ (blk ^. BlockHash ==. val hash)
            pure $ blk ^. BlockId
  pure $ maybeToEither (DbLookupBlockHash hash) unValue (listToMaybe res)

{-# INLINABLE queryMeta #-}
-- | Get the network metadata.
queryMeta :: MonadIO m => ReaderT SqlBackend m (Either DBFail Meta)
queryMeta = do
  res <- select . from $ \ (meta :: SqlExpr (Entity Meta)) -> do
            pure meta
  pure $ case res of
            []  -> Left DbMetaEmpty
            [m] -> Right $ entityVal m
            _   -> Left DbMetaMultipleRows

-- | Get the latest block.
queryLatestBlock :: MonadIO m => ReaderT SqlBackend m (Maybe Block)
queryLatestBlock = do
  res <- select $ from $ \ blk -> do
                orderBy [desc (blk ^. BlockSlotNo)]
                limit 1
                pure $ blk
  pure $ fmap entityVal (listToMaybe res)

-- | Get the 'BlockNo' of the latest block.
queryLatestBlockNo :: MonadIO m => ReaderT SqlBackend m (Maybe Word64)
queryLatestBlockNo = do
  res <- select $ from $ \ blk -> do
                where_ $ (isJust $ blk ^. BlockBlockNo)
                orderBy [desc (blk ^. BlockBlockNo)]
                limit 1
                pure $ blk ^. BlockBlockNo
  pure $ listToMaybe (catMaybes $ map unValue res)

queryCheckPoints :: MonadIO m => Word64 -> ReaderT SqlBackend m [(Word64, ByteString)]
queryCheckPoints limitCount = do
    latest <- select $ from $ \ blk -> do
                where_ $ (isJust $ blk ^. BlockSlotNo)
                orderBy [desc (blk ^. BlockSlotNo)]
                limit 1
                pure $ (blk ^. BlockSlotNo)
    case join (unValue <$> listToMaybe latest) of
      Nothing     -> pure []
      Just slotNo -> mapMaybeM querySpacing (calcSpacing slotNo)
  where
    querySpacing :: MonadIO m => Word64 -> ReaderT SqlBackend m (Maybe (Word64, ByteString))
    querySpacing blkNo = do
       rows <- select $ from $ \ blk -> do
                  where_ $ (blk ^. BlockSlotNo ==. just (val blkNo))
                  pure $ (blk ^. BlockSlotNo, blk ^. BlockHash)
       pure $ join (convert <$> listToMaybe rows)

    convert :: (Value (Maybe Word64), Value ByteString) -> Maybe (Word64, ByteString)
    convert (va, vb) =
      case (unValue va, unValue vb) of
        (Nothing, _ ) -> Nothing
        (Just a, b)   -> Just (a, b)

    calcSpacing :: Word64 -> [Word64]
    calcSpacing end =
      if end > 2 * limitCount
        then [ end, end - end `div` limitCount .. 1 ]
        else [ end, end - 2 .. 1 ]

-- | Check if the hash is in the table.
queryDelistedPool :: MonadIO m => Types.PoolId -> ReaderT SqlBackend m Bool
queryDelistedPool poolId = do
  res <- select . from $ \(pool :: SqlExpr (Entity DelistedPool)) -> do
            where_ (pool ^. DelistedPoolPoolId ==. val poolId)
            pure pool
  pure $ maybe False (\_ -> True) (listToMaybe res)

-- | Check if the ticker is in the table.
queryReservedTicker :: MonadIO m => Text -> ReaderT SqlBackend m (Maybe ReservedTicker)
queryReservedTicker reservedTickerName = do
  res <- select . from $ \(reservedTicker :: SqlExpr (Entity ReservedTicker)) -> do
            where_ (reservedTicker ^. ReservedTickerName ==. val reservedTickerName)
            limit 1
            pure $ reservedTicker
  pure $ fmap entityVal (listToMaybe res)

-- | Query all admin users for authentication.
queryAdminUsers :: MonadIO m => ReaderT SqlBackend m [AdminUser]
queryAdminUsers = do
  res <- selectList [] []
  pure $ entityVal <$> res

------------------------------------------------------------------------------------

maybeToEither :: e -> (a -> b) -> Maybe a -> Either e b
maybeToEither e f =
  maybe (Left e) (Right . f)

-- Filter out 'Nothing' from a 'Maybe a'.
isJust :: PersistField a => SqlExpr (Value (Maybe a)) -> SqlExpr (Value Bool)
isJust = not_ . isNothing

