{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE OverloadedStrings #-}
module Main where

import Control.Arrow (second)
import Control.Monad (when)
import qualified Data.ByteString as B
import qualified Data.ByteString.Char8 as BC
import Data.Function ((&))
import Data.List (sortBy)
import Data.Map (fromListWith, toList)
import Data.Maybe (fromMaybe, mapMaybe)
import Data.String (IsString (..))
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Vector as V
import Data.Yaml (FromJSON(..), ToJSON(..), (.:), (.:?), (.=))
import qualified Data.Yaml as Y
import qualified GitHub as GH
import qualified GitHub.Endpoints.Users as GH
import qualified GitHub.Endpoints.Repos.Commits as GH

import System.Environment (getArgs, lookupEnv)

main :: IO ()
main = do

  args <- getArgs
  when (length args /= 1) $
    error "usage: acknowledgements [path/to/_config.yml]"

  -- Get author information from _config.yml
  Config authors ownerRepo <- getConfig (head args)
  let authorLogins = mapMaybe authorLogin authors
  let (owner, repo) = second T.tail $ T.break (=='/') ownerRepo

  -- Get contributor information from GitHub
  auth <- getAuth
  contributorsAndAuthors <-
    getContributors auth (GH.mkOwnerName owner) (GH.mkRepoName repo)

  -- Filter the contributor list by the authors
  let
    errors :: [Text]
    errors = ["invalid-email-address"]

    isAuthorOrError :: Contributor -> Bool
    isAuthorOrError Contributor{..} =
      contributorLogin `elem` authorLogins || contributorLogin `elem` errors

    contributors =
      Contributors $ filter (not . isAuthorOrError) contributorsAndAuthors

  BC.putStrLn . Y.encode $ contributors

-- * Authors

getConfig :: FilePath -> IO Config
getConfig path = Y.decodeThrow =<< B.readFile path

data Author = Author
  { authorName  :: Text
  , authorEmail :: Text
  , authorLogin :: Maybe Text }
  deriving (Show)

instance FromJSON Author where
  parseJSON (Y.Object o) =
    Author <$>
    o .: "name" <*>
    o .: "email" <*>
    o .:? "github_username"
  parseJSON _ = fail "Expected Object for Author value"

data Config = Config
  { configAuthors :: [Author]
  , configRepo :: Text }

instance FromJSON Config where
  parseJSON (Y.Object o) =
    Config <$>
    o .: "authors" <*>
    o .: "repository"


-- * Contributors

data Contributor = Contributor
  { contributorName  :: Text
  , contributorLogin :: Text }

instance ToJSON Contributor where
  toJSON (Contributor name login) =
    Y.object [ "name" .= name , "github_username" .= login ]

newtype Contributors = Contributors [Contributor]

instance ToJSON Contributors where
  toJSON (Contributors contributors) =
    Y.object [ "contributors" .= toJSON contributors ]


-- |Get an authentication token from the environment.
getAuth :: IO (Maybe (GH.Auth))
getAuth = do
    token <- lookupEnv "GITHUB_TOKEN"
    pure (GH.OAuth . fromString <$> token)

-- |Get user information from a user login.
getUserInfo
  :: Maybe GH.Auth -> GH.SimpleUser
  -> IO GH.User
getUserInfo auth simpleUser =
  fromRight =<< GH.userInfoFor' auth (GH.simpleUserLogin simpleUser)

-- |Get user information for every user login.
getAllUserInfo
  :: Maybe GH.Auth -> [GH.SimpleUser]
  -> IO [GH.User]
getAllUserInfo auth simpleUser =
  mapM (getUserInfo auth) simpleUser

-- |Get commit history for a repository.
getCommits
  :: Maybe GH.Auth -> GH.Name GH.Owner -> GH.Name GH.Repo
  -> IO [GH.Commit]
getCommits auth owner repo =
  V.toList <$> (fromRight =<< GH.commitsFor' auth owner repo)

-- |Get user information for every user who authored a commit.
getContributors
  :: Maybe GH.Auth -> GH.Name GH.Owner -> GH.Name GH.Repo
  -> IO [Contributor]
getContributors auth owner repo = do

  commits <- getCommits auth owner repo

  let
    -- Get the login for every user who authored a commit,
    -- in order from most to fewest commits.
    commitAuthors :: [GH.SimpleUser]
    commitAuthors = commits
                  & mapMaybe GH.commitAuthor
                  & frequency
                  & sortBy (\(_,i) (_,j) -> compare j i)
                  & fmap fst

  commitAuthorInfo <- getAllUserInfo auth commitAuthors

  return $ toContributor <$> commitAuthorInfo

-- |Convert a |GH.User| value to a |Contributor| value.
toContributor :: GH.User -> Contributor
toContributor commitAuthor = Contributor name login
  where
    name = fromMaybe login (GH.userName commitAuthor)
    login = GH.untagName (GH.userLogin commitAuthor)


-- * Utils

frequency :: (Ord a) => [a] -> [(a, Int)]
frequency xs = toList (fromListWith (+) [(x, 1) | x <- xs])

tshow :: Show a => a -> Text
tshow = T.pack . show

fromRight :: Show e => Either e a -> IO a
fromRight = either (fail . show) return