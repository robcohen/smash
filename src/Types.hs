{-# LANGUAGE DeriveGeneric #-}

module Types
    ( ApplicationUser (..)
    , ApplicationUsers
    , stubbedApplicationUsers
    , User
    , UserValidity (..)
    , checkIfUserValid
    -- * Pool info
    , BlacklistPool
    , PoolHash (..)
    , createPoolHash
    -- * Wrapper
    , PoolMetadataWrapped (..)
    -- * Pool offline metadata
    , PoolName (..)
    , PoolDescription (..)
    , PoolTicker (..)
    , PoolHomepage (..)
    , PoolOfflineMetadata
    , createPoolOfflineMetadata
    , examplePoolOfflineMetadata
    -- * Pool online data
    , PoolOnlineData
    , PoolOwner
    , PoolPledgeAddress
    , examplePoolOnlineData
    -- * Configuration
    , Configuration (..)
    , defaultConfiguration
    -- * API
    , ApiResult (..)
    ) where

import           Cardano.Prelude

import           Control.Monad.Fail  (fail)

import           Data.Aeson          (FromJSON (..), ToJSON (..), object,
                                      withObject, (.:), (.=))
import qualified Data.Aeson          as Aeson
import           Data.Aeson.Encoding (unsafeToEncoding)
import qualified Data.Aeson.Types    as Aeson

import           Data.Swagger        (NamedSchema (..), ToParamSchema (..),
                                      ToSchema (..))
import           Data.Text.Encoding  (encodeUtf8Builder)

import           Servant             (FromHttpApiData (..))

import           Cardano.Db.Error

-- | The basic @Configuration@.
data Configuration = Configuration
    { cPortNumber :: !Int
    } deriving (Eq, Show)

defaultConfiguration :: Configuration
defaultConfiguration = Configuration 3100

-- | A list of users with very original passwords.
stubbedApplicationUsers :: ApplicationUsers
stubbedApplicationUsers = ApplicationUsers [ApplicationUser "ksaric" "cirask"]

examplePoolOfflineMetadata :: PoolOfflineMetadata
examplePoolOfflineMetadata =
    PoolOfflineMetadata
        (PoolName "TestPool")
        (PoolDescription "This is a pool for testing")
        (PoolTicker "testp")
        (PoolHomepage "https://iohk.io")

examplePoolOnlineData :: PoolOnlineData
examplePoolOnlineData =
    PoolOnlineData
        (PoolOwner "AAAAC3NzaC1lZDI1NTE5AAAAIKFx4CnxqX9mCaUeqp/4EI1+Ly9SfL23/Uxd0Ieegspc")
        (PoolPledgeAddress "e8080fd3b5b5c9fcd62eb9cccbef9892dd74dacf62d79a9e9e67a79afa3b1207")

-- A data type we use to store user credentials.
data ApplicationUser = ApplicationUser
    { username :: !Text
    , password :: !Text
    } deriving (Eq, Show, Generic)

instance ToJSON ApplicationUser
instance FromJSON ApplicationUser

-- A list of users we use.
newtype ApplicationUsers = ApplicationUsers [ApplicationUser]
    deriving (Eq, Show, Generic)

instance ToJSON ApplicationUsers
instance FromJSON ApplicationUsers

-- | A user we'll grab from the database when we authenticate someone
newtype User = User { userName :: Text }
  deriving (Eq, Show)

-- | This we can leak.
data UserValidity
    = UserValid !User
    | UserInvalid
    deriving (Eq, Show)

-- | 'BasicAuthCheck' holds the handler we'll use to verify a username and password.
checkIfUserValid :: ApplicationUsers -> ApplicationUser -> UserValidity
checkIfUserValid (ApplicationUsers applicationUsers) applicationUser@(ApplicationUser usernameText _) =
    if applicationUser `elem` applicationUsers
        then (UserValid (User usernameText))
        else UserInvalid

newtype BlacklistPool = BlacklistPool
    { blacklistPool :: Text
    } deriving (Eq, Show, Generic)

instance FromJSON BlacklistPool
instance ToJSON BlacklistPool

instance ToSchema BlacklistPool

-- | We use base64 encoding here.
-- Submissions are identified by the subject's Bech32-encoded Ed25519 public key (all lowercase).
-- An Ed25519 public key is a 64-byte string. We'll typically show such string in base16.
-- base64 is fine too, more concise. But bech32 is definitely overkill here.
-- This might be a synonym for @PoolOwner@.
newtype PoolHash = PoolHash
    { getPoolHash :: Text
    } deriving (Eq, Show, Ord, Generic)

instance ToParamSchema PoolHash

-- | Should be an @Either@.
createPoolHash :: Text -> PoolHash
createPoolHash hash = PoolHash hash

-- TODO(KS): Temporarily, validation!?
instance FromHttpApiData PoolHash where
    parseUrlPiece poolHashText = Right $ PoolHash poolHashText

--        if (isPrefixOf "ed25519_" (toS poolHashText))
--            then Right $ PoolHash poolHashText
--            else Left "PoolHash not starting with 'ed25519_'!"

newtype PoolName = PoolName
    { getPoolName :: Text
    } deriving (Eq, Show, Ord, Generic)

instance ToSchema PoolName

newtype PoolDescription = PoolDescription
    { getPoolDescription :: Text
    } deriving (Eq, Show, Ord, Generic)

instance ToSchema PoolDescription

newtype PoolTicker = PoolTicker
    { getPoolTicker :: Text
    } deriving (Eq, Show, Ord, Generic)

instance ToSchema PoolTicker

newtype PoolHomepage = PoolHomepage
    { getPoolHomepage :: Text
    } deriving (Eq, Show, Ord, Generic)

instance ToSchema PoolHomepage

-- | The bit of the pool data off the chain.
data PoolOfflineMetadata = PoolOfflineMetadata
    { pomName        :: !PoolName
    , pomDescription :: !PoolDescription
    , pomTicker      :: !PoolTicker
    , pomHomepage    :: !PoolHomepage
    } deriving (Eq, Show, Ord, Generic)

-- | Smart constructor, just adding one more layer of indirection.
createPoolOfflineMetadata
    :: PoolName
    -> PoolDescription
    -> PoolTicker
    -> PoolHomepage
    -> PoolOfflineMetadata
createPoolOfflineMetadata = PoolOfflineMetadata

newtype PoolOwner = PoolOwner
    { getPoolOwner :: Text
    } deriving (Eq, Show, Ord, Generic)

newtype PoolPledgeAddress = PoolPledgeAddress
    { getPoolPledgeAddress :: Text
    } deriving (Eq, Show, Ord, Generic)

-- | The bit of the pool data on the chain.
-- This doesn't leave the internal database.
data PoolOnlineData = PoolOnlineData
    { podOwner         :: !PoolOwner
    , podPledgeAddress :: !PoolPledgeAddress
    } deriving (Eq, Show, Ord, Generic)

-- Required instances
instance FromJSON PoolOfflineMetadata where
    parseJSON = withObject "poolOfflineMetadata" $ \o -> do
        name'           <- parseName o
        description'    <- parseDescription o
        ticker'         <- parseTicker o
        homepage'       <- o .: "homepage"

        return $ PoolOfflineMetadata
            { pomName           = PoolName name'
            , pomDescription    = PoolDescription description'
            , pomTicker         = PoolTicker ticker'
            , pomHomepage       = PoolHomepage homepage'
            }
      where

        -- Copied from https://github.com/input-output-hk/cardano-node/pull/1299

        -- | Parse and validate the stake pool metadata name from a JSON object.
        --
        -- If the name consists of more than 50 characters, the parser will fail.
        parseName :: Aeson.Object -> Aeson.Parser Text
        parseName obj = do
          name <- obj .: "name"
          if length name <= 50
            then pure name
            else fail $
                 "\"name\" must have at most 50 characters, but it has "
              <> show (length name)
              <> " characters."

        -- | Parse and validate the stake pool metadata description from a JSON
        -- object.
        --
        -- If the description consists of more than 255 characters, the parser will
        -- fail.
        parseDescription :: Aeson.Object -> Aeson.Parser Text
        parseDescription obj = do
          description <- obj .: "description"
          if length description <= 255
            then pure description
            else fail $
                 "\"description\" must have at most 255 characters, but it has "
              <> show (length description)
              <> " characters."

        -- | Parse and validate the stake pool ticker description from a JSON object.
        --
        -- If the ticker consists of less than 3 or more than 5 characters, the parser
        -- will fail.
        parseTicker :: Aeson.Object -> Aeson.Parser Text
        parseTicker obj = do
          ticker <- obj .: "ticker"
          let tickerLen = length ticker
          if tickerLen >= 3 && tickerLen <= 5
            then pure ticker
            else fail $
                 "\"ticker\" must have at least 3 and at most 5 "
              <> "characters, but it has "
              <> show (length ticker)
              <> " characters."

-- |We presume the validation is not required the other way around?
instance ToJSON PoolOfflineMetadata where
    toJSON (PoolOfflineMetadata name' description' ticker' homepage') =
        object
            [ "name"            .= getPoolName name'
            , "description"     .= getPoolDescription description'
            , "ticker"          .= getPoolTicker ticker'
            , "homepage"        .= getPoolHomepage homepage'
            ]

--instance ToParamSchema PoolOfflineMetadata
instance ToSchema PoolOfflineMetadata

newtype PoolMetadataWrapped = PoolMetadataWrapped Text
    deriving (Eq, Ord, Show, Generic)

-- Here we are usingg the unsafe encoding since we already have the JSON format
-- from the database.
instance ToJSON PoolMetadataWrapped where
    toJSON (PoolMetadataWrapped metadata) = toJSON metadata
    toEncoding (PoolMetadataWrapped metadata) = unsafeToEncoding $ encodeUtf8Builder metadata

instance ToSchema PoolMetadataWrapped where
  declareNamedSchema _ =
    return $ NamedSchema (Just "PoolMetadataWrapped") $ mempty

instance ToSchema DBFail where
  declareNamedSchema _ =
    return $ NamedSchema (Just "DBFail") $ mempty

instance ToSchema (ApiResult err a) where
  declareNamedSchema _ =
    return $ NamedSchema (Just "ApiResult") $ mempty

-- Result wrapper.
newtype ApiResult err a = ApiResult (Either err a)

instance (ToJSON err, ToJSON a) => ToJSON (ApiResult err a) where

    toJSON (ApiResult (Left dbFail))  = toJSON dbFail
    toJSON (ApiResult (Right result)) = toJSON result

    toEncoding (ApiResult (Left result))  = toEncoding result
    toEncoding (ApiResult (Right result)) = toEncoding result

