{-# LANGUAGE FlexibleContexts #-}
module Futhark.Internalise.Bindings
  (
  -- * Internalising bindings
    bindingParams
  , bindingLambdaParams
  , stmPattern
  , MatchPattern
  )
  where

import Control.Monad.State  hiding (mapM)
import Control.Monad.Reader hiding (mapM)
import Control.Monad.Writer hiding (mapM)

import qualified Data.Map.Strict as M
import Data.List
import Data.Loc
import Data.Traversable (mapM)

import Language.Futhark as E
import qualified Futhark.Representation.SOACS as I
import Futhark.MonadFreshNames

import Futhark.Internalise.Monad
import Futhark.Internalise.TypesValues
import Futhark.Internalise.AccurateSizes
import Futhark.Util

bindingParams :: [E.TypeParam] -> [E.Pattern]
              -> (ConstParams -> [I.FParam] -> [[I.FParam]] -> InternaliseM a)
              -> InternaliseM a
bindingParams tparams params m = do
  flattened_params <- mapM flattenPattern params
  let (params_idents, params_ascripts, params_types) = unzip3 $ concat flattened_params
      bound = boundInTypes tparams $ params_types ++ concat params_ascripts
  (params_ts, shape_ctx, cm) <- internaliseParamTypes bound params_types
  let num_param_idents = map length flattened_params
      num_param_ts = map (sum . map length) $ chunks num_param_idents params_ts
  (shape_ctx', shapesubst) <- makeShapeIdentsFromContext shape_ctx

  (params_ts', unnamed_shape_params, ascriptsubsts) <-
    fmap unzip3 $ forM (zip params_ts params_ascripts) $ \(param_ts, param_ascripts) -> do
      (param_ts', param_unnamed_dims) <- instantiateShapesWithDecls shape_ctx' param_ts

      -- Context does not matter for the ascription - we just want the
      -- names so we can map them to the actually bound names from
      -- param_ts'.
      (ascripted_ts, ascript_ctx, _) <- internaliseParamTypes bound param_ascripts
      let ascript_ctx_rev = M.fromList $ map (uncurry $ flip (,)) $ M.toList ascript_ctx
      return (param_ts', param_unnamed_dims,
              M.map pure $ mconcat $ zipWith (forwardDims ascript_ctx_rev) param_ts' $
              transpose ascripted_ts)

  let named_shape_params = map nonuniqueParamFromIdent (M.elems shape_ctx')
      shape_params = named_shape_params ++ concat unnamed_shape_params
  bindingFlatPattern params_idents (concat params_ts') $ \valueparams ->
    bindingIdentTypes (map I.paramIdent $ shape_params++concat valueparams) $
    substitutingVars (mconcat ascriptsubsts `M.union` shapesubst) $
    m cm shape_params $ chunks num_param_ts (concat valueparams)

    where forwardDims ctx ref =
            mconcat . map (mconcat . zipWith (forwardDim ctx) (I.arrayDims ref) .
                            I.extShapeDims . I.arrayShape)
          forwardDim ctx d (I.Ext i) | Just v <- M.lookup i ctx,
                                       I.Var v /= d = M.singleton v d
          forwardDim _ _ _ = M.empty

bindingLambdaParams :: [E.TypeParam] ->[E.Pattern] -> [I.Type]
                    -> (ConstParams -> [I.LParam] -> InternaliseM a)
                    -> InternaliseM a
bindingLambdaParams tparams params ts m = do
  (params_idents, params_ascripts, params_types) <-
    unzip3 . concat <$> mapM flattenPattern params
  let bound = boundInTypes tparams $ params_types ++ concat params_ascripts
  (params_ts, _, cm) <- internaliseParamTypes bound params_types

  let ts_for_ps = typesForParams params_ts ts

  ascript_substs <- fmap mconcat . forM (zip params_ascripts ts_for_ps) $ \(ascript, p_t) -> do
    (ascript_ts, shape_ctx, _) <- internaliseParamTypes bound ascript
    return $ lambdaShapeSubstitutions shape_ctx (concat ascript_ts)
      (concat (replicate (length ascript) p_t))

  bindingFlatPattern params_idents ts $ \params' ->
    local (\env -> env { envSubsts = ascript_substs `M.union` envSubsts env }) $
    bindingIdentTypes (map I.paramIdent $ concat params') $ m cm $ concat params'

  where typesForParams (p:ps) ts' = let (p_ts, ts'') = splitAt (length p) ts'
                                    in p_ts : typesForParams ps ts''
        typesForParams []     _  = []

processFlatPattern :: [E.Ident] -> [t]
                   -> InternaliseM ([[I.Param t]], VarSubstitutions)
processFlatPattern = processFlatPattern' []
  where
    processFlatPattern' pat []       _  = do
      let (vs, substs) = unzip pat
          substs' = M.fromList substs
          idents = reverse vs
      return (idents, substs')

    processFlatPattern' pat (p:rest) ts = do
      (ps, subst, rest_ts) <- handleMapping ts <$> internaliseBindee p
      processFlatPattern' ((ps, (E.identName p, map (I.Var . I.paramName) subst)) : pat) rest rest_ts

    handleMapping ts [] =
      ([], [], ts)
    handleMapping ts (r:rs) =
        let (ps, reps, ts')    = handleMapping' ts r
            (pss, repss, ts'') = handleMapping ts' rs
        in (ps++pss, reps:repss, ts'')

    handleMapping' (t:ts) (vname,_) =
      let v' = I.Param vname t
      in ([v'], v', ts)
    handleMapping' [] _ =
      error "processFlatPattern: insufficient identifiers in pattern."

    internaliseBindee :: E.Ident -> InternaliseM [(VName, I.DeclExtType)]
    internaliseBindee bindee = do
      -- XXX: we gotta be screwing up somehow by ignoring the extra
      -- return values.  If not, why not?
      (tss, _, _) <- internaliseParamTypes nothing_bound
                     [flip E.setAliases () $ E.vacuousShapeAnnotations $
                      E.unInfo $ E.identType bindee]
      forM (concat tss) $ \t -> do
        name <- newVName base
        return (name, t)
          where base = nameToString $ baseName $ E.identName bindee

    -- Fixed up later.
    nothing_bound = boundInTypes [] []

bindingFlatPattern :: [E.Ident] -> [t]
                   -> ([[I.Param t]] -> InternaliseM a)
                   -> InternaliseM a
bindingFlatPattern idents ts m = do
  (ps, substs) <- processFlatPattern idents ts
  local (\env -> env { envSubsts = substs `M.union` envSubsts env}) $
    m ps

-- | Flatten a pattern.  Returns a list of identifiers.  Each
-- identifier is also associated with a (possibly empty) list of types
-- that indicate type ascriptions.  These are important for retaining
-- shape declarations.  The structural type of each identifier is also
-- returned separately.
flattenPattern :: MonadFreshNames m => E.Pattern -> m [(E.Ident, [E.StructType], E.StructType)]
flattenPattern = flattenPattern' []
  where flattenPattern' ts (E.PatternParens p _) =
          flattenPattern' ts p
        flattenPattern' ts (E.Wildcard t loc) = do
          name <- newVName "nameless"
          return [(E.Ident name t loc, ts,
                   case ts of [] -> E.vacuousShapeAnnotations $ toStruct $ unInfo t
                              st:_ -> st)]
        flattenPattern' ts (E.Id v) =
          return [(v, ts,
                   case ts of [] -> E.vacuousShapeAnnotations $ toStruct $ unInfo $ identType v
                              st:_ -> st)]
        flattenPattern' ts (E.TuplePattern pats _) =
          concat <$> zipWithM flattenPattern' (tupleComponents ts ++ repeat []) pats
        flattenPattern' ts (E.RecordPattern fs loc) =
          flattenPattern' ts $ E.TuplePattern (map snd $ sortFields $ M.fromList fs) loc
        flattenPattern' ts (E.PatternAscription p td) =
          flattenPattern' (unInfo (expandedType td):ts) p

        tupleComponents = transpose . map tupleComponents'
        tupleComponents' (E.Record ts) = map snd $ sortFields ts
        tupleComponents' t             = [t]

type MatchPattern = SrcLoc -> [I.SubExp] -> InternaliseM [I.SubExp]

stmPattern :: [E.TypeParam] -> E.Pattern -> [I.ExtType]
               -> (ConstParams -> [VName] -> MatchPattern -> InternaliseM a)
               -> InternaliseM a
stmPattern tparams pat ts m = do
  (pat', _, pat_types) <- unzip3 <$> flattenPattern pat
  (ts',_) <- instantiateShapes' ts
  (pat_types', ctx, cm) <- internaliseParamTypes (boundInTypes tparams pat_types) pat_types
  let ctx_rev = M.fromList $ map (uncurry $ flip (,)) $ M.toList ctx
      pat_types'' = map I.fromDecl $ concat pat_types'
  let addShapeStms l =
        m cm (map I.paramName $ concat l) (matchPattern ctx_rev pat_types'')
  bindingFlatPattern pat' ts' addShapeStms

matchPattern :: M.Map Int VName -> [I.ExtType] -> MatchPattern
matchPattern ctx exts loc ses =
  forM (zip exts ses) $ \(et, se) -> do
  se_t <- I.subExpType se
  et' <- unExistentialise ctx et se_t
  ensureExtShape asserting "value cannot match pattern"
    loc et' "correct_shape" se

unExistentialise :: M.Map Int VName -> I.ExtType -> I.Type -> InternaliseM I.ExtType
unExistentialise substs et t = do
  new_dims <- zipWithM inspectDim (I.extShapeDims $ I.arrayShape et) (I.arrayDims t)
  return $ t `I.setArrayShape` I.ExtShape new_dims
  where inspectDim (I.Ext i) d | Just v <- M.lookup i substs = do
          letBindNames'_ [v] $ I.BasicOp $ I.SubExp d
          return $ I.Free $ I.Var v
        inspectDim ed _ = return ed

makeShapeIdentsFromContext :: MonadFreshNames m =>
                              M.Map VName Int
                           -> m (M.Map Int I.Ident,
                                 VarSubstitutions)
makeShapeIdentsFromContext ctx = do
  (ctx', substs) <- fmap unzip $ forM (M.toList ctx) $ \(name, i) -> do
    v <- newIdent (baseString name) $ I.Prim I.int32
    return ((i, v), (name, [I.Var $ I.identName v]))
  return (M.fromList ctx', M.fromList substs)

instantiateShapesWithDecls :: MonadFreshNames m =>
                              M.Map Int I.Ident
                           -> [I.DeclExtType]
                           -> m ([I.DeclType], [I.FParam])
instantiateShapesWithDecls ctx ts =
  runWriterT $ instantiateShapes instantiate ts
  where instantiate x
          | Just v <- M.lookup x ctx =
            return $ I.Var $ I.identName v

          | otherwise = do
            v <- lift $ nonuniqueParamFromIdent <$> newIdent "size" (I.Prim I.int32)
            tell [v]
            return $ I.Var $ I.paramName v

lambdaShapeSubstitutions :: M.Map VName Int
                         -> [I.TypeBase I.ExtShape Uniqueness]
                         -> [I.Type]
                         -> VarSubstitutions
lambdaShapeSubstitutions shape_ctx param_ts ts =
  mconcat $ zipWith matchTypes param_ts ts
  where ctx_to_names = M.fromList $ map (uncurry $ flip (,)) $ M.toList shape_ctx

        matchTypes pt t =
          mconcat $ zipWith matchDims (I.extShapeDims $ I.arrayShape pt) (I.arrayDims t)
        matchDims (I.Ext i) d
          | Just v <- M.lookup i ctx_to_names = M.singleton v [d]
        matchDims _ _ =
          mempty

nonuniqueParamFromIdent :: I.Ident -> I.FParam
nonuniqueParamFromIdent (I.Ident name t) =
  I.Param name $ I.toDecl t Nonunique
