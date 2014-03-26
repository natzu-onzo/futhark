-- | This module implements facilities for determining whether a
-- reduction or fold can be expressed in a closed form (i.e. not as a
-- SOAC).
--
-- Right now, the module can detect only trivial cases.  In the
-- future, we would like to make it more powerful, as well as possibly
-- also being able to analyse sequential loops.
module L0C.EnablingOpts.ClosedForm
  ( foldConstantForm
  , foldClosedForm
  )
where

import Control.Applicative
import Control.Monad

import Data.Maybe
import qualified Data.HashMap.Lazy as HM
import qualified Data.HashSet as HS
import Data.List

import L0C.InternalRep
import L0C.Tools

-- | A function that, given a variable name, returns its definition.
-- XXX: This duplicates something in L0C.EnablingOpts.Simplification.
type VarLookup = VName -> Maybe Exp

-- | If a fold only uses its accumulator parameters and does not
-- change them, it can be converted to a constant form.
foldConstantForm :: Lambda -> [SubExp] -> Maybe [SubExp]
foldConstantForm lam accs =
  zipWithM isConstResult resultSubExps $ zip (lambdaParams lam) accs
  where (_, resultSubExps, _) = bodyResult $ lambdaBody lam
        free = freeNamesInBody (lambdaBody lam) `HS.difference`
               HS.fromList (map identName $ lambdaParams lam)
        isConstResult res (p, acc) =
          case res of Constant {}                          -> Just res
                      Var v | identName v == identName p   -> Just acc
                            | identName v `HS.member` free -> Just res
                      _                                    -> Nothing

{-
Motivation:

  let {*[int,x_size_27] map_computed_shape_1286} = replicate(x_size_27,
                                                             all_equal_shape_1044) in
  let {*[bool,x_size_27] map_size_checks_1292} = replicate(x_size_27, x_1291) in
  let {bool all_equal_checked_1298, int all_equal_shape_1299} =
    reduceT(fn {bool, int} (bool bacc_1293, int nacc_1294, bool belm_1295,
                            int nelm_1296) =>
              let {bool tuplit_elems_1297} = bacc_1293 && belm_1295 in
              {tuplit_elems_1297, nelm_1296},
            {True, 0}, map_size_checks_1292, map_computed_shape_1286)
-}

-- | @foldClosedForm look foldfun accargs arrargs@ determines whether
-- each of the results of @foldfun@ can be expressed in a closed form.
foldClosedForm :: VarLookup -> [Ident] -> Lambda -> [SubExp] -> [SubExp]
               -> Maybe [Binding]
foldClosedForm look pat lam accs arrs = do
  xs <- allAreReplicate arrs
  concat <$> zipWithM (checkResult xs) (zip pat resultSubExps) (zip accparams accs)
  where (_, resultSubExps, _) = bodyResult $ lambdaBody lam
        bndMap = makeBindMap $ lambdaBody lam
        (accparams, arrparams) = splitAt (length accs) $ lambdaParams lam

        checkResult _ (p, Constant val loc) _ =
          Just [LetBind [p] $ subExp $ Constant val loc]
        checkResult arrelems (p, Var v) _
          | Just e <- v `isArrayElem` arrelems =
          -- FIXME need branch here
          Just [LetBind [p] $ subExp e]
        checkResult arrelems (p, Var v) (accparam, acc) = do
          e@(BinOp bop (Var x) (Var y) rt loc) <- HM.lookup v bndMap
          -- One of x,y must be *this* accumulator, and the other must
          -- be an array input.
          el <- x `isArrayElem` arrelems <|> y `isArrayElem` arrelems
          let isThisAccum = (==fromParam accparam)
          if isThisAccum x || isThisAccum y then
            case bop of
              LogAnd -> -- FIXME need branch here
                Just [LetBind [v] e,
                      LetBind [p] $ BinOp LogAnd acc el rt loc]
              _ -> Nothing -- Um... sorry.
          else Nothing

        isArrayElem :: Ident -> [SubExp] -> Maybe SubExp
        isArrayElem v arrelems =
          snd <$> find ((==identName v) . identName . fst)
                       (zip arrparams arrelems)

        allAreReplicate = mapM isReplicate
        isReplicate (Var v)
          | Just (Replicate _ ve _) <- look $ identName v = Just ve
        isReplicate _       = Nothing

makeBindMap :: Body -> HM.HashMap Ident Exp
makeBindMap = HM.fromList . mapMaybe isSingletonBinding . bodyBindings
  where isSingletonBinding (LetBind [v] e) = Just (v,e)
        isSingletonBinding _               = Nothing