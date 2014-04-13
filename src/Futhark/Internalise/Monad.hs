{-# LANGUAGE TypeSynonymInstances, FlexibleInstances #-}
module Futhark.Internalise.Monad
  ( InternaliseM
  , runInternaliseM
  , ShapeTable
  , InternaliseEnv(..)
  , Replacement(..)
  , FunBinding
  , lookupFunction
  )
  where

import Control.Applicative
import Control.Monad.State  hiding (mapM)
import Control.Monad.Reader hiding (mapM)
import Control.Monad.Writer hiding (mapM)

import qualified Data.HashMap.Lazy as HM
import qualified Data.DList as DL
import Data.List

import qualified Futhark.ExternalRep as E
import Futhark.InternalRep
import Futhark.MonadFreshNames
import Futhark.Tools

import Prelude hiding (mapM)

data Replacement = ArraySubst SubExp [Ident]
                 | DirectSubst Ident
                   deriving (Show)

-- | A tuple of a return type and a list of argument types.
type FunBinding = (E.DeclType, [E.DeclType])

type ShapeTable = HM.HashMap VName [SubExp]

data InternaliseEnv = InternaliseEnv {
    envSubsts :: HM.HashMap VName [Replacement]
  , envFtable :: HM.HashMap Name FunBinding
  , envDoBoundsChecks :: Bool
  }

initialFtable :: HM.HashMap Name FunBinding
initialFtable = HM.map addBuiltin builtInFunctions
  where addBuiltin (t, ts) = (E.Elem $ E.Basic t, map (E.Elem . E.Basic) ts)

type InternaliseM =
  WriterT (DL.DList Binding) (ReaderT InternaliseEnv (State VNameSource))

instance MonadFreshNames InternaliseM where
  getNameSource = get
  putNameSource = put

instance MonadBinder InternaliseM where
  addBinding      = addBindingWriter
  collectBindings = collectBindingsWriter

runInternaliseM :: Bool -> E.Prog -> InternaliseM a -> a
runInternaliseM boundsCheck prog m = fst $ evalState (runReaderT (runWriterT m) newEnv) newState
  where newState = E.newNameSourceForProg prog
        newEnv = InternaliseEnv {
                   envSubsts = HM.empty
                 , envFtable = initialFtable `HM.union` ftable
                 , envDoBoundsChecks = boundsCheck
                 }
        ftable = HM.fromList
                 [ (fname,(rettype, map E.identType params)) |
                   (fname,rettype,params,_,_) <- E.progFunctions prog ]

lookupFunction :: Name -> InternaliseM FunBinding
lookupFunction fname = do
  fun <- HM.lookup fname <$> asks envFtable
  case fun of Nothing   -> fail $ "Function '" ++ nameToString fname ++ "' not found"
              Just fun' -> return fun'