-- Unification implementation inspired heavily by Adam Gundry's thesis.
{-# LANGUAGE GADTs #-}
module Unification where

import qualified Data.Map as M
import qualified Data.Set as S

import Control.Monad.Except

import BwdFwd
import FreshNames
import Syntax
import TypeCheckCommon

data Extension = Restore | Replace Suffix

restore :: Contextual Extension
restore = return Restore

replace :: Suffix -> Contextual Extension
replace = return . Replace

onTop :: (Id -> Decl -> Contextual Extension) -> Contextual ()
onTop f = popEntry >>= focus
  where focus :: Entry -> Contextual ()
        focus e@(FlexMVar x d) =
          do m <- f x d
             case m of
               Replace ext -> modify (<>< entrify ext)
               Restore -> modify (:< e)
        focus e = onTop f >> modify (:< e)

unify :: VType Desugared -> VType Desugared -> Contextual ()
unify (MkDTTy dt0 abs0 xs) (MkDTTy dt1 abs1 ys)
  | dt0 == dt1 = mapM (uncurry unifyAb) (zip abs0 abs1) >>
                 mapM_ (uncurry unify) (zip xs ys)
unify (MkSCTy cty0) (MkSCTy cty1) = unifyCType cty0 cty1
unify (MkRTVar a)  (MkRTVar b) | a == b = return ()
unify MkIntTy      MkIntTy           = return ()
unify MkCharTy     MkCharTy          = return ()
unify (MkFTVar a)  (MkFTVar b)       = onTop $ \c d ->
  cmp (a == c) (b == c) d
  where cmp :: Bool -> Bool -> Decl -> Contextual Extension
        cmp True  True  _           = restore
        cmp True  False Hole        = replace [(a, TyDefn (MkFTVar b))]
        cmp False True  Hole        = replace [(b, TyDefn (MkFTVar a))]
        cmp True  False (TyDefn ty) = unify ty (MkFTVar b) >> restore
        cmp False True  (TyDefn ty) = unify (MkFTVar a) ty >> restore
        cmp False False _           = unify (MkFTVar a) (MkFTVar b) >> restore
        cmp _     _     (AbDefn _)  = error "unification invariant broken"
unify (MkFTVar a)  ty                = solve a [] ty
unify ty           (MkFTVar a)       = solve a [] ty
unify t            s                 = throwError $ "failed to unify " ++
                                       (show t) ++ " with " ++ (show s)

unifyAb :: Ab Desugared -> Ab Desugared -> Contextual ()
unifyAb (MkAb (MkAbFVar a) m0) (MkAb (MkAbFVar b) m1) =
  do v <- MkAbFVar <$> freshMVar "£"
     let m = M.difference m0 m1
         m' = M.difference m1 m0
     solveForEVar a [] (MkAb v m')
     solveForEVar b [] (MkAb v m)
unifyAb (MkAb (MkAbFVar a) m0) (MkAb v m1) | M.null (M.difference m0 m1) =
  let m = M.difference m1 m0 in solveForEVar a [] (MkAb v m)
unifyAb (MkAb v m0) (MkAb (MkAbFVar a) m1) | M.null (M.difference m1 m0) =
  let m = M.difference m0 m1 in solveForEVar a [] (MkAb v m)
unifyAb (MkAb v0 m0) (MkAb v1 m1) | v0 == v1 = unifyItfMap m0 m1
unifyAb ab0 ab1 =
  throwError $ "cannot unify abilities " ++ (show ab0) ++ " and " ++
  (show ab1)

unifyItfMap :: ItfMap Desugared -> ItfMap Desugared -> Contextual ()
unifyItfMap m0 m1 = do mapM_ (unifyItfMap' m1) (M.toList m0)
                       mapM_ (unifyItfMap' m0) (M.toList m1)
  where unifyItfMap' :: ItfMap Desugared -> (Id,[VType Desugared]) ->
                        Contextual ()
        unifyItfMap' m (itf,xs) = case M.lookup itf m of
          Nothing -> throwError $ "failed to unify abilities " ++ (show m0) ++
                     " and " ++ (show m1)
          Just ys -> mapM_ (uncurry unify) (zip xs ys)

unifyAdj :: Adj Desugared -> Adj Desugared -> Contextual ()
unifyAdj (MkAdj m0) (MkAdj m1) = unifyItfMap m0 m1

unifyCType :: CType Desugared -> CType Desugared -> Contextual ()
unifyCType (MkCType xs p0) (MkCType ys p1) =
  mapM (uncurry unifyPort) (zip xs ys) >> unifyPeg p0 p1

unifyPeg :: Peg Desugared -> Peg Desugared -> Contextual ()
unifyPeg (MkPeg ab0 ty0) (MkPeg ab1 ty1) = unifyAb ab0 ab1 >> unify ty0 ty1

unifyPort :: Port Desugared -> Port Desugared -> Contextual ()
unifyPort (MkPort adj0 ty0) (MkPort adj1 ty1) = unifyAdj adj0 adj1 >>
                                                unify ty0 ty1

solve :: Id -> Suffix -> VType Desugared -> Contextual ()
solve a ext ty = onTop $ \b d ->
  case ((a == b), (S.member b (fmv ty)), d) of
    (_, _, TyDefn bty) -> modify (<>< entrify ext) >>
                          unify (subst bty b (MkFTVar a)) (subst bty b ty) >>
                          restore
    (True, True, Hole) -> throwError "solve: occurs check failure"
    (True, False, Hole) -> replace (ext ++ [(a, TyDefn ty)])
    (False, True, _) -> solve a ((b,d):ext) ty >> replace []
    (False, False, _) -> solve a ext ty >> restore
    (_, _, AbDefn _) ->
      error "solve invariant broken: reached impossible case"

solveForEVar :: Id -> Suffix -> Ab Desugared -> Contextual ()
solveForEVar a ext ab = onTop $ \b d ->
  case (a == b, (S.member b (fmvAb ab)), d) of
    (_, _, AbDefn ab') ->
      let vab = MkAb (MkAbFVar a) M.empty in
      modify (<>< entrify ext) >>
      unifyAb (substEVarAb ab' b vab) (substEVarAb ab' b ab) >>
      restore
    (True, True, Hole) -> throwError "solveForEvar: occurs check failure"
    (True, False, Hole) -> replace (ext ++ [(a, AbDefn ab)])
    (False, True, _) -> solveForEVar a ((b,d):ext) ab >> replace []
    (False, False, _) -> solveForEVar a ext ab >> restore
    (_, _, TyDefn _) ->
      error "solveForEVar invariant broken: reached impossible case"

subst :: VType Desugared -> Id -> VType Desugared -> VType Desugared
subst ty x (MkDTTy dt abs xs) =
  MkDTTy dt (map (substAb ty x) abs) (map (subst ty x) xs)
subst ty x (MkSCTy cty) = MkSCTy $ substCType ty x cty
subst ty x (MkFTVar y) | x == y = ty
subst _ _ ty = ty

substAb :: VType Desugared -> Id -> Ab Desugared -> Ab Desugared
substAb ty x (MkAb v m) = MkAb v (M.map (map (subst ty x)) m)

substAdj :: VType Desugared -> Id -> Adj Desugared -> Adj Desugared
substAdj ty x (MkAdj m) = MkAdj (M.map (map (subst ty x)) m)

substCType :: VType Desugared -> Id -> CType Desugared -> CType Desugared
substCType ty x (MkCType ps peg) =
  MkCType (map (substPort ty x) ps) (substPeg ty x peg)

substPeg :: VType Desugared -> Id -> Peg Desugared -> Peg Desugared
substPeg ty x (MkPeg ab pty) = MkPeg (substAb ty x ab) (subst ty x pty)

substPort :: VType Desugared -> Id -> Port Desugared -> Port Desugared
substPort ty x (MkPort adj pty) = MkPort (substAdj ty x adj) (subst ty x pty)

substEVar :: Ab Desugared -> Id -> VType Desugared -> VType Desugared
substEVar ab x (MkDTTy dt abs xs) =
  MkDTTy dt (map (substEVarAb ab x) abs) (map (substEVar ab x) xs)
substEVar ab x (MkSCTy cty) = MkSCTy $ substEVarCType ab x cty
substEVar _ _ ty = ty

substEVarAb :: Ab Desugared -> Id -> Ab Desugared -> Ab Desugared
substEVarAb ab@(MkAb v m') x (MkAb (MkAbFVar y) m) | x == y =
  MkAb v (M.union (M.map (map (substEVar ab x)) m) m')
substEVarAb ab x (MkAb v m) = MkAb v (M.map (map (substEVar ab x)) m)

substEVarAdj :: Ab Desugared -> Id -> Adj Desugared -> Adj Desugared
substEVarAdj ab x (MkAdj m) = MkAdj (M.map (map (substEVar ab x)) m)

substEVarCType :: Ab Desugared -> Id -> CType Desugared -> CType Desugared
substEVarCType ab x (MkCType ps peg) =
  MkCType (map (substEVarPort ab x) ps) (substEVarPeg ab x peg)

substEVarPeg :: Ab Desugared -> Id -> Peg Desugared -> Peg Desugared
substEVarPeg ab' x (MkPeg ab pty) =
  MkPeg (substEVarAb ab' x ab) (substEVar ab' x pty)

substEVarPort :: Ab Desugared -> Id -> Port Desugared -> Port Desugared
substEVarPort ab x (MkPort adj pty) =
  MkPort (substEVarAdj ab x adj) (substEVar ab x pty)
