{-# LANGUAGE NamedFieldPuns   #-}
{-# LANGUAGE NumDecimals      #-}
{-# LANGUAGE ParallelListComp #-}
{-# LANGUAGE ViewPatterns     #-}
-- | This module defines the 'Value' type which is a generic
-- representation of values that satisfy some Theta schema. The
-- 'Value' type gives us an intermediate representation that helps us
-- convert between different representations that share a Theta schema
-- (Haskell to Avro, for example), without coupling the formats
-- directly.
--
-- Compare this to similar types in @avro@ and @aeson@.
module Theta.Value where

import           Control.Monad        (replicateM)

import           Data.ByteString.Lazy (ByteString)
import qualified Data.ByteString.Lazy as LBS
import           Data.HashMap.Strict  (HashMap)
import qualified Data.HashMap.Strict  as HashMap
import qualified Data.HashSet         as HashSet
import           Data.Int             (Int32, Int64)
import qualified Data.List.NonEmpty   as NonEmpty
import           Data.Text            (Text)
import qualified Data.Text            as Text
import qualified Data.Time            as Time
import           Data.Time.Calendar   (Day)
import           Data.Time.Clock      (UTCTime)
import           Data.Vector          (Vector)
import qualified Data.Vector          as Vector

import           Test.QuickCheck      (Arbitrary (arbitrary), Gen, choose,
                                       elements, frequency, listOf, scale)

import           Theta.Name           (Name)
import qualified Theta.Types          as Theta

-- | A generic representation of data that could be represented by a
-- Theta schema.
data BaseValue = Boolean !Bool
               | Bytes !ByteString
               | Int {-# UNPACK #-} !Int32
               | Long {-# UNPACK #-} !Int64
               | Float {-# UNPACK #-} !Float
               | Double {-# UNPACK #-} !Double
               | String {-# UNPACK #-} !Text
               | Date !Day
               | Datetime {-# UNPACK #-} !UTCTime

               | Array {-# UNPACK #-} !(Vector Value)
                 -- ^ Each 'Value' in an array should have the same
                 -- type.
               | Map !(HashMap Text Value)
                 -- ^ A map can (currently) only have 'Text'
                 -- keys. Each 'Value' in a map should have the same
                 -- type.
               | Optional !(Maybe Value)

               | Enum !Theta.EnumSymbol
                 -- ^ An enum value is a specific enum symbol.
               | Record {-# UNPACK #-} !(Vector Value)
                 -- ^ A record is a map from field names to
                 -- values.
               | Variant {-# UNPACK #-} !Name {-# UNPACK #-} !(Vector Value)
                 -- ^ A variant is a map from names to cases. Each
                 -- case is a 'Value' that is a record with the field
                 -- names and types of the corresponding case of the
                 -- variant.
           deriving (Show, Eq)

-- | A generic representation of data along with the Theta schema it
-- corresponds to.
--
-- Every 'Value' has a corresponding 'Theta.Type' to account for
-- newtypes as well as schemas for constructed types like records and
-- variants.
--
-- 'Value' has the invariant that 'type_' has to match the type of the
-- associated 'BaseValue'. This is awkward to capture at the Haskell
-- type level, but can be relied on by code processing 'Value's and
-- should be preserved by code creating 'Value's.
data Value = Value
  { type_ :: !Theta.Type
    -- ^ The schema this base value corresponds to. This could be
    -- important even for primitive types because they might be
    -- wrapped in a newtype.
    --
    -- The type always has to match the 'BaseValue' it's attached to.
  , value :: !BaseValue
    -- ^ The actual value.
  } deriving (Eq, Show)

-- * Primitive Values

-- $ These are the canonical 'Value's for primitive types. Each type
-- of primitive value is associated with its type and an empty module
-- called "base" ('Theta.baseModule').

boolean :: Bool -> Value
boolean = Value Theta.bool' . Boolean

bytes :: ByteString -> Value
bytes = Value Theta.bytes' . Bytes

int :: Int32 -> Value
int = Value Theta.int' . Int

long :: Int64 -> Value
long = Value Theta.long' . Long

float :: Float -> Value
float = Value Theta.float' . Float

double :: Double -> Value
double = Value Theta.double' . Double

string :: Text -> Value
string = Value Theta.string' . String

date :: Day -> Value
date = Value Theta.date' . Date

datetime :: UTCTime -> Value
datetime = Value Theta.datetime' . Datetime

-- * Testing

-- | Does the given type match the given base value?
checkBaseValue :: Theta.Type -> BaseValue -> Bool
checkBaseValue Theta.Type { Theta.baseType, Theta.module_ } baseValue =
  case (baseType, baseValue) of
    -- primitives
    (Theta.Bool', Boolean{})      -> True
    (Theta.Bytes', Bytes{})       -> True
    (Theta.Int', Int{})           -> True
    (Theta.Long', Long{})         -> True
    (Theta.Float', Float{})       -> True
    (Theta.Double', Double{})     -> True
    (Theta.String', String{})     -> True
    (Theta.Date', Date{})         -> True
    (Theta.Datetime', Datetime{}) -> True

    -- containers
    (Theta.Array' item, Array values) ->
      all (checkBaseValue item) (value <$> values)
    (Theta.Map' item, Map hashmap) ->
      all (checkBaseValue item) (value <$> hashmap)
    (Theta.Optional' item, Optional x) ->
      all (checkBaseValue item) (value <$> x)

    -- named types
    (Theta.Enum' _ symbols, Enum symbol) -> symbol `elem` symbols
    (Theta.Record' _ fields, Record values) -> checkFields fields values
    (Theta.Variant' _ cases, Variant caseName values) ->
      case lookup caseName $ [(Theta.caseName c, c) | c <- NonEmpty.toList cases] of
        Just case_ -> checkFields (Theta.caseParameters case_) values
        Nothing    -> False

    (Theta.Newtype' _ type_, baseValue) -> checkBaseValue type_ baseValue

    (Theta.Reference' name, baseValue) -> case Theta.lookupName name module_ of
      Right type_ -> checkBaseValue type_ baseValue
      Left _      -> False

    (_, _) -> False

  where checkFields fields values =
          and [ checkBaseValue (Theta.fieldType field) value
              | field           <- Theta.fields fields
              | Value { value } <- Vector.toList values
              ]

-- | Does the 'Theta.Type' set for this value match its underlying
-- 'BaseValue'?
checkValue :: Value -> Bool
checkValue Value { value, type_ } = checkBaseValue type_ value

-- ** QuickCheck Generators

-- | Return a random generator that produces Theta values that match
-- the given schema.
--
-- Warning: by default, this generator will produce prohibilitively
-- large values or even loop forever.
--
-- We can override the generator used for specific types—this is
-- designed for dealing with recursive types, but can be used to
-- customize the behavior in general. (Note: this does not handle
-- changing overriding primitive types, but this might be fixed in the
-- future.)
--
-- The size parameter is reduced by 10 each time an overridden
-- generator is used. We can use this to write generators that recurse
-- at first, but stop once the generated value has gotten too big:
--
-- @
-- genRecursive = do
--   size <- getSize
--   if size <= 10
--     then pure $ Value (theta @Recursive) $ Variant "recursive.Nil" []
--     else ...
-- @
--
-- We would then use this as an override for the
-- @"recursive.Recursive"@ type:
--
-- @
-- genValue' [("recursive.Recursive", genRecursive)] (theta @Recursive)
-- @
genValue' :: HashMap Name (Gen Value) -> Theta.Type -> Gen Value
genValue' overrides = go
  where go t = case Theta.baseType t of
          Theta.Bool'          -> boolean <$> arbitrary
          Theta.Bytes'         -> bytes . LBS.pack <$> arbitrary
          Theta.Int'           -> int <$> arbitrary
          Theta.Long'          -> long <$> arbitrary
          Theta.Float'         -> float <$> arbitrary
          Theta.Double'        -> double <$> arbitrary
          Theta.String'        -> string . Text.pack <$> arbitrary
          Theta.Date'          -> date <$> genDate
          Theta.Datetime'      -> datetime <$> genDatetime

          Theta.Array' item    -> Value t <$> genArray item
          Theta.Map' item      -> Value t <$> genMap item
          Theta.Optional' item -> Value t <$> genOptional item

          Theta.Reference' name -> tryOverride name $
            case Theta.lookupName name (Theta.module_ t) of
              Right t' -> go t'
              -- Error case should not trigger for validly
              -- constructed Theta types
              Left err -> error err

          Theta.Enum' name symbols -> tryOverride name $
            Value t . Enum <$> elements (NonEmpty.toList symbols)
          Theta.Record' name fields -> tryOverride name $
            Value t . Record <$> genFields fields
          Theta.Variant' name cases -> tryOverride name $ do
            case_ <- elements (NonEmpty.toList cases)
            let toValue = Value t . Variant (Theta.caseName case_)
            toValue <$> genFields (Theta.caseParameters case_)

          Theta.Newtype' name t' -> tryOverride name $
            Value t . value <$> go t'

        tryOverride name normal = case HashMap.lookup name overrides of
          Just gen -> scale (max 0 . subtract 10) gen
          Nothing  -> normal

        genFields (Theta.fields -> f) =
          Vector.fromList <$> mapM go (Theta.fieldType <$> f)

        genArray item = Array . Vector.fromList <$> listOf (go item)

        genMap item = do
          keys   <- HashSet.toList . HashSet.fromList <$> listOf (Text.pack <$> arbitrary)
          values <- replicateM (length keys) (go item)
          pure $ Map $ HashMap.fromList $ keys `zip` values

            -- Generate null with a 5% probability
        genOptional item = frequency
          [ (1, pure $ Optional Nothing)
          , (19, Optional . Just <$> go item)
          ]

        genDate = Time.ModifiedJulianDay <$> arbitrary
        genDatetime = Time.UTCTime <$> genDate <*> inDay
          where inDay = Time.picosecondsToDiffTime . toPico <$> choose (0, dayLength - 1)
                dayLength = 24 * 60 * 60 * 1e6 - 1 -- in μs
                toPico = (* 1e6)

-- | Generate values with the given type.
--
-- Warning: this generator will generate arbitrarily large values or
-- loop forever with recursive types. To handle recursive types, use
-- 'genValue'' and override the generator for recursive types.
genValue :: Theta.Type -> Gen Value
genValue = genValue' HashMap.empty
