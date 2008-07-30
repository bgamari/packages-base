{-# OPTIONS_GHC -XNoImplicitPrelude -XOverlappingInstances -funbox-strict-fields #-}

-- The -XOverlappingInstances flag allows the user to over-ride
-- the instances for Typeable given here.  In particular, we provide an instance
--      instance ... => Typeable (s a) 
-- But a user might want to say
--      instance ... => Typeable (MyType a b)

-----------------------------------------------------------------------------
-- |
-- Module      :  Data.Typeable
-- Copyright   :  (c) The University of Glasgow, CWI 2001--2004
-- License     :  BSD-style (see the file libraries/base/LICENSE)
-- 
-- Maintainer  :  libraries@haskell.org
-- Stability   :  experimental
-- Portability :  portable
--
-- The 'Typeable' class reifies types to some extent by associating type
-- representations to types. These type representations can be compared,
-- and one can in turn define a type-safe cast operation. To this end,
-- an unsafe cast is guarded by a test for type (representation)
-- equivalence. The module "Data.Dynamic" uses Typeable for an
-- implementation of dynamics. The module "Data.Generics" uses Typeable
-- and type-safe cast (but not dynamics) to support the \"Scrap your
-- boilerplate\" style of generic programming.
--
-----------------------------------------------------------------------------

module Data.Typeable
  (

        -- * The Typeable class
        Typeable( typeOf ),     -- :: a -> TypeRep

        -- * Type-safe cast
        cast,                   -- :: (Typeable a, Typeable b) => a -> Maybe b
        gcast,                  -- a generalisation of cast

        -- * Type representations
        TypeRep,        -- abstract, instance of: Eq, Show, Typeable
        TyCon,          -- abstract, instance of: Eq, Show, Typeable
        showsTypeRep,

        -- * Construction of type representations
        mkTyCon,        -- :: String  -> TyCon
        mkTyConApp,     -- :: TyCon   -> [TypeRep] -> TypeRep
        mkAppTy,        -- :: TypeRep -> TypeRep   -> TypeRep
        mkFunTy,        -- :: TypeRep -> TypeRep   -> TypeRep

        -- * Observation of type representations
        splitTyConApp,  -- :: TypeRep -> (TyCon, [TypeRep])
        funResultTy,    -- :: TypeRep -> TypeRep   -> Maybe TypeRep
        typeRepTyCon,   -- :: TypeRep -> TyCon
        typeRepArgs,    -- :: TypeRep -> [TypeRep]
        tyConString,    -- :: TyCon   -> String
        typeRepKey,     -- :: TypeRep -> IO Int

        -- * The other Typeable classes
        -- | /Note:/ The general instances are provided for GHC only.
        Typeable1( typeOf1 ),   -- :: t a -> TypeRep
        Typeable2( typeOf2 ),   -- :: t a b -> TypeRep
        Typeable3( typeOf3 ),   -- :: t a b c -> TypeRep
        Typeable4( typeOf4 ),   -- :: t a b c d -> TypeRep
        Typeable5( typeOf5 ),   -- :: t a b c d e -> TypeRep
        Typeable6( typeOf6 ),   -- :: t a b c d e f -> TypeRep
        Typeable7( typeOf7 ),   -- :: t a b c d e f g -> TypeRep
        gcast1,                 -- :: ... => c (t a) -> Maybe (c (t' a))
        gcast2,                 -- :: ... => c (t a b) -> Maybe (c (t' a b))

        -- * Default instances
        -- | /Note:/ These are not needed by GHC, for which these instances
        -- are generated by general instance declarations.
        typeOfDefault,  -- :: (Typeable1 t, Typeable a) => t a -> TypeRep
        typeOf1Default, -- :: (Typeable2 t, Typeable a) => t a b -> TypeRep
        typeOf2Default, -- :: (Typeable3 t, Typeable a) => t a b c -> TypeRep
        typeOf3Default, -- :: (Typeable4 t, Typeable a) => t a b c d -> TypeRep
        typeOf4Default, -- :: (Typeable5 t, Typeable a) => t a b c d e -> TypeRep
        typeOf5Default, -- :: (Typeable6 t, Typeable a) => t a b c d e f -> TypeRep
        typeOf6Default  -- :: (Typeable7 t, Typeable a) => t a b c d e f g -> TypeRep

  ) where

import qualified Data.HashTable as HT
import Data.Maybe
import Data.Either
import Data.Int
import Data.Word
import Data.List( foldl, intersperse )
import Unsafe.Coerce

#ifdef __GLASGOW_HASKELL__
import GHC.Base
import GHC.Show
import GHC.Err
import GHC.Num
import GHC.Float
import GHC.Real         ( rem, Ratio )
import GHC.IOBase       (IORef,newIORef,unsafePerformIO)

-- These imports are so we can define Typeable instances
-- It'd be better to give Typeable instances in the modules themselves
-- but they all have to be compiled before Typeable
import GHC.IOBase       ( IO, MVar, Exception, ArithException, IOException,
                          ArrayException, AsyncException, Handle, block )
import GHC.ST           ( ST )
import GHC.STRef        ( STRef )
import GHC.Ptr          ( Ptr, FunPtr )
import GHC.ForeignPtr   ( ForeignPtr )
import GHC.Stable       ( StablePtr, newStablePtr, freeStablePtr,
                          deRefStablePtr, castStablePtrToPtr,
                          castPtrToStablePtr )
import GHC.Arr          ( Array, STArray )

#endif

#ifdef __HUGS__
import Hugs.Prelude     ( Key(..), TypeRep(..), TyCon(..), Ratio,
                          Exception, ArithException, IOException,
                          ArrayException, AsyncException, Handle,
                          Ptr, FunPtr, ForeignPtr, StablePtr )
import Hugs.IORef       ( IORef, newIORef, readIORef, writeIORef )
import Hugs.IOExts      ( unsafePerformIO )
        -- For the Typeable instance
import Hugs.Array       ( Array )
import Hugs.ConcBase    ( MVar )
#endif

#ifdef __NHC__
import NHC.IOExtras (IORef,newIORef,readIORef,writeIORef,unsafePerformIO)
import IO (Handle)
import Ratio (Ratio)
        -- For the Typeable instance
import NHC.FFI  ( Ptr,FunPtr,StablePtr,ForeignPtr )
import Array    ( Array )
#endif

#include "Typeable.h"

#ifndef __HUGS__

-------------------------------------------------------------
--
--              Type representations
--
-------------------------------------------------------------

-- | A concrete representation of a (monomorphic) type.  'TypeRep'
-- supports reasonably efficient equality.
data TypeRep = TypeRep !Key TyCon [TypeRep] 

-- Compare keys for equality
instance Eq TypeRep where
  (TypeRep k1 _ _) == (TypeRep k2 _ _) = k1 == k2

-- | An abstract representation of a type constructor.  'TyCon' objects can
-- be built using 'mkTyCon'.
data TyCon = TyCon !Key String

instance Eq TyCon where
  (TyCon t1 _) == (TyCon t2 _) = t1 == t2
#endif

-- | Returns a unique integer associated with a 'TypeRep'.  This can
-- be used for making a mapping with TypeReps
-- as the keys, for example.  It is guaranteed that @t1 == t2@ if and only if
-- @typeRepKey t1 == typeRepKey t2@.
--
-- It is in the 'IO' monad because the actual value of the key may
-- vary from run to run of the program.  You should only rely on
-- the equality property, not any actual key value.  The relative ordering
-- of keys has no meaning either.
--
typeRepKey :: TypeRep -> IO Int
typeRepKey (TypeRep (Key i) _ _) = return i

        -- 
        -- let fTy = mkTyCon "Foo" in show (mkTyConApp (mkTyCon ",,")
        --                                 [fTy,fTy,fTy])
        -- 
        -- returns "(Foo,Foo,Foo)"
        --
        -- The TypeRep Show instance promises to print tuple types
        -- correctly. Tuple type constructors are specified by a 
        -- sequence of commas, e.g., (mkTyCon ",,,,") returns
        -- the 5-tuple tycon.

----------------- Construction --------------------

-- | Applies a type constructor to a sequence of types
mkTyConApp  :: TyCon -> [TypeRep] -> TypeRep
mkTyConApp tc@(TyCon tc_k _) args 
  = TypeRep (appKeys tc_k arg_ks) tc args
  where
    arg_ks = [k | TypeRep k _ _ <- args]

-- | A special case of 'mkTyConApp', which applies the function 
-- type constructor to a pair of types.
mkFunTy  :: TypeRep -> TypeRep -> TypeRep
mkFunTy f a = mkTyConApp funTc [f,a]

-- | Splits a type constructor application
splitTyConApp :: TypeRep -> (TyCon,[TypeRep])
splitTyConApp (TypeRep _ tc trs) = (tc,trs)

-- | Applies a type to a function type.  Returns: @'Just' u@ if the
-- first argument represents a function of type @t -> u@ and the
-- second argument represents a function of type @t@.  Otherwise,
-- returns 'Nothing'.
funResultTy :: TypeRep -> TypeRep -> Maybe TypeRep
funResultTy trFun trArg
  = case splitTyConApp trFun of
      (tc, [t1,t2]) | tc == funTc && t1 == trArg -> Just t2
      _ -> Nothing

-- | Adds a TypeRep argument to a TypeRep.
mkAppTy :: TypeRep -> TypeRep -> TypeRep
mkAppTy (TypeRep tr_k tc trs) arg_tr
  = let (TypeRep arg_k _ _) = arg_tr
     in  TypeRep (appKey tr_k arg_k) tc (trs++[arg_tr])

-- If we enforce the restriction that there is only one
-- @TyCon@ for a type & it is shared among all its uses,
-- we can map them onto Ints very simply. The benefit is,
-- of course, that @TyCon@s can then be compared efficiently.

-- Provided the implementor of other @Typeable@ instances
-- takes care of making all the @TyCon@s CAFs (toplevel constants),
-- this will work. 

-- If this constraint does turn out to be a sore thumb, changing
-- the Eq instance for TyCons is trivial.

-- | Builds a 'TyCon' object representing a type constructor.  An
-- implementation of "Data.Typeable" should ensure that the following holds:
--
-- >  mkTyCon "a" == mkTyCon "a"
--

mkTyCon :: String       -- ^ the name of the type constructor (should be unique
                        -- in the program, so it might be wise to use the
                        -- fully qualified name).
        -> TyCon        -- ^ A unique 'TyCon' object
mkTyCon str = TyCon (mkTyConKey str) str

----------------- Observation ---------------------

-- | Observe the type constructor of a type representation
typeRepTyCon :: TypeRep -> TyCon
typeRepTyCon (TypeRep _ tc _) = tc

-- | Observe the argument types of a type representation
typeRepArgs :: TypeRep -> [TypeRep]
typeRepArgs (TypeRep _ _ args) = args

-- | Observe string encoding of a type representation
tyConString :: TyCon   -> String
tyConString  (TyCon _ str) = str

----------------- Showing TypeReps --------------------

instance Show TypeRep where
  showsPrec p (TypeRep _ tycon tys) =
    case tys of
      [] -> showsPrec p tycon
      [x]   | tycon == listTc -> showChar '[' . shows x . showChar ']'
      [a,r] | tycon == funTc  -> showParen (p > 8) $
                                 showsPrec 9 a .
                                 showString " -> " .
                                 showsPrec 8 r
      xs | isTupleTyCon tycon -> showTuple xs
         | otherwise         ->
            showParen (p > 9) $
            showsPrec p tycon . 
            showChar ' '      . 
            showArgs tys

showsTypeRep :: TypeRep -> ShowS
showsTypeRep = shows

instance Show TyCon where
  showsPrec _ (TyCon _ s) = showString s

isTupleTyCon :: TyCon -> Bool
isTupleTyCon (TyCon _ ('(':',':_)) = True
isTupleTyCon _                     = False

-- Some (Show.TypeRep) helpers:

showArgs :: Show a => [a] -> ShowS
showArgs [] = id
showArgs [a] = showsPrec 10 a
showArgs (a:as) = showsPrec 10 a . showString " " . showArgs as 

showTuple :: [TypeRep] -> ShowS
showTuple args = showChar '('
               . (foldr (.) id $ intersperse (showChar ',') 
                               $ map (showsPrec 10) args)
               . showChar ')'

-------------------------------------------------------------
--
--      The Typeable class and friends
--
-------------------------------------------------------------

-- | The class 'Typeable' allows a concrete representation of a type to
-- be calculated.
class Typeable a where
  typeOf :: a -> TypeRep
  -- ^ Takes a value of type @a@ and returns a concrete representation
  -- of that type.  The /value/ of the argument should be ignored by
  -- any instance of 'Typeable', so that it is safe to pass 'undefined' as
  -- the argument.

-- | Variant for unary type constructors
class Typeable1 t where
  typeOf1 :: t a -> TypeRep

-- | For defining a 'Typeable' instance from any 'Typeable1' instance.
typeOfDefault :: (Typeable1 t, Typeable a) => t a -> TypeRep
typeOfDefault x = typeOf1 x `mkAppTy` typeOf (argType x)
 where
   argType :: t a -> a
   argType =  undefined

-- | Variant for binary type constructors
class Typeable2 t where
  typeOf2 :: t a b -> TypeRep

-- | For defining a 'Typeable1' instance from any 'Typeable2' instance.
typeOf1Default :: (Typeable2 t, Typeable a) => t a b -> TypeRep
typeOf1Default x = typeOf2 x `mkAppTy` typeOf (argType x)
 where
   argType :: t a b -> a
   argType =  undefined

-- | Variant for 3-ary type constructors
class Typeable3 t where
  typeOf3 :: t a b c -> TypeRep

-- | For defining a 'Typeable2' instance from any 'Typeable3' instance.
typeOf2Default :: (Typeable3 t, Typeable a) => t a b c -> TypeRep
typeOf2Default x = typeOf3 x `mkAppTy` typeOf (argType x)
 where
   argType :: t a b c -> a
   argType =  undefined

-- | Variant for 4-ary type constructors
class Typeable4 t where
  typeOf4 :: t a b c d -> TypeRep

-- | For defining a 'Typeable3' instance from any 'Typeable4' instance.
typeOf3Default :: (Typeable4 t, Typeable a) => t a b c d -> TypeRep
typeOf3Default x = typeOf4 x `mkAppTy` typeOf (argType x)
 where
   argType :: t a b c d -> a
   argType =  undefined

-- | Variant for 5-ary type constructors
class Typeable5 t where
  typeOf5 :: t a b c d e -> TypeRep

-- | For defining a 'Typeable4' instance from any 'Typeable5' instance.
typeOf4Default :: (Typeable5 t, Typeable a) => t a b c d e -> TypeRep
typeOf4Default x = typeOf5 x `mkAppTy` typeOf (argType x)
 where
   argType :: t a b c d e -> a
   argType =  undefined

-- | Variant for 6-ary type constructors
class Typeable6 t where
  typeOf6 :: t a b c d e f -> TypeRep

-- | For defining a 'Typeable5' instance from any 'Typeable6' instance.
typeOf5Default :: (Typeable6 t, Typeable a) => t a b c d e f -> TypeRep
typeOf5Default x = typeOf6 x `mkAppTy` typeOf (argType x)
 where
   argType :: t a b c d e f -> a
   argType =  undefined

-- | Variant for 7-ary type constructors
class Typeable7 t where
  typeOf7 :: t a b c d e f g -> TypeRep

-- | For defining a 'Typeable6' instance from any 'Typeable7' instance.
typeOf6Default :: (Typeable7 t, Typeable a) => t a b c d e f g -> TypeRep
typeOf6Default x = typeOf7 x `mkAppTy` typeOf (argType x)
 where
   argType :: t a b c d e f g -> a
   argType =  undefined

#ifdef __GLASGOW_HASKELL__
-- Given a @Typeable@/n/ instance for an /n/-ary type constructor,
-- define the instances for partial applications.
-- Programmers using non-GHC implementations must do this manually
-- for each type constructor.
-- (The INSTANCE_TYPEABLE/n/ macros in Typeable.h include this.)

-- | One Typeable instance for all Typeable1 instances
instance (Typeable1 s, Typeable a)
       => Typeable (s a) where
  typeOf = typeOfDefault

-- | One Typeable1 instance for all Typeable2 instances
instance (Typeable2 s, Typeable a)
       => Typeable1 (s a) where
  typeOf1 = typeOf1Default

-- | One Typeable2 instance for all Typeable3 instances
instance (Typeable3 s, Typeable a)
       => Typeable2 (s a) where
  typeOf2 = typeOf2Default

-- | One Typeable3 instance for all Typeable4 instances
instance (Typeable4 s, Typeable a)
       => Typeable3 (s a) where
  typeOf3 = typeOf3Default

-- | One Typeable4 instance for all Typeable5 instances
instance (Typeable5 s, Typeable a)
       => Typeable4 (s a) where
  typeOf4 = typeOf4Default

-- | One Typeable5 instance for all Typeable6 instances
instance (Typeable6 s, Typeable a)
       => Typeable5 (s a) where
  typeOf5 = typeOf5Default

-- | One Typeable6 instance for all Typeable7 instances
instance (Typeable7 s, Typeable a)
       => Typeable6 (s a) where
  typeOf6 = typeOf6Default

#endif /* __GLASGOW_HASKELL__ */

-------------------------------------------------------------
--
--              Type-safe cast
--
-------------------------------------------------------------

-- | The type-safe cast operation
cast :: (Typeable a, Typeable b) => a -> Maybe b
cast x = r
       where
         r = if typeOf x == typeOf (fromJust r)
               then Just $ unsafeCoerce x
               else Nothing

-- | A flexible variation parameterised in a type constructor
gcast :: (Typeable a, Typeable b) => c a -> Maybe (c b)
gcast x = r
 where
  r = if typeOf (getArg x) == typeOf (getArg (fromJust r))
        then Just $ unsafeCoerce x
        else Nothing
  getArg :: c x -> x 
  getArg = undefined

-- | Cast for * -> *
gcast1 :: (Typeable1 t, Typeable1 t') => c (t a) -> Maybe (c (t' a)) 
gcast1 x = r
 where
  r = if typeOf1 (getArg x) == typeOf1 (getArg (fromJust r))
       then Just $ unsafeCoerce x
       else Nothing
  getArg :: c x -> x 
  getArg = undefined

-- | Cast for * -> * -> *
gcast2 :: (Typeable2 t, Typeable2 t') => c (t a b) -> Maybe (c (t' a b)) 
gcast2 x = r
 where
  r = if typeOf2 (getArg x) == typeOf2 (getArg (fromJust r))
       then Just $ unsafeCoerce x
       else Nothing
  getArg :: c x -> x 
  getArg = undefined

-------------------------------------------------------------
--
--      Instances of the Typeable classes for Prelude types
--
-------------------------------------------------------------

INSTANCE_TYPEABLE0((),unitTc,"()")
INSTANCE_TYPEABLE1([],listTc,"[]")
INSTANCE_TYPEABLE1(Maybe,maybeTc,"Maybe")
INSTANCE_TYPEABLE1(Ratio,ratioTc,"Ratio")
INSTANCE_TYPEABLE2(Either,eitherTc,"Either")
INSTANCE_TYPEABLE2((->),funTc,"->")
INSTANCE_TYPEABLE1(IO,ioTc,"IO")

#if defined(__GLASGOW_HASKELL__) || defined(__HUGS__)
-- Types defined in GHC.IOBase
INSTANCE_TYPEABLE1(MVar,mvarTc,"MVar" )
INSTANCE_TYPEABLE0(Exception,exceptionTc,"Exception")
INSTANCE_TYPEABLE0(IOException,ioExceptionTc,"IOException")
INSTANCE_TYPEABLE0(ArithException,arithExceptionTc,"ArithException")
INSTANCE_TYPEABLE0(ArrayException,arrayExceptionTc,"ArrayException")
INSTANCE_TYPEABLE0(AsyncException,asyncExceptionTc,"AsyncException")
#endif

-- Types defined in GHC.Arr
INSTANCE_TYPEABLE2(Array,arrayTc,"Array")

#ifdef __GLASGOW_HASKELL__
-- Hugs has these too, but their Typeable<n> instances are defined
-- elsewhere to keep this module within Haskell 98.
-- This is important because every invocation of runhugs or ffihugs
-- uses this module via Data.Dynamic.
INSTANCE_TYPEABLE2(ST,stTc,"ST")
INSTANCE_TYPEABLE2(STRef,stRefTc,"STRef")
INSTANCE_TYPEABLE3(STArray,sTArrayTc,"STArray")
#endif

#ifndef __NHC__
INSTANCE_TYPEABLE2((,),pairTc,"(,)")
INSTANCE_TYPEABLE3((,,),tup3Tc,"(,,)")

tup4Tc :: TyCon
tup4Tc = mkTyCon "(,,,)"

instance Typeable4 (,,,) where
  typeOf4 tu = mkTyConApp tup4Tc []

tup5Tc :: TyCon
tup5Tc = mkTyCon "(,,,,)"

instance Typeable5 (,,,,) where
  typeOf5 tu = mkTyConApp tup5Tc []

tup6Tc :: TyCon
tup6Tc = mkTyCon "(,,,,,)"

instance Typeable6 (,,,,,) where
  typeOf6 tu = mkTyConApp tup6Tc []

tup7Tc :: TyCon
tup7Tc = mkTyCon "(,,,,,,)"

instance Typeable7 (,,,,,,) where
  typeOf7 tu = mkTyConApp tup7Tc []
#endif /* __NHC__ */

INSTANCE_TYPEABLE1(Ptr,ptrTc,"Ptr")
INSTANCE_TYPEABLE1(FunPtr,funPtrTc,"FunPtr")
INSTANCE_TYPEABLE1(ForeignPtr,foreignPtrTc,"ForeignPtr")
INSTANCE_TYPEABLE1(StablePtr,stablePtrTc,"StablePtr")
INSTANCE_TYPEABLE1(IORef,iORefTc,"IORef")

-------------------------------------------------------
--
-- Generate Typeable instances for standard datatypes
--
-------------------------------------------------------

INSTANCE_TYPEABLE0(Bool,boolTc,"Bool")
INSTANCE_TYPEABLE0(Char,charTc,"Char")
INSTANCE_TYPEABLE0(Float,floatTc,"Float")
INSTANCE_TYPEABLE0(Double,doubleTc,"Double")
INSTANCE_TYPEABLE0(Int,intTc,"Int")
#ifndef __NHC__
INSTANCE_TYPEABLE0(Word,wordTc,"Word" )
#endif
INSTANCE_TYPEABLE0(Integer,integerTc,"Integer")
INSTANCE_TYPEABLE0(Ordering,orderingTc,"Ordering")
INSTANCE_TYPEABLE0(Handle,handleTc,"Handle")

INSTANCE_TYPEABLE0(Int8,int8Tc,"Int8")
INSTANCE_TYPEABLE0(Int16,int16Tc,"Int16")
INSTANCE_TYPEABLE0(Int32,int32Tc,"Int32")
INSTANCE_TYPEABLE0(Int64,int64Tc,"Int64")

INSTANCE_TYPEABLE0(Word8,word8Tc,"Word8" )
INSTANCE_TYPEABLE0(Word16,word16Tc,"Word16")
INSTANCE_TYPEABLE0(Word32,word32Tc,"Word32")
INSTANCE_TYPEABLE0(Word64,word64Tc,"Word64")

INSTANCE_TYPEABLE0(TyCon,tyconTc,"TyCon")
INSTANCE_TYPEABLE0(TypeRep,typeRepTc,"TypeRep")

#ifdef __GLASGOW_HASKELL__
INSTANCE_TYPEABLE0(RealWorld,realWorldTc,"RealWorld")
#endif

---------------------------------------------
--
--              Internals 
--
---------------------------------------------

#ifndef __HUGS__
newtype Key = Key Int deriving( Eq )
#endif

data KeyPr = KeyPr !Key !Key deriving( Eq )

hashKP :: KeyPr -> Int32
hashKP (KeyPr (Key k1) (Key k2)) = (HT.hashInt k1 + HT.hashInt k2) `rem` HT.prime

data Cache = Cache { next_key :: !(IORef Key),  -- Not used by GHC (calls genSym instead)
                     tc_tbl   :: !(HT.HashTable String Key),
                     ap_tbl   :: !(HT.HashTable KeyPr Key) }

{-# NOINLINE cache #-}
#ifdef __GLASGOW_HASKELL__
foreign import ccall unsafe "RtsTypeable.h getOrSetTypeableStore"
    getOrSetTypeableStore :: Ptr a -> IO (Ptr a)
#endif

cache :: Cache
cache = unsafePerformIO $ do
                empty_tc_tbl <- HT.new (==) HT.hashString
                empty_ap_tbl <- HT.new (==) hashKP
                key_loc      <- newIORef (Key 1) 
                let ret = Cache {       next_key = key_loc,
                                        tc_tbl = empty_tc_tbl, 
                                        ap_tbl = empty_ap_tbl }
#ifdef __GLASGOW_HASKELL__
                block $ do
                        stable_ref <- newStablePtr ret
                        let ref = castStablePtrToPtr stable_ref
                        ref2 <- getOrSetTypeableStore ref
                        if ref==ref2
                                then deRefStablePtr stable_ref
                                else do
                                        freeStablePtr stable_ref
                                        deRefStablePtr
                                                (castPtrToStablePtr ref2)
#else
                return ret
#endif

newKey :: IORef Key -> IO Key
#ifdef __GLASGOW_HASKELL__
newKey kloc = do i <- genSym; return (Key i)
#else
newKey kloc = do { k@(Key i) <- readIORef kloc ;
                   writeIORef kloc (Key (i+1)) ;
                   return k }
#endif

#ifdef __GLASGOW_HASKELL__
foreign import ccall unsafe "genSymZh"
  genSym :: IO Int
#endif

mkTyConKey :: String -> Key
mkTyConKey str 
  = unsafePerformIO $ do
        let Cache {next_key = kloc, tc_tbl = tbl} = cache
        mb_k <- HT.lookup tbl str
        case mb_k of
          Just k  -> return k
          Nothing -> do { k <- newKey kloc ;
                          HT.insert tbl str k ;
                          return k }

appKey :: Key -> Key -> Key
appKey k1 k2
  = unsafePerformIO $ do
        let Cache {next_key = kloc, ap_tbl = tbl} = cache
        mb_k <- HT.lookup tbl kpr
        case mb_k of
          Just k  -> return k
          Nothing -> do { k <- newKey kloc ;
                          HT.insert tbl kpr k ;
                          return k }
  where
    kpr = KeyPr k1 k2

appKeys :: Key -> [Key] -> Key
appKeys k ks = foldl appKey k ks
