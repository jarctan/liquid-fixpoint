{-# LANGUAGE CPP                        #-}
{-# LANGUAGE DeriveDataTypeable         #-}
{-# LANGUAGE DeriveGeneric              #-}
{-# LANGUAGE FlexibleInstances          #-}
{-# LANGUAGE OverloadedStrings          #-}
{-# LANGUAGE ScopedTypeVariables        #-}
{-# LANGUAGE StandaloneDeriving         #-}
{-# LANGUAGE TypeFamilies               #-}
{-# LANGUAGE ViewPatterns               #-}
{-# LANGUAGE PatternGuards              #-}

{-# OPTIONS_GHC -Wno-orphans            #-}

-- | This module contains Haskell variables representing globally visible names.
--   Rather than have strings floating around the system, all constant names
--   should be defined here, and the (exported) variables should be used and
--   manipulated elsewhere.

module Language.Fixpoint.Types.Names (

  -- * Symbols
    Symbol
  , Symbolic (..)
  , LocSymbol
  , LocText
  , symbolicString

  -- * Conversion to/from Text
  , symbolSafeText
  , symbolSafeString
  , symbolText
  , symbolString
  , symbolBuilder
  , buildMany

  -- Predicates
  , isPrefixOfSym
  , isSuffixOfSym
  , isNonSymbol
  , isLitSymbol
  , isTestSymbol
  -- , isCtorSymbol
  , isNontrivialVV
  , isDummy
  , isFixKey

  -- * Destructors
  , prefixOfSym
  , suffixOfSym
  , stripPrefix
  , stripSuffix
  , consSym
  , unconsSym
  , dropSym
  , dropPrefixOfSym
  , headSym
  , lengthSym

  -- * Transforms
  , nonSymbol
  , vvCon
  , tidySymbol
  , unKArgSymbol

  -- * Widely used prefixes
  , anfPrefix
  , tempPrefix
  , vv
  , symChars

  -- * Creating Symbols
  , dummySymbol
  , intSymbol
  , tempSymbol
  , gradIntSymbol
  , appendSymbolText
  , hvarArgSymbol

  -- * Wrapping Symbols
  , litSymbol
  , bindSymbol
  , testSymbol
  , renameSymbol
  , kArgSymbol
  , existSymbol
  , suffixSymbol
  , mappendSym

  -- * Unwrapping Symbols
  , unLitSymbol

  -- * Hardwired global names
  , dummyName
  , preludeName
  , boolConName
  , boolLConName
  , funConName
  , listConName
  , listLConName
  , tupConName
  , setConName
  , mapConName
  , arrayConName
  , strConName
  , charConName
  , nilName
  , consName
  , vvName
  , sizeName
  , bitVecName
  -- , bvAndName, bvOrName, bvSubName, bvAddName
  , intbv32Name, intbv64Name, bv32intName, bv64intName
  , propConName

  -- HKT , tyAppName
  , isPrim
  , prims
  , mulFuncName
  , divFuncName

  -- * Casting function names
  , setToIntName, bitVecToIntName, mapToIntName, boolToIntName, realToIntName, toIntName, tyCastName
  , setApplyName, bitVecApplyName, mapApplyName, boolApplyName, realApplyName, intApplyName
  , applyName
  , coerceName

  , lambdaName
  , lamArgSymbol
  , isLamArgSymbol

) where

import           Control.DeepSeq             (NFData (..))
import           Control.Arrow               (second)
import           Data.ByteString.Builder     (Builder)
import           Data.Char                   (ord)
import           Data.Maybe                  (fromMaybe)
import           Data.Generics               (Data)
import           Data.Hashable               (Hashable (..))
import qualified Data.HashSet                as S hiding (size)
import           Data.Interned
import           Data.Interned.Internal.Text
import           Data.String                 (IsString(..))
import qualified Data.Text                   as T
import qualified Data.Store                  as S
import           Data.Typeable               (Typeable)
import qualified GHC.Arr                     as Arr
import           GHC.Generics                (Generic)
import           Text.PrettyPrint.HughesPJ   (text)
import           Language.Fixpoint.Types.PrettyPrint
import           Language.Fixpoint.Types.Spans
import           Language.Fixpoint.Utils.Builder as Builder (fromText)
import Data.Functor.Contravariant (Contravariant(contramap))
import qualified Data.Binary as B
import qualified Data.Aeson       as Aeson
import qualified Data.Aeson.Types as Aeson

---------------------------------------------------------------
-- | Symbols --------------------------------------------------
---------------------------------------------------------------

deriving instance Data     InternedText
deriving instance Typeable InternedText
deriving instance Generic  InternedText

{- type SafeText = {v: T.Text | IsSafe v} @-}
type SafeText = T.Text

-- | Invariant: a `SafeText` is made up of:
--
--     ['0'..'9'] ++ ['a'...'z'] ++ ['A'..'Z'] ++ '$'
--
--   If the original text has ANY other chars, it is represented as:
--
--     lq$i
--
--   where i is a unique integer (for each text)

data Symbol
  = S { _symbolId      :: !Id
      , symbolRaw      :: T.Text
      , symbolEncoded  :: T.Text
      }
    deriving (Data, Typeable, Generic)

instance Eq Symbol where
  S i _ _ == S j _ _ = i == j

instance Ord Symbol where
  -- compare (S i _ _) (S j _ _) = compare i j
  -- compare s1 s2 = compare (symbolString s1) (symbolString s2)
  compare s1 s2 = compare (symbolText s1) (symbolText s2)

instance Interned Symbol where
  type Uninterned Symbol = T.Text
  newtype Description Symbol = DT T.Text deriving (Eq)
  describe     = DT
  identify i t = S i t (encode t)
  cache        = sCache

instance Uninternable Symbol where
  unintern (S _ t _) = t

instance Hashable (Description Symbol) where
  hashWithSalt s (DT t) = {-# SCC "hashWithSalt-Description-Symbol" #-} hashWithSalt s t

instance Hashable Symbol where
  -- NOTE: hash based on original text rather than id
  hashWithSalt s (S _ t _) = hashWithSalt s t

instance NFData Symbol where
  rnf S {} = ()

instance S.Store Symbol where
  poke = S.poke . symbolText
  peek = textSymbol <$> S.peek
  size = contramap symbolText S.size

instance B.Binary Symbol where
  get = textSymbol <$> B.get
  put = B.put . symbolText

instance Aeson.ToJSON Symbol where
  toJSON = Aeson.toJSON . symbolText

instance Aeson.FromJSON Symbol where
  parseJSON = fmap textSymbol . Aeson.parseJSON

instance Aeson.ToJSONKey Symbol where
  toJSONKey = Aeson.toJSONKeyText symbolText

instance Aeson.FromJSONKey Symbol where
  fromJSONKey = Aeson.FromJSONKeyText textSymbol

sCache :: Cache Symbol
sCache = mkCache
{-# NOINLINE sCache #-}

instance IsString Symbol where
  fromString = textSymbol . T.pack

instance Show Symbol where
  show = show . symbolRaw

mappendSym :: Symbol -> Symbol -> Symbol
mappendSym s1 s2 = textSymbol $ mappend s1' s2'
    where
      s1'        = symbolText s1
      s2'        = symbolText s2

instance PPrint Symbol where
  pprintTidy _ = text . symbolString

instance Fixpoint T.Text where
  toFix = text . T.unpack

{- | [NOTE: SymbolText]
	Use `symbolSafeText` if you want it to machine-readable,
        but `symbolText`     if you want it to be human-readable.
 -}

instance Fixpoint Symbol where
  toFix = toFix . checkedText -- symbolSafeText

checkedText :: Symbol -> T.Text
checkedText x
  | Just (c, t') <- T.uncons t
  , okHd c && T.all okChr t'   = t
  | otherwise                  = symbolSafeText x
  where
    t     = symbolText x
    okHd  = (`S.member` alphaChars)
    okChr = (`S.member` symChars)

---------------------------------------------------------------------------
-- | Located Symbols -----------------------------------------------------
---------------------------------------------------------------------------

type LocSymbol = Located Symbol
type LocText   = Located T.Text

isDummy :: (Symbolic a) => a -> Bool
isDummy a = isPrefixOfSym (symbol dummyName) (symbol a)

instance Symbolic a => Symbolic (Located a) where
  symbol = symbol . val

---------------------------------------------------------------------------
-- | Decoding Symbols -----------------------------------------------------
---------------------------------------------------------------------------

symbolText :: Symbol -> T.Text
symbolText = symbolRaw

{-# SCC symbolString #-}
symbolString :: Symbol -> String
symbolString = T.unpack . symbolText

symbolSafeText :: Symbol -> SafeText
symbolSafeText = symbolEncoded

symbolSafeString :: Symbol -> String
symbolSafeString = T.unpack . symbolSafeText

---------------------------------------------------------------------------
-- | Encoding Symbols -----------------------------------------------------
---------------------------------------------------------------------------

-- INVARIANT: All strings *must* be built from here

{-# SCC textSymbol #-}
textSymbol :: T.Text -> Symbol
textSymbol = intern

encode :: T.Text -> SafeText
encode t
  | isFixKey t     = T.append "key$" t
  | otherwise      = encodeUnsafe t

isFixKey :: T.Text -> Bool
isFixKey x = S.member x keywords

{-# SCC encodeUnsafe #-}
encodeUnsafe :: T.Text -> T.Text
encodeUnsafe t = T.pack $ pad $ go $ T.unpack (prefixAlpha t)
  where
    pad cs@('$':_) = 'z' : '$' : cs
    pad cs = cs
    go [] = []
    go (c:cs) =
      if isUnsafeChar c then
        '$' : shows (ord c) ('$' : go cs)
      else
        c : go cs

prefixAlpha :: T.Text -> T.Text
prefixAlpha t
  | isAlpha0 t = t
  | otherwise  = T.append "fix$" t

isAlpha0 :: T.Text -> Bool
isAlpha0 t = case T.uncons t of
               Just (c, _) -> S.member c alphaChars
               Nothing     -> False

isUnsafeChar :: Char -> Bool
isUnsafeChar c =
  let ic = ord c
   in ic >= Arr.numElements okSymChars || not (okSymChars Arr.! ic)

keywords :: S.HashSet T.Text
keywords   = S.fromList [ "env"
                        , "id"
                        , "tag"
                        , "qualif"
                        , "constant"
                        , "cut"
                        , "bind"
                        , "constraint"
                        , "lhs"
                        , "rhs"
                        , "NaN"
                        , "min"
                        , "map"
                        ]

-- | RJ: We allow the extra 'unsafeChars' to allow parsing encoded symbols.
--   e.g. the raw string "This#is%$inval!d" may get encoded as "enc%12"
--   and serialized as such in the fq/bfq file. We want to allow the parser
--   to then be able to read the above back in.

alphaChars :: S.HashSet Char
alphaChars = S.fromList $ ['a' .. 'z'] ++ ['A' .. 'Z']

numChars :: S.HashSet Char
numChars = S.fromList ['0' .. '9']

safeChars :: S.HashSet Char
safeChars = alphaChars `mappend`
            numChars   `mappend`
            S.fromList ['_', '.']

symChars :: S.HashSet Char
symChars =  safeChars `mappend`
            S.fromList ['%', '#', '$', '\'']

okSymChars :: Arr.Array Int Bool
okSymChars =
    Arr.listArray (0, maxChar) [ S.member (toEnum i) safeChars | i <- [0..maxChar]]
  where
    cs = S.toList safeChars
    maxChar = ord (maximum cs)

isPrefixOfSym :: Symbol -> Symbol -> Bool
isPrefixOfSym (symbolText -> p) (symbolText -> x) = p `T.isPrefixOf` x

isSuffixOfSym :: Symbol -> Symbol -> Bool
isSuffixOfSym (symbolText -> p) (symbolText -> x) = p `T.isSuffixOf` x


headSym :: Symbol -> Char
headSym (symbolText -> t) = T.head t

consSym :: Char -> Symbol -> Symbol
consSym c (symbolText -> s) = symbol $ T.cons c s

unconsSym :: Symbol -> Maybe (Char, Symbol)
unconsSym (symbolText -> s) = second symbol <$> T.uncons s

-- singletonSym :: Char -> Symbol -- Yuck
-- singletonSym = (`consSym` "")

lengthSym :: Symbol -> Int
lengthSym (symbolText -> t) = T.length t

dropSym :: Int -> Symbol -> Symbol
dropSym n (symbolText -> t) = symbol $ T.drop n t

dropPrefixOfSym :: Symbol -> Symbol
dropPrefixOfSym =
  symbol .  T.drop (T.length symSepName) .  snd .  T.breakOn symSepName .  symbolText

prefixOfSym :: Symbol -> Symbol
prefixOfSym = symbol . fst . T.breakOn symSepName . symbolText

suffixOfSym :: Symbol -> Symbol
suffixOfSym = symbol . snd . T.breakOnEnd symSepName . symbolText

stripPrefix :: Symbol -> Symbol -> Maybe Symbol
stripPrefix p x = symbol <$> T.stripPrefix (symbolText p) (symbolText x)

stripSuffix :: Symbol -> Symbol -> Maybe Symbol
stripSuffix p x = symbol <$> T.stripSuffix (symbolText p) (symbolText x)


--------------------------------------------------------------------------------
-- | Use this **EXCLUSIVELY** when you want to add stuff in front of a Symbol
--------------------------------------------------------------------------------
suffixSymbol :: Symbol -> Symbol -> Symbol
suffixSymbol  x y = symbol $ suffixSymbolText (symbolText x) (symbolText y)

suffixSymbolText :: T.Text -> T.Text -> T.Text
suffixSymbolText  x y = x <> symSepName <> y

vv                  :: Maybe Integer -> Symbol
-- vv (Just i)         = symbol $ symbolSafeText vvName `T.snoc` symSepName `mappend` T.pack (show i)
vv (Just i)         = intSymbol vvName i
vv Nothing          = vvName

isNontrivialVV      :: Symbol -> Bool
isNontrivialVV      = (vv Nothing /=)

vvCon, dummySymbol :: Symbol
vvCon       = vvName `suffixSymbol` "F"
dummySymbol = dummyName

-- ctorSymbol :: Symbol -> Symbol
-- ctorSymbol s = ctorPrefix `mappendSym` s

-- isCtorSymbol :: Symbol -> Bool
-- isCtorSymbol = isPrefixOfSym ctorPrefix

-- | 'testSymbol c' creates the `is-c` symbol for the adt-constructor named 'c'.
testSymbol :: Symbol -> Symbol
testSymbol s = testPrefix `mappendSym` s

isTestSymbol :: Symbol -> Bool
isTestSymbol = isPrefixOfSym testPrefix

litSymbol :: Symbol -> Symbol
litSymbol s = litPrefix `mappendSym` s

isLitSymbol :: Symbol -> Bool
isLitSymbol = isPrefixOfSym litPrefix

unLitSymbol :: Symbol -> Maybe Symbol
unLitSymbol = stripPrefix litPrefix

intSymbol :: (Show a) => Symbol -> a -> Symbol
intSymbol x i = symbol $ symbolText x `suffixSymbolText` T.pack (show i)

appendSymbolText :: Symbol -> T.Text -> T.Text
appendSymbolText s t = encode (symbolText s <> symSepName <> t)

tempSymbol :: Symbol -> Integer -> Symbol
tempSymbol prefix = intSymbol (tempPrefix `mappendSym` prefix)

renameSymbol :: Symbol -> Int -> Symbol
renameSymbol prefix = intSymbol (renamePrefix `mappendSym` prefix)

kArgSymbol :: Symbol -> Symbol -> Symbol
kArgSymbol x k = (kArgPrefix `mappendSym` x) `suffixSymbol` k

existSymbol :: Symbol -> Integer -> Symbol
existSymbol prefix = intSymbol (existPrefix `mappendSym` prefix)

gradIntSymbol :: Integer -> Symbol
gradIntSymbol = intSymbol gradPrefix

hvarArgSymbol :: Symbol -> Int -> Symbol
hvarArgSymbol s i = intSymbol (suffixSymbol hvarPrefix s) i


-- | Used to define functions corresponding to binding predicates
--
-- The integer is the BindId.
bindSymbol :: Integer -> Symbol
bindSymbol = intSymbol bindPrefix

tempPrefix, anfPrefix, renamePrefix, litPrefix, gradPrefix, bindPrefix :: Symbol
tempPrefix   = "lq_tmp$"
anfPrefix    = "lq_anf$"
renamePrefix = "lq_rnm$"
litPrefix    = "lit$"
gradPrefix   = "grad$"
bindPrefix   = "b$"

testPrefix  :: Symbol
testPrefix   = "is$"

-- ctorPrefix  :: Symbol
-- ctorPrefix   = "mk$"

kArgPrefix, existPrefix, hvarPrefix :: Symbol
kArgPrefix  = "lq_karg$"
existPrefix = "lq_ext$"
hvarPrefix  = "nnf_arg$"

-- | `unKArgSymbol` is like `tidySymbol` (see comment below) except it
--    (a) *removes* the argument-index, and
--    (b) *preserves* the `nnf_arg` (without replacing it with `$`)
--    For example `unKArgSymbol lq_karg$nnf_arg$##k0##0##k0` ---> `nnf_arg##k0`

unKArgSymbol :: Symbol -> Symbol
unKArgSymbol = unSuffixSymbol . unSuffixSymbol . unPrefixSymbol kArgPrefix

-- | 'tidySymbol' is used to prettify the names of parameters of kvars appearing in solutions.(*)
--   For example, if you have a kvar $k0 with two parameters, you may have a solution that looks like
--       0 <  lq_karg$nnf_arg$##k0##0##k0
--   where we know it is a kvar-arg because of the
--      - `kArgPrefix` (`lq_arg`)
--      - `hvarArgPrefix` (`nnf_arg`)
--      - `k0` the name of the kvar
--      - `0`  the parameter index
--      - `k0` again (IDK why?!)
--    all of which are separated by `##`
--   So `tidySymbol` tests if indeed it is a `kArgPrefix`-ed symbol and if so converts
--      `lq_karg$nnf_arg$##k0##0##k0` ----> `$k0##0`

tidySymbol :: Symbol -> Symbol
tidySymbol s
  | s == s'   = s
  | otherwise = s''
  where
    s'        = unPrefixSymbol kArgPrefix s
    s''       = consSym '$' . unPrefixSymbol symSepName . unSuffixSymbol . unPrefixSymbol hvarPrefix $ s'

unPrefixSymbol :: Symbol -> Symbol -> Symbol
unPrefixSymbol p s = fromMaybe s (stripPrefix p s)

unSuffixSymbol :: Symbol -> Symbol
unSuffixSymbol s@(symbolText -> t)
  = maybe s symbol $ T.stripSuffix symSepName $ fst $ T.breakOnEnd symSepName t

-- takeWhileSym :: (Char -> Bool) -> Symbol -> Symbol
-- takeWhileSym p (symbolText -> t) = symbol $ T.takeWhile p t


nonSymbol :: Symbol
nonSymbol = ""

isNonSymbol :: Symbol -> Bool
isNonSymbol = (== nonSymbol)

------------------------------------------------------------------------------
-- | Values that can be viewed as Symbols
------------------------------------------------------------------------------

class Symbolic a where
  symbol :: a -> Symbol

symbolicString :: (Symbolic a) => a -> String
symbolicString = symbolString . symbol

instance Symbolic T.Text where
  symbol = textSymbol

instance Symbolic String where
  symbol = symbol . T.pack

instance Symbolic Symbol where
  symbol = id

symbolBuilder :: (Symbolic a) => a -> Builder
symbolBuilder = Builder.fromText . symbolSafeText . symbol

{-# INLINE buildMany #-}
buildMany :: [Builder] -> Builder
buildMany []     = mempty
buildMany [b]    = b
buildMany (b:bs) = b <> mconcat [ " " <> b' | b' <- bs ]

----------------------------------------------------------------------------
--------------- Global Name Definitions ------------------------------------
----------------------------------------------------------------------------

lambdaName :: Symbol
lambdaName = "smt_lambda"

lamArgPrefix :: Symbol
lamArgPrefix = "lam_arg"

lamArgSymbol :: Int -> Symbol
lamArgSymbol = intSymbol lamArgPrefix

isLamArgSymbol :: Symbol -> Bool
isLamArgSymbol = isPrefixOfSym lamArgPrefix

setToIntName, bitVecToIntName, mapToIntName, realToIntName, toIntName, tyCastName :: Symbol
setToIntName    = "set_to_int"
bitVecToIntName = "bitvec_to_int"
mapToIntName    = "map_to_int"
realToIntName   = "real_to_int"
toIntName       = "cast_as_int"
tyCastName      = "cast_as"

boolToIntName :: (IsString a) => a
boolToIntName   = "bool_to_int"

setApplyName, bitVecApplyName, mapApplyName, boolApplyName, realApplyName, intApplyName :: Int -> Symbol
setApplyName    = intSymbol "set_apply_"
bitVecApplyName = intSymbol "bitvec_apply"
mapApplyName    = intSymbol "map_apply_"
boolApplyName   = intSymbol "bool_apply_"
realApplyName   = intSymbol "real_apply_"
intApplyName    = intSymbol "int_apply_"

applyName :: Symbol
applyName = "apply"

coerceName :: Symbol
coerceName = "coerce"

preludeName, dummyName, boolConName, boolLConName, funConName :: Symbol
preludeName  = "Prelude"
dummyName    = "LIQUID$dummy"
boolConName  = "Bool"
boolLConName  = "bool"
funConName   = "->"


listConName, listLConName, tupConName, propConName, _hpropConName, vvName, setConName, mapConName, arrayConName:: Symbol
listConName  = "[]"
listLConName = "List"
tupConName   = "Tuple"
setConName   = "Set_Set"
mapConName   = "Map_t"
arrayConName = "Array_t"
vvName       = "VV"
propConName  = "Prop"
_hpropConName = "HProp"

strConName, charConName :: (IsString a) => a
strConName   = "Str"
charConName  = "Char"
-- symSepName   :: Char
-- symSepName   = '#' -- DO NOT EVER CHANGE THIS

symSepName   :: (IsString a) => a
symSepName   = "##"

-- nilName, consName, size32Name, size64Name, bitVecName :: Symbol
-- nilName      = "nil"
-- consName     = "cons"
-- size32Name   = "Size32"
-- size64Name   = "Size64"
-- bitVecName   = "BitVec"

-- bvOrName, bvAndName, bvSubName, bvAddName,
intbv32Name, intbv64Name, bv32intName, bv64intName :: Symbol
-- bvOrName    = "bvor"
-- bvAndName   = "bvand"
-- bvSubName   = "bvsub"
-- bvAddName   = "bvadd"
intbv32Name = "int_to_bv32"
intbv64Name = "int_to_bv64"
bv32intName = "bv32_to_int"
bv64intName = "bv64_to_int"

nilName, consName, sizeName, bitVecName :: Symbol
nilName       = "nil"
consName      = "cons"
sizeName      = "Size"
bitVecName    = "BitVec"


mulFuncName, divFuncName :: Symbol
mulFuncName  = "Z3_OP_MUL"
divFuncName  = "Z3_OP_DIV"

isPrim :: Symbol -> Bool
isPrim x = S.member x prims

prims :: S.HashSet Symbol
prims = S.fromList
  [ propConName
  , _hpropConName
  , vvName
  , "Pred"
  , "List"
  , "[]"
  , "bool"
  -- , "int"
  -- , "real"
  , setConName
  , charConName
  , "Set_sng"
  , "Set_cup"
  , "Set_cap"
  , "Set_dif"
  , "Set_emp"
  , "Set_empty"
  , "Set_mem"
  , "Set_sub"
  , mapConName
  , "Map_select"
  , "Map_store"
  , "Map_union"
  , "Map_default"
  , arrayConName
  -- Currently we parse X in "SizeX" to get the bitvec size
  -- so there is no finite set of names to add here...
  -- , size32Name
  -- , size64Name
  , bitVecName
  -- , bvOrName
  -- , bvAndName
  , "FAppTy"
  , nilName
  , consName
  ]

{-
-------------------------------------------------------------------------------
-- | Memoized Decoding
-------------------------------------------------------------------------------

{-# NOINLINE symbolMemo #-}
symbolMemo :: IORef (M.HashMap Int T.Text)
symbolMemo = unsafePerformIO (newIORef M.empty)

{-# NOINLINE memoEncode #-}
memoEncode :: T.Text -> Int
memoEncode t = unsafePerformIO $
                 atomicModifyIORef symbolMemo $ \m ->
                    (M.insert i t m, i)
  where
    i        = internedTextId $ intern t

{-# NOINLINE memoDecode #-}
memoDecode :: Int -> T.Text
memoDecode i = unsafePerformIO $
                 safeLookup msg i <$> readIORef symbolMemo
               where
                 msg = "Symbol Decode Error: " ++ show i

-}
