{-# LANGUAGE OverloadedStrings #-}

module Logic.Login
  ( LoginResult(..)
  , login ) where

--------------------------------------------------------------------------------
import           Graphics.UI.Threepenny.Core
import qualified Crypto.BCrypt           as Crypt  (validatePassword)
import           Data.ByteString.Char8             (ByteString(..), pack, unpack)
import           Control.Exception                 (catch)
import qualified System.Directory        as Dir    (getCurrentDirectory)
--DB----------------------------------------------------------------------------
-- Пока что используем SQLite. После заменим либо MySQL, либо PostgreSQL.
import qualified Database.SQLite.Simple  as Sqlite (ResultError(..)
                                                   ,field, open, query)
import           Database.SQLite.Simple            (FromRow(..), Only(..))
--------------------------------------------------------------------------------

type Email    = String
type Password = String

-- | Уточняет, в каком именно
-- поле совершена ошибка ввода.
-- Тем самым, дает дополнительную
-- информацию Frontend-логике.
data MistakeIn =
  InEmailField
 |InPasswordField
 |InBothFields
 deriving (Show)

-- | Описывает результат запроса
-- пользователя на вход.
data LoginResult =
  InvalidValues MistakeIn -- Поля входа заполнены не правильно. (см. checkReceivedValues)
 |CorrectPassword
 |IncorrectPassword
 |NonexistentAccount
 |BlockedAccount -- TODO: Продумать логику. (Добавить поле в базу?)
 deriving (Show)

newtype HashedPassword = HashedPassword { hpValue :: Password }

instance FromRow HashedPassword where
  fromRow = HashedPassword <$> Sqlite.field

-- | Реализация Backend-части авторизации.
-- Возвращает LoginResult, тем самым
-- делегируя Frontend-логику модулю GUI.Login.
login :: Element -> Element -> UI LoginResult
login inpEmail inpPassword = do
    email    <- getValue inpEmail
    password <- getValue inpPassword
    worker email password
    where worker email password =
            case (checkReceivedValues email password) of
              Just mistakeIn -> return (InvalidValues mistakeIn)
              Nothing        -> do
                mPasswordHash <- liftIO (getHashedPassword email)
                return $
                  case mPasswordHash of
                    Nothing           -> NonexistentAccount
                    Just passwordHash -> validatePassword passwordHash password
          getValue = get value
          validatePassword ph pd
           |Crypt.validatePassword (pack ph) (pack pd) == True = CorrectPassword
           |otherwise = IncorrectPassword

-- | Проверяет, могут ли существовать
-- введенные пользователем значения.
checkReceivedValues :: Email -> Password -> Maybe MistakeIn
checkReceivedValues email password
  |checkPassword password !&& checkEmail email = Just InBothFields
  |(not . checkEmail) email       = Just InEmailField
  |(not . checkPassword) password = Just InPasswordField
  |otherwise                      = Nothing
  where (!&&) a b = (not a) && (not b)
        isBlank value = length value == 0
        checkPassword = (not . isBlank)
        checkEmail email -- | Проверяет, может ли существовать подобный email.
         |isBlank email          = False
         |(not . elem '@') email = False -- Нет '@' в строке
         |(length . flip filter email) (== '@') /= 1 = False -- Несколько '@'
         |(not . elem '.' . afterEmailSymbol) email  = False -- Нет '.' после '@'
         |last email == '.' = False -- Заканчивается на '.'
         |otherwise         = True
         where afterEmailSymbol email = (tail . snd . flip break email) (== '@')

-- Получает хеш пароля по указанному значению
-- поля email. Если пользователь отсутствует в базе,
-- возвращает Nothing.
getHashedPassword :: Email -> IO (Maybe Password)
getHashedPassword email =
  let query = "SELECT PASSWORD FROM USERS WHERE EMAIL = ?"
  in do
    currentDir <- Dir.getCurrentDirectory
    conn       <- Sqlite.open (currentDir ++ "/users.db")
    sqlResult  <- Sqlite.query conn query (Only email) :: IO [HashedPassword]
    return $
      case sqlResult of
        []               -> Nothing
        [hashedPassword] -> Just $ hpValue hashedPassword